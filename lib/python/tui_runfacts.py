"""What a finished run really was, read from the files the engine left behind.

Two run-folder shapes exist. The current one holds ``events.jsonl`` (the event stream); the older one
holds only engine.log, journal.jsonl, plan.json, report.md, run.json and unreadable.tsv. Type, steps,
quarantined bytes and items, warnings and per-category sizes come from the event stream when it is there;
otherwise from run.json, journal.jsonl and the quarantine run's manifest of the same run id. A fact that
no file establishes stays unknown: a run whose type cannot be established is ``unknown``, never ``scan``.

Everything is bounded, never follows a symlink and never writes.
"""
import base64
import json
import os

import mc_events
import tui_registry
from tui_backend import open_regular
from tui_runner import MODE_TYPES, RESULT_MAP, RunModel, restore_facts

MAX_EVENTS = 8 * 1024 * 1024
MAX_JOURNAL = 16 * 1024 * 1024
MAX_MANIFEST = 16 * 1024 * 1024
MAX_REPORT = 2 * 1024 * 1024
# Only a scan or preview measures every category; a clean measures just the ones it was asked to clean.
SCAN_TYPES = ('scan', 'preview')
STRICT_MODE_TYPES = dict(MODE_TYPES, **{'dry-run-then-interactive': 'clean'})
TYPES = ('scan', 'preview', 'clean', 'apply', 'restore', 'purge', 'unattended', 'prune', 'unknown')
WARNINGS_HEADING = '## Warnings'


def run_dir(state_dir, run_id):
    return os.path.join(state_dir, 'runs', run_id)


def read_events(state_dir, run_id):
    """A RunModel replayed from <run>/events.jsonl, or None when there is no readable event stream."""
    if not tui_registry.RUN_ID_PATTERN.fullmatch(str(run_id)):
        return None
    raw = open_regular(os.path.join(run_dir(state_dir, run_id), 'events.jsonl'), MAX_EVENTS)
    if not raw:
        return None
    model = RunModel()
    seen = 0
    for line in raw.split(b'\n'):
        event = mc_events.parse_line(line)
        if event is None or event.get('type') not in mc_events.EVENT_TYPES:
            continue
        model.handle(event)
        seen += 1
    if not seen or model.events_seen == 0:
        return None
    model.from_history = True
    if model.run_end is None:
        model.finish()                      # the stream stops early: whatever was running did not end well
        model.result = 'unknown'
    return model


def read_json(path, limit=1024 * 1024):
    raw = open_regular(path, limit)
    if raw is None:
        return None
    try:
        data = json.loads(raw.decode('utf-8', 'replace'))
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def read_journal(path):
    """Quarantine facts from a run journal: (items, bytes) of the rows that say ``quarantined`` ok."""
    raw = open_regular(path, MAX_JOURNAL)
    if raw is None:
        return None
    items = total = 0
    for line in raw.split(b'\n'):
        if b'"quarantined"' not in line:
            continue
        try:
            row = json.loads(line.decode('utf-8', 'replace'))
        except ValueError:
            continue
        if isinstance(row, dict) and row.get('action') == 'quarantined' and row.get('status') == 'ok':
            items += 1
            size = row.get('bytes')
            total += size if isinstance(size, int) and not isinstance(size, bool) and size >= 0 else 0
    return items, total


def read_manifest(quarantine_dir, run_id):
    """(items, bytes) from <quarantine>/<run id>/manifest.tsv (base64 path, base64 origin, size), or None."""
    if not quarantine_dir or not tui_registry.RUN_ID_PATTERN.fullmatch(str(run_id)):
        return None
    raw = open_regular(os.path.join(quarantine_dir, run_id, 'manifest.tsv'), MAX_MANIFEST)
    if raw is None:
        return None
    items = total = 0
    for line in raw.split(b'\n'):
        parts = line.rstrip(b'\r').split(b'\t')
        if len(parts) < 2:
            continue
        try:
            if not base64.b64decode(parts[0]) or not base64.b64decode(parts[1]):
                continue
        except ValueError:
            continue
        items += 1
        if len(parts) > 2 and parts[2].isdigit():
            total += int(parts[2])
    return items, total


def report_warnings(state_dir, run_id):
    """The lines of report.md's 'Warnings & Notes' section (the engine's own list of what it warned about)."""
    raw = open_regular(os.path.join(run_dir(state_dir, run_id), 'report.md'), MAX_REPORT)
    if raw is None:
        return []
    out, inside = [], False
    for line in raw.decode('utf-8', 'replace').splitlines():
        if line.startswith('## '):
            inside = line.startswith(WARNINGS_HEADING)
            continue
        if inside and line.lstrip().startswith('- '):
            text = line.lstrip()[2:]
            for mark in ('⚠️', '⚠', 'ℹ️', 'ℹ'):
                text = text.replace(mark, '')
            text = text.strip()
            if text:
                out.append(text[:300])
    return out


# The engine's advisory notes carry no category; these phrases name the category they are about.
NOTE_HINTS = (('time machine backup', ''), ('contains messages, attachments', 'mail-data'), ('mail download', 'mail-downloads'),
              ('apple mail', 'mail-data'), ('profiles/cookies', 'browser-data'), ('cookies', 'browser-data'),
              ('browser', 'browser-caches'), ('heuristic', 'app-leftovers'), ('heurystyk', 'app-leftovers'), ('heuristique', 'app-leftovers'), ('heurística', 'app-leftovers'),
              ('euristica', 'app-leftovers'), ('vor löschung prüfen', 'app-leftovers'), ('large_dmg_pkg', 'installers'),
              ('local apfs snapshots', 'tm-snapshots'), ('time machine', 'tm-snapshots'))


def note_category(text):
    """The category id a note is about, found by its wording; None for a general note."""
    lowered = str(text).lower()
    for phrase, ident in NOTE_HINTS:
        if phrase in lowered:
            return ident or None           # '' marks a general note that only sounds like a category
    return None


def type_from_mode(mode):
    return STRICT_MODE_TYPES.get(str(mode or ''), 'unknown')


def derived_steps(summary, folder_files, quarantined):
    """Steps evidenced by the files of an older run: [(phase id, result)]. No durations: nothing recorded them."""
    steps = []
    mode = str((summary or {}).get('mode') or '')
    scanned = bool((summary or {}).get('categories')) or mode in ('dry-run', 'plan', 'dry-run-then-interactive')
    if scanned:
        steps.append(('scan', 'ok'))
    if 'plan.json' in folder_files:
        steps.append(('plan', 'ok'))
    if quarantined or type_from_mode(mode) in ('clean', 'apply') and not (summary or {}).get('dry_run', True):
        steps.append(('clean', 'ok'))
    if 'report.md' in folder_files:
        steps.append(('report', 'ok'))
    return steps


class RunFacts:
    """What is known about one run. ``source`` is where the steps came from: events | files."""
    __slots__ = ('run_id', 'type', 'source', 'result', 'seconds', 'steps', 'estimated', 'measured', 'quarantined_bytes',
                 'quarantined_items', 'warnings', 'warning_count', 'model', 'exit_code', 'quarantine_source', 'restore')

    def __init__(self, run_id):
        self.run_id = run_id
        self.type = 'unknown'
        self.source = 'files'
        self.result = None
        self.seconds = None
        self.steps = []                  # [(phase id, result or None, seconds or None)]
        self.estimated = self.measured = None
        self.quarantined_bytes = self.quarantined_items = 0
        self.quarantine_source = ''
        self.warnings = []
        self.warning_count = 0
        self.model = None
        self.exit_code = None
        self.restore = None              # dict(items, bytes, skipped, reasons) for a restore run

    def reasons(self):
        """Why a run is marked '!': [(kind, text)]; kind is 'warning' or 'result'. Never empty for a '!' run."""
        out = [('warning', text) for text in self.warnings]
        if not out and self.result == 'warn':
            out.append(('count', str(self.warning_count)))
        elif not out and self.result in ('error', 'cancelled'):
            out.append(('result', self.result))
        return out


def gather(state_dir, quarantine_dir, row):
    """RunFacts for one history row (a dict with at least run_id; mode, result, seconds, totals optional)."""
    run_id = row['run_id']
    facts = RunFacts(run_id)
    folder = run_dir(state_dir, run_id)
    summary = read_json(os.path.join(folder, 'run.json'))
    model = read_events(state_dir, run_id)
    try:
        files = set(os.listdir(folder))
    except OSError:
        files = set()
    totals = (summary or {}).get('totals') if isinstance((summary or {}).get('totals'), dict) else {}
    # -- result, time, sizes --------------------------------------------------------------------------
    facts.result = row.get('result') or (summary or {}).get('result')
    facts.seconds = row.get('seconds') if row.get('seconds') is not None else (summary or {}).get('seconds')
    facts.exit_code = (summary or {}).get('exit_code')
    facts.estimated = row.get('estimated_bytes') if row.get('estimated_bytes') is not None else totals.get('estimated_bytes')
    facts.measured = row.get('measured_freed_bytes') if row.get('measured_freed_bytes') is not None \
        else totals.get('measured_freed_bytes')
    # -- type -----------------------------------------------------------------------------------------
    if model is not None and (model.action or model.mode):
        facts.type = model.type() if model.action in mc_events.ACTION_NAMES else type_from_mode(model.mode)
    else:
        facts.type = type_from_mode(row.get('mode') or (summary or {}).get('mode'))
    facts.model = model
    if facts.type == 'restore':
        facts.restore = restore_facts(model, totals)
    # -- steps ----------------------------------------------------------------------------------------
    if model is not None and model.phase_ids:
        facts.source = 'events'
        for pid in model.phase_ids:
            phase = model.phases[pid]
            facts.steps.append((pid, phase.result or ('skipped' if phase.state == 'off' else 'ok'), phase.elapsed()))
        if model.result and facts.result is None:
            facts.result = {'failed': 'error', 'stopped': 'cancelled'}.get(model.result, model.result)
        if model.run_end:
            if model.run_end.get('estimated_bytes') is not None:
                facts.estimated = model.run_end['estimated_bytes']
            if model.run_end.get('freed_bytes') is not None:
                facts.measured = model.run_end['freed_bytes']
    else:
        facts.steps = [(pid, result, None) for pid, result in derived_steps(summary, files, False)]
    # -- quarantine: events, then run.json, then the journal, then the manifest ---------------------
    q_bytes = q_items = None
    if model is not None and model.run_end and model.run_end.get('quarantined_bytes') is not None:
        q_bytes = model.run_end['quarantined_bytes']
        q_items = model.counts().get('quarantined', 0)
        facts.quarantine_source = 'events'
    if not q_bytes and not q_items:
        s_bytes = totals.get('quarantined_bytes') if isinstance(totals.get('quarantined_bytes'), int) else row.get('quarantined_bytes')
        s_items = totals.get('quarantined_items')
        if s_bytes or s_items:
            q_bytes, q_items, facts.quarantine_source = s_bytes or 0, s_items or 0, 'run.json'
    if not q_bytes and not q_items:
        journal = read_journal(os.path.join(folder, 'journal.jsonl'))
        if journal and (journal[0] or journal[1]):
            q_items, q_bytes, facts.quarantine_source = journal[0], journal[1], 'journal'
    if not q_bytes and not q_items:
        manifest = read_manifest(quarantine_dir, run_id)
        if manifest and (manifest[0] or manifest[1]):
            q_items, q_bytes, facts.quarantine_source = manifest[0], manifest[1], 'manifest'
    facts.quarantined_bytes, facts.quarantined_items = q_bytes or 0, q_items or 0
    if facts.type == 'unknown' and facts.quarantined_items:
        facts.type = 'clean'                    # files moved to quarantine under this run id: it cleaned
    if facts.source == 'files' and facts.quarantined_items and not any(p == 'clean' for p, _, _ in facts.steps):
        facts.steps = [(p, r, s) for p, r, s in facts.steps if p != 'report'] + [('clean', 'ok', None)] \
            + ([('report', 'ok', None)] if 'report.md' in files else [])
    # -- warnings -------------------------------------------------------------------------------------
    seen = set()
    for _, text in (model.warnings if model is not None else []):
        if text and text not in seen:
            seen.add(text)
            facts.warnings.append(text)
    for text in report_warnings(state_dir, run_id):
        if text not in seen:
            seen.add(text)
            facts.warnings.append(text)
    count = (summary or {}).get('warnings')
    facts.warning_count = count if isinstance(count, int) and not isinstance(count, bool) else len(facts.warnings)
    return facts


# -- sizes of the latest scan, for the Categories screen -------------------------------------------------------
def scan_sizes_from_model(model):
    """{category id: dict(bytes, items, partial, unit)} from a RunModel's scan groups (None without any)."""
    out = {}
    for ident, group in model.cats['scan'].items():
        if group.estimated is not None:
            out[ident] = dict(bytes=group.estimated, items=group.item_count, partial=group.partial, unit=group.unit)
    return out or None


def scan_sizes_from_plan(plan):
    """Sizes by category from a plan's operations. Categories with no operation are simply absent."""
    sums = {}
    for op in plan.get('operations') or []:
        if not isinstance(op, dict) or not tui_registry.known(str(op.get('category'))):
            continue
        size = op.get('estimated_bytes')
        slot = sums.setdefault(op['category'], dict(bytes=0, items=0, partial=False, unit='bytes'))
        slot['bytes'] += size if isinstance(size, int) and not isinstance(size, bool) and size >= 0 else 0
        slot['items'] += 1
    return sums or None


def latest_scan(state_dir, history_rows, limit=12):
    """The newest run that measured categories: dict(run_id, started_at, sizes). None when there is none.
    Looks at the event stream first, then at run.json's category records, then at the plan."""
    import tui_plan
    for row in history_rows[:limit]:
        run_id = row['run_id']
        sizes = None
        model = read_events(state_dir, run_id)
        if model is not None:
            sizes = scan_sizes_from_model(model) if model.type() in SCAN_TYPES else None
        elif type_from_mode(row.get('mode')) not in SCAN_TYPES:
            continue
        if sizes is None and model is None:
            summary = read_json(os.path.join(run_dir(state_dir, run_id), 'run.json')) or {}
            cats = summary.get('categories')
            if isinstance(cats, list) and cats and all(isinstance(c, dict) for c in cats):
                sizes = {c['id']: dict(bytes=c.get('estimated_bytes'), items=c.get('items'), partial=c.get('partial') is True,
                                       unit=c.get('unit') or 'bytes')
                         for c in cats if tui_registry.known(str(c.get('id'))) and isinstance(c.get('estimated_bytes'), int)} or None
        if sizes is None and type_from_mode(row.get('mode')) in SCAN_TYPES:
            plan = tui_plan.load_plan(os.path.join(run_dir(state_dir, run_id), 'plan.json'))
            if plan:
                sizes = scan_sizes_from_plan(plan)
        if sizes:
            return dict(run_id=run_id, started_at=row.get('started_at') or '', sizes=sizes)
    return None
