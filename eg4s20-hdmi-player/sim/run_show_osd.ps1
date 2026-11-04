param([string]$VivadoBin = $env:VIVADO_BIN)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($VivadoBin)) { throw 'Pass -VivadoBin with your Vivado bin directory, or set VIVADO_BIN.' }
$simulationDirectory = Join-Path $PSScriptRoot 'osd_run'
New-Item -ItemType Directory -Path $simulationDirectory -Force | Out-Null
$source = Join-Path $PSScriptRoot '..\src\user_source\hdl_source\OSD\brightness_osd.v'
$testbench = Join-Path $PSScriptRoot 'tb_show_osd.sv'
Push-Location $simulationDirectory
try {
    & (Join-Path $VivadoBin 'xvlog.bat') --sv $source $testbench --log compile.log
    if ($LASTEXITCODE -ne 0) { throw 'Show OSD compilation failed' }
    & (Join-Path $VivadoBin 'xelab.bat') tb_show_osd --O0 -s show_osd_test --log elaborate.log
    if ($LASTEXITCODE -ne 0) { throw 'Show OSD elaboration failed' }
    & (Join-Path $VivadoBin 'xsim.bat') show_osd_test --runall --onerror quit --onfinish quit --log simulate.log
    if ($LASTEXITCODE -ne 0 -or !(Get-Content -LiteralPath simulate.log -Raw).Contains('PASS: show OSD')) {
        throw 'Show OSD simulation failed'
    }
    @'
from pathlib import Path
import struct,zlib
def chunk(tag,data):
    return struct.pack('!I',len(data))+tag+data+struct.pack('!I',zlib.crc32(tag+data)&0xffffffff)
for source in Path('.').glob('show_*.ppm'):
    tokens=source.read_text().split()
    assert tokens[:4]==['P3','640','480','255']
    pixels=bytes(map(int,tokens[4:]))
    assert len(pixels)==640*480*3
    rows=b''.join(b'\0'+pixels[y*1920:(y+1)*1920] for y in range(480))
    png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!2I5B',640,480,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(rows))+chunk(b'IEND',b'')
    source.with_suffix('.png').write_bytes(png)
'@ | python -
    if ($LASTEXITCODE -ne 0) { throw 'Show OSD preview conversion failed' }
} finally {
    Pop-Location
}
