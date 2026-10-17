#!/usr/bin/env python3
"""Copy CRC-checked release archives to reviewable local Git delivery paths."""
import hashlib
import json
from pathlib import Path
import shutil

PROJECT = Path('/workspace/xyf2001.github.io/chromatic-wars')
BUILT = Path('/workspace/deliverables-1.5.1')
DEST = PROJECT.parent / '_deliverables/chromatic-wars'
NAMES = {
    '颜色大战_Windows_x64.zip': 'ChromaticWars-Windows-x64-Validated.zip',
    '颜色大战_Godot工程.zip': 'ChromaticWars-Godot-Source-Validated.zip',
}

def digest(path):
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()

def main():
    manifest = json.loads((BUILT / '交付校验.json').read_text())
    build = json.loads((PROJECT / 'BUILD_INFO.json').read_text())
    if manifest.get('zip_integrity') != 'PASS' or build.get('release_label') != '1.5.1-energy-magazine' or build.get('release_validation_status') != 'PARTIAL':
        raise RuntimeError('Missing actual current release validation')
    for old, new in NAMES.items():
        file = BUILT / old
        expected = manifest['files'][old]
        if file.stat().st_size != expected['bytes'] or digest(file) != expected['sha256']:
            raise RuntimeError('Built archive differs from verified manifest: ' + old)
        if expected['bytes'] >= 100 * 1024 * 1024:
            raise RuntimeError('Archive exceeds ordinary GitHub file size: ' + new)
        if (DEST / new).exists() and digest(DEST / new) != expected['sha256']:
            raise RuntimeError('Preserve existing distinct release archive before replacing: ' + new)
    copied = {}
    for old, new in NAMES.items():
        shutil.copy2(BUILT / old, DEST / new)
        actual = digest(DEST / new)
        if actual != manifest['files'][old]['sha256']:
            raise RuntimeError('Delivery copy verification failed: ' + new)
        copied[new] = {**manifest['files'][old], 'original_archive_name': old}
    shutil.copy2(PROJECT / 'BUILD_INFO.json', DEST / 'BUILD-Validated.json')
    remapped = {**manifest, 'files': copied, 'release_label': build['release_label'],
        'release_validation_status': build['release_validation_status'],
        'validation_result': '../../chromatic-wars/artifacts/validation-1.5.1/release_validation.json'}
    (DEST / 'MANIFEST-Validated.json').write_text(json.dumps(remapped, ensure_ascii=False, indent=2) + '\n')
    checks = {}
    checksum_file = DEST / 'SHA256SUMS.txt'
    if checksum_file.exists():
        for line in checksum_file.read_text().splitlines():
            if not line.strip():
                continue
            checksum, name = line.split(None, 1)
            if len(checksum) != 64:
                raise RuntimeError('Malformed pre-existing checksum record')
            checks[name.lstrip('*')] = checksum
    for name, entry in copied.items():
        checks[name] = entry['sha256']
    checksum_file.write_text(''.join(f'{value}  {name}\n' for name, value in sorted(checks.items())))
    print(json.dumps(remapped, ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
