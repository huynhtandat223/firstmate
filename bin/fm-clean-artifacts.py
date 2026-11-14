#!/usr/bin/env python3
"""Back up and remove terminal tasks' local artifacts.

Usage: fm-clean-artifacts.py [TASK | --sweep] [--apply]
Defaults to a read-only dry run. FM_HOME is required. FM_DATA_OVERRIDE and
FM_STATE_OVERRIDE follow the home contract. Archives and attached Markdown
manifests live in data/artifact-archives, never in a removal root.
Only done/archived 5001 records with a definitely absent worker are eligible.
Unknown ownership, symlinks, special files and repositories with unlanded work
are refused. Files are conservatively archived even when 5001 may hold a copy.
No pool slots or shared caches are administered. Python standard library only.
"""
import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
PROTECTED = {'artifact-archives', 'handoffs', 'retro', 'project-rules', 'verify'}


def command(args, env=None):
    result = subprocess.run([str(x) for x in args], capture_output=True, text=True,
                            timeout=120, env=env)
    if result.returncode:
        raise ValueError(result.stderr.strip() or result.stdout.strip() or 'command failed')
    return result.stdout


def task_call(*args):
    return command([os.environ.get('FM_CLEAN_TASK_READER', os.environ.get('FM_VERIFY_GATE_TASK', os.environ.get('FM_TASK_SHADOW_WRITER', str(HERE / 'fm-task.sh')))), *args])


def fingerprint(file):
    before = file.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError('not a private regular file: ' + str(file))
    digest = hashlib.sha256()
    with file.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    after = file.lstat()
    if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
        raise ValueError('file changed: ' + str(file))
    return {'path': str(file), 'size': after.st_size, 'sha256': digest.hexdigest()}


def safe_directory(directory):
    current = directory
    while current != current.parent:
        if current.is_symlink():
            raise ValueError('symlink path: ' + str(current))
        current = current.parent


def worker_absent(meta):
    if not meta.exists():
        return
    safe_directory(meta)
    result = command(['bash', '-c', '. "$1/fm-backend.sh"; b=$(fm_backend_of_meta "$2") || exit 1; '
                      't=$(fm_backend_target_of_meta "$2") || exit 1; [ -n "$t" ] || exit 1; '
                      'fm_backend_agent_alive "$b" "$t"', 'artifact-check', HERE, meta]).strip()
    if result != 'dead':
        raise ValueError('worker is live or unreadable')


def repository_safe(root):
    # Check both an enclosing repository and any nested repository before backup.
    repositories = set()
    enclosing = subprocess.run(['git', '-C', str(root), 'rev-parse', '--show-toplevel'],
                               capture_output=True, text=True)
    if enclosing.returncode == 0:
        parent = Path(enclosing.stdout.strip())
        relative = str(root.relative_to(parent))
        ignored = subprocess.run(['git', '-C', str(parent), 'check-ignore', '-q', relative], capture_output=True)
        if ignored.returncode != 0:
            repositories.add(parent)
    for base, dirs, files in os.walk(root, followlinks=False):
        if '.git' in dirs or '.git' in files:
            repositories.add(Path(base))
        dirs[:] = [d for d in dirs if d != '.git']
    for repo in repositories:
        if command(['git', '-C', repo, 'status', '--porcelain', '--untracked-files=all']).strip():
            raise ValueError('uncommitted work: ' + str(repo))
        branches = command(['git', '-C', repo, 'for-each-ref', '--format=%(refname)', 'refs/heads']).splitlines()
        for branch in branches:
            upstream = subprocess.run(['git', '-C', str(repo), 'rev-parse', '--verify', branch + '@{upstream}'],
                                      capture_output=True, text=True)
            if upstream.returncode or command(['git', '-C', repo, 'rev-list', branch, '--not', '--remotes']).strip():
                raise ValueError('unpushed or untracked branch: ' + str(repo))


def roots_for(task, data, state):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', task) or task in PROTECTED or task.startswith('captain') or task == 'learnings.md':
        raise ValueError('protected or invalid task id')
    roots = [data / task, data / 'verify' / task]
    meta = state / (task + '.meta')
    worker_absent(meta)
    if meta.exists():
        values = dict(line.split('=', 1) for line in meta.read_text().splitlines() if '=' in line)
        tmp = values.get('tasktmp', '')
        if tmp:
            candidate = Path(tmp)
            if candidate != Path('/tmp') / ('fm-' + task):
                raise ValueError('unrecognized recorded tasktmp: ' + tmp)
            roots.append(candidate)
    return [root for root in roots if root.exists() or root.is_symlink()]


def snapshot(roots):
    entries = []
    for root in roots:
        safe_directory(root)
        if not root.is_dir():
            raise ValueError('root is not a directory: ' + str(root))
        repository_safe(root)
        for base, dirs, files in os.walk(root, followlinks=False):
            for name in dirs:
                child = Path(base) / name
                if child.is_symlink():
                    raise ValueError('symlink directory: ' + str(child))
            for name in sorted(files):
                entries.append(fingerprint(Path(base) / name))
    return sorted(entries, key=lambda entry: entry['path'])


def check_record(task):
    row = json.loads(task_call('show', task, '--json'))
    if row.get('state') not in ('done', 'archived') or row.get('holdUntil') or row.get('backlogHoldReason'):
        raise ValueError('record is not terminal or is held')
    return row


def classify(task, entries):
    copies = {item['sha256']: item['reference'] for item in json.loads(task_call('artifact-copies', task))}
    for entry in entries:
        parts = Path(entry['path']).parts
        if entry['sha256'] in copies:
            entry['copy'] = copies[entry['sha256']]
        elif any(part in {'node_modules', '__pycache__', '.pytest_cache', '.mypy_cache', '.next', '.nuxt', '.cache'} for part in parts):
            entry['copy'] = 'regenerable'
        else:
            entry['copy'] = 'archive:' + entry['path'].lstrip('/')
    return entries


def pack(stream, entries):
    with tarfile.open(fileobj=stream, mode='w:gz') as archive:
        for entry in entries:
            if entry['copy'].startswith('archive:'):
                archive.add(entry['path'], arcname=entry['path'].lstrip('/'), recursive=False)


class Counter(io.RawIOBase):
    def __init__(self):
        self.size = 0

    def writable(self):
        return True

    def write(self, content):
        self.size += len(content)
        return len(content)


def process(task, data, state, apply, if_terminal=False, teardown_tmp=False, backup_only=False, tasktmp=None):
    if if_terminal:
        row = json.loads(task_call('show', task, '--json'))
        if row.get('state') not in ('done', 'archived'):
            if teardown_tmp:
                meta = state / (task + '.meta')
                if meta.exists():
                    values = dict(line.split('=', 1) for line in meta.read_text().splitlines() if '=' in line)
                    tmp = values.get('tasktmp', '')
                    if tmp:
                        safe_directory(Path(tmp))
                        if Path(tmp) != Path('/tmp') / ('fm-' + task):
                            raise ValueError('unrecognized recorded tasktmp: ' + tmp)
                        if Path(tmp).exists():
                            shutil.rmtree(tmp)
            return None
    check_record(task)
    roots = roots_for(task, data, state)
    if tasktmp:
        candidate = Path(tasktmp)
        if candidate != Path('/tmp') / ('fm-' + task):
            raise ValueError('unrecognized tasktmp')
        if candidate.exists() and candidate not in roots:
            roots.append(candidate)
    if not roots:
        return None
    entries = classify(task, snapshot(roots))
    gross = sum(entry['size'] for entry in entries)
    if not apply:
        counter = Counter()
        pack(counter, entries)
        return gross, counter.size
    destination = data / 'artifact-archives' / task
    safe_directory(destination)
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (destination / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        # Unique backup generations retain the original copy across a partial retry.
        generation = Path(tempfile.mkdtemp(prefix='backup-', dir=destination))
        archive_path = generation / 'files.tar.gz'
        with archive_path.open('xb') as stream:
            pack(stream, entries)
            stream.flush()
            os.fsync(stream.fileno())
        with tarfile.open(archive_path, 'r:gz') as archive:
            for entry in entries:
                if not entry['copy'].startswith('archive:'):
                    continue
                stream = archive.extractfile(entry['path'].lstrip('/'))
                digest = hashlib.sha256()
                while chunk := stream.read(1024 * 1024):
                    digest.update(chunk)
                if digest.hexdigest() != entry['sha256']:
                    raise ValueError('archive verification failed')
        manifest = generation / 'manifest.md'
        content = '# Artifact backup: ' + task + '\n\n'
        content += 'Archive: ' + str(archive_path) + '\n\n'
        content += '```json\n' + json.dumps(entries, ensure_ascii=True, indent=2) + '\n```\n'
        manifest.write_text(content)
        with manifest.open('rb') as stream:
            os.fsync(stream.fileno())
        task_call('comment', task, '--note', 'Local artifact backup manifest', '--document', manifest,
                  '--document-title', 'Artifact backup manifest', '--key', 'artifact-backup:' + task + ':' + generation.name)
        check_record(task)
        worker_absent(state / (task + '.meta'))
        if snapshot(roots) != [{k: v for k, v in entry.items() if k != 'copy'} for entry in entries]:
            raise ValueError('task files or ownership changed before removal')
        if not backup_only:
            for root in roots:
                shutil.rmtree(root)
        return gross, archive_path.stat().st_size + manifest.stat().st_size


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('task', nargs='?')
    parser.add_argument('--sweep', action='store_true')
    parser.add_argument('--backup-only', action='store_true', help='verify and attach backup without deleting roots')
    parser.add_argument('--tasktmp', help='carry recorded tasktmp across teardown record retirement')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--teardown-tmp', action='store_true', help='retain the existing nonterminal teardown temp removal')
    parser.add_argument('--if-terminal', action='store_true', help='leave nonterminal records untouched')
    args = parser.parse_args()
    if bool(args.task) == args.sweep:
        parser.error('give one TASK or --sweep')
    os.umask(0o077)
    try:
        home = Path(os.environ['FM_HOME'])
        data = Path(os.environ.get('FM_DATA_OVERRIDE', str(home / 'data')))
        state = Path(os.environ.get('FM_STATE_OVERRIDE', str(home / 'state')))
        safe_directory(data)
        safe_directory(state)
        tasks = [args.task] if args.task else [row['taskId'] for row in json.loads(task_call('list', '--json')) if row['state'] in ('done', 'archived')]
        count = gross = archive = failures = 0
        for task in tasks:
            try:
                result = process(task, data, state, args.apply, args.if_terminal, args.teardown_tmp and args.apply, args.backup_only, args.tasktmp)
                if result:
                    count += 1
                    gross += result[0]
                    archive += result[1]
                    print('task: ' + json.dumps(task) + '\ngrossBytes: ' + str(result[0]) + '\narchiveBytes: ' + str(result[1]))
            except (ValueError, OSError, subprocess.TimeoutExpired) as error:
                failures += 1
                print('kept: ' + json.dumps(task) + '\nreason: ' + json.dumps(str(error)))
        print('mode: ' + ('apply' if args.apply else 'dry-run') + '\neligibleTasks: ' + str(count) +
              '\ngrossBytes: ' + str(gross) + '\narchiveBytes: ' + str(archive) + '\nnetBytes: ' + str(gross - archive) + '\nkeptTasks: ' + str(failures))
        return 1 if failures and args.task else 0
    except (KeyError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        print('error: ' + json.dumps(str(error)) + '\nhelp: set FM_HOME and use --help', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
