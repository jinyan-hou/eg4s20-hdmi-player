"""Check or locally restore licensed vendor dependencies; never downloads or publishes."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil

ROOT = Path(__file__).resolve().parents[1]

def check_or_restore(root, source=None):
    root = Path(root).resolve()
    entries = json.loads((root/'docs/vendor_dependencies.json').read_text(encoding='utf-8'))['required_files']
    plan = []
    for item in entries:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Unsafe dependency path')
        target = (root/relative).resolve()
        if not target.is_relative_to(root):
            raise ValueError('Dependency escaped project directory')
        if target.is_file():
            if hashlib.sha256(target.read_bytes()).hexdigest() != item['sha256']:
                raise ValueError('Existing dependency differs; not overwritten: '+item['path'])
        elif source is not None:
            source_root = Path(source).resolve()
            candidate = (source_root/relative).resolve()
            if not candidate.is_relative_to(source_root):
                raise ValueError('Source dependency escaped project directory')
            if not candidate.is_file() or hashlib.sha256(candidate.read_bytes()).hexdigest() != item['sha256']:
                raise ValueError('Missing or incompatible licensed source: '+item['path'])
            plan.append((candidate,target))
        else:
            plan.append((None,target))
    if source is None:
        for _,target in plan: print('MISSING '+target.relative_to(root).as_posix())
        print('PASS: dependencies complete' if not plan else 'Dependencies are intentionally not distributed; see docs/DEPENDENCIES.md')
        return 0 if not plan else 1
    # Validate the complete plan before writing any file.
    for candidate,target in plan:
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(candidate,target)
    print('PASS: restored '+str(len(plan))+' matching vendor dependencies locally')
    return 0

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--from-project',type=Path,help='Your legally obtained, matching complete project directory')
    args = parser.parse_args()
    try:
        raise SystemExit(check_or_restore(ROOT,args.from_project))
    except (OSError,ValueError,KeyError) as exc:
        parser.exit(2,str(exc)+'\n')
