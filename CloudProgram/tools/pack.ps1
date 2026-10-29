<#
.SYNOPSIS
  Pack every cloud function into CloudProgram/dist/<fn>.zip for manual upload to AGC.

.DESCRIPTION
  Each zip contains: index.js, package.json, function-config.json,
  node_modules/ (with @hw-agconnect/cloud-server and _zupu_shared),
  and agconnect-credential.json when present.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File CloudProgram/tools/pack.ps1
#>
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cloudProgram = Split-Path -Parent $here
$fnRoot = Join-Path $cloudProgram 'cloudfunctions'
$dist = Join-Path $cloudProgram 'dist'

if (-not (Test-Path -Path $dist)) {
  New-Item -ItemType Directory -Path $dist -Force | Out-Null
}

$dirs = Get-ChildItem -Path $fnRoot -Directory | Where-Object { $_.Name -ne '_shared' }
$ok = 0
$fail = @()
foreach ($d in $dirs) {
  $zipPath = Join-Path $dist ($d.Name + '.zip')
  if (Test-Path -Path $zipPath) { Remove-Item -Path $zipPath -Force }

  $files = @('index.js', 'package.json', 'function-config.json', 'node_modules')
  if (Test-Path -Path (Join-Path $d.FullName 'agconnect-credential.json')) {
    $files += 'agconnect-credential.json'
  }

  Push-Location $d.FullName
  & tar.exe -a -c -f $zipPath @files 2>&1 | Out-Null
  $code = $LASTEXITCODE
  Pop-Location

  if ($code -eq 0 -and (Test-Path -Path $zipPath)) {
    $ok++
  } else {
    $fail += $d.Name
  }
}

Write-Host ("packed: " + $ok + " / " + $dirs.Count)
if ($fail.Count -gt 0) {
  Write-Host ("failed: " + ($fail -join ', '))
  exit 1
}

$total = (Get-ChildItem -Path $dist -Filter *.zip | Measure-Object -Property Length -Sum).Sum
Write-Host ("total size: " + [math]::Round($total / 1MB, 1) + " MB")
