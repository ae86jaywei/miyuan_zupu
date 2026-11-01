<#
.SYNOPSIS
  Pack CloudProgram/cloudfunctions/_shared into an AGC cloud function layer zip.
  Output: CloudProgram/dist/zupu-shared-layer.zip
  Zip root must be node_modules/zupu_shared/ (no outer directory).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File CloudProgram/tools/build-layer.ps1
#>
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cloudProgram = Split-Path -Parent $here
$sourceShared = Join-Path $cloudProgram 'cloudfunctions\_shared'
$dist = Join-Path $cloudProgram 'dist'
$buildDir = Join-Path $env:TEMP 'zupu-layer-build'
$outZip = Join-Path $dist 'zupu-shared-layer.zip'

if (-not (Test-Path -Path $sourceShared)) {
    throw "shared dir not found: $sourceShared"
}

# clean old build dir
if (Test-Path $buildDir) {
    Remove-Item $buildDir -Recurse -Force
}
if (Test-Path $outZip) {
    Remove-Item $outZip -Force
}

# directory structure node_modules/zupu_shared
New-Item -ItemType Directory -Path "$buildDir/node_modules/zupu_shared" -Force | Out-Null

# copy all _shared sources (.js and .json such as schema-meta.json)
Copy-Item "$sourceShared\*" "$buildDir/node_modules/zupu_shared/" -Recurse

# pack: from inside buildDir, compress only the node_modules folder (no outer dir)
Push-Location $buildDir
try {
    Compress-Archive -Path node_modules -DestinationPath $outZip -Force
}
finally {
    Pop-Location
}
Remove-Item $buildDir -Recurse -Force

Write-Host "`nlayer zip generated: $outZip"
Write-Host 'structure check: zip root must be node_modules/zupu_shared/'
