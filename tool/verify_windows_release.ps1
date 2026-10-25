$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Run only in an isolated Windows CI account' }
$installers = @(Get-ChildItem dist -Recurse -File -Filter '*.exe')
$archives = @(Get-ChildItem dist -Recurse -File -Filter '*.zip')
if ($installers.Count -ne 1 -or $archives.Count -ne 1) { throw 'Expected one installer and one portable ZIP' }
New-Item -ItemType Directory publish -Force | Out-Null
Copy-Item -LiteralPath $installers[0].FullName -Destination publish/Hotaru-0.5.0-windows-x64-setup.exe
Copy-Item -LiteralPath $archives[0].FullName -Destination publish/Hotaru-0.5.0-windows-x64-portable.zip
$portable = Join-Path $env:RUNNER_TEMP 'hotaru-portable-check'
Expand-Archive -LiteralPath $archives[0].FullName -DestinationPath $portable
foreach ($name in @('Hotaru.exe','HotaruCore.exe','HotaruHelperService.exe','HotaruProxyGuardian.exe','rust_api.dll')) {
  if (-not (Get-ChildItem -LiteralPath $portable -Recurse -File -Filter $name)) { throw "Missing $name" }
}
$core = (Get-ChildItem -LiteralPath $portable -Recurse -File -Filter HotaruCore.exe | Select-Object -First 1).FullName
$guardian = (Get-ChildItem -LiteralPath $portable -Recurse -File -Filter HotaruProxyGuardian.exe | Select-Object -First 1).FullName
& ./tool/windows_core_smoke.ps1 -Core $core
& ./tool/windows_guardian_smoke.ps1 -Guardian $guardian
$install = Join-Path $env:RUNNER_TEMP 'Hotaru-install-check'
$sentinel = Join-Path $env:APPDATA 'dev.hotaru/Hotaru/release-sentinel.txt'
New-Item -ItemType Directory (Split-Path $sentinel) -Force | Out-Null
Set-Content -LiteralPath $sentinel -Value 'keep-user-data'
foreach ($attempt in 1..2) {
  $process = Start-Process -FilePath $installers[0].FullName -ArgumentList "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=`"$install`"" -WindowStyle Hidden -PassThru -Wait
  if ($process.ExitCode -ne 0) { throw "Installer failed: $($process.ExitCode)" }
  if (-not (Test-Path -LiteralPath "$install/Hotaru.exe")) { throw 'Installed application missing' }
  if ((Get-Content -LiteralPath $sentinel -Raw).Trim() -ne 'keep-user-data') { throw 'User data changed during installation' }
}
$uninstaller = Get-ChildItem -LiteralPath $install -Filter 'unins*.exe' | Select-Object -First 1
$process = Start-Process -FilePath $uninstaller.FullName -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WindowStyle Hidden -PassThru -Wait
if ($process.ExitCode -ne 0 -or (Test-Path -LiteralPath "$install/Hotaru.exe")) { throw 'Uninstall failed' }
if (-not (Test-Path -LiteralPath $sentinel)) { throw 'Silent uninstall removed user data' }
Write-Output 'PASS: package inventory, proxy chain, guardian, install, overwrite, uninstall, data preservation'
