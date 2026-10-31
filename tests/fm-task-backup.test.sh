#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

script = Path(sys.argv[1]) / 'bin/fm-task-backup.py'
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp)
    source = root / 'source.db'
    db = sqlite3.connect(source)
    db.execute('PRAGMA journal_mode=WAL')
    db.execute('CREATE TABLE fm_task(task_id TEXT, title TEXT)')
    db.execute("INSERT INTO fm_task VALUES('probe','known task')")
    for name in ('fm_task_event', 'fm_event_document', 'fm_task_check', 'fm_owner_check', 'fm_task_link', 'fm_event_done', 'fm_event_question', 'fm_event_block', 'fm_event_image', 'fm_task_delivery', 'fm_future_child'):
        db.execute(f'CREATE TABLE {name}(value TEXT)')
        db.execute(f"INSERT INTO {name} VALUES('retained')")
    db.execute('CREATE TABLE unrelated(secret TEXT)')
    db.execute("INSERT INTO unrelated VALUES('excluded')")
    db.execute('CREATE VIRTUAL TABLE search_private USING fts5(secret)')
    db.execute("INSERT INTO search_private VALUES('sensitive-fts-literal')")
    db.execute("CREATE VIEW private_view AS SELECT 'sensitive-view-literal'")
    db.execute("CREATE TRIGGER private_trigger AFTER INSERT ON unrelated BEGIN SELECT 'sensitive-trigger-literal'; END")
    db.commit()
    def run(*args, ok=True):
        result = subprocess.run([sys.executable, str(script), *map(str, args)], capture_output=True, text=True)
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result.stdout
    directory = root / 'backups'
    run('backup', '--source', source, '--directory', directory, '--dry-run')
    assert not directory.exists()
    directory.mkdir(mode=0o700)
    abandoned = directory / '.snapshot-abandoned'
    abandoned.write_text('sensitive-abandoned-literal')
    run('backup', '--source', source, '--directory', directory)
    assert not abandoned.exists()
    snapshot = next(directory.glob('*.sqlite3'))
    assert snapshot.stat().st_mode & 0o077 == 0
    for secret in (b'sensitive-fts-literal', b'sensitive-view-literal', b'sensitive-trigger-literal'):
        assert secret not in snapshot.read_bytes()
    with sqlite3.connect(snapshot) as check:
        assert not check.execute("SELECT name FROM sqlite_master WHERE type IN ('view','trigger') OR name LIKE 'search_private%'").fetchall()
    restored = root / 'scratch.db'
    run('restore', '--backup', snapshot, '--scratch', restored, '--task', 'probe')
    with sqlite3.connect(restored) as check:
        assert check.execute('SELECT title FROM fm_task').fetchone()[0] == 'known task'
        assert check.execute('SELECT value FROM fm_owner_check').fetchone()[0] == 'retained'
        assert check.execute('SELECT value FROM fm_event_document').fetchone()[0] == 'retained'
        assert check.execute('SELECT value FROM fm_future_child').fetchone()[0] == 'retained'
        assert not check.execute("SELECT name FROM sqlite_master WHERE name='unrelated'").fetchall()
    before = restored.read_bytes()
    run('restore', '--backup', snapshot, '--scratch', restored, '--task', 'probe', ok=False)
    assert restored.read_bytes() == before
    run('restore', '--backup', snapshot, '--scratch', root/'missing.db', '--task', 'absent', ok=False)
    assert not (root/'missing.db').exists()
    old = directory / 'fm-task-20000101T000000000000Z.sqlite3'
    old.write_bytes(b'old')
    unrelated = directory / 'keep.sqlite3'
    unrelated.write_bytes(b'keep')
    for path in (old, unrelated):
        os.utime(path, (0,0))
    run('backup', '--source', source, '--directory', directory, '--keep-days', 1)
    assert not old.exists() and unrelated.exists()
    for missing in ('fm_owner_check', 'fm_event_done', 'fm_event_question', 'fm_event_block', 'fm_event_image', 'fm_task_delivery'):
        db.execute('ALTER TABLE ' + missing + ' RENAME TO temporarily_absent')
        db.commit()
        run('backup', '--source', source, '--directory', directory, ok=False)
        db.execute('ALTER TABLE temporarily_absent RENAME TO ' + missing)
        db.commit()
    assert unrelated.exists()
    run('backup', '--source', source, '--directory', directory, '--typo', ok=False)
    db.close()
print('PASS: WAL snapshot, task children, private output, dry run, restore guards, retention, missing schema, unknown flags')
PY
