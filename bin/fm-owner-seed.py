#!/usr/bin/env python3
"""Seed owner records without deleting local sources.

Usage: fm-owner-seed.py HOME BACKUP_DIRECTORY
Copies legacy inbox, bindings and requests before uploading; reruns converge.
"""
import os
import pathlib
import shutil
import subprocess
import sys

home = pathlib.Path(sys.argv[1]).resolve()
backup = pathlib.Path(sys.argv[2]).resolve()
backup.mkdir(parents=True, exist_ok=True, mode=0o700)
root = pathlib.Path(__file__).resolve().parent
env = dict(os.environ, FM_HOME=str(home))
for name in ('inbox', 'decision-bindings', 'reconcile-requests'):
    source = home / 'state' / name
    if not source.exists():
        continue
    target = backup / name
    if target.exists():
        raise SystemExit(f'Backup already exists; choose a fresh directory: {target}')
    shutil.copytree(source, target, symlinks=True)
    print(f'backup: {target}')
    if name == 'inbox':
        subprocess.run([sys.executable, str(root / 'fm-owner-notes.py'), 'push', str(source),
                        env.get('FM_BACKLOG_HOME', 'main'), str(root / 'fm-task.sh')], env=env, check=True)
    else:
        kind, suffix = ('binding', '*.origin') if name == 'decision-bindings' else ('reconcile', '*.request')
        for path in sorted(source.glob(suffix)):
            if path.is_symlink():
                raise SystemExit(f'Unsafe legacy record: {path}')
            subprocess.run(['bash', str(root / 'fm-owner-record.sh'), 'hold-write', kind, path.stem, str(path)],
                           env=env, check=True)
print('Seed uploaded; compare public readbacks before deleting any backed-up source.')
