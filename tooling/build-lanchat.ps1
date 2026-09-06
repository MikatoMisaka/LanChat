param(
    [ValidateSet('basic', 'server')]
    [string]$Edition = 'basic',
    [ValidateSet('android', 'windows')]
    [string]$Platform = 'windows'
)

$root = Split-Path -Parent $PSScriptRoot
$flutterScript = Join-Path $PSScriptRoot 'flutter-local-rust.ps1'
$flutterTarget = if ($Platform -eq 'android') { 'apk' } else { 'windows' }
$flutterArguments = @('build', $flutterTarget, '--release')

if ($Edition -eq 'server') {
    $flutterArguments += '--dart-define=LANCHAT_SERVER_EDITION=true'
}

& $flutterScript @flutterArguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$releaseDirectory = Join-Path $root 'release'
if (-not (Test-Path -LiteralPath $releaseDirectory)) {
    New-Item -ItemType Directory -Path $releaseDirectory | Out-Null
}

if ($Platform -eq 'android') {
    $source = Join-Path $root 'build\app\outputs\flutter-apk\app-release.apk'
    $target = Join-Path $releaseDirectory "LanChat-$Edition-android.apk"
    Copy-Item -LiteralPath $source -Destination $target -Force
    Write-Output "Built $target"
    exit 0
}

$sourceDirectory = Join-Path $root 'build\windows\x64\runner\Release'
$targetDirectory = Join-Path $releaseDirectory "windows-$Edition"
if (-not (Test-Path -LiteralPath $targetDirectory)) {
    New-Item -ItemType Directory -Path $targetDirectory | Out-Null
}
Copy-Item -Path (Join-Path $sourceDirectory '*') -Destination $targetDirectory -Recurse -Force
Write-Output "Built $targetDirectory"
