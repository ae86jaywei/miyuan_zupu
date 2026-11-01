<#
.SYNOPSIS
  Batch update every cloud function's function-config.json to bind the shared layer.
  No version specified, so functions always use the layer's latest version.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File CloudProgram/tools/batch-update-function-config.ps1
#>
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cloudProgram = Split-Path -Parent $here
$fnRoot = Join-Path $cloudProgram 'cloudfunctions'

$layerName = 'zupu-shared-layer'

$targets = Get-ChildItem -Path $fnRoot -Directory | Where-Object { $_.Name -ne '_shared' }
$ok = 0
$fail = @()
foreach ($fn in $targets) {
    $cfgPath = Join-Path $fn.FullName 'function-config.json'
    if (Test-Path $cfgPath) {
        $obj = Get-Content $cfgPath -Raw | ConvertFrom-Json
        # bind the shared layer; no version -> always use the latest
        $obj | Add-Member -MemberType NoteProperty -Name 'layers' -Value @(
            @{ layerName = $layerName }
        ) -Force
        $obj | ConvertTo-Json -Depth 10 | Out-File $cfgPath -Encoding utf8
        Write-Host "updated: $($fn.Name)/function-config.json"
        $ok++
    }
    else {
        Write-Host "missing: $($fn.Name)/function-config.json"
        $fail += $fn.Name
    }
}
Write-Host "`ndone, $ok updated, $($fail.Count) missing"
if ($fail.Count -gt 0) {
    Write-Host "missing files in: $($fail -join ', ')"
}
Write-Host 'Please review the changes and commit to git.'
