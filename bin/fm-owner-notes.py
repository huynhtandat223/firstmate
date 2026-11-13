#!/usr/bin/env python3
"""Materialize and replay owner notes through the authenticated task writer.

Usage: fm-owner-notes.py pull|push CACHE HOME WRITER
The cache is a machine-local outage spool, not an alternate authority.
"""
import datetime
import json
import pathlib
import re
import subprocess
import sys
import tempfile


def call(*args):
    result = subprocess.run([writer, 'owner-record', 'note', *args], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'owner-note request failed')
    return json.loads(result.stdout)


def read(path):
    header, _, body = path.read_text().partition('--\n')
    fields = dict(line.split('=', 1) for line in header.splitlines() if '=' in line)
    return fields, body


def atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as staged:
        staged.write(text)
    pathlib.Path(staged.name).replace(path)
    path.chmod(0o600)


def pull():
    for row in call('list', '--home', home):
        identity = row['noteId']
        if not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9._-]*', identity or '') or '..' in identity:
            raise ValueError('unsafe owner note identity')
        target = cache / ('handled' if row['state'] == 'handled' else '') / (identity + '.note')
        fields = {'id': identity, 'at': row['at'], 'source': row['source'], 'announce_marker': '1'}
        if row.get('requestId'):
            request = row['requestId']
            if not re.fullmatch(r'[A-Za-z0-9_:-][A-Za-z0-9._:-]*', request):
                raise ValueError('unsafe owner request identity')
            fields['request_id'] = row['requestId']
            atomic(cache / '.requests' / row['requestId'], identity + '\n')
        atomic(target, ''.join(f'{k}={v}\n' for k, v in fields.items()) + '--\n' + row['text'])
        if row['state'] == 'handled':
            (cache / (identity + '.note')).unlink(missing_ok=True)
        if row.get('announcedAt'):
            atomic(cache / '.announced' / identity, row['announcedAt'] + '\n')
        if row.get('reply') is not None:
            atomic(cache / '.replies' / identity,
                   f'id={identity}\nat={row["replyAt"]}\nseq={row["replySeq"]}\n--\n{row["reply"]}')


def push():
    for path in sorted(list(cache.glob('*.note')) + list((cache / 'handled').glob('*.note'))):
        fields, text = read(path)
        identity = fields['id']
        row = dict(home=home, noteId=identity, text=text, source=fields['source'],
                   state='handled' if path.parent.name == 'handled' else 'waiting', at=fields['at'],
                   requestId=fields.get('request_id'))
        announced = cache / '.announced' / identity
        if announced.exists():
            row['announcedAt'] = announced.read_text().strip()
        reply = cache / '.replies' / identity
        if reply.exists():
            # Replay is a reply write too: a former holder must not upload a
            # queued answer through receipts before the CLI's reply guard.
            guard = pathlib.Path(writer).with_name('fm-home-lease-lib.sh')
            checked = subprocess.run(['bash', '-c', '. "$1"; fm_home_lease_require', 'lease-replay', str(guard)], capture_output=True, text=True)
            if checked.returncode:
                raise RuntimeError('queued reply requires the active home lease; retained locally')
            reply_fields, body = read(reply)
            row.update(reply=body, replyAt=reply_fields['at'], replySeq=int(reply_fields['seq']))
        if row['state'] == 'handled':
            row['handledAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        with tempfile.NamedTemporaryFile(mode='w', dir=cache) as staged:
            json.dump(row, staged)
            staged.flush()
            saved = call('put', '--home', home, '--identity', identity, '--file', staged.name)
        if saved['noteId'] != identity:
            # Transfer local handling/reply before retiring a duplicate capture.
            merged = dict(row, noteId=saved['noteId'], source=saved['source'])
            if saved.get('reply') is not None:
                if row.get('reply') is not None and row['reply'] != saved['reply']:
                    raise ValueError('duplicate capture has a conflicting reply; retained for reconciliation')
                merged.pop('reply', None)
                merged.pop('replySeq', None)
                merged.pop('replyAt', None)
            if saved.get('state') == 'handled':
                merged['state'] = 'handled'
            with tempfile.NamedTemporaryFile(mode='w', dir=cache) as transfer:
                json.dump(merged, transfer)
                transfer.flush()
                call('put', '--home', home, '--identity', saved['noteId'], '--file', transfer.name)
            if row.get('requestId'):
                atomic(cache / '.requests' / row['requestId'], saved['noteId'] + '\n')
            path.unlink()
        elif saved.get('replySeq') and reply.exists():
            reply_fields, body = read(reply)
            atomic(reply, f'id={identity}\nat={saved["replyAt"]}\nseq={saved["replySeq"]}\n--\n{body}')


if __name__ == '__main__':
    action, directory, home, writer = sys.argv[1:]
    cache = pathlib.Path(directory)
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        {'pull': pull, 'push': push}[action]()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f'owner notes: {error}', file=sys.stderr)
        sys.exit(1)
