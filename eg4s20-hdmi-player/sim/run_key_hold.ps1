param([string]$VivadoBin = $env:VIVADO_BIN)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VivadoBin)) { throw 'Pass -VivadoBin with your Vivado bin directory, or set VIVADO_BIN.' }
$runDirectory = Join-Path $PSScriptRoot 'key_run'
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$source = Join-Path $PSScriptRoot '../src/user_source/hdl_source'
Push-Location $runDirectory
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv (Join-Path $source 'SD/sd_card_bmp.v') (Join-Path $source 'OSD/key_hold_actions.v') (Join-Path $PSScriptRoot 'tb_key_hold.sv') --log compile.log 2>&1 | Out-File compile_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Key compilation failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_key_hold --O0 --timescale 1ns/1ps -s key_hold_test --log elaborate.log 2>&1 | Out-File elaborate_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Key elaboration failed' }
    & (Join-Path $VivadoBin 'xsim.bat') key_hold_test --runall --onerror quit --onfinish quit --log result.log 2>&1 | Out-File result_console.log -Encoding utf8
    $text = Get-Content -LiteralPath result.log -Raw
    if ($LASTEXITCODE -ne 0 -or !$text.Contains('PASS key hold:') -or $text -match 'Fatal:|FATAL|ERROR:') { throw 'Key simulation failed' }
    Select-String -LiteralPath result.log -Pattern 'PASS key hold:'
} finally { Pop-Location }
