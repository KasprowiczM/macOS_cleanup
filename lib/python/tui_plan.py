"""Plan review: read a run's plan.json (bounded, no symlinks) and sort its
operations into the groups the user must see before anything is cleaned:

    reversible   moved to quarantine, can be restored
    permanent    deleted by the tool or its own command; cannot be restored
    native       run by a native tool (npm, brew ...); permanent
    prompted     native command the engine asks about once more (docker, simulator runtimes, local
                 snapshots); only Clean selected runs it
    permonly     in a temporary folder outside home: quarantine cannot hold it, so the engine leaves it
                 alone unless the removal mode is permanent
    never        in a system location: the engine refuses it in every mode
    selonly      the same native operation seen by an action that does not run it (Clean safe, Apply
                 plan, the preview page): only Clean selected can
    report       never acted on, listed for information only
    skipped      will not run, with the reason

The review is built from the plan the engine wrote; nothing here decides what
runs. ``PlanReview`` is the overlay model: the run button is reachable only
from it, and permanent operations need their own acknowledgement.
"""
import json
import os
import re

import mc_events
import tui_registry
from tui_backend import open_regular

MAX_PLAN = 32 * 1024 * 1024
GROUPS = ('reversible', 'permanent', 'native', 'prompted', 'permonly', 'never', 'selonly', 'report', 'skipped')
OPTIONAL_GROUPS = ('prompted', 'permonly', 'never', 'selonly')       # shown only when they hold something
LIST_CAP = 60
_TM_DATE = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}')


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


def interactive_native(op):
    """True for a native operation the engine plans without a host target (planner.sh
    plan_add_interactive_native: docker, unusable simulator runtimes, dated local snapshots). A plan file
    shows it as ``report_only`` with an empty command, yet ``--interactive`` runs it after its own question
    (executor.sh _exc_run_interactive_native); no other entry point does (a plan file has no command to run,
    and Clean safe never approves it, _exc_auto_eligible). A ``report_only`` operation of a native category
    that is not one of these (an unresolved target, a target outside the known roots, an undated snapshot) is
    a real report and is not matched."""
    if op.get('action') != 'report_only':
        return False
    category = str(op.get('category') or '')
    if tui_registry.info(category)['action'] != 'native':
        return False
    path = str(op.get('path') or '')
    if category == 'docker':
        return path.startswith('docker:')
    if category == 'sim-runtimes':
        return path.startswith('simctl:')
    if category == 'tm-snapshots':
        return bool(_TM_DATE.search(path))
    return False


def normalize_path(path):
    """The engine's normalize_path (common.sh): slashes collapsed, ancestors resolved physically, the leaf of an
    existing path left as it is, a missing path normalized by its segments. None for a relative or empty path."""
    if not isinstance(path, str) or not path.startswith('/') or '\0' in path:
        return None
    path = re.sub(r'/+', '/', path).rstrip('/')
    if not path:
        return None
    if os.path.lexists(path):
        parent, _, base = path.rpartition('/')
        if base == '..':
            return os.path.realpath(path)
        parent = os.path.realpath(parent or '/')
        if base in ('', '.'):
            return parent
        return ('' if parent == '/' else parent) + '/' + base
    out = []
    for seg in path.split('/'):
        if seg in ('', '.'):
            continue
        if seg == '..':
            if out:
                out.pop()
            continue
        out.append(seg)
    return '/' + '/'.join(out)


# Where the engine's file removal reaches (common.sh safe_remove), in its order of checks:
#   under HOME            quarantined; in permanent mode deleted
#   /private/tmp/*, /private/var/folders/*
#                         skipped in quarantine mode (needs_permanent); deleted in permanent mode
#   anything else         never removed: /Library, /System and the rest of /private are privileged (deletion
#                         disabled, P0-1b), any other root is unknown territory (F16)
TEMP_ROOTS = ('/private/tmp/', '/private/var/folders/')
# The categories whose registry roots lie wholly outside HOME (undo is none), for a call that has no path to judge.
CATEGORY_PLACE = {'tmp': 'temp', 'system-logs': 'system'}


def place_of(path, home):
    """'home', 'temp' or 'system' for a path, by the engine's order of checks (is_user_space_path first, so a
    HOME that itself lies under /tmp is still home); None when there is no usable path or home."""
    norm, base = normalize_path(path), normalize_path(home) if home else None
    if norm is None or base is None:
        return None
    if norm.startswith(base + '/'):
        return 'home'
    return 'temp' if norm.startswith(TEMP_ROOTS) else 'system'


def where(op, home):
    """place_of for an operation's own path; None when it has none. Existence is not asked: the plan is a
    snapshot of items that existed."""
    if not home or not isinstance(op.get('path'), str):
        return None
    return place_of(op['path'], home)


def removal_place(category, op=None, home=None):
    """Where a file removal of this operation reaches: its own path decides (the engine decides per path); without
    a path or a home, the category's registry roots do (CATEGORY_PLACE); None when neither says."""
    return (where(op, home) if op is not None else None) or CATEGORY_PLACE.get(category)


def needs_permanent_mode(category, remove_mode, op=None, home=None):
    """One rule for the plan review, the plan overview and the Categories details: a file removal in a temporary
    folder is left alone by the engine unless the removal mode is permanent (executor.sh _exc_offer, reason
    needs_permanent; common.sh safe_remove)."""
    return remove_mode != 'permanent' and removal_place(category, op, home) == 'temp'


def never_removed(category, op=None, home=None):
    """A file removal in a system location (privileged, or an unknown root): the engine refuses it in every mode."""
    return removal_place(category, op, home) == 'system'


def auto_eligible(op, category, effective_auto, remove_mode, home=None):
    """(eligible, reason): whether Clean safe (--auto-safe) and a scheduled --unattended run approve this operation.
    A mirror of executor.sh ``_exc_auto_eligible``, condition by condition and in its order; its reason codes are
    the engine's:
      1. a remove_path operation (a native or interactive-only one is never approved here);
      2. not DANGEROUS (dangerous_blocked);
      3. the category's effective mode is auto;
      4. the registry row is regenerable, quarantine, unattended yes (tui_registry.auto_allowed);
      5. outside HOME only in permanent mode (needs_permanent), judged by the operation's own path.
    The risk class REVIEW is not tested: V4 section 13.1 makes the user's auto mode the decision. (Apply plan is a
    different path, consent_plan_file, and does skip REVIEW without --include-review: see classify.)"""
    if op.get('action') != 'remove_path':
        return False, 'review_not_included'
    if str(op.get('risk') or 'SAFE').upper() == 'DANGEROUS':
        return False, 'dangerous_blocked'
    if not effective_auto or not tui_registry.auto_allowed(category):
        return False, 'review_not_included'
    if remove_mode != 'permanent' and where(op, home) in ('temp', 'system'):
        return False, 'needs_permanent'
    return True, ''


def classify(op, remove_mode='quarantine', include_review=False, only=None, auto_only=None, home=None, mode_of=None):
    """(group, reason) for one plan operation. ``only`` restricts to category ids
    (clean selected); ``auto_only`` is the set of categories that may run
    unattended-style (clean safe). Without ``only`` an interactive-only native operation is not part of the
    run: only Clean selected starts the engine in the mode that asks about it. ``home`` is the HOME the engine
    runs with; with it a file removal is judged by its own path (needs_permanent_mode). ``mode_of(category)``
    gives (mode, effective_auto) as the category settings say now: the engine refuses every operation of a
    category whose mode is skip (executor.sh _exc_offer, user_declined), whatever the plan file shows."""
    category = str(op.get('category') or '')
    action = op.get('action')
    risk = str(op.get('risk') or 'SAFE').upper()
    ask = interactive_native(op)
    if tui_registry.info(category)['action'] == 'report':
        return 'report', ''
    if mode_of is not None and mode_of(category)[0] == 'skip':
        return 'skipped', 'user_declined'
    if action == 'report_only' and not ask:
        return 'report', ''
    if op.get('decision') == 'skipped' or op.get('skip_reason'):
        reason = str(op.get('skip_reason') or op.get('reason') or 'unknown')
        return 'skipped', reason if reason in mc_events.REASONS else 'unknown'
    if only is not None and category not in only:
        return 'skipped', 'not_selected'
    if ask and only is None:
        return 'selonly', ''
    if auto_only is not None:                   # Clean safe: the engine's own test, REVIEW included (auto_eligible)
        eligible, why = auto_eligible(op, category, category in auto_only, remove_mode, home)
        if not eligible:                        # the engine files "not auto" under review_not_included; the screen says what it is
            return 'skipped', 'not_auto' if why == 'review_not_included' else why
    if risk == 'DANGEROUS':
        return 'skipped', 'dangerous_blocked'
    if risk == 'REVIEW' and not include_review and auto_only is None:      # Apply plan without --include-review
        return 'skipped', 'review_not_included'
    if ask:
        return 'prompted', ''
    if action == 'native_command':
        return 'native', ''
    if action == 'remove_path':
        place = removal_place(category, op, home)
        if place == 'system':
            return 'never', ''                  # privileged or unknown root: refused in every mode
        if remove_mode != 'permanent':
            if place == 'temp':
                return 'permonly', ''
            if place == 'home':
                return 'reversible', ''         # the engine quarantines what lies under HOME, whatever the registry says
    if remove_mode == 'permanent' or tui_registry.info(category)['undo'] != 'quarantine':
        return 'permanent', ''
    return 'reversible', ''


def summarize(plan, remove_mode='quarantine', include_review=False, only=None, auto_only=None, home=None, mode_of=None):
    """{group: {'count', 'bytes', 'ops': [(op, reason)], 'tools': set}} for a plan."""
    out = {g: dict(count=0, bytes=0, ops=[], tools=set()) for g in GROUPS}
    for op in plan.get('operations', []):
        if not isinstance(op, dict):
            continue
        group, reason = classify(op, remove_mode, include_review, only, auto_only, home, mode_of)
        size = op.get('estimated_bytes')
        size = size if isinstance(size, int) and not isinstance(size, bool) and size >= 0 else 0
        slot = out[group]
        slot['count'] += 1
        slot['bytes'] += size
        slot['ops'].append((op, reason))
        if group in ('native', 'prompted'):
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
        return sum(self.summary[g]['count'] for g in ('permanent', 'native', 'prompted'))

    def needs_ack(self):
        return self.permanent_count > 0

    def run_enabled(self):
        return bool(self.plan) and (self.acked or not self.needs_ack()) and self.executable_count() > 0

    def executable_count(self):
        return sum(self.summary[g]['count'] for g in ('reversible', 'permanent', 'native', 'prompted'))

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
        if self.executable_count() == 0:                # say why Run is off, before the groups that explain it
            nothing = 'ui_plan_nothing' if not self.plan.get('operations') else 'ui_plan_run_off'
            out.extend((l, 'warn') for l in wrap(app.t(nothing), width))
            out.append(('', 'base'))
        label_style = dict(reversible='ok', permanent='fail', native='fail', prompted='fail', permonly='muted',
                           never='muted', selonly='warn', report='muted', skipped='warn')
        for group in GROUPS:
            slot = self.summary[group]
            if not slot['count']:
                if group not in OPTIONAL_GROUPS:
                    out.append(('%s %s (0)' % (g['off'], app.t('ui_plan_g_' + group)), 'muted'))
                continue
            title = '%s %s: %d, %s' % (g['needs'] if group in ('permanent', 'native', 'prompted', 'selonly') else g['ok'],
                                       app.t('ui_plan_g_' + group), slot['count'], fmt_bytes(slot['bytes']))
            if group in ('native', 'prompted') and slot['tools']:
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


def overview(plan, mode_of, remove_mode='quarantine', home=None):
    """What Clean would do with a plan, per category, read only from fields the engine writes
    (operation category, risk, action, estimated_bytes). ``mode_of(category)`` returns (mode, effective_auto)
    from the category settings. Returns (rows, totals):

    row    {id, ops, bytes, auto_ops, auto_bytes, decision_ops, decision_bytes, blocked_ops, state, removal, tools}
           state: auto | decision | blocked | permonly | never | selonly | report | skipped
           permonly: in a temporary folder outside home, so quarantine cannot hold it; the engine leaves it
           unless the removal mode is permanent (the rule is classify's, not a second one)
           never: in a system location; the engine refuses it in every mode
           selonly: a native command the engine asks about once more; only Clean selected runs it
           removal: quarantine | native | permanent | '' (report-only categories)
    totals {auto: (ops, bytes), decision: (ops, bytes), report: (ops, bytes), skipped: (ops, bytes),
            blocked: (ops, bytes), permonly: (ops, bytes), never: (ops, bytes), selonly: (ops, bytes)}
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
                                        permonly_ops=0, permonly_bytes=0, never_ops=0, never_bytes=0, selonly_ops=0, selonly_bytes=0, skipped_ops=0, skipped_bytes=0, state='', removal='', tools=set())
            order.append(category)
        size = op.get('estimated_bytes')
        size = size if isinstance(size, int) and not isinstance(size, bool) and size >= 0 else 0
        row['ops'] += 1
        row['bytes'] += size
        group, _ = classify(op, remove_mode, include_review=True, home=home, mode_of=mode_of)
        risk = str(op.get('risk') or 'SAFE').upper()
        mode, auto = mode_of(category)
        if group == 'report':
            slot = 'report'
        elif mode == 'skip':
            slot = 'skipped'
        elif risk == 'DANGEROUS':
            slot = 'blocked'
        elif group in ('permonly', 'never'):
            slot = group
        elif group == 'selonly':
            slot = 'selonly'
        elif auto and auto_eligible(op, category, auto, remove_mode, home)[0]:
            slot = 'auto'
        else:
            slot = 'decision'
        row[slot + '_ops'] += 1
        row[slot + '_bytes'] += size
        if group == 'selonly' and slot == 'selonly':
            row['removal'] = 'native'
            row['tools'].add(_tool(op))
        if group in ('reversible', 'native', 'permanent') and slot in ('auto', 'decision'):
            row['removal'] = row['removal'] if row['removal'] == 'native' else (
                'native' if group == 'native' else ('permanent' if group == 'permanent' or row['removal'] == 'permanent' else 'quarantine'))
            if group == 'native':
                row['tools'].add(_tool(op))
    totals = {k: (0, 0) for k in ('auto', 'decision', 'report', 'skipped', 'blocked', 'permonly', 'never', 'selonly')}
    out = []
    for category in order:
        row = rows[category]
        for k in totals:
            totals[k] = (totals[k][0] + row[k + '_ops'], totals[k][1] + row[k + '_bytes'])
        row['state'] = ('decision' if row['decision_ops'] else 'auto' if row['auto_ops'] else
                        'blocked' if row['blocked_ops'] else 'permonly' if row['permonly_ops'] else
                        'never' if row['never_ops'] else 'selonly' if row['selonly_ops'] else 'skipped' if row['skipped_ops'] else 'report')
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
