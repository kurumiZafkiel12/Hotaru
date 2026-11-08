param(
  [Parameter(Mandatory = $true)][string]$Destination,
  [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-f]{64}$')][string]$ExpectedDigest,
  [Parameter(Mandatory = $true)][string]$ReleaseUrl,
  [Parameter(Mandatory = $true)][string]$AssetApiUrl
)
$ErrorActionPreference = 'Stop'
if ((Test-Path $Destination -PathType Leaf) -and
    (Get-FileHash $Destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $ExpectedDigest) {
  return
}
$assetPath = [IO.Path]::GetFullPath($Destination)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($assetPath)) | Out-Null
$temporaryAsset = $assetPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
$sources = @(
  @{ Uri = $ReleaseUrl; Headers = @{} },
  @{ Uri = $AssetApiUrl; Headers = @{ Accept = 'application/octet-stream'; 'X-GitHub-Api-Version' = '2022-11-28' } }
)
try {
  foreach ($source in $sources) {
    try {
      Invoke-WebRequest -Uri $source.Uri -Headers $source.Headers -OutFile $temporaryAsset -MaximumRetryCount 1 -RetryIntervalSec 5 -TimeoutSec 45
      if ((Get-FileHash $temporaryAsset -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedDigest) {
        throw 'Pinned asset digest mismatch'
      }
      Move-Item -LiteralPath $temporaryAsset -Destination $assetPath -Force
      return
    } catch {
      Remove-Item -LiteralPath $temporaryAsset -ErrorAction SilentlyContinue
      Write-Warning 'Could not retrieve the verified asset from this official endpoint.'
    }
  }
  throw 'Unable to fetch the pinned release asset with the required SHA-256 digest.'
} finally {
  Remove-Item -LiteralPath $temporaryAsset -ErrorAction SilentlyContinue
}
