#!/usr/bin/env python3
"""Back up the SQLite task record, or restore it into a NEW scratch database.

backup --source DB --directory DIR [--keep-days 30] [--dry-run]
restore --backup DB --scratch DB --task TASK_ID

The source must be the managed runtime database, not the app's root forge.db.
Uses SQLite online backup (includes committed WAL), then removes non-task tables
from the private snapshot. Includes every fm_* table, including owner items.
Retention deletes only this tool's dated snapshots after a successful backup.
Restore never writes an existing path and is NOT a live-database restore command.
Dependencies: Python 3 standard library. Output is a flat TOON object.
"""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile

REQUIRED = {'fm_task', 'fm_task_event', 'fm_event_document', 'fm_task_check',
            'fm_owner_check', 'fm_task_link'}


def read_db(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)


def tables(db):
    return {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def validate(db):
    missing = REQUIRED - tables(db)
    if missing:
        raise ValueError('missing task tables: ' + ', '.join(sorted(missing)))
    if db.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
        raise ValueError('database integrity check failed')
    return db.execute('SELECT count(*) FROM fm_task').fetchone()[0]


def quoted(name):
    return '"' + name.replace('"', '""') + '"'


def backup(args):
    with read_db(args.source) as source:
        count = validate(source)
        if args.dry_run:
            print('status: dry-run\ntasks: ' + str(count))
            return
        directory = Path(args.directory)
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        if directory.is_symlink() or directory.stat().st_uid != os.getuid() or directory.stat().st_mode & 0o077:
            raise ValueError('backup directory must be owned by this user with mode 0700')
        with (directory / '.backup.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            fd, temporary = tempfile.mkstemp(prefix='.snapshot-', dir=directory)
            os.close(fd)
            try:
                with sqlite3.connect(temporary) as target:
                    source.backup(target)
                    for name in tables(target):
                        if not name.startswith('fm_') and not name.startswith('sqlite_'):
                            target.execute('DROP TABLE ' + quoted(name))
                    target.commit()
                    # Removed tables must not remain recoverable in free pages.
                    target.execute('VACUUM')
                    count = validate(target)
                    target.execute('PRAGMA journal_mode=DELETE')
                target.close()
                now = datetime.datetime.now(datetime.timezone.utc)
                final = directory / ('fm-task-' + now.strftime('%Y%m%dT%H%M%S%fZ') + '.sqlite3')
                with open(temporary, 'rb') as handle:
                    os.fsync(handle.fileno())
                os.rename(temporary, final)
                cutoff = now.timestamp() - args.keep_days * 86400
                for old in directory.iterdir():
                    if re.fullmatch(r'fm-task-\d{8}T\d{12}Z\.sqlite3', old.name) and not old.is_symlink() and old.is_file() and old.stat().st_mtime < cutoff:
                        old.unlink()
                print('status: backed-up\nbackup: ' + json.dumps(str(final)) + '\ntasks: ' + str(count))
            finally:
                Path(temporary).unlink(missing_ok=True)


def restore(args):
    destination = Path(args.scratch)
    with read_db(args.backup) as source:
        validate(source)
        if not source.execute('SELECT 1 FROM fm_task WHERE task_id=?', (args.task,)).fetchone():
            raise ValueError('known task not found in backup')
        fd = os.open(destination, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        try:
            with sqlite3.connect(destination) as target:
                source.backup(target)
                validate(target)
                row = target.execute('SELECT task_id, title FROM fm_task WHERE task_id=?', (args.task,)).fetchone()
                if row is None:
                    raise ValueError('known task not readable after restore')
            target.close()
            print('status: restored\ntask: ' + json.dumps(row[0]) + '\ntitle: ' + json.dumps(row[1]))
        except Exception:
            destination.unlink()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    b = sub.add_parser('backup')
    b.add_argument('--source', required=True)
    b.add_argument('--directory', required=True)
    b.add_argument('--keep-days', type=int, default=30)
    b.add_argument('--dry-run', action='store_true')
    r = sub.add_parser('restore')
    r.add_argument('--backup', required=True)
    r.add_argument('--scratch', required=True)
    r.add_argument('--task', required=True)
    args = parser.parse_args()
    if args.command == 'backup' and args.keep_days < 1:
        parser.error('--keep-days must be positive')
    os.umask(0o077)
    try:
        (backup if args.command == 'backup' else restore)(args)
        return 0
    except (OSError, sqlite3.Error, ValueError) as error:
        print('error: ' + json.dumps(str(error)) + '\nhelp: check paths and use --help')
        return 1


if __name__ == '__main__':
    sys.exit(main())
