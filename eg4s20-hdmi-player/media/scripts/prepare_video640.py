"""Reuse the verified packer for 640x480 at 10 fps; keep older packs intact."""
from pathlib import Path
import argparse
import json
import shutil
import types

root = Path(__file__).resolve().parents[1]
output = root / 'output640'
output.mkdir(exist_ok=True)
(output / 'work').mkdir(exist_ok=True)
for name in ('audio_info.json', 'audio_s16le.pcm'):
    target = output / 'work' / name
    if not target.exists():
        shutil.copyfile(root / 'work' / name, target)
source = (root / 'scripts/prepare_video.py').read_text(encoding='utf-8-sig')
source = source.replace("'VIDEO.AVP'", "'VIDEO640.AVP'")
source = source.replace("'preview.png'", "'preview640.png'")
module = types.ModuleType('packer640')
module.__file__ = str(root / 'scripts/prepare_video.py')
exec(compile(source, module.__file__, 'exec'), module.__dict__)
module.MEDIA, module.PROJECT = output, root.parent
module.WIDTH, module.HEIGHT = 640, 480
module.VIDEO_BYTES, module.RECORD_SECTORS = 614400, 1219
module.RECORD_BYTES = module.RECORD_SECTORS * module.SECTOR
assert module.FPS == 10 and module.AUDIO_BYTES == 9600
assert module.RECORD_BYTES == module.VIDEO_BYTES + module.AUDIO_BYTES + 128
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
if args.check:
    print(json.dumps(module.check(output / 'VIDEO640.AVP'), indent=2))
else:
    module.build()
