<#
.SYNOPSIS
  Citrix DaaS Autoscale Schedule — Azure Automation Runbook
.DESCRIPTION
  Pulls hourly machine usage from the Citrix DaaS REST API for all Delivery
  Groups and applies it as Autoscale schedules (PoolSizeSchedule + PeakTimeRanges).
  Credentials are read from Automation Variables — no parameters required.
#>

# ── Credentials from Automation Variables ────────────────────────────────────
$CustomerId   = Get-AutomationVariable -Name 'CitrixCustomerId'
$ClientId     = Get-AutomationVariable -Name 'CitrixClientId'
$ClientSecret = Get-AutomationVariable -Name 'CitrixClientSecret'

# ── Configuration ─────────────────────────────────────────────────────────────
$Filter           = "*"   # All DGs — change to e.g. "*Windows11MS*" to narrow scope
$PeakThresholdPct = 70    # Hours at/above this % of peak avg are classified as Peak
$MinMachines      = 2     # Minimum machines on during off-peak
$PeakBuffer       = 10    # Peak capacity buffer %
$OffPeakBuffer    = 5     # Off-peak capacity buffer %

$ErrorActionPreference = "Stop"

# ── Authenticate ──────────────────────────────────────────────────────────────
Write-Output "Authenticating to Citrix Cloud..."
$tok = (Invoke-RestMethod -Method Post `
  -Uri "https://api.cloud.com/cctrustoauth2/$CustomerId/tokens/clients" `
  -Body @{ grant_type="client_credentials"; client_id=$ClientId; client_secret=$ClientSecret }
).access_token

# ── Resolve Site ID ───────────────────────────────────────────────────────────
Write-Output "Resolving Site ID..."
$h0     = @{ Authorization="CwsAuth Bearer=$tok"; "Citrix-CustomerId"=$CustomerId }
$me     = Invoke-RestMethod -Uri "https://api.cloud.com/cvad/manage/me" -Headers $h0
$siteId = ($me.Customers | Where-Object { $_.Id -eq $CustomerId }).Sites[0].Id
if (-not $siteId) { throw "Could not resolve Site ID for customer: $CustomerId" }
Write-Output "  Site ID: $siteId"

$hdrs = @{
  Authorization        = "CwsAuth Bearer=$tok"
  "Citrix-CustomerId"  = $CustomerId
  "Citrix-InstanceId"  = $siteId
  "Content-Type"       = "application/json"
}
$base = "https://api.cloud.com/cvad/manage"

# ── Enumerate Delivery Groups (paginated, deduplicated) ───────────────────────
Write-Output "Discovering Delivery Groups (filter: $Filter)..."
$seenIds = @{}
$allDGs  = [Collections.Generic.List[object]]::new()
$dgUri   = "$base/DeliveryGroups?limit=100"
do {
  $pg = Invoke-RestMethod -Uri $dgUri -Headers $hdrs
  if ($pg.Items) {
    foreach ($item in $pg.Items) {
      if (-not $seenIds.ContainsKey($item.Id)) {
        $seenIds[$item.Id] = $true
        $allDGs.Add($item)
      }
    }
  }
  if ($pg.ContinuationToken) {
    $dgUri = "$base/DeliveryGroups?limit=100&continuationToken=$($pg.ContinuationToken)"
  } else { $dgUri = $null }
} while ($dgUri)

$targetDGs = $allDGs | Where-Object { $_.Name -like $Filter }
Write-Output "  Found $($allDGs.Count) unique DGs, $($targetDGs.Count) match filter."
if ($targetDGs.Count -eq 0) { throw "No DGs matched filter [$Filter]." }

$summary = [Collections.Generic.List[object]]::new()

# ── Helper: HH:MM string for a given hour (24 = 00:00 end-of-day) ────────────
function Format-Hour {
  param([int]$h)
  if ($h -ge 24) { return "00:00" }
  return ([string]$h).PadLeft(2,'0') + ":00"
}

# ── Helper: build a compact JSON time-range array string ─────────────────────
# For PeakTimeRanges (bool array) — only emit ranges where value is $true
# For PoolSizeSchedule (int array) — emit all ranges with PoolSize, split only on value change
function Build-TimeRangeJson {
  param([array]$Values, [bool]$IsBool)
  $segments = [Collections.Generic.List[string]]::new()
  $segStart = 0
  $cur      = $Values[0]
  for ($h = 1; $h -le 24; $h++) {
    $next     = if ($h -lt 24) { $Values[$h] } else { $null }
    $boundary = ($h -eq 24) -or ($next -ne $cur)
    if ($boundary) {
      $s = Format-Hour $segStart
      $e = Format-Hour $h
      if ($IsBool) {
        if ($cur) { $segments.Add('{"TimeRange":"' + $s + '-' + $e + '"}') }
      } else {
        $segments.Add('{"TimeRange":"' + $s + '-' + $e + '","PoolSize":' + [int]$cur + '}')
      }
      $segStart = $h
      $cur      = $next
    }
  }
  return '[' + ($segments -join ',') + ']'
}

# ── Process each DG ───────────────────────────────────────────────────────────
foreach ($dg in $targetDGs) {
  Write-Output ""
  Write-Output "Processing: $($dg.Name)"

  # Pull Usage data
  try {
    $usage = (Invoke-RestMethod -Uri "$base/DeliveryGroups/$($dg.Id)/Usage" -Headers $hdrs).Items
  } catch {
    Write-Warning "  Could not retrieve usage data: $($_.Exception.Message)"
    continue
  }

  if (-not $usage -or $usage.Count -eq 0) {
    Write-Output "  No usage data — skipping."
    continue
  }
  Write-Output "  $($usage.Count) hourly records retrieved."

  # Average by DayOfWeek + Hour
  $sums = @{}; $counts = @{}
  foreach ($entry in $usage) {
    $ts  = [datetime]$entry.Time
    $key = "$($ts.DayOfWeek.value__)_$($ts.Hour)"
    if (-not $sums[$key])   { $sums[$key]   = 0 }
    if (-not $counts[$key]) { $counts[$key] = 0 }
    $sums[$key]   += [int]$entry.Usage
    $counts[$key] += 1
  }

  $avg = @{}
  for ($d = 0; $d -le 6; $d++) {
    $avg[$d] = @{}
    for ($h = 0; $h -le 23; $h++) {
      $key        = "${d}_${h}"
      $avg[$d][$h] = if ($counts[$key]) { [math]::Ceiling($sums[$key] / $counts[$key]) } else { $MinMachines }
    }
  }

  $allAvgs   = for ($d = 0; $d -le 6; $d++) { for ($h = 0; $h -le 23; $h++) { $avg[$d][$h] } }
  $maxAvg    = ($allAvgs | Measure-Object -Maximum).Maximum
  $threshold = [math]::Ceiling($maxAvg * $PeakThresholdPct / 100)
  Write-Output "  Peak avg: $maxAvg machines | Threshold: $threshold ($PeakThresholdPct%)"

  # Build Weekdays and Weekend scheme arrays
  $schemes = @(
    @{ Label='Weekdays'; DayNums=@(1,2,3,4,5); MatchDay='Monday'   },
    @{ Label='Weekend';  DayNums=@(6,0);        MatchDay='Saturday' }
  )

  foreach ($scheme in $schemes) {
    $peakHours = [bool[]]::new(24)
    $poolSize  = [int[]]::new(24)
    for ($h = 0; $h -le 23; $h++) {
      $vals    = $scheme.DayNums | ForEach-Object { $avg[$_][$h] }
      $slotAvg = [math]::Ceiling(($vals | Measure-Object -Average).Average)
      $bufPct  = if ($slotAvg -ge $threshold) { $PeakBuffer } else { $OffPeakBuffer }
      $pool    = [math]::Max($MinMachines, [math]::Floor($slotAvg * (1 - $bufPct / 100)))
      $poolSize[$h]  = $pool
      $peakHours[$h] = ($slotAvg -ge $threshold)
    }
    $scheme.PeakHours = $peakHours
    $scheme.PoolSize  = $poolSize

    $peakRanges = @(); $inPeak = $false; $peakStart = 0
    for ($h = 0; $h -le 24; $h++) {
      if ($h -lt 24 -and $peakHours[$h] -and -not $inPeak) { $inPeak = $true; $peakStart = $h }
      elseif (($h -eq 24 -or -not $peakHours[$h]) -and $inPeak) {
        $peakRanges += "$($peakStart):00-$($h):00"; $inPeak = $false
      }
    }
    $peakStr = if ($peakRanges) { $peakRanges -join ', ' } else { 'No peak hours' }
    $poolMin = ($poolSize | Measure-Object -Minimum).Minimum
    $poolMax = ($poolSize | Measure-Object -Maximum).Maximum
    Write-Output "  $($scheme.Label.PadRight(10)) Pool: $poolMin-$poolMax | Peak: $peakStr"
  }

  # Get existing PowerTimeSchemes
  $pts = (Invoke-RestMethod -Uri "$base/DeliveryGroups/$($dg.Id)/PowerTimeSchemes" -Headers $hdrs).Items
  if (-not $pts) {
    Write-Warning "  No PowerTimeSchemes found — skipping."
    continue
  }

  # Enable Autoscale + set buffers
  $dgBody = @{
    AutoscalingEnabled       = $true
    PeakBufferSizePercent    = $PeakBuffer
    OffPeakBufferSizePercent = $OffPeakBuffer
  } | ConvertTo-Json
  Invoke-RestMethod -Method Patch -Uri "$base/DeliveryGroups/$($dg.Id)" -Headers $hdrs -Body $dgBody | Out-Null
  Write-Output "  Autoscale enabled."

  # Apply each scheme
  $applied = 0
  foreach ($scheme in $schemes) {
    $match = $pts | Where-Object { $_.DaysOfWeek -contains $scheme.MatchDay }
    if (-not $match) {
      Write-Warning "  No scheme found containing $($scheme.MatchDay) — skipping."
      continue
    }

    # PeakHours = 24-element boolean array (API accepts this)
    # PeakTimeRanges = rejected by API when non-empty, so don't send it
    # PoolSizeSchedule = time range format (required, array format accepted)
    $peakHoursJson = '[' + (($scheme.PeakHours | ForEach-Object { if ($_) { 'true' } else { 'false' } }) -join ',') + ']'
    $poolJson      = Build-TimeRangeJson -Values $scheme.PoolSize -IsBool $false
    $schemeBody    = '{"PeakHours":' + $peakHoursJson + ',"PoolSizeSchedule":' + $poolJson + '}'

    Write-Output "  DEBUG $($scheme.Label): $schemeBody"

    try {
      Invoke-RestMethod -Method Patch `
        -Uri "$base/DeliveryGroups/$($dg.Id)/PowerTimeSchemes/$($match.Id)" `
        -Headers $hdrs -Body $schemeBody | Out-Null
      Write-Output "  $($scheme.Label): applied."
      $applied++
    } catch {
      Write-Warning "  $($scheme.Label): FAILED — $($_.Exception.Message)"
    }
  }

  $summary.Add([PSCustomObject]@{
    DG             = $dg.Name
    PeakMachines   = $maxAvg
    Threshold      = $threshold
    SchemesApplied = $applied
    Status         = if ($applied -gt 0) { 'Applied' } else { 'Failed' }
  })
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Output ""
Write-Output "== Summary =="
$summary | ForEach-Object {
  Write-Output "$($_.DG) | Peak: $($_.PeakMachines) | Threshold: $($_.Threshold) | Schemes: $($_.SchemesApplied) | $($_.Status)"
}
Write-Output "Done."
