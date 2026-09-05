param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$FlutterArguments
)

$root = Split-Path -Parent $PSScriptRoot
$env:RUSTUP_HOME = Join-Path $root '.rustup'
$env:CARGO_HOME = Join-Path $root '.cargo'
$env:PATH = "$env:CARGO_HOME\bin;$env:PATH"

& flutter @FlutterArguments
exit $LASTEXITCODE
