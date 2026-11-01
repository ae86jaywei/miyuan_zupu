<#
.SYNOPSIS
  Copy CloudProgram/cloudfunctions/_shared into each function's shared/ directory.
  Also copies CloudProgram/agconnect-credential.json into each function when present.

  NOTE: 不再放到 node_modules 下 —— DevEco 构建云函数时会执行 npm install，
  会把未在 package.json 声明的 node_modules/_zupu_shared 当作多余依赖删除，
  导致线上运行报 'Cannot find module '_zupu_shared''。放在函数目录内则会被原样打包。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File CloudProgram/tools/sync-shared.ps1
#>
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cloudProgram = Split-Path -Parent $here
$fnRoot = Join-Path $cloudProgram 'cloudfunctions'
$sharedDir = Join-Path $fnRoot '_shared'

if (-not (Test-Path -Path $sharedDir)) {
  throw "shared dir not found: $sharedDir"
}

$targets = Get-ChildItem -Path $fnRoot -Directory | Where-Object { $_.Name -ne '_shared' }
$count = 0
foreach ($fn in $targets) {
  $indexFile = Join-Path $fn.FullName 'index.js'
  if (-not (Test-Path -Path $indexFile)) {
    Write-Host "skip (not a function): $($fn.Name)"
    continue
  }
  $dest = Join-Path -Path $fn.FullName -ChildPath 'shared'
  if (Test-Path -Path $dest) {
    Remove-Item -Path $dest -Recurse -Force
  }
  New-Item -ItemType Directory -Path $dest -Force | Out-Null
  # copy every file in _shared (.js and .json such as schema-meta.json)
  Get-ChildItem -Path $sharedDir -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $dest -Force
  }
  $count++
  Write-Host "synced: $($fn.Name)"
}
Write-Host "done, $count functions"

# ---------------- credential (optional) ----------------
$credPath = Join-Path -Path $cloudProgram -ChildPath 'agconnect-credential.json'
if (Test-Path -Path $credPath) {
  $n = 0
  foreach ($fn in $targets) {
    Copy-Item -Path $credPath -Destination (Join-Path $fn.FullName 'agconnect-credential.json') -Force
    $n++
  }
  Write-Host "credential synced: $n functions"
} else {
  Write-Host 'credential skipped (CloudProgram/agconnect-credential.json not found)'
}
