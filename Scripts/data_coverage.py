#!/usr/bin/env python3
"""Read-only data coverage report for Agent Stats.

Aggregates what the host stores, what the app can read, and where the two
disagree. Prints counts and token totals only; no session content leaves the
report. Uses only the standard library.

    python3 Scripts/data_coverage.py                # both providers
    python3 Scripts/data_coverage.py --provider codex
"""
import argparse
import collections
import json
import os
import pathlib
import sqlite3
import sys

SUPPORT = pathlib.Path.home() / 'Library' / 'Application Support' / 'Agent Stats'


def expand(value):
    return pathlib.Path(os.path.expanduser(value))


def parse_cache(provider):
    path = SUPPORT / f'parse-cache-{provider}.json'
    try:
        return json.loads(path.read_text()).get('entries', {})
    except Exception:
        return {}


def journal_tokens(entry):
    journal = entry.get('journal') or {}
    records = journal.get('records') or {}
    if records:
        return sum((r.get('totalTokens') or 0) for r in records.values()), 'requests'
    cumulative = journal.get('cumulative')
    if cumulative:
        return cumulative.get('totalTokens') or 0, 'cumulative'
    return 0, 'none'


def codex_report(data_root):
    root = expand(data_root)
    db = next(iter(sorted(root.glob('state_*.sqlite'), reverse=True)), None)
    if db is None:
        print(f'codex: no state_*.sqlite under {root}')
        return
    connection = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
    columns = {row[1] for row in connection.execute('PRAGMA table_info(threads)')}
    select = ('SELECT id, rollout_path, archived, '
              + ('tokens_used' if 'tokens_used' in columns else 'NULL') + ' FROM threads')
    rows = list(connection.execute(select))
    kinds = collections.Counter()
    host_tokens = collections.Counter()
    unreadable = 0
    compressed = 0
    for _, path, archived, tokens in rows:
        exists = os.path.exists(path)
        kind = ('plain' if not path.endswith('.zst') else 'zst-path') + ('' if exists else '+missing')
        if not exists and os.path.exists(path + '.zst'):
            kind += ' (zst twin)'
        elif not exists:
            unreadable += 1
        if 'zst' in kind:
            compressed += 1
        kinds[('archived' if archived else 'visible', kind)] += 1
        host_tokens['archived' if archived else 'visible'] += tokens or 0
    cache = parse_cache('codex')
    parsed, parsed_modes = 0, collections.Counter()
    for entry in cache.values():
        tokens, mode = journal_tokens(entry)
        parsed += tokens
        parsed_modes[mode] += 1
    pages = collections.Counter()
    names = collections.defaultdict(list)
    pattern = ('rollout-.*?([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
               '[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    import re
    expression = re.compile(pattern)
    for directory in ('sessions', 'archived_sessions'):
        for base, _, files in os.walk(root / directory):
            for name in files:
                match = expression.match(name)
                if match and (name.endswith('.jsonl') or name.endswith('.jsonl.zst')):
                    names[match.group(1)].append(name)
    for group in names.values():
        if len(group) > 1:
            pages['multi-page threads'] += 1
    print(f'codex: {len(rows)} catalogued threads ({db.name})')
    for (where, kind), count in sorted(kinds.items()):
        print(f'  {where:8} {kind:24} {count:4}')
    print(f'  host tokens_used: visible {host_tokens["visible"]:,} / archived {host_tokens["archived"]:,}')
    print(f'  parse cache entries: {len(cache)} ({dict(parsed_modes)}), journal tokens {parsed:,}')
    for key, count in pages.items():
        print(f'  {key}: {count}')
    if compressed:
        print(f'  compressed rollouts decoded by the zstd reader: {compressed}')
    if unreadable:
        print(f'  ! {unreadable} threads have no rollout bytes at all; their totals can only'
              ' fall back to the host counter')


def kimi_report(data_root):
    root = expand(data_root)
    sessions = [p for p in (root / 'sessions').glob('*/*') if p.is_dir()]
    archived = 0
    wires = 0
    for session in sessions:
        state = session / 'state.json'
        try:
            if json.loads(state.read_text()).get('archived'):
                archived += 1
        except Exception:
            pass
        wires += len(list((session / 'agents').glob('*/wire.jsonl'))) if (session / 'agents').is_dir() else 0
    cache = parse_cache('kimi')
    parsed, parsed_modes = 0, collections.Counter()
    for entry in cache.values():
        tokens, mode = journal_tokens(entry)
        parsed += tokens
        parsed_modes[mode] += 1
    tasks = len(list((root / 'sessions').glob('*/*/agents/*/tasks/*.json')))
    print(f'kimi: {len(sessions)} sessions ({archived} archived, {len(sessions) - archived} visible), '
          f'{wires} agent logs, {tasks} task records')
    print(f'  parse cache entries: {len(cache)} ({dict(parsed_modes)}), journal tokens {parsed:,}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--provider', choices=['codex', 'kimi', 'all'], default='all')
    args = parser.parse_args()
    if args.provider in ('codex', 'all'):
        codex_report(os.environ.get('CODEX_HOME', '~/.codex'))
    if args.provider in ('kimi', 'all'):
        kimi_report(os.environ.get('KIMI_CODE_HOME', '~/.kimi-code'))
    return 0


if __name__ == '__main__':
    sys.exit(main())
