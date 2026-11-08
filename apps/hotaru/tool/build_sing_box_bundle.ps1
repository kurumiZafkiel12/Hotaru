param([Parameter(Mandatory = $true)][string]$Destination)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
  throw 'This bundle builder currently requires Windows x64'
}
$root = Split-Path $PSScriptRoot -Parent
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path $destinationPath) { throw 'Bundle destination must be a new directory' }
$parent = Split-Path $destinationPath -Parent
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$staging = Join-Path $parent ('.hotaru-box-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
$environmentKeys = @('GOOS', 'GOARCH', 'CGO_ENABLED', 'CORE_SHA256', 'CORE_NAME')
$saved = @{}
foreach ($key in $environmentKeys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
try {
  $module = Join-Path $root 'core/sing_box_host'
  go -C $module mod verify
  if ($LASTEXITCODE -ne 0) { throw 'Go module verification failed' }
  $harness = Join-Path $root 'plugins/setup/setup_hooks'
  Push-Location $harness
  try {
    dart pub get
    if ($LASTEXITCODE -ne 0) { throw 'Build hook dependencies failed' }
    dart run bin/windows_host.dart $root $staging
    if ($LASTEXITCODE -ne 0) { throw 'Application build hook failed' }
  } finally { Pop-Location }
  $artifacts = Join-Path $staging 'windows'
  $core = Join-Path $staging 'HotaruCore.exe'
  $helper = Join-Path $staging 'HotaruHelperService.exe'
  Move-Item (Join-Path $artifacts 'HotaruCore.exe') $core
  Move-Item (Join-Path $artifacts 'HotaruHelperService.exe') $helper
  Remove-Item $artifacts -Recurse -Force
  $version = @(& $core version)
  if ($LASTEXITCODE -ne 0 -or $version[0] -ne 'sing-box version 1.14.4' -or $version[1] -ne 'Host control: hotaru-stdio-v1') {
    throw 'Built host version or control protocol does not match'
  }
  $env:CORE_SHA256 = (Get-FileHash $core -Algorithm SHA256).Hash.ToLowerInvariant()
  $upstream = go -C $module list -mod=readonly -m -f '{{.Dir}}' github.com/sagernet/sing-box
  if ($LASTEXITCODE -ne 0) { throw 'Cannot locate pinned upstream source' }
  Copy-Item (Join-Path $upstream 'LICENSE') (Join-Path $staging 'LICENSE-sing-box')
  Copy-Item ([IO.Path]::GetFullPath((Join-Path $root '../../LICENSE'))) (Join-Path $staging 'LICENSE-Hotaru')
  $revision = git -C $root rev-parse HEAD
  if ($LASTEXITCODE -ne 0) { throw 'Cannot identify bundle source revision' }
  $manifest = @{
    engine = 'sing-box'
    coreVersion = '1.14.4'
    hostProtocol = 'hotaru-bootstrap-v1'
    coreSha256 = $env:CORE_SHA256
    helperSha256 = (Get-FileHash $helper -Algorithm SHA256).Hash.ToLowerInvariant()
    target = 'windows-amd64'
    sourceCommit = $revision.Trim()
  }
  [IO.File]::WriteAllText((Join-Path $staging 'manifest.json'),
    ($manifest | ConvertTo-Json) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $staging 'SOURCES.txt'),
    "sing-box: https://github.com/SagerNet/sing-box/tree/v1.14.4`nHotaru: https://github.com/kurumiZafkiel12/Hotaru/tree/$($revision.Trim())`n",
    [Text.UTF8Encoding]::new($false))
  [IO.Directory]::Move($staging, $destinationPath)
  Write-Output $destinationPath
} finally {
  foreach ($key in $environmentKeys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
  if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
}
