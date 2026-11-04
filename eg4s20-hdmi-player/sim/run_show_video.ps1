param([string]$VivadoBin = $env:VIVADO_BIN)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VivadoBin)) { throw 'Pass -VivadoBin with your Vivado bin directory, or set VIVADO_BIN.' }
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\user_source\hdl_source'
$runDirectory = Join-Path $PSScriptRoot 'video_run'
New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
Push-Location $runDirectory
try {
    $files = @(
        (Join-Path $source 'AVP\avp_audio.v'),
        (Join-Path $source 'AVP\avp_subtitles.v'),
        (Join-Path $source 'OSD\brightness_osd.v'),
        (Join-Path $source 'OSD\audio_waveform.v'),
        (Join-Path $source 'video_rgb_to_axis_640x480.v'),
        (Join-Path $PSScriptRoot 'tb_show_video.sv'))
    & (Join-Path $VivadoBin 'xvlog.bat') --sv @files --log compile.log 2>&1 | Out-File compile_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Show video compilation failed; inspect video_run/compile.log' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_show_video --O0 --timescale 1ns/1ps -s show_video_test --log elaborate.log 2>&1 | Out-File elaborate_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'Show video elaboration failed; inspect video_run/elaborate.log' }
    & (Join-Path $VivadoBin 'xsim.bat') show_video_test --runall --onerror quit --onfinish quit --log result.log 2>&1 | Out-File result_console.log -Encoding utf8
    if ($LASTEXITCODE -ne 0 -or !(Select-String -LiteralPath result.log -SimpleMatch 'PASS show video:')) { throw 'Show video simulation failed; inspect video_run/result.log' }
    Get-Content -LiteralPath result.log | Select-String -Pattern 'PASS|Fatal'
} finally { Pop-Location }
