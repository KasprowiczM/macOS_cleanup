"""Quarantine, History, Diagnostics and Help screens."""
import base64
import json
import os
import time

import tui_data
import tui_plan
import tui_registry
import tui_runfacts
from tui_dialogs import ChoiceDialog
from tui_itemlist import ItemList, read_manifest
from tui_keymap import Binding
from tui_runner import fmt_bytes, model_from_summary, run_type
from tui_screens import (check_text, ListState, Screen, TIER_STYLE, draw_wrapped, render_scrollbar, restore_text, size_text, status_glyph,
                         tui_data_type)
from tui_widgets import Rect, clip, duration, pad, plain, scroll_window, text_width, wrap

RUN_TYPES = ('all', 'scan', 'preview', 'clean', 'apply', 'restore', 'purge', 'unattended', 'unknown')
EXPIRY_SOON_DAYS = 3
FDA_URL = 'x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles'


def row_type(row):
    return row.get('type') or tui_data_type(row)


def short_run(run_id):
    """2026-11-14_090000_999 -> 2026-11-14 09:00 (the full id is in the detail line)."""
    return run_id[:10] + ' ' + run_id[11:13] + ':' + run_id[13:15]


def read_restored(path):
    """Original paths already restored, from the run's quarantine journal (bounded)."""
    from tui_backend import open_regular
    raw = open_regular(path, 16 * 1024 * 1024)
    out = set()
    for line in (raw or b'').decode('utf-8', 'replace').splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict) and entry.get('op') == 'restore' and entry.get('result') in ('restored', 'ok') \
                and isinstance(entry.get('path'), str):
            out.add(entry['path'])
    return out


# ---------------------------------------------------------------------------
class Quarantine(Screen):
    id, tab = 'quarantine', 'ui_tab_quarantine'

    def __init__(self):
        self.runs = ListState()
        self.lists = {}                  # run_id -> ItemList
        self.truncated = {}
        self.manifest = {}               # run_id -> (manifest path, readable with at least one row)

    def zones(self, app):
        return ['runs', 'contents']

    def rows(self, app):
        return app.models.quarantine_runs()

    def current(self, app):
        rows = self.rows(app)
        if not rows:
            return None
        self.runs.clamp(len(rows))
        return rows[self.runs.index]

    def itemlist(self, app, run):
        """The contents list of a run (manifest read once, bounded, restored rows hidden)."""
        run_id = run['run_id']
        if run_id not in self.lists:
            base = os.path.join(app.paths['quarantine'], run_id)
            manifest = os.path.join(base, 'manifest.tsv')
            rows, truncated = read_manifest(manifest, app.home)
            if not rows and run.get('manifest') == 'legacy':
                # A v3 run: its restore list is in the old reports folder (the same place the engine counted it in).
                legacy = self.legacy_manifest(app, run_id)
                if legacy:
                    manifest = legacy
                    rows, truncated = read_manifest(manifest, app.home)
            self.manifest[run_id] = (manifest, bool(rows))
            restored = read_restored(os.path.join(base, 'journal.jsonl'))
            date = str(run.get('created_at') or '')[:10]
            items = [dict(path=p, bytes=b, category=cat, date=date, check_original=True) for p, b, cat in rows
                     if p not in restored]
            il = ItemList(items, title=run_id, kind='quarantine', multi=True)
            self.lists[run_id] = il
            self.truncated[run_id] = truncated
        return self.lists[run_id]

    @staticmethod
    def legacy_manifest(app, run_id):
        """Path of a v3 run's restore list (``restore_<run id>.tsv``), searched where the engine looks:
        <state>/legacy/reports and, for a checkout install, <program>/reports. '' when there is none."""
        import stat
        folders = [os.path.join(app.state_dir, 'legacy', 'reports')]
        if app.paths.get('mode') == 'checkout':
            folders.append(os.path.join(app.paths['program'], 'reports'))
        for folder in folders:
            path = os.path.join(folder, 'restore_%s.tsv' % run_id)
            try:
                info = os.lstat(path)
            except OSError:
                continue
            if stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid():
                return path
        return ''

    def models_changed(self, app, name):
        if name == 'list_quarantine':
            self.lists = {}
            self.manifest = {}

    def expiry(self, app, run):
        """(text key, params, style) for the expiry badge."""
        if run.get('expired'):
            return 'ui_q_expired', {}, 'fail'
        retention = (app.models.get('list_quarantine') or {}).get('retention_days')
        age = run.get('age_days')
        if isinstance(retention, int) and isinstance(age, int):
            left = retention - age
            if left <= EXPIRY_SOON_DAYS:
                return 'ui_q_expires_soon', dict(days=max(0, left)), 'warn'
            return 'ui_q_expires_in', dict(days=left), 'base'
        return '', {}, 'base'

    def contents_state(self, app, run):
        """'empty' (everything restored), 'unreadable' (manifest missing or without rows) or 'items'."""
        if self.is_empty(run):
            return 'empty'
        il = self.itemlist(app, run)
        return 'items' if il.items else 'unreadable'

    def readable(self, app, run):
        """True when the run's restore list could be read and holds rows."""
        self.itemlist(app, run)
        return self.manifest.get(run['run_id'], ('', False))[1]

    def is_empty(self, run):
        total, restored = run.get('items_total'), run.get('items_restored')
        return isinstance(total, int) and isinstance(restored, int) and total > 0 and restored >= total

    def bindings(self, app, zone):
        if zone == 'contents':
            run = self.current(app)
            il = self.itemlist(app, run) if run else None
            base = il.bindings() if il else []
            return base[:3] + [Binding(('r',), 'ui_btn_restore', 'restore')] + base[3:]
        return [Binding(('up', 'down'), 'ui_key_move', 'vmove'), Binding(('enter',), 'ui_key_open', 'open'),
                Binding(('r',), 'ui_btn_restore', 'restore'), Binding(('p',), 'ui_btn_purge', 'purge'),
                Binding(('E',), 'ui_btn_purge_expired', 'purge_expired'), Binding(('o',), 'ui_key_reveal', 'reveal'),
                Binding(('R',), 'ui_btn_refresh', 'refresh', show=False)]

    def help(self, app, zone):
        run = self.current(app)
        if zone == 'contents':
            return app.t('ui_help_q_contents')
        if run is None:
            return app.t('ui_help_q_runs')
        lines = [run['run_id'], self.run_line(app, run), '', app.t('ui_help_q_runs')]
        return '\n'.join(lines)

    def run_line(self, app, run):
        if run.get('manifest') == 'legacy' and not self.readable(app, run):
            return app.t('ui_q_legacy_line', size=fmt_bytes(run.get('bytes')))
        parts = ['%s' % fmt_bytes(run.get('bytes')), app.t('ui_q_items', n=run.get('items', '?'))]
        if isinstance(run.get('items_total'), int):
            parts = [app.t('ui_q_restored_of', done=run.get('items_restored', 0), total=run['items_total']),
                     app.t('ui_q_remaining', size=fmt_bytes(run.get('bytes_remaining', run.get('bytes'))))]
        return ' | '.join(parts)

    def action(self, app, zone, action):
        run = self.current(app)
        rows = self.rows(app)
        if action == 'refresh':
            app.models.refresh('list_quarantine')
            self.lists = {}
            return True
        if zone == 'contents':
            if run is None:
                return False
            il = self.itemlist(app, run)
            if action == 'restore':
                self.restore(app)
                return True
            if action == 'up' and il.index == 0 and not il.searching:
                app.focus_zone('runs')
                return True
            return il.action(app, action)
        if action == 'up':
            self.runs.move(-1, len(rows))
        elif action == 'down':
            self.runs.move(1, len(rows))
        elif action == 'open' and run:
            app.focus_zone('contents')
        elif action == 'restore' and run:
            self.restore(app)
        elif action == 'purge' and run:
            # What a purge removes is what is still in quarantine, not what the run once moved.
            left = run.get('items')
            if isinstance(run.get('items_total'), int) and isinstance(run.get('items_restored'), int):
                left = max(0, run['items_total'] - run['items_restored'])
            app.request_action('purge', run['run_id'], info=dict(
                bytes=run.get('bytes_remaining', run.get('bytes')), items=left))
        elif action == 'purge_expired':
            app.request_action('purge', 'expired')
        elif action == 'reveal' and run:
            app.reveal(os.path.join(app.paths['quarantine'], run['run_id']))
        else:
            return action in ('vmove', 'page')
        return True

    def text(self, app, zone, text):
        if zone == 'contents':
            run = self.current(app)
            return bool(run) and self.itemlist(app, run).text(text)
        return False

    def restore(self, app):
        run = self.current(app)
        if run is None:
            return
        if self.is_empty(run):
            app.notify(app.t('ui_q_empty_run'), 'status_warn')
            return
        il = self.itemlist(app, run)
        order = [i['path'] for i in il.items if i['path'] in il.marked]
        info = dict(bytes=run.get('bytes_remaining', run.get('bytes')), items=run.get('items'))
        app.begin_restore(run['run_id'], order or None, info)

    def click(self, app, payload, double=False):
        if payload[0] == 'q_run':
            app.focus_zone('runs')
            self.runs.index = payload[1]
            if double:
                app.focus_zone('contents')
            return True
        if payload[0] == 'item_row':
            run = self.current(app)
            if run:
                app.focus_zone('contents')
                self.itemlist(app, run).click(payload[1])
            return True
        return False

    def scroll(self, app, zone, delta):
        if zone == 'contents':
            run = self.current(app)
            if run:
                self.itemlist(app, run).move(delta)
            return True
        self.runs.move(delta, len(self.rows(app)))
        return True

    def render(self, app, c, main, side):
        g = app.glyphs
        rows = self.rows(app)
        totals = app.models.quarantine_totals()
        c.box(main, app.t('ui_pane_quarantine'), self.pane_focus(app, 'runs'), right=str(len(rows)) if rows else '')
        inner = main.inner()
        y = inner.y
        free = app.facts().get('disk_free')
        disk = app.models.doctor().get('disk') if isinstance(app.models.doctor().get('disk'), dict) else {}
        free = disk.get('container_free_bytes', free)
        summary = app.t('ui_q_total', size=size_text(totals.get('bytes')), runs=totals.get('runs', len(rows)),
                        free=size_text(free))
        c.put(y, inner.x, clip(summary, inner.w, g['ellipsis']), 'strong')
        y += 1
        if not rows:
            msg = app.t('ui_engine_missing') if app.models.error['list_quarantine'] and not app.models.get('list_quarantine') \
                else app.t('ui_q_none')
            for line in wrap(msg, inner.w):
                c.put(y + 1, inner.x, line, 'base')
                y += 1
            if side is not None:
                c.box(side, app.t('ui_pane_contents'), self.pane_focus(app, 'contents'))
            return
        y += 1
        id_w = 16                                    # "2026-11-16 00:14"
        c.put(y, inner.x + 2, app.t('ui_col_run'), 'muted')
        c.put(y, inner.x + inner.w - 13, pad(app.t('ui_col_age'), 4, 'right') + pad(app.t('ui_col_size'), 9, 'right'), 'muted')
        y += 1
        visible = inner.y + inner.h - y - 5
        self.runs.clamp(len(rows))
        self.runs.offset = scroll_window(self.runs.index, self.runs.offset, max(1, visible), len(rows))
        for i, row in enumerate(rows[self.runs.offset:self.runs.offset + max(1, visible)], self.runs.offset):
            selected = i == self.runs.index
            style = ('sel_focus' if app.zone == 'runs' and app.dialog is None else 'sel') if selected else 'base'
            if selected:
                c.fill(y, inner.x, 1, inner.w, style)
                c.put(y, inner.x, g['marker'], style)
            badge_key, badge_params, badge_style = self.expiry(app, row)
            empty = self.is_empty(row)
            c.put(y, inner.x + 2, short_run(row['run_id']), style if selected else ('muted' if empty else 'base'))
            tail = pad('%sd' % row.get('age_days', '?'), 4, 'right') + pad(fmt_bytes(row.get('bytes_remaining', row.get('bytes'))), 9, 'right')
            c.put(y, inner.x + inner.w - 13, tail, style if selected else 'base')
            badge = ''
            if empty:
                badge = app.t('ui_q_empty')
            elif badge_key and (row.get('expired') or badge_style == 'warn'):
                badge = app.t(badge_key, **badge_params)
            elif row.get('manifest') in ('legacy', 'missing'):
                badge = app.t('ui_q_manifest_' + row['manifest'])
            room = inner.w - 2 - id_w - 13 - 1
            if badge and room >= 6:
                c.put(y, inner.x + 2 + id_w + 1, clip(badge, room, g['ellipsis']), style if selected else
                      ('fail' if row.get('expired') else 'warn' if not empty else 'muted'))
            c.region(y, inner.x, 1, inner.w, ('q_run', i))
            y += 1
        run = self.current(app)
        if run is not None and inner.h >= 10:
            by = inner.y + inner.h - 4
            c.put(by - 1, inner.x, g['h'] * inner.w, 'border')
            key, params, style = self.expiry(app, run)
            line1 = app.t('ui_q_created', date=str(run.get('created_at') or '?')[:16].replace('T', ' '))
            if run.get('manifest') in ('legacy', 'missing'):
                line1 += '  ' + g['sep'] + '  ' + app.t('ui_q_manifest_' + run['manifest'])
            row_y = by
            c.put(row_y, inner.x, clip(line1, inner.w, g['ellipsis']), 'base')
            row_y += 1
            for line in wrap(self.run_line(app, run), inner.w)[:1 if key else 2]:
                c.put(row_y, inner.x, line, 'base')
                row_y += 1
            if key:
                c.put(row_y, inner.x, clip(app.t(key, **params), inner.w, g['ellipsis']), style)
        if side is not None:
            self.render_contents(app, c, side, run)

    def render_contents(self, app, c, rect, run):
        g = app.glyphs
        focused = self.pane_focus(app, 'contents')
        il = self.itemlist(app, run) if run else None
        state = self.contents_state(app, run) if run else ''
        right = app.t('ui_q_items', n=len(il.items)) if il and state == 'items' else ''
        c.box(rect, app.t('ui_pane_contents'), focused, right=right)
        inner = rect.inner()
        if run is None:
            return
        if state == 'empty':                                  # items_restored == items_total
            draw_wrapped(c, inner, app.t('ui_q_empty_run'), 'base')
            return
        if state == 'unreadable':                             # the run still holds items we cannot list
            path = self.manifest.get(run['run_id'], ('', False))[0]
            if run.get('manifest') == 'legacy':
                draw_wrapped(c, inner, app.t('ui_q_legacy_unreadable'), 'warn')
            else:
                draw_wrapped(c, inner, app.t('ui_q_manifest_unreadable') + '\n\n' + path, 'warn')
            return
        top = inner.y
        if self.truncated.get(run['run_id']):
            c.put(top, inner.x, clip(app.t('ui_q_truncated'), inner.w, g['ellipsis']), 'warn')
            top += 1
        il.render(app, c, Rect(top, inner.x, inner.y + inner.h - top, inner.w), focused)


# ---------------------------------------------------------------------------
class History(Screen):
    id, tab = 'history', 'ui_tab_history'
    TYPES = ('apply', 'clean', 'preview', 'prune', 'purge', 'restore', 'scan', 'unattended', 'unknown')

    def type_columns(self, app):
        """Width of the longest type name in the current language, capped."""
        return min(24, max(text_width(app.t('ui_type_' + t)) for t in self.TYPES))

    def wanted_main(self, app):
        return 46 + max(9, self.type_columns(app))              # border and padding, marker, time, gaps, mark and the two size columns

    def __init__(self):
        self.list = ListState()
        self.filter = 'all'
        self._models = {}

    def zones(self, app):
        return ['list']

    def rows(self, app):
        rows = app.models.history_rows()
        if self.filter != 'all':
            rows = [r for r in rows if app.run_facts(r).type == self.filter]
        return rows

    def current(self, app):
        rows = self.rows(app)
        if not rows:
            return None
        self.list.clamp(len(rows))
        return rows[self.list.index]

    def models_changed(self, app, name):
        if name == 'history':
            self._models = {}

    def applicable(self, app, row):
        """A dry-run/plan run younger than 24 h whose plan file still exists. Never in read-only mode."""
        if app.read_only:
            return None
        if not tui_data.dry_run_row(row, lambda r: app.run_facts(r).type):
            return None
        path = os.path.join(app.state_dir, 'runs', row['run_id'], 'plan.json')
        if not tui_plan.known_plan_path(path, app.state_dir) or not os.path.isfile(path) or os.path.islink(path):
            return None
        try:
            if time.time() - os.stat(path).st_mtime > 24 * 3600:
                return None
        except OSError:
            return None
        return path

    def bindings(self, app, zone):
        row = self.current(app)
        can_apply = row is not None and self.applicable(app, row) is not None
        return [Binding(('up', 'down'), 'ui_key_move', 'vmove'), Binding(('enter',), 'ui_btn_open_report', 'open'),
                Binding(('f',), 'ui_key_filter', 'filter')] \
            + ([Binding(('A',), 'ui_btn_apply_plan', 'apply')] if can_apply else []) \
            + [Binding(('o',), 'ui_key_reveal', 'reveal'), Binding(('y',), 'ui_key_copy_report', 'copy'),
               Binding(('r',), 'ui_btn_refresh', 'refresh', show=False)]

    def help(self, app, zone):
        return app.t('ui_help_history')

    def action(self, app, zone, action):
        rows = self.rows(app)
        row = self.current(app)
        if action == 'up':
            if self.list.index == 0:
                app.focus_zone('tabs')
            self.list.move(-1, len(rows))
        elif action == 'down':
            self.list.move(1, len(rows))
        elif action in ('pgup', 'pgdn'):
            self.list.move(-10 if action == 'pgup' else 10, len(rows))
        elif action == 'filter':
            self.filter = RUN_TYPES[(RUN_TYPES.index(self.filter) + 1) % len(RUN_TYPES)]
            self.list.index = 0
            app.notify(app.t('ui_filter_is', type=app.t('ui_type_' + self.filter) if self.filter != 'all' else app.t('ui_type_all')), 'status')
        elif action == 'refresh':
            app.models.refresh('history')
        elif row is None:
            return action in ('vmove', 'page')
        elif action == 'open':
            app.view_file(os.path.join(app.state_dir, 'runs', row['run_id'], 'report.md'), row['run_id'], markdown=True)
        elif action == 'reveal':
            app.reveal(os.path.join(app.state_dir, 'runs', row['run_id']))
        elif action == 'copy':
            app.copy_text(os.path.join(app.state_dir, 'runs', row['run_id'], 'report.md'))
        elif action == 'apply':
            self.apply(app, row)
        else:
            return action in ('vmove', 'page')
        return True

    def apply(self, app, row):
        path = self.applicable(app, row)
        if path is None:
            app.notify(app.t('ui_history_not_applicable'), 'status_warn')
            return
        plan = tui_plan.load_plan(path) or {}
        review = sum(1 for op in plan.get('operations', []) if isinstance(op, dict) and str(op.get('risk')).upper() == 'REVIEW')
        if not review:
            app.request_action('apply_plan', path)
            return
        entries = [(app.t('ui_apply_safe_only'), 'safe'), (app.t('ui_apply_with_review', count=review), 'review')]

        def done(a, value):
            if value == 'safe':
                a.request_action('apply_plan', path)
            elif value == 'review':
                a.request_action('apply_plan', path, ['--include-review'])
        app.open_dialog(ChoiceDialog(app.t('ui_btn_apply_plan'), entries, done, current='safe',
                                     body=app.t('ui_apply_review_note')))

    def click(self, app, payload, double=False):
        if payload[0] == 'hist_row':
            app.focus_zone('list')
            self.list.index = payload[1]
            if double:
                self.action(app, 'list', 'open')
            return True
        return False

    def scroll(self, app, zone, delta):
        self.list.move(delta, len(self.rows(app)))
        return True

    def render(self, app, c, main, side):
        g = app.glyphs
        rows = self.rows(app)
        title = app.t('ui_pane_history') + ((' [%s]' % app.t('ui_type_' + self.filter)) if self.filter != 'all' else '')
        c.box(main, title, self.pane_focus(app, 'list'), right=str(len(rows)) if rows else '')
        inner = main.inner()
        if not rows:
            draw_wrapped(c, inner, app.t('ui_history_empty'), 'base')
            if side is not None:
                c.box(side, app.t('ui_pane_details'))
            return
        y = inner.y
        when_w, res_w = 16, 3
        # The type column fits the longest type name of the language (Apply plan, Usuwanie z kwarantanny), as far as
        # the window allows after the time, the mark and the two size columns; 9 where it is narrow.
        type_w = max(9, min(self.type_columns(app), inner.w - (42 if inner.w >= 56 else 22)))      # 42: the size columns follow
        c.put(y, inner.x + 2, app.t('ui_col_when'), 'muted')
        c.put(y, inner.x + 2 + when_w + 1, app.t('ui_col_type'), 'muted')
        if inner.w >= 56:
            c.put(y, inner.x + inner.w - 20, pad(app.t('ui_card_estimated'), 10, 'right') + pad(app.t('ui_card_measured_short'), 10, 'right'), 'muted')
        y += 1
        visible = inner.y + inner.h - y
        self.list.clamp(len(rows))
        self.list.offset = scroll_window(self.list.index, self.list.offset, visible, len(rows))
        for i, row in enumerate(rows[self.list.offset:self.list.offset + visible], self.list.offset):
            selected = i == self.list.index
            style = ('sel_focus' if app.zone == 'list' and app.dialog is None else 'sel') if selected else 'base'
            if selected:
                c.fill(y, inner.x, 1, inner.w, style)
                c.put(y, inner.x, g['marker'], style)
            facts = app.run_facts(row)
            glyph, gstyle = status_glyph(app, 'done', {'ok': 'ok', 'warn': 'warn', 'error': 'failed', 'cancelled': 'stopped'}.get(facts.result, 'ok'))
            c.put(y, inner.x + 2, (row.get('started_at') or row['run_id'])[:16].replace('T', ' '), style)
            c.put(y, inner.x + 2 + when_w + 1, clip(app.t('ui_type_' + facts.type), type_w), style)
            c.put(y, inner.x + 2 + when_w + type_w + 2, glyph, style if selected else gstyle)
            if inner.w >= 56:
                est = size_text(None if facts.type == 'restore' else facts.estimated)       # a restore estimates nothing
                meas = size_text(None if facts.type == 'restore' else facts.measured, unknown='-')
                c.put(y, inner.x + inner.w - 20, pad(est, 10, 'right') + pad(meas, 10, 'right'), style if selected else 'base')
            c.region(y, inner.x, 1, inner.w, ('hist_row', i))
            y += 1
        if side is not None:
            self.render_details(app, c, side, self.current(app))

    def details_lines(self, app, row, width):
        """(text, style) rows of the details pane for a run; every '!' carries its reason."""
        g = app.glyphs
        facts = app.run_facts(row)
        glyph, style = status_glyph(app, 'done', {'ok': 'ok', 'warn': 'warn', 'error': 'failed', 'cancelled': 'stopped'}.get(facts.result, 'ok'))
        out = [(clip('%s %s  %s' % (glyph, app.t('ui_type_' + facts.type), duration(facts.seconds)), width, g['ellipsis']), style)]
        if facts.type == 'unknown':
            out.extend(('  ' + l, 'base') for l in wrap(app.t('ui_hist_type_unknown'), max(10, width - 2)))
        for kind, text in facts.reasons():
            if kind == 'warning':
                ident = tui_runfacts.note_category(text)          # say which category a note is about
                why = (app.category_label(ident) + ': ' if ident else '') + text
            elif kind == 'count':
                why = app.t('ui_hist_why_count', n=text)
            elif text == 'cancelled':
                why = app.t('ui_hist_why_cancelled')
            else:
                why = app.t('ui_hist_why_error', code=facts.exit_code if facts.exit_code is not None else '?')
            for i, line in enumerate(wrap(why, max(10, width - 4))):
                out.append((('  ' + g['needs'] + ' ' if i == 0 else '    ') + line, 'warn'))
        out.append(('', 'base'))
        if facts.type == 'restore' and facts.restore is not None:
            out.extend((l, 'base') for l in restore_text(app, facts.restore))
        else:
            out.append((app.t('ui_card_estimated') + ' ' + size_text(facts.estimated), 'base'))
        if facts.type in ('clean', 'apply', 'unattended'):
            out.append((app.t('ui_card_measured') + ' ' + size_text(facts.measured, unknown=app.t('ui_not_measured')), 'base'))
            quarantined = size_text(facts.quarantined_bytes) + (
                ' ' + app.t('ui_hist_in_items', n=facts.quarantined_items) if facts.quarantined_items else '')
            out.append((app.t('ui_card_quarantined') + ' ' + quarantined, 'base'))
        out.append(('', 'base'))
        out.append((app.t('ui_result_phases'), 'accent'))
        if facts.steps:
            for pid, result, took in facts.steps:
                word = app.t('ui_phres_' + (result or 'ok'))
                out.append((clip('  %s %s  %s' % (pad(app.t('ui_phase_' + pid), 11), pad(word, 9), duration(took) if took is not None else ''),
                                 width, g['ellipsis']), 'warn' if result in ('warn', 'error') else 'base'))
            if facts.source != 'events':
                out.extend(('  ' + l, 'base') for l in wrap(app.t('ui_hist_steps_derived'), max(10, width - 2)))
        else:
            out.append(('  ' + app.t('ui_result_no_phases'), 'base'))
        model = facts.model
        why = [] if row.get('legacy') or model is None or facts.type == 'restore' else model.differences()
        if why or facts.type in ('scan', 'preview'):
            out.append(('', 'base'))
        for key, params in (why if why else ([('dry_run', {})] if facts.type in ('scan', 'preview') else [])):
            out.extend((l, 'base') for l in wrap(app.t('ui_why_' + key, **params), max(10, width - 2)))
        return out

    def render_details(self, app, c, rect, row):
        g = app.glyphs
        c.box(rect, app.t('ui_pane_details'))
        inner = rect.inner()
        if row is None:
            return
        lines = self.details_lines(app, row, inner.w)
        bottom = inner.y + inner.h
        for i, (text, style) in enumerate(lines[:max(0, bottom - inner.y - 1)]):
            c.put(inner.y + i, inner.x, clip(text, inner.w, g['ellipsis']), style)
        if self.applicable(app, row):
            c.put(bottom - 1, inner.x, clip(app.t('ui_history_can_apply'), inner.w, g['ellipsis']), 'accent')


# ---------------------------------------------------------------------------
def check_mark(g, status):
    """(glyph, style) of a health check; 'info' is a row nothing was measured for, drawn without a tick."""
    return {'ok': (g['ok'], 'ok'), 'warn': (g['needs'], 'warn'), 'fail': (g['fail'], 'fail'),
            'info': (g['current'], 'muted')}.get(status, (g['ok'], 'ok'))


class Diagnostics(Screen):
    id, tab = 'diagnostics', 'ui_tab_diagnostics'

    def __init__(self):
        self.list = ListState()

    def zones(self, app):
        return ['checks', 'facts']

    def checks(self, app):
        doctor = app.models.doctor()
        rows = [dict(id=str(c.get('id', '?')), status=str(c.get('status', 'ok')), text=check_text(app, c))
                for c in (doctor.get('checks') or []) if isinstance(c, dict)]
        store = app.settings
        bad = list(store.invalid) + list(store.unknown)
        rows.append(dict(id='settings_conf', status='warn' if bad else 'ok',
                         text=app.t('ui_diag_settings_bad', n=len(bad)) if bad else app.t('ui_diag_settings_ok')))
        if not any(r['id'] == 'rules_overlay' for r in rows):
            rows.append(dict(id='rules_overlay', status='info', text=app.t('ui_diag_rules_unknown')))      # an older engine: nothing was checked, so no tick
        fda = (doctor.get('fda') or {}).get('status') if isinstance(doctor.get('fda'), dict) else None
        if fda and not any(r['id'] == 'fda' for r in rows):
            rows.append(dict(id='fda', status={'granted': 'ok', 'denied': 'warn'}.get(fda, 'warn'), text=app.t('ui_diag_fda_' + fda) if fda in ('granted', 'denied', 'unknown') else fda))
        mode = app.paths.get('mode', '?')
        previous = os.path.isdir(app.paths['program'].rstrip('/') + '.previous')
        rows.append(dict(id='install', status='ok', text=app.t('ui_diag_install', mode=app.t('ui_mode_install_' + mode) if mode in ('env', 'checkout', 'installed', 'default') else mode,
                                                           rollback=app.t('ui_yes' if previous else 'ui_no'))))
        return rows

    def bindings(self, app, zone):
        return [Binding(('up', 'down'), 'ui_key_move', 'vmove'), Binding(('enter',), 'ui_key_details', 'detail'),
                Binding(('F',), 'ui_diag_fda_open', 'fda'), Binding(('M',), 'ui_diag_migrate', 'migrate'),
                Binding(('u',), 'ui_diag_unreadable', 'unreadable'), Binding(('P',), 'ui_diag_protected', 'protected'),
                Binding(('r',), 'ui_btn_refresh', 'refresh')]

    def help(self, app, zone):
        return app.t('ui_help_diag')

    def action(self, app, zone, action):
        rows = self.checks(app)
        if action == 'up':
            if self.list.index == 0:
                app.focus_zone('tabs')
            self.list.move(-1, len(rows))
        elif action == 'down':
            self.list.move(1, len(rows))
        elif action == 'refresh':
            app.models.refresh('doctor')
        elif action == 'fda':
            try:
                app.opener(['/usr/bin/open', FDA_URL])
            except Exception as exc:
                app.notify(app.t('ui_error', message=plain(exc)), 'status_warn')
        elif action == 'migrate':
            self.migrate(app)
        elif action == 'unreadable':
            self.unreadable(app)
        elif action == 'protected':
            self.protected(app)
        elif action == 'detail' and rows:
            app.open_viewer(rows[min(self.list.index, len(rows) - 1)]['id'], wrap(rows[min(self.list.index, len(rows) - 1)]['text'], 70))
        else:
            return action in ('vmove', 'page')
        return True

    def migrate(self, app):
        """Run the migrate preview, then (after its own confirmation) the copy-only apply."""
        def after(a, model):
            if a.task_log is not None:
                a.open_viewer(a.t('ui_diag_migrate'), a.task_log.all_lines()[-500:])
            a.request_action('migrate_apply')
        app.request_action('migrate_preview', after=after)

    def unreadable(self, app):
        rows = app.models.history_rows()
        run_id = rows[0]['run_id'] if rows else (app.last_model and None)
        paths = tui_data.read_unreadable(app.state_dir, run_id) if run_id else []
        note = app.t('ui_diag_fda_hint')
        if not paths:
            app.open_viewer(app.t('ui_diag_unreadable'), wrap(app.t('ui_diag_unreadable_none') + '\n\n' + note, 70))
            return
        il = ItemList([dict(path=p, bytes=0, category='') for p in paths], title=app.t('ui_diag_unreadable'),
                      kind='unreadable', readonly_note=note)
        app.open_items(il)

    def protected(self, app):
        doctor = app.models.doctor()
        listed = doctor.get('protected_paths') if isinstance(doctor.get('protected_paths'), list) else []
        own = [app.paths[k] for k in ('program', 'config', 'state', 'quarantine')]
        lines = [app.t('ui_diag_protected_intro'), '']
        lines += ['  ' + p for p in own] + ['  ' + plain(p) for p in listed if isinstance(p, str)]
        if not listed:
            lines += ['', app.t('ui_diag_protected_more')]
        app.open_viewer(app.t('ui_diag_protected'), lines)

    def click(self, app, payload, double=False):
        if payload[0] == 'diag_row':
            app.focus_zone('checks')
            self.list.index = payload[1]
            return True
        return False

    def scroll(self, app, zone, delta):
        self.list.move(delta, len(self.checks(app)))
        return True

    def advice(self, app, row):
        """What to do about a check: its own advice when it is not ok, else 'nothing to do'."""
        if row['status'] in ('ok', 'info'):
            return app.t('ui_diag_advice_ok')
        key = 'ui_diag_advice_' + row['id']
        text = app.t(key)
        return text if text != key else app.t('ui_diag_advice_generic')

    def facts(self, app, width):
        """The right-hand pane: the full text and advice of the selected check, then facts as plain sentences.
        Sections without data are left out."""
        doctor = app.models.doctor()
        out = []
        rows = self.checks(app)
        if rows:
            self.list.clamp(len(rows))
            row = rows[self.list.index]
            glyph, style = check_mark(app.glyphs, row['status'])
            out.append((app.t('ui_diag_selected'), 'accent'))
            out.extend(((glyph + ' ' if i == 0 else '  ') + line, style) for i, line in enumerate(wrap(row['text'], max(10, width - 2))))
            out.append(('', 'base'))
            out.append((app.t('ui_diag_what_to_do'), 'accent'))
            out.extend(('  ' + line, 'base') for line in wrap(self.advice(app, row), max(10, width - 2)))

        def section(title, sentences):
            sentences = [t for t in sentences if t]
            if sentences:
                out.append(('', 'base'))
                out.append((title, 'accent'))
                for sentence in sentences:
                    out.extend(('  ' + line, 'base') for line in wrap(sentence, max(10, width - 2)))
        section(app.t('ui_diag_paths'), ['%s: %s' % (app.t('ui_path_' + key), app.paths[key])
                                         for key in ('program', 'config', 'state', 'quarantine')]
                + ['%s: %s' % (app.t('ui_path_mode'), app.t('ui_mode_install_' + app.paths.get('mode', '?'))
                               if app.paths.get('mode') in ('env', 'checkout', 'installed', 'default') else app.paths.get('mode', '?'))])
        runtime = doctor.get('runtime') if isinstance(doctor.get('runtime'), dict) else {}
        if runtime:
            py = runtime.get('python3')
            section(app.t('ui_diag_runtime'), [app.t('ui_diag_f_runtime', bash=plain(runtime.get('bash') or '?'),
                                                    python=plain(py) if py else app.t('ui_diag_f_none'),
                                                    macos=plain(runtime.get('macos') or '?'), arch=plain(runtime.get('arch') or '?'),
                                                    language=plain(runtime.get('lang') or '?'))])
        snaps = doctor.get('snapshots') if isinstance(doctor.get('snapshots'), dict) else {}
        if isinstance(snaps.get('count'), int):
            section(app.t('ui_diag_snapshots'), [app.t('ui_diag_f_snapshots', n=snaps['count']) if snaps['count']
                                                 else app.t('ui_diag_f_snapshots_none')])
        tm = doctor.get('time_machine') if isinstance(doctor.get('time_machine'), dict) else {}
        if tm.get('latest_backup'):
            section(app.t('ui_diag_tm'), [app.t('ui_diag_f_tm', when=plain(tm['latest_backup']),
                                                days=tm['age_days'] if isinstance(tm.get('age_days'), int) else '?')])
        lock = doctor.get('lock') if isinstance(doctor.get('lock'), dict) else {}
        if lock:
            held, stale = bool(lock.get('held')), bool(lock.get('stale'))
            section(app.t('ui_diag_lock'), [app.t('ui_diag_f_lock_held', pid=plain(lock.get('pid') or '?')) if held else
                                            app.t('ui_diag_f_lock_stale') if stale else app.t('ui_diag_f_lock_free')])
        sched = doctor.get('schedule') if isinstance(doctor.get('schedule'), dict) else {}
        if sched:
            on = bool(sched.get('installed'))
            section(app.t('ui_diag_schedule'), [app.t('ui_diag_f_schedule_on', when=plain(sched.get('time') or '?'))
                                                if on else app.t('ui_diag_f_schedule_off')])
        legacy = doctor.get('legacy') if isinstance(doctor.get('legacy'), dict) else {}
        num = lambda key: legacy.get(key) if isinstance(legacy.get(key), int) and not isinstance(legacy.get(key), bool) else 0   # noqa: E731
        if legacy.get('checkout') and (num('logs') or num('reports') or num('orphan_manifests')):
            section(app.t('ui_diag_legacy'), [app.t('ui_diag_f_legacy', path=plain(legacy['checkout']), logs=num('logs'),
                                                    reports=num('reports'), lists=num('orphan_manifests'), migrated=num('migrated'))])
        out.append(('', 'base'))
        out.append((app.t('ui_diag_keys'), 'accent'))
        out.extend(('  ' + l, 'base') for l in wrap(app.t('ui_diag_keys_text'), max(10, width - 2)))
        return out

    def render(self, app, c, main, side):
        g = app.glyphs
        rows = self.checks(app)
        c.box(main, app.t('ui_pane_diag'), self.pane_focus(app, 'checks'), right=str(len(rows)))
        inner = main.inner()
        self.list.clamp(len(rows))
        visible = inner.h
        self.list.offset = scroll_window(self.list.index, self.list.offset, visible, len(rows))
        for n, row in enumerate(rows[self.list.offset:self.list.offset + visible], self.list.offset):
            y = inner.y + n - self.list.offset
            selected = n == self.list.index
            style = ('sel_focus' if app.zone == 'checks' and app.dialog is None else 'sel') if selected else 'base'
            if selected:
                c.fill(y, inner.x, 1, inner.w, style)
                c.put(y, inner.x, g['marker'], style)
            glyph, gstyle = check_mark(g, row['status'])
            c.put(y, inner.x + 2, glyph, style if selected else gstyle)
            c.put(y, inner.x + 4, clip(row['text'], inner.w - 4, g['ellipsis']), style)
            c.region(y, inner.x, 1, inner.w, ('diag_row', n))
        if side is not None:
            c.box(side, app.t('ui_pane_details'), self.pane_focus(app, 'facts'))
            si = side.inner()
            lines = self.facts(app, si.w)
            self.facts_scroll = min(getattr(self, 'facts_scroll', 0), max(0, len(lines) - si.h))
            for i, (text, style) in enumerate(lines[self.facts_scroll:self.facts_scroll + si.h]):
                c.put(si.y + i, si.x, clip(text, si.w, g['ellipsis']), style)


# ---------------------------------------------------------------------------
class About(Screen):
    id, tab = 'help', 'ui_tab_help'

    def __init__(self):
        self.scroll_pos = 0

    def zones(self, app):
        return ['main']

    def lines(self, app, width):
        t = app.t
        out = []

        def section(title, body, style='base'):
            out.append((t(title), 'accent'))
            for line in wrap(body, max(10, width)):
                out.append((line, style))
            out.append(('', 'base'))
        state = app.update_state
        status = {'checking': t('ui_update_checking'), 'failed': t('ui_update_failed'), 'dev': t('ui_update_dev'),
                  'current': t('ui_update_current', version=state.get('current', '')),
                  'available': t('ui_update_available', current=state.get('current', ''), latest=state.get('latest', ''))
                  }.get(state.get('status'), t('ui_update_not_checked'))
        out.extend((l, 'strong') for l in wrap(t('ui_help_version', version=app.version, mode=app.paths.get('mode', '?')), max(10, width)))
        out.extend((l, 'warn' if state.get('status') == 'failed' else 'base') for l in wrap(status, max(10, width)))
        out.append(('', 'base'))
        section('ui_help_sec_keys', t('ui_help_keys_text'))
        section('ui_help_sec_tiers', t('ui_help_tiers_text'))
        section('ui_help_sec_safety', t('ui_help_safety_text'))
        out.append((t('ui_help_sec_paths'), 'accent'))
        for key in ('program', 'config', 'state', 'quarantine'):
            out.append(('  %s: %s' % (t('ui_path_' + key), app.paths[key]), 'base'))
        out.append(('', 'base'))
        section('ui_help_sec_licence', t('ui_help_licence_text'))
        return out

    def bindings(self, app, zone):
        return [Binding(('up', 'down'), 'ui_key_scroll', 'vmove'), Binding(('U',), 'ui_btn_check_updates', 'update'),
                Binding(('pgup', 'pgdn'), 'ui_key_scroll', 'page', show=False)]

    def help(self, app, zone):
        return app.t('ui_help_about')

    def action(self, app, zone, action):
        if action == 'update':
            app.check_updates(origin='help')
            return True
        step = {'up': -1, 'down': 1, 'pgup': -10, 'pgdn': 10, 'home': -10 ** 6, 'end': 10 ** 6}.get(action)
        if step is not None:
            self.scroll_pos = max(0, self.scroll_pos + step)
            return True
        return action in ('vmove', 'page')

    def scroll(self, app, zone, delta):
        self.scroll_pos = max(0, self.scroll_pos + delta)
        return True

    def render(self, app, c, main, side):
        c.box(main, app.t('ui_pane_about'), self.pane_focus(app, 'main'))
        inner = main.inner()
        lines = self.lines(app, min(inner.w - 1, 110))      # long lines are hard to read: keep a comfortable measure
        self.scroll_pos = min(self.scroll_pos, max(0, len(lines) - inner.h))
        for i, (text, style) in enumerate(lines[self.scroll_pos:self.scroll_pos + inner.h]):
            c.put(inner.y + i, inner.x, clip(text, inner.w, app.glyphs['ellipsis']), style)
        if len(lines) > inner.h:
            render_scrollbar(c, inner.y, inner.x + inner.w - 1, inner.h, self.scroll_pos, len(lines))
        if side is not None:
            c.box(side, app.t('ui_pane_details'))
