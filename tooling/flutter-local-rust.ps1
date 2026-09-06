param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArguments
)

$root = Split-Path -Parent $PSScriptRoot
$env:RUSTUP_HOME = Join-Path $root '.rustup'
$env:CARGO_HOME = Join-Path $root '.cargo'
$env:PATH = "$env:CARGO_HOME\bin;$env:PATH"
# Cargokit resolves rustup through USERPROFILE on Windows during clean builds.
$rustupPath = Join-Path $env:CARGO_HOME 'bin\rustup.exe'
if (Test-Path -LiteralPath $rustupPath) {
    $env:USERPROFILE = $root
}

& flutter @FlutterArguments
exit $LASTEXITCODE
