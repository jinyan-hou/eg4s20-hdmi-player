param([string]$VivadoBin = $env:VIVADO_BIN)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VivadoBin)) { throw 'Pass -VivadoBin with your Vivado bin directory, or set VIVADO_BIN.' }
$projectDirectory = Split-Path $PSScriptRoot -Parent
$source = Join-Path $projectDirectory 'src\user_source\hdl_source\AVP\avp_audio.v'
$baselineSource = Join-Path $PSScriptRoot 'fixtures\avp_audio_baseline_source.v'
$runDirectory = Join-Path $PSScriptRoot 'pause_run'
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
$baseline = Get-Content -LiteralPath $baselineSource -Raw
if ($baseline -match 'input\s+wire\s+paused') { throw 'The unpaused video_wave baseline fixture has changed' }
($baseline -replace 'module avp_audio\s*#', 'module avp_audio_baseline #') | Set-Content -LiteralPath (Join-Path $runDirectory 'avp_audio_baseline.v') -Encoding utf8
Push-Location $runDirectory
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv $source avp_audio_baseline.v (Join-Path $PSScriptRoot 'tb_pause_audio.sv') --log compile.log 2>&1 | Out-File compile_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Pause audio compilation failed; inspect pause_run/compile.log' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_pause_audio --O0 --timescale 1ns/1ps -s pause_audio_test --log elaborate.log 2>&1 | Out-File elaborate_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Pause audio elaboration failed; inspect pause_run/elaborate.log' }
    & (Join-Path $VivadoBin 'xsim.bat') pause_audio_test --runall --onerror quit --onfinish quit --log result.log 2>&1 | Out-File result_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath result.log -SimpleMatch 'PASS pause audio:')) { throw 'Pause audio simulation failed; inspect pause_run/result.log' }
    Get-Content -LiteralPath result.log | Select-String -Pattern 'PASS|Fatal'
} finally { Pop-Location }
