param([Parameter(Mandatory=$true)][string]$BuildDir)
$ErrorActionPreference='Stop'
$version='v24.22.1'
$archive=Join-Path $env:RUNNER_TEMP 'hotaru-node.zip'
Invoke-WebRequest "https://nodejs.org/dist/$version/node-$version-win-x64.zip" -OutFile $archive
if((Get-FileHash $archive -Algorithm SHA256).Hash -ne 'D2046D28C2C3DCD211AC5145C0BF30E2047EF9DFB306693C8C6E2ECCD8B95FA5'){throw 'Node runtime SHA256 mismatch'}
$extract=Join-Path $env:RUNNER_TEMP 'hotaru-node'
Expand-Archive $archive $extract -Force
$runtime=Join-Path $BuildDir 'runtime'
New-Item -ItemType Directory -Force $runtime|Out-Null
Copy-Item "$extract/node-$version-win-x64/node.exe" $runtime/
Copy-Item "$extract/node-$version-win-x64/LICENSE" "$runtime/Node-LICENSE.txt"
Write-Output 'Pinned Node.js runtime verified and bundled for user-authored Script overrides.'
