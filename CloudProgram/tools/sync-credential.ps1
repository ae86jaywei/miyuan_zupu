<#
.SYNOPSIS
  Copy the AGC API-client credential into every cloud function folder so it can be packed.

.WHERE TO GET THE FILE
  AGC console -> My projects -> Project settings -> API clients -> Create / download.
  The file looks like api-client-project.json and contains: "type": "project_client_id".
  Do NOT use the "service account key" (it has private_key/token_uri) - the server SDK rejects it.
  Do NOT use AppScope/resources/rawfile/agconnect-services.json - that is a client-side credential.

.USAGE
  1) Save the downloaded JSON as: CloudProgram/agconnect-credential.json
  2) powershell -ExecutionPolicy Bypass -File CloudProgram/tools/sync-credential.ps1
#>
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cloudProgram = Split-Path -Parent $here
$credPath = Join-Path $cloudProgram 'agconnect-credential.json'

if (-not (Test-Path -Path $credPath)) {
  Write-Host "ERROR: not found: $credPath"
  Write-Host "Download it from AGC console: Project settings -> API clients -> download credentials."
  exit 1
}

$raw = Get-Content -Raw -Encoding UTF8 -Path $credPath
$obj = $null
try {
  $obj = $raw | ConvertFrom-Json
} catch {
  Write-Host "ERROR: credential file is not valid JSON."
  exit 1
}

if ($obj.private_key -or $obj.token_uri) {
  Write-Host "ERROR: this is a SERVICE ACCOUNT KEY, which the server SDK does not support."
  Write-Host "Use: AGC console -> Project settings -> API clients -> download credentials."
  Write-Host 'Expected content: { "type": "project_client_id", ... }'
  exit 1
}
if (-not $obj.type) {
  Write-Host 'ERROR: credential has no "type" field (expected project_client_id).'
  Write-Host "Do NOT use AppScope/resources/rawfile/agconnect-services.json (client-side credential)."
  exit 1
}
if ($obj.type -ne 'project_client_id' -and $obj.type -ne 'team_client_id') {
  Write-Host ("ERROR: unsupported credential type: " + $obj.type)
  exit 1
}

$fnRoot = Join-Path $cloudProgram 'cloudfunctions'
$dirs = Get-ChildItem -Path $fnRoot -Directory | Where-Object { $_.Name -ne '_shared' }
$count = 0
foreach ($d in $dirs) {
  Copy-Item -Path $credPath -Destination (Join-Path $d.FullName 'agconnect-credential.json') -Force
  $count++
}
Write-Host ("credential copied to " + $count + " functions: type=" + $obj.type + " project=" + $obj.project_id)
