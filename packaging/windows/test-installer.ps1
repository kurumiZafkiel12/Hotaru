$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Installer tests require an isolated Windows CI runner'}
$setup=(Resolve-Path '../../dist/Hotaru-0.4.1-windows-x64-setup.exe').Path
$target=Join-Path $env:RUNNER_TEMP 'Hotaru-installed'
$arguments=@('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/DIR=$target")
function Invoke-Installer {
  $process=Start-Process -FilePath $setup -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
  if($process.ExitCode -ne 0){throw "Installer failed: $($process.ExitCode)"}
}
Invoke-Installer
if(-not (Test-Path "$target/hotaru.exe") -or -not (Test-Path "$target/core/mihomo.exe")){throw 'Incomplete installation'}
& "$target/core/mihomo.exe" -v
if($LASTEXITCODE -ne 0){throw 'Installed core failed'}
$data=Join-Path $env:APPDATA 'Hotaru'
New-Item -ItemType Directory -Force $data|Out-Null
'[0,1]'|Set-Content "$data/layout-v1.json"
Invoke-Installer
if((Get-Content "$data/layout-v1.json" -Raw).Trim() -ne '[0,1]'){throw 'Upgrade lost user layout'}
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runKey -Force|Out-Null
New-ItemProperty -Path $runKey -Name Hotaru -Value "`"$target/hotaru.exe`" --silent" -PropertyType String -Force|Out-Null
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
& "$target/Hotaru.Service.exe" install $sid
if($LASTEXITCODE -ne 0){throw 'Optional service install before uninstall failed'}
$process=Start-Process -FilePath "$target/unins000.exe" -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait -PassThru -WindowStyle Hidden
if($process.ExitCode -ne 0){throw 'Uninstall failed'}
if(-not (Test-Path "$data/layout-v1.json")){throw 'Uninstall deleted user data'}
if($null -ne (Get-Item -LiteralPath $runKey).GetValue('Hotaru',$null)){throw 'Uninstall left autostart behind'}
if(@(Get-CimInstance Win32_Service -Filter "Name='HotaruCoreHost'").Count -ne 0){throw 'Uninstall left optional SCM service behind'}
