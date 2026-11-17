"""Plan review: read a run's plan.json (bounded, no symlinks) and sort its
operations into the groups the user must see before anything is cleaned:

    reversible   moved to quarantine, can be restored
    permanent    deleted by the tool or its own command; cannot be restored
    native       run by a native tool (npm, brew, docker ...); permanent
    report       never acted on, listed for information only
    skipped      will not run, with the reason

The review is built from the plan the engine wrote; nothing here decides what
runs. ``PlanReview`` is the overlay model: the run button is reachable only
from it, and permanent operations need their own acknowledgement.
"""
import json
import re

import mc_events
import tui_registry
from tui_backend import open_regular

MAX_PLAN = 32 * 1024 * 1024
GROUPS = ('reversible', 'permanent', 'native', 'report', 'skipped')
LIST_CAP = 60


def load_plan(path):
    """The parsed plan dict, or None when missing, unsafe or malformed."""
    if not isinstance(path, str) or not path.startswith('/'):
        return None
    raw = open_regular(path, MAX_PLAN)
    if raw is None:
        return None
    try:
        data = json.loads(raw.decode('utf-8', 'replace'))
    except ValueError:
        return None
    ops = data.get('operations') if isinstance(data, dict) else None
    return data if isinstance(ops, list) else None


def _tool(op):
    tool = str(op.get('tool') or '').strip()
    if tool:
        return tool[:24]
    command = str(op.get('command') or '').strip().split()
    return (command[0] if command else tui_registry.info(str(op.get('category')))['native_cmd'].split(' ')[0] or 'native')[:24]


def classify(op, remove_mode='quarantine', include_review=False, only=None, auto_only=None):
    """(group, reason) for one plan operation. ``only`` restricts to category ids
    (clean selected); ``auto_only`` is the set of categories that may run
    unattended-style (clean safe)."""
    category = str(op.get('category') or '')
    action = op.get('action')
    risk = str(op.get('risk') or 'SAFE').upper()
    if action == 'report_only' or tui_registry.info(category)['action'] == 'report':
        return 'report', ''
    if op.get('decision') == 'skipped' or op.get('skip_reason'):
        reason = str(op.get('skip_reason') or op.get('reason') or 'unknown')
        return 'skipped', reason if reason in mc_events.REASONS else 'unknown'
    if only is not None and category not in only:
        return 'skipped', 'not_selected'
    if auto_only is not None and category not in auto_only:
        return 'skipped', 'review_not_included'
    if risk == 'DANGEROUS':
        return 'skipped', 'dangerous_blocked'
    if risk == 'REVIEW' and not include_review:
        return 'skipped', 'review_not_included'
    if action == 'native_command':
        return 'native', ''
    if remove_mode == 'permanent' or tui_registry.info(category)['undo'] != 'quarantine':
        return 'permanent', ''
    return 'reversible', ''


def summarize(plan, remove_mode='quarantine', include_review=False, only=None, auto_only=None):
    """{group: {'count', 'bytes', 'ops': [(op, reason)], 'tools': set}} for a plan."""
    out = {g: dict(count=0, bytes=0, ops=[], tools=set()) for g in GROUPS}
    for op in plan.get('operations', []):
        if not isinstance(op, dict):
            continue
        group, reason = classify(op, remove_mode, include_review, only, auto_only)
        size = op.get('estimated_bytes')
        size = size if isinstance(size, int) and not isinstance(size, bool) and size >= 0 else 0
        slot = out[group]
        slot['count'] += 1
        slot['bytes'] += size
        slot['ops'].append((op, reason))
        if group == 'native':
            slot['tools'].add(_tool(op))
    return out


class PlanReview:
    """Overlay model. Focus order: ack (when permanent operations exist), run,
    cancel. Cancel is focused first; ``run_enabled`` needs the acknowledgement."""

    def __init__(self, title, plan, summary, on_done, action, notes=()):
        self.title, self.plan, self.summary, self.on_done, self.action = title, plan, summary, on_done, action
        self.notes = list(notes)
        self.scroll = 0
        self.acked = False
        self.closed = False
        self.focus = 'cancel'

    @property
    def permanent_count(self):
        return self.summary['permanent']['count'] + self.summary['native']['count']

    def needs_ack(self):
        return self.permanent_count > 0

    def run_enabled(self):
        return bool(self.plan) and (self.acked or not self.needs_ack()) and self.executable_count() > 0

    def executable_count(self):
        return sum(self.summary[g]['count'] for g in ('reversible', 'permanent', 'native'))

    def focus_order(self):
        return (['ack'] if self.needs_ack() else []) + ['run', 'cancel']

    def move_focus(self, delta):
        order = self.focus_order()
        self.focus = order[(order.index(self.focus) + delta) % len(order)] if self.focus in order else 'cancel'

    def finish(self, app, value):
        if self.closed:
            return
        self.closed = True
        if app.overlay is self.overlay_ref:
            app.overlay = None
        if self.on_done:
            self.on_done(app, value)

    overlay_ref = None

    def key(self, app, name):
        if name in ('up', 'down', 'pgup', 'pgdn', 'home', 'end'):
            step = {'up': -1, 'down': 1, 'pgup': -10, 'pgdn': 10, 'home': -10 ** 6, 'end': 10 ** 6}[name]
            self.scroll = max(0, self.scroll + step)
            return True
        if name in ('tab', 'right'):
            self.move_focus(1)
        elif name in ('btab', 'left'):
            self.move_focus(-1)
        elif name in ('enter', 'space'):
            if self.focus == 'ack':
                self.acked = not self.acked
            elif self.focus == 'run' and self.run_enabled():
                self.finish(app, 'run')
            elif self.focus == 'cancel':
                self.finish(app, None)
        elif name == 'esc':
            self.finish(app, None)
        else:
            return False
        return True

    def click(self, app, what):
        if what == 'ack':
            self.focus = 'ack'
            self.acked = not self.acked
        elif what == 'run':
            self.focus = 'run'
            if self.run_enabled():
                self.finish(app, 'run')
        elif what == 'cancel':
            self.finish(app, None)

    def lines(self, app, width):
        """(text, style) rows of the scrollable body."""
        from tui_runner import fmt_bytes
        from tui_widgets import clip, wrap
        g = app.glyphs
        out = []
        for note in self.notes:
            out.extend((l, 'base') for l in wrap(note, width))
        if self.notes:
            out.append(('', 'base'))
        if not self.plan:
            out.extend((l, 'warn') for l in wrap(app.t('ui_plan_none'), width))
            return out
        label_style = dict(reversible='ok', permanent='fail', native='fail', report='muted', skipped='warn')
        for group in GROUPS:
            slot = self.summary[group]
            if not slot['count']:
                out.append(('%s %s (0)' % (g['off'], app.t('ui_plan_g_' + group)), 'muted'))
                continue
            title = '%s %s: %d, %s' % (g['needs'] if group in ('permanent', 'native') else g['ok'],
                                       app.t('ui_plan_g_' + group), slot['count'], fmt_bytes(slot['bytes']))
            if group == 'native' and slot['tools']:
                title += ' (%s)' % ', '.join(sorted(slot['tools']))
            out.append((title, label_style[group]))
            for line in wrap(app.t('ui_plan_g_%s_help' % group), width - 2):
                out.append(('  ' + line, 'base'))
            for op, reason in slot['ops'][:LIST_CAP]:
                size = op.get('estimated_bytes') if isinstance(op.get('estimated_bytes'), int) else 0
                what = op.get('path') or op.get('command') or op.get('description') or '?'
                text = '  %s  %s  %s' % (fmt_bytes(size).rjust(8), app.category_label(str(op.get('category'))), what)
                if reason:
                    text += '  [%s]' % app.t('reason_' + reason)
                out.append((clip(text, width, g['ellipsis']), 'base'))
            if slot['count'] > LIST_CAP:
                out.append(('  ' + app.t('ui_more', count=slot['count'] - LIST_CAP), 'muted'))
            out.append(('', 'base'))
        return out


def overview(plan, mode_of, remove_mode='quarantine'):
    """What Clean would do with a plan, per category, read only from fields the engine writes
    (operation category, risk, action, estimated_bytes). ``mode_of(category)`` returns (mode, effective_auto)
    from the category settings. Returns (rows, totals):

    row    {id, ops, bytes, auto_ops, auto_bytes, decision_ops, decision_bytes, blocked_ops, state, removal, tools}
           state: auto | decision | blocked | permonly | report | skipped
           permonly: outside the home folder, so quarantine cannot hold it; the engine leaves it unless
           the removal mode is permanent
           removal: quarantine | native | permanent | '' (report-only categories)
    totals {auto: (ops, bytes), decision: (ops, bytes), report: (ops, bytes), skipped: (ops, bytes),
            blocked: (ops, bytes), permonly: (ops, bytes)}
    """
    rows = {}
    order = []
    for op in plan.get('operations', []) if isinstance(plan, dict) else []:
        if not isinstance(op, dict):
            continue
        category = str(op.get('category') or '')
        if not category:
            continue
        row = rows.get(category)
        if row is None:
            row = rows[category] = dict(id=category, ops=0, bytes=0, auto_ops=0, auto_bytes=0, decision_ops=0,
                                        decision_bytes=0, blocked_ops=0, blocked_bytes=0, report_ops=0, report_bytes=0,
                                        permonly_ops=0, permonly_bytes=0, skipped_ops=0, skipped_bytes=0, state='', removal='', tools=set())
            order.append(category)
        size = op.get('estimated_bytes')
        size = size if isinstance(size, int) and not isinstance(size, bool) and size >= 0 else 0
        row['ops'] += 1
        row['bytes'] += size
        group, _ = classify(op, remove_mode, include_review=True)
        risk = str(op.get('risk') or 'SAFE').upper()
        mode, auto = mode_of(category)
        if group == 'report':
            slot = 'report'
        elif mode == 'skip':
            slot = 'skipped'
        elif risk == 'DANGEROUS':
            slot = 'blocked'
        elif group == 'permanent' and remove_mode != 'permanent':
            slot = 'permonly'
        elif auto and risk == 'SAFE':
            slot = 'auto'
        else:
            slot = 'decision'
        row[slot + '_ops'] += 1
        row[slot + '_bytes'] += size
        if group in ('reversible', 'native', 'permanent') and slot in ('auto', 'decision'):
            row['removal'] = row['removal'] if row['removal'] == 'native' else (
                'native' if group == 'native' else ('permanent' if group == 'permanent' or row['removal'] == 'permanent' else 'quarantine'))
            if group == 'native':
                row['tools'].add(_tool(op))
    totals = {k: (0, 0) for k in ('auto', 'decision', 'report', 'skipped', 'blocked', 'permonly')}
    out = []
    for category in order:
        row = rows[category]
        for k in totals:
            totals[k] = (totals[k][0] + row[k + '_ops'], totals[k][1] + row[k + '_bytes'])
        row['state'] = ('decision' if row['decision_ops'] else 'auto' if row['auto_ops'] else
                        'blocked' if row['blocked_ops'] else 'permonly' if row['permonly_ops'] else
                        'skipped' if row['skipped_ops'] else 'report')
        out.append(row)
    return out, totals


def plan_age_seconds(plan, now=None):
    import time
    stamp = plan.get('created_epoch') if isinstance(plan, dict) else None
    if isinstance(stamp, int):
        return (time.time() if now is None else now) - stamp
    return None


def known_plan_path(path, state_dir):
    return bool(re.fullmatch(re.escape(str(state_dir)) + r'/runs/[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}_[0-9]+/plan\.json',
                             str(path)))


class RestorePreview(PlanReview):
    """Overlay for the dry-run restore preview: what goes back where, and what is
    skipped (destination exists, parent missing, blocked). It never restores; its
    run button is the one confirmation of a restore (Cancel is focused first)."""

    def __init__(self, title, preview, on_done):
        PlanReview.__init__(self, title, preview, {g: dict(count=0, bytes=0, ops=[], tools=set()) for g in GROUPS},
                            on_done, 'restore')

    def needs_ack(self):
        return False

    def executable_count(self):
        return sum(1 for i in self.plan.get('items', []) if isinstance(i, dict) and i.get('action') == 'restore')

    def run_enabled(self):
        return self.executable_count() > 0

    def lines(self, app, width):
        from tui_runner import fmt_bytes
        from tui_widgets import clip, wrap
        g = app.glyphs
        items = [i for i in self.plan.get('items', []) if isinstance(i, dict)]
        will = [i for i in items if i.get('action') == 'restore']
        skip = [i for i in items if i.get('action') != 'restore']
        size = lambda i: i.get('bytes') if isinstance(i.get('bytes'), int) else 0   # noqa: E731
        out = [(app.t('ui_restore_summary', count=len(will), size=fmt_bytes(sum(size(i) for i in will)), skipped=len(skip)), 'strong')]
        out.extend((l, 'base') for l in wrap(app.t('ui_restore_never_overwrites'), width))
        out.extend((l, 'base') for l in wrap(app.t('ui_note_restore'), width))
        out.append(('', 'base'))
        if not items:
            out.append((app.t('ui_restore_nothing'), 'warn'))
        for title, rows, style in ((app.t('ui_restore_will'), will, 'ok'), (app.t('ui_restore_skips'), skip, 'warn')):
            if not rows:
                continue
            out.append(('%s (%d)' % (title, len(rows)), style))
            for i in rows[:LIST_CAP * 5]:
                state = str(i.get('destination_state') or '')
                tail = app.t('ui_dest_' + state) if state in ('free', 'exists', 'parent_missing', 'blocked') else state
                if i.get('reason'):
                    reason = str(i['reason'])
                    tail += ' / ' + (app.t('reason_' + reason) if reason in mc_events.REASONS else reason)
                out.append((clip('  %s  %s  [%s]' % (fmt_bytes(size(i)).rjust(8), i.get('path', '?'), tail), width, g['ellipsis']),
                            'base' if style == 'ok' else 'warn'))
            out.append(('', 'base'))
        return out
