"""Reader and validator for the engine's JSON-lines event channel (contract section 3).

The engine emits events from Bash, one ``printf >>`` per event. This module only
reads them: it never writes an event on the engine's behalf and nothing here
touches the event file except to open it for reading.

    iter_events(path)   yield validated, normalised events (tolerant, bounded)
    validate(event)     list of problems for one event (empty when valid)
    normalise(event)    copy with ts as epoch seconds and reasons coerced

Readers ignore unknown fields and keep unknown event types aside without
crashing; ``Reader`` exposes them as ``.unknown``.
"""
import datetime
import json
import os
import re
import sys

import tui_registry

MAX_LINE = 8192 * 8        # the engine writes at most 8 KiB per line; be tolerant
MAX_BYTES = 64 * 1024 * 1024

EVENT_TYPES = ('run_start', 'phase', 'warning', 'disk_space', 'group_start', 'group_total', 'group_sized', 'item_start',
               'item_progress', 'item_end', 'group_end', 'prompt', 'plan_written', 'run_end')
MODES = ('dry-run', 'plan', 'interactive', 'auto-safe', 'apply-plan', 'restore', 'list-quarantine',
         'purge-quarantine', 'prune-artifacts', 'unattended', 'doctor')
REMOVE_MODES = ('quarantine', 'permanent')
PHASES = ('preflight', 'scan', 'plan', 'clean', 'verify', 'report')
PHASE_STATUS = ('start', 'end')
PHASE_RESULTS = ('ok', 'warn', 'error', 'skipped')
ACTION_NAMES = ('scan', 'preview', 'clean_safe', 'clean_selected', 'apply_plan', 'restore', 'purge')
# Phases each action goes through (contract section 11).
ACTION_PHASES = dict(
    scan=('preflight', 'scan', 'report'),
    preview=('preflight', 'scan', 'plan', 'report'),
    clean_safe=('preflight', 'scan', 'plan', 'clean', 'verify', 'report'),
    clean_selected=('preflight', 'scan', 'plan', 'clean', 'verify', 'report'),
    apply_plan=('preflight', 'scan', 'plan', 'clean', 'verify', 'report'),
    restore=('preflight', 'clean', 'verify', 'report'),
    purge=('preflight', 'clean', 'verify', 'report'),
)
# Weights of the overall percentage (renormalised over the phases in the run).
PHASE_WEIGHTS = dict(preflight=5, scan=35, plan=5, clean=45, verify=5, report=5)
WARNING_CODES = ('fda_missing', 'backup_missing', 'snapshots_retain_space', 'legacy_layout', 'scan_partial',
                 'rules_overlay_invalid', 'env_ignored', 'consent_no_terminal')
DISK_PHASES = ('before', 'after')
GROUP_PHASES = ('scan', 'clean')
TIERS = tui_registry.TIERS
ACTIONS = ('remove', 'native', 'report')
UNDO = ('quarantine', 'none')
ITEM_PHASES = ('measuring', 'checking', 'moving', 'deleting', 'running', 'verifying')
ITEM_RESULTS = ('cleaned', 'quarantined', 'restored', 'skipped', 'failed', 'unavailable', 'report_only', 'dry_run')
REASONS = ('in_use', 'protected_path', 'permission_denied', 'fda_missing', 'too_recent', 'user_declined',
           'native_failed', 'timeout', 'not_found', 'needs_permanent', 'identity_changed', 'risk_escalated',
           'review_not_included', 'dangerous_blocked', 'backup_running', 'unreadable', 'outside_category_root',
           'plan_rejected', 'destination_exists', 'parent_missing', 'unknown')
GROUP_RESULTS = ('ok', 'warn', 'error', 'skipped', 'unknown')
COUNT_KEYS = ('cleaned', 'quarantined', 'restored', 'skipped', 'failed', 'unavailable', 'report_only', 'dry_run')
PROMPT_KINDS = ('yesno', 'text')
RUN_RESULTS = ('ok', 'warn', 'error', 'cancelled')
UNITS = ('bytes', 'count')
CATEGORY_OUTCOMES = ('cleaned', 'partial', 'failed', 'skipped', 'not_processed', 'report_only', 'not_run', 'dry_run')
COMMON = ('ts', 'type', 'run_id', 'seq')


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _is_str(value):
    return isinstance(value, str)


def parse_ts(value):
    """Epoch seconds (float) from an integer, a numeric string or an ISO 8601
    string; None when it cannot be read."""
    if _is_int(value) or (isinstance(value, float) and value == value):
        return float(value) if value >= 0 else None
    if _is_str(value):
        text = value.strip()
        if re.fullmatch(r'[0-9]{1,12}', text):
            return float(text)
        try:
            return datetime.datetime.fromisoformat(text.replace('Z', '+00:00')).timestamp()
        except ValueError:
            return None
    return None


def normalise_reason(reason):
    """Reason codes outside the contract's list become ``unknown``; '' stays ''."""
    if reason in (None, ''):
        return ''
    return reason if reason in REASONS else 'unknown'


def _need(event, key, check, problems, what):
    if key not in event:
        problems.append('missing %s' % key)
    elif not check(event[key]):
        problems.append('bad %s (%s)' % (key, what))


def _group(value):
    return _is_str(value) and value in tui_registry.GROUP_IDS


def _optional(event, key, check, problems, what):
    if key in event and event[key] is not None and not check(event[key]):
        problems.append('bad %s (%s)' % (key, what))


def validate(event):
    """Problems found in one event, as short strings. Unknown types are not
    problems (they are kept aside); unknown fields are ignored."""
    if not isinstance(event, dict):
        return ['not an object']
    problems = []
    kind = event.get('type')
    if not _is_str(kind):
        return ['missing type']
    if 'ts' not in event or parse_ts(event.get('ts')) is None:
        problems.append('bad ts')
    if kind not in EVENT_TYPES:
        return problems
    one_of = lambda values: (lambda v: v in values)       # noqa: E731
    if kind == 'run_start':
        _need(event, 'version', _is_str, problems, 'string')
        _need(event, 'mode', one_of(MODES), problems, 'mode')
        _need(event, 'remove_mode', one_of(REMOVE_MODES), problems, 'remove_mode')
        _need(event, 'dry_run', lambda v: isinstance(v, bool), problems, 'bool')
        _need(event, 'groups', lambda v: isinstance(v, list) and all(_group(g) for g in v), problems, 'group ids')
        _need(event, 'paths', lambda v: isinstance(v, dict), problems, 'object')
        _optional(event, 'phases', lambda v: isinstance(v, list) and all(p in PHASES for p in v), problems, 'phase ids')
        _optional(event, 'action', _is_str, problems, 'string')
    elif kind == 'phase':
        _need(event, 'phase', _is_str, problems, 'phase id')
        _need(event, 'status', one_of(PHASE_STATUS), problems, 'status')
        _optional(event, 'result', one_of(PHASE_RESULTS), problems, 'result')
        _optional(event, 'seconds', _is_int, problems, 'int')
        if event.get('status') == 'start' and ('result' in event or 'seconds' in event):
            problems.append('result and seconds only on end')
    elif kind == 'warning':
        _need(event, 'code', one_of(WARNING_CODES), problems, 'code')
        _need(event, 'text', _is_str, problems, 'string')
    elif kind == 'disk_space':
        _need(event, 'phase', one_of(DISK_PHASES), problems, 'phase')
        _need(event, 'free_bytes', _is_int, problems, 'int')
        _optional(event, 'source', one_of(('diskutil', 'df')), problems, 'source')
        _optional(event, 'snapshots', _is_int, problems, 'int')
    elif kind == 'group_start':
        _need(event, 'group', _group, problems, 'group id')
        _need(event, 'phase', one_of(GROUP_PHASES), problems, 'phase')
        _optional(event, 'tier', one_of(TIERS), problems, 'tier')
        _optional(event, 'section', _is_str, problems, 'section id')
    elif kind == 'group_total':
        _need(event, 'group', _group, problems, 'group id')
        _need(event, 'total', _is_int, problems, 'int')
    elif kind == 'group_sized':
        _need(event, 'group', _group, problems, 'group id')
        _need(event, 'estimated_bytes', _is_int, problems, 'int')
        _need(event, 'items', _is_int, problems, 'int')
        _optional(event, 'partial', lambda v: isinstance(v, bool), problems, 'bool')
        _optional(event, 'unit', one_of(UNITS), problems, 'unit')
    elif kind == 'item_start':
        _need(event, 'group', _group, problems, 'group id')
        _need(event, 'id', lambda v: _is_str(v) and v != '' and not re.search(r'[|\t\n]', v), problems, 'item id')
        _optional(event, 'estimated_bytes', _is_int, problems, 'int')
        _optional(event, 'action', one_of(ACTIONS), problems, 'action')
        _optional(event, 'undo', one_of(UNDO), problems, 'undo')
    elif kind == 'item_progress':
        _need(event, 'group', _group, problems, 'group id')
        _need(event, 'id', _is_str, problems, 'item id')
        _need(event, 'phase', one_of(ITEM_PHASES), problems, 'phase')
        _optional(event, 'percent', lambda v: _is_int(v) and 0 <= v <= 100, problems, '0..100')
    elif kind == 'item_end':
        _need(event, 'group', _group, problems, 'group id')
        _need(event, 'id', _is_str, problems, 'item id')
        _need(event, 'result', one_of(ITEM_RESULTS), problems, 'result')
        _optional(event, 'estimated_bytes', _is_int, problems, 'int')
        _optional(event, 'freed_bytes', _is_int, problems, 'int')
        if event.get('result') in ('skipped', 'failed') and not event.get('reason'):
            problems.append('missing reason')
        if event.get('reason') not in (None, '') and event.get('reason') not in REASONS:
            problems.append('bad reason')
    elif kind == 'group_end':
        _need(event, 'group', _group, problems, 'group id')
        _need(event, 'phase', one_of(GROUP_PHASES), problems, 'phase')
        _need(event, 'result', one_of(GROUP_RESULTS), problems, 'result')
        _optional(event, 'counts', lambda v: isinstance(v, dict) and all(
            k in COUNT_KEYS and _is_int(n) for k, n in v.items()), problems, 'counts')
    elif kind == 'prompt':
        _need(event, 'id', lambda v: _is_str(v) and v != '', problems, 'string')
        _need(event, 'kind', one_of(PROMPT_KINDS), problems, 'kind')
        _need(event, 'text', _is_str, problems, 'string')
        _optional(event, 'options', lambda v: isinstance(v, list), problems, 'list')
    elif kind == 'plan_written':
        _need(event, 'path', _is_str, problems, 'string')
        _need(event, 'operations', _is_int, problems, 'int')
    elif kind == 'run_end':
        _need(event, 'result', one_of(RUN_RESULTS), problems, 'result')
        _need(event, 'exit_code', _is_int, problems, 'int')
        _optional(event, 'estimated_bytes', _is_int, problems, 'int')
        _optional(event, 'freed_bytes', _is_int, problems, 'int')
        _optional(event, 'quarantined_bytes', _is_int, problems, 'int')
    return problems


def normalise(event):
    """A copy of ``event`` with ``ts`` as epoch seconds and an out-of-list
    ``reason`` replaced by ``unknown``. Other fields are left untouched."""
    out = dict(event)
    ts = parse_ts(event.get('ts'))
    if ts is not None:
        out['ts'] = ts
    if 'reason' in out:
        out['reason'] = normalise_reason(out['reason'])
    return out


def parse_line(raw):
    """One event from a line of bytes or text; None for blank, oversized or
    malformed lines and for objects without a string ``type``."""
    if isinstance(raw, bytes):
        if len(raw) > MAX_LINE:
            return None
        raw = raw.decode('utf-8', 'replace')
    raw = raw.strip()
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except ValueError:
        return None
    if isinstance(value, dict) and _is_str(value.get('type')):
        return normalise(value)
    return None


class Reader:
    """Incremental reader. ``unknown`` collects events whose type is not in the
    contract; ``invalid`` counts lines that parsed but failed validation (they
    are still delivered, so a newer engine never hides progress)."""

    def __init__(self, path):
        self.path = path
        self.offset = 0
        self.partial = b''
        self.unknown = []
        self.invalid = 0
        self.last_seq = 0

    def read(self, limit=262144):
        try:
            with open(self.path, 'rb') as handle:
                handle.seek(self.offset)
                data = handle.read(limit)
        except OSError:
            return []
        if not data:
            return []
        self.offset += len(data)
        lines = (self.partial + data).split(b'\n')
        self.partial = lines.pop()
        if len(self.partial) > MAX_LINE:
            self.partial = b''
        events = []
        for raw in lines:
            event = parse_line(raw)
            if event is None:
                continue
            if event['type'] not in EVENT_TYPES:
                self.unknown.append(event)
                continue
            if validate(event):
                self.invalid += 1
            if _is_int(event.get('seq')):
                self.last_seq = event['seq']
            events.append(event)
        return events


def iter_events(path):
    """Yield every well-formed known event of a finished (or running) file."""
    return iter_events_with(Reader(path))


def read_all(path):
    """(events, unknown_events, invalid_count) for a file."""
    reader = Reader(path)
    events = list(iter_events_with(reader))
    return events, reader.unknown, reader.invalid


def iter_events_with(reader):
    total = 0
    while total < MAX_BYTES:
        before = reader.offset
        chunk = reader.read()
        for event in chunk:
            yield event
        total = reader.offset
        if reader.offset == before:
            break


def check_stream(events):
    """Contract-level checks over a whole run: run_start first, run_end last,
    seq strictly increasing, every item_end preceded by its item_start.
    Returns a list of problems."""
    problems = []
    kinds = [e.get('type') for e in events]
    if not kinds or kinds[0] != 'run_start':
        problems.append('run_start is not first')
    if not kinds or kinds[-1] != 'run_end':
        problems.append('run_end is not last')
    seq = 0
    started = set()
    listed = None
    starts, ends = {}, {}
    for event in events:
        if event.get('type') == 'run_start' and isinstance(event.get('phases'), list):
            listed = list(event['phases'])
        elif event.get('type') == 'phase':
            table = starts if event.get('status') == 'start' else ends
            table[event.get('phase')] = table.get(event.get('phase'), 0) + 1
        value = event.get('seq')
        if _is_int(value):
            if value <= seq:
                problems.append('seq not increasing at %s' % value)
            seq = value
        if event.get('type') == 'item_start':
            started.add((event.get('group'), event.get('id')))
        elif event.get('type') == 'item_end' and (event.get('group'), event.get('id')) not in started:
            problems.append('item_end without item_start: %s/%s' % (event.get('group'), event.get('id')))
    if listed is not None:
        for phase in listed:
            if ends.get(phase, 0) != 1:
                problems.append('phase %s needs exactly one end' % phase)
            if starts.get(phase, 0) > 1:       # a skipped phase has an end and no start
                problems.append('phase %s has more than one start' % phase)
        for phase in list(starts) + list(ends):
            if phase not in listed:
                problems.append('phase %s is not in run_start.phases' % phase)
    return problems


def _main(argv):
    if len(argv) != 2 or argv[0] != 'check':
        print('Usage: mc_events.py check EVENTS.jsonl', file=sys.stderr)
        return 2
    if not os.path.isfile(argv[1]):
        print('No such file.', file=sys.stderr)
        return 2
    events, unknown, invalid = read_all(argv[1])
    problems = check_stream(events)
    for event in events:
        for problem in validate(event):
            problems.append('%s: %s' % (event.get('type'), problem))
    for problem in problems:
        print(problem)
    print('%d events, %d unknown, %d invalid' % (len(events), len(unknown), invalid))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(_main(sys.argv[1:]))
