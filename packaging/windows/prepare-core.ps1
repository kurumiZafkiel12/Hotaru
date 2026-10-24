param([Parameter(Mandatory=$true)][string]$BuildDir)
$ErrorActionPreference='Stop'
$coreVersion='v1.19.33'
$url="https://github.com/MetaCubeX/mihomo/releases/download/$coreVersion/mihomo-windows-amd64-compatible-$coreVersion.zip"
$archive=if($env:RUNNER_TEMP){Join-Path $env:RUNNER_TEMP 'mihomo.zip'}else{Join-Path ([IO.Path]::GetTempPath()) 'hotaru-mihomo.zip'}
Invoke-WebRequest $url -OutFile $archive
if((Get-FileHash $archive -Algorithm SHA256).Hash -ne '7AAF636A4F2172DCD8EC34AC4F52797B059195E5AFD6409508C963E545F8864D'){throw 'Mihomo SHA256 mismatch'}
$coreDir=Join-Path $BuildDir 'core'
New-Item -ItemType Directory -Force $coreDir|Out-Null
Expand-Archive $archive $coreDir -Force
$binary=Get-ChildItem $coreDir -Filter '*.exe'|Select-Object -First 1
if(-not $binary){throw 'Mihomo binary missing'}
if($binary.Name -ne 'mihomo.exe'){Move-Item -LiteralPath $binary.FullName -Destination (Join-Path $coreDir 'mihomo.exe')}
Copy-Item (Join-Path $PSScriptRoot '../../LICENSE') (Join-Path $BuildDir 'LICENSE.txt')
Copy-Item (Join-Path $PSScriptRoot '../../THIRD-PARTY.md') (Join-Path $BuildDir 'THIRD-PARTY.md')
Invoke-WebRequest "https://raw.githubusercontent.com/MetaCubeX/mihomo/$coreVersion/LICENSE" -OutFile (Join-Path $coreDir 'LICENSE.txt')
Write-Output 'Pinned Mihomo downloaded and checksum verified.'
