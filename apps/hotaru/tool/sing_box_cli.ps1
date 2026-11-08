param([Parameter(Mandatory = $true)][string]$Destination)
& (Join-Path $PSScriptRoot 'fetch_verified_release.ps1') -Destination $Destination `
  -ExpectedDigest '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df' `
  -ReleaseUrl 'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip' `
  -AssetApiUrl 'https://api.github.com/repos/SagerNet/sing-box/releases/assets/669527524'
