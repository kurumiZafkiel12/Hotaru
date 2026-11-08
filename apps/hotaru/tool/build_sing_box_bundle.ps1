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
  Get-ChildItem -LiteralPath $artifacts -File | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $staging }
  Remove-Item $artifacts -Recurse -Force
  $version = @(& $core version)
  if ($LASTEXITCODE -ne 0 -or $version[0] -ne 'sing-box version 1.14.4' -or $version[1] -ne 'Host control: hotaru-stdio-v1') {
    throw 'Built host version or control protocol does not match'
  }
  $manifest = Get-Content (Join-Path $staging 'manifest.json') -Raw | ConvertFrom-Json
  if ($manifest.engine -ne 'sing-box' -or $manifest.coreVersion -ne '1.14.4' -or
      $manifest.coreSha256 -ne (Get-FileHash $core -Algorithm SHA256).Hash.ToLowerInvariant() -or
      $manifest.helperSha256 -ne (Get-FileHash $helper -Algorithm SHA256).Hash.ToLowerInvariant()) {
    throw 'Application hook bundle metadata does not match the built files'
  }
  [IO.Directory]::Move($staging, $destinationPath)
  Write-Output $destinationPath
} finally {
  if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
}
