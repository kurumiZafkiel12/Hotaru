param([Parameter(Mandatory=$true)][string]$BuildDir)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Service installation tests are isolated CI only'}
$helper=(Resolve-Path (Join-Path $BuildDir 'Hotaru.Service.exe')).Path
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& $helper install $sid
if($LASTEXITCODE -ne 0){throw 'SCM service install failed'}
try {
  for($i=0;$i -lt 50;$i++) {
    & $helper status
    if($LASTEXITCODE -eq 0){break}
    Start-Sleep -Milliseconds 200
  }
  $service=Get-CimInstance Win32_Service -Filter "Name='HotaruCoreHost'"
  if($service.StartName -ne 'NT AUTHORITY\LocalService' -or $service.State -ne 'Running'){throw 'Incorrect service identity/state'}
  dart run tool/service_smoke.dart (Join-Path $BuildDir 'core/mihomo.exe') $helper
  if($LASTEXITCODE -ne 0){throw 'Service proxy loop failed'}
} finally {
  & $helper remove
  if($LASTEXITCODE -ne 0){throw 'Service uninstall failed'}
}
