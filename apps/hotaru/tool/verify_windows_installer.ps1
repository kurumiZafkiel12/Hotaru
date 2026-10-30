$ErrorActionPreference = 'Stop'
if (-not $env:GITHUB_ACTIONS -or $env:RUNNER_OS -ne 'Windows') { throw 'Disposable Windows CI runner required' }
if (Get-Process Hotaru, HotaruCore, HotaruHelperService -ErrorAction SilentlyContinue) { throw 'Existing app processes present' }
$destination = Join-Path $env:RUNNER_TEMP 'hotaru-installer-probe'
$expanded = Join-Path $env:RUNNER_TEMP 'hotaru-zip-probe'
if (Test-Path $destination) { throw 'Probe installation folder already exists' }
New-Item -ItemType Directory -Force 'installer-probe' | Out-Null
$sentinels = @()
foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
    $folder = Join-Path $base 'dev.hotaru/Hotaru'
    New-Item -ItemType Directory -Force $folder | Out-Null
    $path = Join-Path $folder ('installer-probe-' + [guid]::NewGuid().ToString() + '.txt')
    Set-Content $path 'preserve-installed-user-data'
    $sentinels += $path
}
function Assert-Preserved {
    foreach ($path in $sentinels) {
        if (-not (Test-Path $path) -or (Get-Content -Raw $path).Trim() -ne 'preserve-installed-user-data') { throw 'User data sentinel changed' }
    }
}
function Install-Package($file, $label) {
    $arguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', ('/DIR="' + $destination + '"'), ('/LOG="' + (Join-Path $PWD "installer-probe/$label.log") + '"'))
    $process = Start-Process -FilePath $file -ArgumentList $arguments -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw "$label exited $($process.ExitCode)" }
    Assert-Preserved
}
try {
    $previous = @(Get-ChildItem 'previous-windows/*-setup.exe')
    $candidate = @(Get-ChildItem 'staged-windows/*-setup.exe')
    if ($previous.Count -ne 1 -or $candidate.Count -ne 1) { throw 'Missing or duplicate installers' }
    Install-Package $previous[0].FullName 'previous'
    Install-Package $candidate[0].FullName 'upgrade'
    Install-Package $candidate[0].FullName 'repeat'
    Expand-Archive -Path 'staged-windows/Hotaru-0.0.5-windows-amd64.zip' -DestinationPath $expanded
    foreach ($name in @('Hotaru.exe', 'HotaruCore.exe', 'HotaruHelperService.exe', 'flutter_windows.dll')) {
        $installed = Join-Path $destination $name
        $zipped = Join-Path $expanded $name
        if (-not (Test-Path $installed) -or -not (Test-Path $zipped)) { throw "Missing packaged file $name" }
        if ((Get-FileHash $installed).Hash -ne (Get-FileHash $zipped).Hash) { throw "Installed ZIP mismatch: $name" }
    }
    $version = (Get-Item (Join-Path $destination 'Hotaru.exe')).VersionInfo.ProductVersion
    if ($version -notmatch '^0\.0\.5(?:\+17|\.17)?$') { throw "Unexpected installed version: $version" }
    $uninstaller = Join-Path $destination 'unins000.exe'
    $process = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -PassThru -Wait
    if ($process.ExitCode -ne 0) { throw 'Uninstaller failed' }
    for ($attempt = 0; $attempt -lt 30 -and (Test-Path $destination); $attempt++) { Start-Sleep -Milliseconds 500 }
    if (Test-Path (Join-Path $destination 'Hotaru.exe')) { throw 'Installed executable remains after uninstall' }
    Assert-Preserved
    $result = [ordered]@{ source_sha='93e8c03cb3df550685b8001b8682ae173905e417'; version=$version; previous_install=$true; upgrade=$true; repeated_install=$true; uninstall=$true; roaming_and_local_data_preserved=$true; installed_binaries_match_zip=$true; scope='Disposable Windows runner; no connected proxy/TUN or interactive UI acceptance' }
    $result | ConvertTo-Json | Set-Content 'installer-probe/result.json'
    Write-Host "::notice title=Windows installer verification::$($result | ConvertTo-Json -Compress)"
} finally {
    foreach ($path in $sentinels) { Remove-Item $path -ErrorAction SilentlyContinue }
}
