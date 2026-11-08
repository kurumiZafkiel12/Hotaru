param([Parameter(Mandatory = $true)][string]$Destination)
$ErrorActionPreference = 'Stop'
$expectedDigest = '99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df'
if ((Test-Path $Destination -PathType Leaf) -and
    (Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $expectedDigest) {
  return
}
$assetPath = [IO.Path]::GetFullPath($Destination)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($assetPath)) | Out-Null
$temporaryAsset = $assetPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
$sources = @(
  @{
    Uri = 'https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-windows-amd64.zip'
    Headers = @{}
  },
  @{
    Uri = 'https://api.github.com/repos/SagerNet/sing-box/releases/assets/669527524'
    Headers = @{ Accept = 'application/octet-stream'; 'X-GitHub-Api-Version' = '2022-11-28' }
  }
)
try {
  foreach ($source in $sources) {
    try {
      Invoke-WebRequest -Uri $source.Uri -Headers $source.Headers -OutFile $temporaryAsset -MaximumRetryCount 1 -RetryIntervalSec 5 -TimeoutSec 45
      if ((Get-FileHash $temporaryAsset -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedDigest) {
        throw 'Pinned asset digest mismatch'
      }
      Move-Item -LiteralPath $temporaryAsset -Destination $assetPath -Force
      return
    } catch {
      Remove-Item -LiteralPath $temporaryAsset -ErrorAction SilentlyContinue
      Write-Warning 'Could not retrieve the verified archive from this official endpoint.'
    }
  }
  throw 'Unable to fetch the pinned sing-box 1.14.4 archive with the required SHA-256 digest.'
} finally {
  Remove-Item -LiteralPath $temporaryAsset -ErrorAction SilentlyContinue
}
