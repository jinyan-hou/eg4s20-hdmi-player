param([string]$VivadoBin = $env:VIVADO_BIN)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VivadoBin)) { throw 'Pass -VivadoBin with your Vivado bin directory, or set VIVADO_BIN.' }
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\user_source\hdl_source\SD'
$runDirectory = Join-Path $PSScriptRoot 'bmp_run'
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Push-Location $runDirectory
try {
    $files = @((Join-Path $source 'bmp_read.v'),(Join-Path $source 'sd_card_bmp.v'),(Join-Path $PSScriptRoot 'tb_bmp_preload.sv'))
    & (Join-Path $VivadoBin 'xvlog.bat') --sv @files --log compile.log 2>&1 | Out-File compile_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'BMP preload compilation failed; inspect bmp_run/compile.log' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_bmp_preload --O0 --timescale 1ns/1ps -s bmp_preload_test --log elaborate.log 2>&1 | Out-File elaborate_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'BMP preload elaboration failed; inspect bmp_run/elaborate.log' }
    & (Join-Path $VivadoBin 'xsim.bat') bmp_preload_test --runall --onerror quit --onfinish quit --log result.log 2>&1 | Out-File result_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath result.log -SimpleMatch 'PASS BMP preload:')) { throw 'BMP preload simulation failed; inspect bmp_run/result.log' }
    Get-Content -LiteralPath result.log | Select-String -Pattern 'PASS|Fatal'
} finally { Pop-Location }
