"""Run supervision: tail the engine's JSON-lines event file, keep a tolerant
model of phases, sections, categories, items and prompts, and split PTY output
into per-category log blocks. Nothing here blocks; every read is incremental
and bounded.

A run is a pipeline of phases (preflight, scan, plan, clean, verify, report);
categories are the work inside the scan and clean phases, so a category can
appear once under scan and once under clean. Vocabulary (phase ids, group ids,
item results, reason codes) is the event contract's; see mc_events.py.
"""
import re
import time

import mc_events
import tui_registry
from mc_events import ACTION_PHASES, COUNT_KEYS, ITEM_RESULTS, PHASE_WEIGHTS, PHASES
from tui_widgets import ANSI

MAX_LOG_LINES = 5000
ITEM_PHASE_STEP = dict(measuring=0.15, checking=0.3, moving=0.6, deleting=0.6, running=0.5, verifying=0.85)
# The engine localizes the letter of its own yes/no questions ([t/N] pl, [j/N] de, [s/N] es it pt, [o/N] fr).
YESNO = re.compile(r'\[([yntjso])/([yntjso])\]|\(([yntjso])/([yntjso])\)|\b(yes/no)\b', re.I)
DIRECTIVE = '@@MACOS_CLEANUP_'
RESULT_MAP = {'ok': 'ok', 'warn': 'warn', 'error': 'failed', 'cancelled': 'stopped'}
GROUP_RESULT_MAP = {'ok': 'ok', 'warn': 'warn', 'error': 'failed', 'skipped': 'off', 'unknown': 'unknown'}
CAT_PHASES = ('scan', 'clean')
RUN_TYPES = dict(scan='scan', preview='preview', clean_safe='clean', clean_selected='clean', apply_plan='apply',
                 restore='restore', purge='purge')
MODE_TYPES = {'dry-run': 'scan', 'plan': 'preview', 'interactive': 'clean', 'auto-safe': 'clean',
              'apply-plan': 'apply', 'restore': 'restore', 'purge-quarantine': 'purge', 'unattended': 'unattended',
              'prune-artifacts': 'prune', 'list-quarantine': 'scan', 'doctor': 'scan'}


UNITS_BINARY = ('KiB', 'MiB', 'GiB', 'TiB')      # one convention everywhere: powers of 1024, named as such (the engine says GiB too)


def fmt_bytes(value, unit='bytes'):
    """Human-readable size in KiB/MiB/GiB/TiB (1024-based); '-' when unknown."""
    if value is None:
        return '-'
    value = int(value)
    if unit == 'count':
        return str(value)
    if value < 1024:
        return '%d B' % value
    size = float(value)
    for suffix in UNITS_BINARY:
        size /= 1024.0
        if size < 1024 or suffix == UNITS_BINARY[-1]:
            return ('%.1f %s' % (size, suffix)) if size < 100 else ('%d %s' % (round(size), suffix))
    return '%d B' % value


def run_type(mode, action=None, dry_run=False):
    """scan | preview | clean | restore | purge | unattended | prune for a run."""
    if action in RUN_TYPES:
        return RUN_TYPES[action]
    return MODE_TYPES.get(mode, 'scan')


def category_outcome(counts, action='remove'):
    """Outcome of one category from its item counts (contract section 3.2)."""
    ok = counts.get('cleaned', 0) + counts.get('quarantined', 0) + counts.get('restored', 0)
    skipped, failed = counts.get('skipped', 0), counts.get('failed', 0)
    other = counts.get('unavailable', 0)
    if action == 'report' or (counts.get('report_only', 0) and not (ok or skipped or failed or other)):
        return 'report_only'
    if counts.get('dry_run', 0) and not (ok or skipped or failed or other):
        return 'dry_run'
    if ok and not (skipped or failed or other):
        return 'cleaned'
    if ok:
        return 'partial'
    if failed:
        return 'failed'
    if skipped:
        return 'skipped'
    if other:
        return 'not_processed'
    return 'not_run'


def item_fraction(item):
    if item.result:
        return 1.0
    if item.percent is not None:
        return item.percent / 100.0
    return ITEM_PHASE_STEP.get(item.phase, 0.25)


def item_progress(item):
    """How much of an unfinished item is really done: its reported percent, or
    nothing while it is still only being checked. Used for phase progress, so a
    long single operation moves the bar."""
    if item.result:
        return 1.0
    if item.percent is None and item.phase == 'checking':
        return 0.0
    return max(0.0, min(1.0, item_fraction(item)))


class Item:
    __slots__ = ('id', 'group', 'name', 'path', 'estimated', 'freed', 'action', 'undo', 'phase', 'percent',
                 'result', 'reason', 'detail', 'started', 'ended')

    def __init__(self, ident, group, name=''):
        self.id, self.group, self.name = ident, group, name or ident
        self.path = self.detail = self.reason = ''
        self.estimated = self.freed = 0
        self.action, self.undo = 'remove', 'none'
        self.phase, self.percent, self.result = 'checking', None, None
        self.started, self.ended = time.monotonic(), None


class Group:
    """One category inside one phase (scan or clean)."""

    def __init__(self, ident, phase='scan'):
        self.id, self.phase = ident, phase
        self.info = tui_registry.info(ident)
        self.tier, self.action, self.unit = self.info['tier'], self.info['action'], self.info['unit']
        self.section = self.info['section']
        self.state = 'pending'                            # pending | running | done | off
        self.result = None                                # ok | warn | failed | off | unknown
        self.total = None
        self.items = {}
        self.order = []
        self.counts = dict.fromkeys(COUNT_KEYS, 0)
        self.estimated = None
        self.freed = 0
        self.item_count = None
        self.partial = False
        self.started = self.ended = self.seconds = None
        self.reason = ''
        self.outcome = None

    def finished(self):
        return sum(1 for i in self.items.values() if i.result)

    def known_total(self):
        if self.total is None:
            return None
        return max(self.total, self.finished())

    def bytes_total(self):
        if self.estimated is not None:
            return self.estimated
        return sum(i.estimated for i in self.items.values())

    def bytes_done(self):
        """Bytes finished plus the share of the items still in progress."""
        if self.state == 'done':
            return self.bytes_total()
        done = sum(i.estimated * item_progress(i) for i in self.items.values())
        return int(min(done, self.bytes_total() or done))

    def units_done(self):
        """Finished items plus the fraction of the unfinished ones."""
        return sum(item_progress(i) for i in self.items.values())

    def fraction(self):
        if self.state in ('done', 'off'):
            return 1.0
        if self.state != 'running':
            return 0.0
        if self.phase == 'scan':
            return 1.0 if self.estimated is not None else None
        total = self.known_total()
        if total:
            return min(1.0, self.units_done() / float(total))
        if total == 0:
            return 1.0
        return None

    def elapsed(self, now=None):
        if self.seconds is not None:
            return self.seconds
        if self.started is None:
            return None
        return (self.ended or now or time.monotonic()) - self.started

    def item(self, ident, name=''):
        if ident not in self.items:
            self.items[ident] = Item(ident, self.id, name)
            self.order.append(ident)
        elif name:
            self.items[ident].name = name
        return self.items[ident]

    def computed_outcome(self):
        return self.outcome or category_outcome(self.counts, self.action)

    def dominant_reason(self):
        if self.reason:
            return self.reason
        tally = {}
        for item in self.items.values():
            if item.result in ('skipped', 'failed') and item.reason:
                tally[item.reason] = tally.get(item.reason, 0) + 1
        return max(sorted(tally), key=lambda r: tally[r]) if tally else ''


class Phase:
    def __init__(self, ident):
        self.id = ident
        self.state = 'pending'            # pending | running | done | skipped | off
        self.result = None                # ok | warn | error | skipped
        self.seconds = None
        self.started = self.ended = None

    def elapsed(self, now=None):
        if self.seconds is not None:
            return self.seconds
        if self.started is None:
            return None
        return (self.ended or now or time.monotonic()) - self.started


def _clip(value, limit):
    return str(value if value is not None else '')[:limit]


def _int(value, default=0):
    return value if isinstance(value, int) and not isinstance(value, bool) and value >= 0 else default


class RunModel:
    """``declared`` phases come from run_start.phases (or the action); without
    phase events everything counts as one implicit phase per category phase seen."""

    def __init__(self, action=None, dry_run=False, selected=None):
        self.action = action
        self.dry_run = dry_run
        self.mode = ''
        self.remove_mode = ''
        self.phase_ids = list(ACTION_PHASES.get(action, ()))
        self.declared = bool(self.phase_ids)
        self.phases = {p: Phase(p) for p in self.phase_ids}
        self.cats = {'scan': {}, 'clean': {}}
        self.order = {'scan': [], 'clean': []}
        self.cur = {}
        self.selected = list(selected or ())
        self.started = time.monotonic()
        self.ended = None
        self.result = None           # ok | warn | failed | stopped | unknown
        self.run_end = None
        self.version = None
        self.paths = {}
        self.disk = {}
        self.snapshots = 0
        self.warnings = []
        self.plan = None
        self.prompt = None
        self.answered = set()
        self.last_event = None
        self.events_seen = 0
        self.prompt_events = 0
        self.unknown_types = []
        self.unknown_phases = []
        self.active = None
        self.from_history = False
        self.summary_totals = None
        self._overall = 0.0

    # -- structure ------------------------------------------------------------
    def type(self):
        return run_type(self.mode, self.action, self.dry_run)

    def _phase(self, ident):
        if ident not in PHASES:
            if ident not in self.unknown_phases:
                self.unknown_phases.append(ident)
            return None
        if ident not in self.phases:
            self.phases[ident] = Phase(ident)
            self.phase_ids = [p for p in PHASES if p in self.phases]
        return self.phases[ident]

    def _implicit(self, phase):
        """No phase events: the phases seen so far are the whole pipeline."""
        if not self.declared:
            self._phase(phase)
            self._phase_state(phase, 'running')

    def _phase_state(self, ident, state, result=None, seconds=None):
        phase = self.phases.get(ident)
        if phase is None:
            return
        if state == 'running':
            if phase.state in ('pending', 'off'):
                phase.state, phase.started = 'running', time.monotonic()
        else:
            phase.state, phase.result, phase.ended = state, result, time.monotonic()
            if phase.started is None:
                phase.started = phase.ended
            if seconds is not None:
                phase.seconds = float(seconds)

    def group(self, ident, phase=None, create=False):
        if not isinstance(ident, str) or not tui_registry.ID_PATTERN.fullmatch(ident):
            return None
        phase = phase if phase in CAT_PHASES else self.cur.get(ident, 'scan')
        found = self.cats[phase].get(ident)
        if found is None and create:
            found = self.cats[phase][ident] = Group(ident, phase)
            self.order[phase].append(ident)
        return found

    def ordered(self, phase):
        return [self.cats[phase][i] for i in self.order[phase]]

    def sections(self, phase):
        """[(section id, [groups])] in registry section order."""
        out = {}
        for group in self.ordered(phase):
            out.setdefault(group.section or 'other', []).append(group)
        known = [s for s in tui_registry.SECTIONS if s in out]
        return [(s, out[s]) for s in known + [s for s in out if s not in known]]

    def merged(self):
        """One record per category: the clean group when it ran, else the scan group,
        with the scan estimate carried over. Used by result views."""
        out = []
        seen = set()
        for ident in self.order['clean'] + self.order['scan']:
            if ident in seen:
                continue
            seen.add(ident)
            scan, clean = self.cats['scan'].get(ident), self.cats['clean'].get(ident)
            group = clean or scan
            if clean is not None and scan is not None and clean.estimated is None:
                clean.estimated = scan.estimated
            out.append(group)
        return out

    # -- events ----------------------------------------------------------------
    def handle(self, event):
        if not isinstance(event, dict) or not isinstance(event.get('type'), str):
            return
        kind = event['type']
        self.events_seen += 1
        self.last_event = time.monotonic()
        if kind not in mc_events.EVENT_TYPES:
            if kind not in self.unknown_types:
                self.unknown_types.append(kind)
            return
        getattr(self, '_on_' + kind)(event)

    def _on_run_start(self, event):
        self.version = _clip(event.get('version'), 32)
        self.mode = _clip(event.get('mode'), 24)
        self.remove_mode = _clip(event.get('remove_mode'), 16)
        if event.get('action') in mc_events.ACTION_NAMES:
            self.action = event['action']
        if isinstance(event.get('dry_run'), bool):
            self.dry_run = event['dry_run'] or self.dry_run
        if isinstance(event.get('paths'), dict):
            self.paths = {k: _clip(v, 400) for k, v in event['paths'].items() if k in ('state', 'run_dir', 'quarantine')}
        listed = event.get('phases')
        if isinstance(listed, list):
            ids = [p for p in listed if p in PHASES]
            if ids:
                self.declared = True
                self.phase_ids = ids
                self.phases = {p: self.phases.get(p) or Phase(p) for p in ids}
        groups = event.get('groups')
        if isinstance(groups, list):
            self.selected = [g for g in groups[:64] if isinstance(g, str)]

    def _on_phase(self, event):
        phase = self._phase(event.get('phase'))
        if phase is None:
            return
        if event.get('status') == 'start':
            self._phase_state(phase.id, 'running')
        elif event.get('status') == 'end':
            result = event.get('result') if event.get('result') in mc_events.PHASE_RESULTS else 'ok'
            self._phase_state(phase.id, 'skipped' if result == 'skipped' else 'done', result, event.get('seconds'))

    def _on_warning(self, event):
        if len(self.warnings) < 50:
            self.warnings.append((_clip(event.get('code'), 40), _clip(event.get('text'), 300)))

    def _on_disk_space(self, event):
        if event.get('phase') in mc_events.DISK_PHASES and isinstance(event.get('free_bytes'), int):
            self.disk[event['phase']] = event['free_bytes']
        self.snapshots = max(self.snapshots, _int(event.get('snapshots')))

    def _start(self, group):
        if group.state in ('pending', 'off'):
            group.state = 'running'
            group.started = time.monotonic()
        self.active = (group.id, group.phase)

    def _on_group_start(self, event):
        phase = event.get('phase') if event.get('phase') in CAT_PHASES else 'scan'
        ident = event.get('group')
        if not isinstance(ident, str) or not tui_registry.ID_PATTERN.fullmatch(ident):
            return
        self.cur[ident] = phase
        self._implicit(phase)
        group = self.group(ident, phase, create=True)
        if event.get('tier') in tui_registry.TIERS:
            group.tier = event['tier']
        if isinstance(event.get('section'), str) and tui_registry.ID_PATTERN.fullmatch(event['section']):
            group.section = event['section']
        self._start(group)

    def _on_group_total(self, event):
        group = self.group(event.get('group'), create=True)
        if group is not None and isinstance(event.get('total'), int) and event['total'] >= 0:
            group.total = event['total']

    def _on_group_sized(self, event):
        group = self.group(event.get('group'), 'scan' if event.get('group') not in self.cur else None, create=True)
        if group is None:
            return
        group.estimated = _int(event.get('estimated_bytes'))
        group.item_count = _int(event.get('items'))
        group.partial = bool(event.get('partial'))
        if event.get('unit') in mc_events.UNITS:
            group.unit = event['unit']
        if group.state == 'pending':
            self._start(group)

    def _item_group(self, event):
        group = self.group(event.get('group'), create=True)
        if group is not None:
            if group.id not in self.cur:
                self.cur[group.id] = group.phase
                self._implicit(group.phase)
            self._start(group)
        return group

    def _on_item_start(self, event):
        group = self._item_group(event)
        if group is None:
            return
        item = group.item(_clip(event.get('id', '?'), 200), _clip(event.get('name'), 200))
        item.path = _clip(event.get('path'), 400)
        item.estimated = _int(event.get('estimated_bytes'))
        if event.get('action') in mc_events.ACTIONS:
            item.action = event['action']
        if event.get('undo') in mc_events.UNDO:
            item.undo = event['undo']
        item.phase = 'checking'

    def _on_item_progress(self, event):
        group = self._item_group(event)
        if group is None:
            return
        item = group.item(_clip(event.get('id', '?'), 200))
        if event.get('phase') in mc_events.ITEM_PHASES:
            item.phase = event['phase']
        pct = event.get('percent')
        if isinstance(pct, (int, float)) and not isinstance(pct, bool):
            item.percent = max(0.0, min(100.0, float(pct)))

    def _on_item_end(self, event):
        group = self._item_group(event)
        if group is None:
            return
        item = group.item(_clip(event.get('id', '?'), 200), _clip(event.get('name'), 200))
        result = event.get('result')
        if result not in ITEM_RESULTS:
            result = 'failed' if result in ('error', 'fail') else 'skipped'
        if item.result:
            group.counts[item.result] -= 1
        item.result = result
        item.ended = time.monotonic()
        item.percent = 100.0
        item.estimated = _int(event.get('estimated_bytes'), item.estimated)
        item.freed = _int(event.get('freed_bytes'))
        if event.get('undo') in mc_events.UNDO:
            item.undo = event['undo']
        if event.get('detail'):
            item.detail = _clip(event['detail'], 300)
        item.reason = mc_events.normalise_reason(event.get('reason')) if event.get('reason') else ''
        if result in ('skipped', 'failed') and not item.reason:
            item.reason = 'unknown'
        group.counts[result] += 1

    def _on_group_end(self, event):
        phase = event.get('phase') if event.get('phase') in CAT_PHASES else None
        group = self.group(event.get('group'), phase, create=True)
        if group is None:
            return
        result = GROUP_RESULT_MAP.get(event.get('result'), 'unknown')
        if group.started is None:
            group.started = time.monotonic()
        group.state = 'done' if result != 'off' else 'off'
        group.result, group.ended = result, time.monotonic()
        if self.active == (group.id, group.phase):
            self.active = None
        counts = event.get('counts')
        if isinstance(counts, dict):
            for key in COUNT_KEYS:
                if _int(counts.get(key), -1) >= 0:
                    group.counts[key] = counts[key]
        if 'estimated_bytes' in event and group.estimated is None:
            group.estimated = _int(event.get('estimated_bytes'))
        if group.phase == 'clean':
            group.freed = _int(event.get('freed_bytes'), group.freed)
            group.outcome = None
        seconds = event.get('seconds')
        if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) and seconds >= 0:
            group.seconds = float(seconds)
        if event.get('reason'):
            group.reason = mc_events.normalise_reason(event['reason'])

    def _on_prompt(self, event):
        self.prompt_events += 1
        ident = _clip(event.get('id'), 80) or 'prompt-%d' % self.events_seen
        if ident in self.answered:
            return
        options = event.get('options') if isinstance(event.get('options'), list) else []
        timeout = event.get('timeout')
        kind = event.get('kind') if event.get('kind') in mc_events.PROMPT_KINDS else 'yesno'
        self.prompt = dict(id=ident, kind=kind, text=_clip(event.get('text'), 2000),
                           options=[str(o)[:80] for o in options[:9]], default=_clip(event.get('default'), 80),
                           timeout=timeout if isinstance(timeout, (int, float)) and not isinstance(timeout, bool)
                           and timeout > 0 else None,
                           opened=time.monotonic(), group=_clip(event.get('group'), 40) or None)

    def _on_plan_written(self, event):
        self.plan = dict(path=_clip(event.get('path'), 400), operations=_int(event.get('operations')),
                         executable_bytes=_int(event.get('executable_bytes')),
                         report_only_bytes=_int(event.get('report_only_bytes')))

    def _on_run_end(self, event):
        def opt(key):
            return event[key] if isinstance(event.get(key), int) and not isinstance(event.get(key), bool) else None
        self.run_end = dict(result=event.get('result'), exit_code=event.get('exit_code'),
                            summary_file=_clip(event.get('summary_file'), 400), estimated_bytes=opt('estimated_bytes'),
                            freed_bytes=opt('freed_bytes'), quarantined_bytes=opt('quarantined_bytes'),
                            seconds=event.get('seconds'))
        self.finish(event.get('result'), event.get('seconds'))

    def finish(self, result=None, seconds=None, returncode=None, stopped=False):
        if self.ended is not None and result is None and not stopped:
            return
        self.ended = time.monotonic()
        failed = stopped or returncode not in (None, 0) or result in ('error', 'cancelled')
        for phase in self.phases.values():
            if phase.state == 'running':
                self._phase_state(phase.id, 'done', 'error' if failed else 'ok')
            elif phase.state == 'pending':
                phase.state = 'off'
        for table in self.cats.values():
            for group in table.values():
                if group.state == 'running':
                    group.state, group.result = 'done', ('failed' if failed else (group.result or 'ok'))
                    group.ended = self.ended
                elif group.state == 'pending' and stopped:
                    group.state = 'off'
        if stopped:
            self.result = 'stopped'
        elif result is not None:
            self.result = RESULT_MAP.get(str(result), 'unknown')
        elif self.result is None:
            self.result = 'ok' if returncode in (0, None) else 'failed'
        self.prompt = None

    # -- progress ---------------------------------------------------------------
    def selected_count(self):
        return len(self.selected) or len(self.order['scan'])

    def phase_fraction(self, ident):
        """0..1, or None (indeterminate) while running without a measure."""
        phase = self.phases.get(ident)
        if phase is None:
            return 0.0
        if phase.state in ('done', 'skipped'):
            return 1.0
        if phase.state != 'running':
            return 0.0
        if ident == 'scan':
            total = self.selected_count()
            if not total:
                return None
            sized = sum(1 for g in self.cats['scan'].values() if g.estimated is not None or g.state == 'done')
            return min(1.0, sized / float(total))
        if ident == 'clean':
            groups = self.ordered('clean')
            total = sum(g.bytes_total() for g in groups)
            if total > 0:
                return min(1.0, sum(g.bytes_done() for g in groups) / float(total))
            items = sum((g.known_total() or 0) for g in groups)
            if items:
                return min(1.0, sum(g.units_done() for g in groups) / float(items))
        return None

    def overall(self):
        """Weighted over the phases in this run (skipped phases drop out)."""
        live = [p for p in self.phase_ids if self.phases[p].state != 'skipped']
        total = float(sum(PHASE_WEIGHTS[p] for p in live)) or 1.0
        value = 0.0
        for ident in live:
            fraction = self.phase_fraction(ident)
            if fraction is None:
                fraction = 0.5 if self.phases[ident].state == 'running' else 0.0
            value += PHASE_WEIGHTS[ident] * fraction
        value = value / total if live else (1.0 if self.ended else 0.0)
        self._overall = max(self._overall, min(1.0, value))
        return self._overall

    def active_phase(self):
        for ident in self.phase_ids:
            if self.phases[ident].state == 'running':
                return ident
        return None

    # -- derived totals ------------------------------------------------------------
    def counts(self):
        out = dict.fromkeys(COUNT_KEYS, 0)
        for table in self.cats.values():
            for g in table.values():
                if g.phase == 'scan' and g.id in self.cats['clean']:
                    continue
                for key in out:
                    out[key] += g.counts.get(key, 0)
        return out

    def estimated_total(self):
        if self.run_end and self.run_end.get('estimated_bytes') is not None:
            return self.run_end['estimated_bytes']
        if self.summary_totals and isinstance(self.summary_totals.get('estimated_bytes'), int):
            return self.summary_totals['estimated_bytes']
        return sum((g.estimated or 0) for g in self.cats['scan'].values() if g.action != 'report' and g.unit == 'bytes')

    def restore_summary(self):
        return restore_facts(self, self.summary_totals)

    def informational_total(self):
        return sum((g.estimated or 0) for g in self.cats['scan'].values() if g.action == 'report' and g.unit == 'bytes')

    def quarantined_total(self):
        if self.run_end and self.run_end.get('quarantined_bytes') is not None:
            return self.run_end['quarantined_bytes']
        if self.summary_totals and isinstance(self.summary_totals.get('quarantined_bytes'), int):
            return self.summary_totals['quarantined_bytes']
        return sum(i.freed or i.estimated for g in self.cats['clean'].values() for i in g.items.values()
                   if i.result == 'quarantined')

    def measured_freed(self):
        """Measured change in free space; None when it was not measured."""
        if self.run_end and self.run_end.get('freed_bytes') is not None:
            return self.run_end['freed_bytes']
        if self.summary_totals and 'measured_freed_bytes' in self.summary_totals:
            value = self.summary_totals['measured_freed_bytes']
            return value if isinstance(value, int) else None
        if 'before' in self.disk and 'after' in self.disk:
            return self.disk['after'] - self.disk['before']
        return None

    def skipped_bytes(self):
        return sum(i.estimated for g in self.cats['clean'].values() for i in g.items.values()
                   if i.result in ('skipped', 'failed'))

    def differences(self):
        """Why 'estimated' and 'measured freed' differ: [(key, params)] naming ui_why_* strings."""
        out = []
        measured = self.measured_freed()
        if self.dry_run or self.type() in ('scan', 'preview'):
            return [('dry_run', {})]
        if measured is None:
            out.append(('unmeasured', {}))
        quarantined = self.quarantined_total()
        if quarantined:
            out.append(('quarantine', dict(size=fmt_bytes(quarantined))))
        skipped = self.skipped_bytes()
        if skipped:
            out.append(('skipped', dict(size=fmt_bytes(skipped))))
        if self.snapshots or any(code == 'snapshots_retain_space' for code, _ in self.warnings):
            out.append(('snapshots', {}))
        if any(g.partial for g in self.cats['scan'].values()) or any(c == 'scan_partial' for c, _ in self.warnings):
            out.append(('partial', {}))
        if measured is not None and not out:
            out.append(('estimate', {}))
        return out

    def buckets(self):
        """Items grouped by result for the result view (clean phase, else scan)."""
        buckets = {k: [] for k in ITEM_RESULTS}
        for phase in ('clean', 'scan'):
            for g in self.ordered(phase):
                if phase == 'scan' and g.id in self.cats['clean']:
                    continue
                for ident in g.order:
                    item = g.items[ident]
                    if item.result:
                        buckets[item.result].append((g.id, item))
        return buckets

    def stalled(self, seconds=8.0):
        return time.monotonic() - (self.last_event or self.started) > seconds


def restore_facts(model, totals=None):
    """What a restore did, for the summary of a restore run: dict(items, bytes, skipped, reasons). ``reasons``
    maps a skip reason to its item count (empty when only run.json is known). Items come from the events the
    model saw; the size and, without events, the counts come from run.json ``totals`` (restored_bytes and
    restored_items are what the engine measured when it moved each item back)."""
    totals = totals if isinstance(totals, dict) else {}
    group = model.cats['clean'].get('restore') if model is not None else None
    items = skipped = size = 0
    reasons = {}
    if group is not None and group.items:
        for item in group.items.values():
            if item.result == 'restored':
                items += 1
                size += item.estimated
            elif item.result in ('skipped', 'failed'):
                skipped += 1
                reasons[item.reason or 'unknown'] = reasons.get(item.reason or 'unknown', 0) + 1
    else:
        items, skipped = _int(totals.get('restored_items')), _int(totals.get('skipped_items'))
    if _int(totals.get('restored_bytes'), -1) >= 0 and (items or not size):
        size = _int(totals.get('restored_bytes'))
    return dict(items=items, bytes=size, skipped=skipped, reasons=reasons)


def model_from_summary(summary):
    """Rebuild a finished RunModel from a run.json (schema 2.0 read model);
    unknown fields are ignored so older and newer files both load."""
    model = RunModel()
    model.from_history = True
    if not isinstance(summary, dict):
        return model
    model.mode = _clip(summary.get('mode'), 24)
    model.remove_mode = _clip(summary.get('remove_mode'), 16)
    model.dry_run = bool(summary.get('dry_run'))
    model.version = _clip(summary.get('version'), 32)
    phase_name = 'clean' if run_type(model.mode) in ('clean', 'apply', 'restore', 'purge', 'unattended') and not model.dry_run \
        else 'scan'
    for raw in (summary.get('categories') or [])[:64]:
        if not isinstance(raw, dict):
            continue
        group = model.group(raw.get('id'), phase_name, create=True)
        if group is None:
            continue
        outcome = raw.get('outcome')
        group.outcome = outcome if outcome in mc_events.CATEGORY_OUTCOMES else None
        group.state = 'done'
        group.result = {'cleaned': 'ok', 'partial': 'warn', 'failed': 'failed', 'skipped': 'off',
                        'not_processed': 'warn', 'report_only': 'ok', 'not_run': 'off', 'dry_run': 'ok'}.get(outcome, 'ok')
        if raw.get('tier') in tui_registry.TIERS:
            group.tier = raw['tier']
        if raw.get('section') in tui_registry.SECTIONS:
            group.section = raw['section']
        if raw.get('unit') in mc_events.UNITS:
            group.unit = raw['unit']
        group.estimated = _int(raw.get('estimated_bytes'))
        group.item_count = _int(raw.get('items'))
        group.freed = _int(raw.get('freed_bytes'))
        group.partial = bool(raw.get('partial'))
        group.reason = mc_events.normalise_reason(raw.get('reason'))
        if isinstance(raw.get('counts'), dict):
            for key in COUNT_KEYS:
                group.counts[key] = _int(raw['counts'].get(key))
        group.started = group.ended = 0.0
    totals = summary.get('totals')
    model.summary_totals = totals if isinstance(totals, dict) else None
    if model.summary_totals:
        for key, phase in (('disk_free_before', 'before'), ('disk_free_after', 'after')):
            if isinstance(model.summary_totals.get(key), int):
                model.disk[phase] = model.summary_totals[key]
        model.snapshots = _int(model.summary_totals.get('snapshots'))
    # run.json (the --json summary, schema 1.0) carries a warning COUNT here;
    # only a list of {code, text} objects is read.
    warnings = summary.get('warnings')
    for raw in (warnings if isinstance(warnings, list) else []):
        if isinstance(raw, dict) and len(model.warnings) < 50:
            model.warnings.append((_clip(raw.get('code'), 40), _clip(raw.get('text'), 300)))
    ph = summary.get('phases')
    if isinstance(ph, list):                    # optional per-phase results (run.json may carry them)
        for raw in ph:
            if isinstance(raw, dict) and raw.get('phase') in PHASES:
                phase = model._phase(raw['phase'])
                model.declared = True
                model._phase_state(phase.id, 'skipped' if raw.get('result') == 'skipped' else 'done',
                                   raw.get('result') if raw.get('result') in mc_events.PHASE_RESULTS else 'ok',
                                   raw.get('seconds') if isinstance(raw.get('seconds'), int) else None)
    model.result = RESULT_MAP.get(summary.get('result'), 'unknown')
    seconds = summary.get('seconds')
    model.started = 0.0
    model.ended = float(seconds) if isinstance(seconds, (int, float)) and not isinstance(seconds, bool) and seconds >= 0 else 0.0
    plan = summary.get('plan')
    if isinstance(plan, dict) and plan.get('path'):
        model.plan = dict(path=_clip(plan.get('path'), 400), operations=_int(plan.get('operations')),
                          executable_bytes=_int(plan.get('executable_bytes')),
                          report_only_bytes=_int(plan.get('report_only_bytes')))
    return model


class EventTailer(mc_events.Reader):
    """Incremental reader for the event file (it may not exist yet)."""


class LogBuffer:
    """Turns PTY text into lines, grouped into per-category blocks."""

    def __init__(self):
        self.blocks = [[None, []]]      # [group id or None, lines]
        self.partial = ''
        self.last_output = time.monotonic()
        self.count = 0

    def begin(self, group):
        if self.blocks[-1][0] != group:
            if not self.blocks[-1][1] and self.blocks[-1][0] is None:
                self.blocks[-1][0] = group
            else:
                self.blocks.append([group, []])

    def feed(self, text):
        if not text:
            return []
        self.last_output = time.monotonic()
        text = self.partial + text.replace('\r\n', '\n')
        parts = text.split('\n')
        self.partial = parts.pop()
        if '\r' in self.partial:
            self.partial = self.partial.rsplit('\r', 1)[-1]
        if len(self.partial) > 4000:
            parts.append(self.partial)
            self.partial = ''
        for line in parts:
            if '\r' in line:
                line = line.rstrip('\r').rsplit('\r', 1)[-1]
            line = ANSI.sub('', line)
            line = ''.join(c for c in line if c.isprintable() or c == '\t').replace('\t', '    ')
            if line.startswith(DIRECTIVE):
                continue
            self.blocks[-1][1].append(line)
            self.count += 1
        if self.count > MAX_LOG_LINES:
            drop = self.count - MAX_LOG_LINES
            while drop > 0 and self.blocks:
                lines = self.blocks[0][1]
                cut = min(drop, len(lines))
                del lines[:cut]
                drop -= cut
                self.count -= cut
                if not lines and len(self.blocks) > 1:
                    self.blocks.pop(0)
        return []

    def visible_partial(self):
        return ''.join(c for c in ANSI.sub('', self.partial) if c.isprintable())

    def all_lines(self):
        out = []
        for _, lines in self.blocks:
            out.extend(lines)
        partial = self.visible_partial()
        if partial.strip():
            out.append(partial)
        return out

    def last_line(self):
        partial = self.visible_partial().strip()
        if partial:
            return partial
        for _, lines in reversed(self.blocks):
            for line in reversed(lines):
                if line.strip():
                    return line.strip()
        return ''


_BOX = set('║│┃|╔╗╚╝╠╣═─━┌┐└┘├┤╭╮╰╯┏┓┗┛▔▁=*#~_+-')


def clean_log_line(line):
    """Strip decorative box-drawing frames; None for pure banner lines."""
    text = line.strip()
    while text and text[0] in _BOX:
        text = text[1:].lstrip()
    while text and text[-1] in _BOX:
        text = text[:-1].rstrip()
    if not any(ch.isalnum() for ch in text):
        return None if line.strip() else ''
    return text if line.strip() != text else line.rstrip()


def wrap_log(lines, width, indent='  '):
    """Clean and wrap log lines to ``width``; continuation lines are indented."""
    from tui_widgets import wrap
    out = []
    for line in lines:
        text = clean_log_line(line)
        if text is None:
            continue
        parts = wrap(text, max(8, width - len(indent) - 2)) or ['']
        out.append(indent + parts[0])
        out.extend(indent + '  ' + part for part in parts[1:])
    return out


def detect_prompt(log, secret_input, idle, allow_yesno=True):
    """Fallback for engines without prompt events: guess from the PTY state."""
    partial = log.visible_partial().strip()
    if secret_input and idle >= 0.3:
        return dict(id='pty-sudo', kind='sudo', text=partial[:300], options=[], default='', timeout=None,
                    opened=time.monotonic(), group=None, detected=True)
    if allow_yesno and partial and idle >= 0.6:
        match = YESNO.search(partial)
        if match:
            token = match.group(0)
            default = 'y' if 'Y' in token and 'N' not in token else ('n' if 'N' in token else '')
            return dict(id='pty-yesno', kind='yesno', text=partial[:300], options=['y', 'n'], default=default,
                        timeout=None, opened=time.monotonic(), group=None, detected=True)
    return None
