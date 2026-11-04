param([string]$VivadoBin = $env:VIVADO_BIN)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VivadoBin)) { throw 'Pass -VivadoBin with your Vivado bin directory, or set VIVADO_BIN.' }
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\user_source\hdl_source'
$runDirectory = Join-Path $PSScriptRoot 'controller_run'
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Push-Location $runDirectory
try {
    $files = @((Join-Path $source 'OSD\show_controller.v'), (Join-Path $source 'SD\sd_card_bmp.v'), (Join-Path $source 'SD\bmp_read.v'), (Join-Path $PSScriptRoot 'tb_show_controller.sv'))
    & (Join-Path $VivadoBin 'xvlog.bat') --sv @files --log compile.log 2>&1 | Out-File compile_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Show controller compilation failed; inspect controller_run/compile.log' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_show_controller --O0 --timescale 1ns/1ps -s show_controller_test --log elaborate.log 2>&1 | Out-File elaborate_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Show controller elaboration failed; inspect controller_run/elaborate.log' }
    & (Join-Path $VivadoBin 'xsim.bat') show_controller_test --runall --onerror quit --onfinish quit --log result.log 2>&1 | Out-File result_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath result.log -SimpleMatch 'PASS show controller:')) { throw 'Show controller simulation failed; inspect controller_run/result.log' }
    Get-Content -LiteralPath result.log | Select-String -Pattern 'PASS|Fatal'
} finally { Pop-Location }
