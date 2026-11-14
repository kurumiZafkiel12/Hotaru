$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'This hook configuration is limited to the disposable CI checkout.' }
$packageConfig = Get-Content -Raw '.dart_tool/package_config.json' | ConvertFrom-Json
$sqlite = @($packageConfig.packages | Where-Object { $_.name -eq 'sqlite3' })
if ($sqlite.Count -ne 1) { throw 'Expected exactly one sqlite3 package.' }
$rootUri = [Uri]$sqlite[0].rootUri
if (-not $rootUri.IsAbsoluteUri -or -not $rootUri.IsFile) { throw 'Expected an absolute local sqlite3 package path.' }
$package = Get-Content -Raw (Join-Path $rootUri.LocalPath 'pubspec.yaml')
if ($package -notmatch '(?m)^version: 3\.7\.0\s*$') { throw 'Recheck the verified asset when changing the sqlite3 dependency.' }
$directory = Join-Path $env:RUNNER_TEMP 'hotaru-verified-sqlite3-3.7.0'
& (Join-Path $PSScriptRoot 'fetch_verified_release.ps1') -Destination (Join-Path $directory 'sqlite3.x64.windows.dll') `
  -ExpectedDigest '98b4be674137b85ec111a7a29223e87aa41c3e964d61f73602471ddd7b9c56ce' `
  -ReleaseUrl 'https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.7.0/sqlite3.x64.windows.dll' `
  -AssetApiUrl 'https://api.github.com/repos/simolus3/sqlite3.dart/releases/assets/600689009'
$source = Get-Content -Raw 'pubspec.yaml'
if ($source -match '(?m)^    sqlite3:') { throw 'Do not overwrite an existing sqlite3 hook configuration.' }
if (($source | Select-String -Pattern '(?m)^  user_defines:' -AllMatches).Matches.Count -ne 1) { throw 'Expected one hook configuration block.' }
$escapedDirectory = ConvertTo-Json -InputObject ($directory.Replace('\', '/') + '/') -Compress
$definition = "  user_defines:`n    sqlite3:`n      source: test-sqlite3`n      directory: " + $escapedDirectory
$source = [regex]::Replace($source, '(?m)^  user_defines:', $definition)
Set-Content -NoNewline -Encoding utf8 'pubspec.yaml' $source
