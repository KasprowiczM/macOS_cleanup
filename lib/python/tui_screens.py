"""The seven screens. Each screen declares its focus zones, the keymap for
each zone, the help text for the focused element, and draws itself into the
rectangles the app hands it. Screens never start processes directly; they ask
the app (``app.request_action``), which confirms every mutating action first.

This module holds the shared helpers, the Dashboard and the Categories screen;
Quarantine, History, Diagnostics and Help are in tui_screens_data, Settings in
tui_screens_settings.
"""
import os
import re
import time

import tui_data
import tui_plan
import tui_registry
import tui_runfacts
from mc_events import ACTION_PHASES, REASONS
from tui_dialogs import ConfirmDialog
from tui_itemlist import ItemList
from tui_keymap import Binding
from tui_runner import fmt_bytes, item_fraction
from tui_widgets import Rect, clip, duration, pad, plain, scroll_window, text_width, wrap, wrap_items

SCREENS = ('dashboard', 'categories', 'quarantine', 'history', 'settings', 'diagnostics', 'help')
TIER_STYLE = dict(regenerable='ok', review='warn', report='muted')


class ListState:
    def __init__(self):
        self.index = 0
        self.offset = 0

    def move(self, delta, total):
        if total:
            self.index = max(0, min(total - 1, self.index + delta))

    def clamp(self, total):
        self.index = max(0, min(self.index, max(0, total - 1)))


def status_glyph(app, state, result=None, tick=0):
    g = app.glyphs
    if state == 'running':
        return g['spinner'][tick % len(g['spinner'])] if app.animate else g['running'], 'accent'
    if state in ('off', 'skipped'):
        return g['off'], 'muted'
    if state == 'pending':
        return g['pending'], 'muted'
    return {'ok': (g['ok'], 'ok'), 'warn': (g['needs'], 'warn'), 'failed': (g['fail'], 'fail'),
            'error': (g['fail'], 'fail'), 'off': (g['off'], 'muted'), 'skipped': (g['off'], 'muted')
            }.get(result, (g['ok'], 'ok'))


def item_glyph(app, result):
    g = app.glyphs
    return {'cleaned': (g['ok'], 'ok'), 'quarantined': (g['ok'], 'ok'), 'restored': (g['ok'], 'ok'),
            'skipped': (g['needs'], 'warn'), 'failed': (g['fail'], 'fail'), 'unavailable': (g['off'], 'muted'),
            'report_only': (g['current'], 'muted'), 'dry_run': (g['pending'], 'accent')
            }.get(result, (g['running'], 'accent'))


def draw_wrapped(c, rect, text, style='base', offset=0):
    lines = wrap(text, rect.w)
    for i, line in enumerate(lines[offset:offset + rect.h]):
        c.put(rect.y + i, rect.x, line, style, rect.w)
    return len(lines)


def render_scrollbar(c, y, x, height, offset, total):
    thumb = max(1, height * height // max(1, total))
    start = (height - thumb) * offset // max(1, total - height)
    for i in range(height):
        on = start <= i < start + thumb
        c.put(y + i, x, c.g['bar_full'] if on else c.g['v'], 'accent' if on else 'border')


def size_text(value, unit='bytes', unknown='-'):
    if value is None:
        return unknown
    return fmt_bytes(value, unit)


def draw_search_row(app, c, inner, y, query, hint, region):
    """The search line of a screen. While it has the focus the whole row is highlighted and says that keys
    (digits included) now type into it, so it cannot be mistaken for a list that ignores the keyboard."""
    g = app.glyphs
    searching = app.zone == 'search' and app.dialog is None
    label = app.t('ui_search_label')
    field = query + (('\u258f' if g['tl'] != '+' else '_') if searching else '')
    if searching:
        c.fill(y, inner.x, 1, inner.w, 'sel_focus')
    c.put(y, inner.x, label, 'sel_focus' if searching else 'muted')
    shown = clip(field or hint, inner.w - text_width(label), g['ellipsis'])
    c.put(y, inner.x + text_width(label), shown, 'sel_focus' if searching else ('base' if field else 'muted'))
    if searching:
        note = app.t('ui_search_active')
        x = inner.x + inner.w - text_width(note) - 1
        if x > inner.x + text_width(label) + text_width(shown) + 2:
            c.put(y, x, note, 'sel_focus')
    c.region(y, inner.x, 1, inner.w, region)


def restore_text(app, info):
    """What a restore did, as one or two lines: 'Restored 7 items, 175 MiB' and, when rows were left in the
    quarantine, 'Skipped 2: <why>'. Estimated, measured and quarantined sizes mean nothing for a restore."""
    out = [app.t('ui_restore_did', count=info['items'], size=fmt_bytes(info['bytes']))]
    if info['skipped']:
        why = ' '.join(app.t('reason_' + r) if r in REASONS else r for r in sorted(info['reasons'], key=lambda r: -info['reasons'][r])[:2])
        out.append(app.t('ui_restore_left', count=info['skipped'], reasons=why) if why
                   else app.t('ui_restore_left_plain', count=info['skipped']))
    return out


_Q_UNMEASURED = re.compile(r'(\S+) run\(s\); the size could not be measured in time')


def check_text(app, check):
    """Text of one engine health check for the screen. The engine writes its check texts in English; the ones
    that were not understandable as they stand are said plainly here (and in the user's language)."""
    text = plain(check.get('text', ''))
    if str(check.get('id')) == 'quarantine':
        match = _Q_UNMEASURED.fullmatch(text)
        if match:
            return app.t('ui_diag_q_unmeasured', n=match.group(1))
    return text


def size_label(app, value, unit='bytes', ident=''):
    """Size text for a category row: bytes as a size, counts as a number with their noun, '-' when unknown."""
    if value is None:
        return '-'
    if unit == 'count':
        return app.t('ui_unit_count', n=int(value))
    return fmt_bytes(value, unit)


class Screen:
    id = ''
    tab = ''

    def zones(self, app):
        return ['main']

    def bindings(self, app, zone):
        return []

    def help(self, app, zone):
        return ''

    def render(self, app, c, main, side):
        pass

    def action(self, app, zone, action):
        return False

    def text(self, app, zone, text):
        return False

    def click(self, app, payload, double=False):
        return False

    def scroll(self, app, zone, delta):
        return False

    def on_enter(self, app):
        pass

    def models_changed(self, app, name):
        pass

    def result_mode(self, app):
        return False

    def pane_focus(self, app, *zones):
        return app.zone in zones and app.dialog is None


# ---------------------------------------------------------------------------
class Dashboard(Screen):
    id, tab = 'dashboard', 'ui_tab_dashboard'
    BUTTON_ACTIONS = ('scan', 'preview', 'clean_safe', 'clean_selected')

    def __init__(self):
        self.button = None
        self.sel, self.offset, self.follow = 0, 0, True
        self.expanded, self.collapsed = set(), set()
        self.result_scroll = 0
        self.status_scroll = 0

    # -- state ------------------------------------------------------------------
    def reset_run(self, app):
        self.follow, self.sel, self.offset = True, 0, 0
        self.expanded, self.collapsed = set(), set()
        self.button = 0

    def result_mode(self, app):
        return app.show_result and app.last_model is not None and not app.run_active()

    def zones(self, app):
        if self.result_mode(app):
            return ['actions', 'result']
        return ['actions', 'steps', 'log' if app.run_active() else 'status']

    def buttons(self, app):
        if self.result_mode(app):
            return [('ui_btn_done', 'done'), ('ui_btn_log', 'log'), ('ui_btn_again', 'again')]
        if app.run_active():
            out = [('ui_btn_answer', 'answer')] if app.prompt_hidden else []
            return out + [('ui_btn_stop', 'stop'), ('ui_btn_log', 'log')]
        return [('ui_btn_scan', 'scan'), ('ui_btn_preview', 'preview'), ('ui_btn_clean_safe', 'clean_safe'),
                ('ui_btn_clean_selected', 'clean_selected')]

    def current_button(self, app):
        buttons = self.buttons(app)
        if self.button is None:
            default = app.settings.get('default_action')
            names = [b[1] for b in buttons]
            self.button = names.index(default) if default in names else 0
        self.button = max(0, min(self.button, len(buttons) - 1))
        return self.button

    def hot(self):
        return [Binding(('s', 'S'), 'ui_btn_scan', 'hot_scan', show=False), Binding(('p', 'P'), 'ui_btn_preview', 'hot_preview', show=False),
                Binding(('c', 'C'), 'ui_btn_clean_safe', 'hot_clean_safe', show=False),
                Binding(('x', 'X'), 'ui_btn_clean_selected', 'hot_clean_selected', show=False)]

    def bindings(self, app, zone):
        idle = not app.run_active() and not self.result_mode(app)
        if zone == 'actions':
            out = [Binding(('enter',), 'ui_key_select', 'press'), Binding(('left', 'right'), 'ui_key_other_button', 'hmove'),
                   Binding(('down',), 'ui_key_move', 'down', show=False), Binding(('up',), 'ui_key_move', 'up', show=False)]
            return out + (self.hot() if idle else [])
        if zone == 'steps':
            out = [Binding(('up', 'down'), 'ui_key_move', 'vmove'), Binding(('enter',), 'ui_key_expand', 'enter'),
                   Binding(('pgup', 'pgdn'), 'ui_key_scroll', 'page', show=False),
                   Binding(('home', 'end'), 'ui_key_scroll', 'ends', show=False)]
            return out + (self.hot() if idle else [])
        if zone == 'log':
            return [Binding(('up', 'down'), 'ui_key_scroll', 'vmove'), Binding(('enter',), 'ui_key_expand', 'expand'),
                    Binding(('pgup', 'pgdn'), 'ui_key_scroll', 'page', show=False),
                    Binding(('home', 'end'), 'ui_key_scroll', 'ends', show=False)]
        if zone == 'result':
            return [Binding(('up', 'down'), 'ui_key_scroll', 'vmove'), Binding(('pgup', 'pgdn'), 'ui_key_scroll', 'page', show=False)]
        if zone == 'status':
            return [Binding(('up', 'down'), 'ui_key_scroll', 'vmove')]
        return []

    def help(self, app, zone):
        if zone == 'actions':
            if self.result_mode(app):
                return app.t('ui_help_dash_result')
            return app.t('ui_help_dash_actions_run' if app.run_active() else 'ui_help_dash_actions')
        if zone == 'steps':
            row = self.selected_row(app)
            model = app.run
            if row and row[0] == 'phase':
                return app.t('ui_phase_' + row[1]) + ': ' + app.t('ui_phase_%s_help' % row[1]) + '\n\n' + app.t('ui_help_dash_steps')
            if row and row[0] == 'cat' and model is not None:
                group = model.cats[row[1]].get(row[2])
                if group is not None:
                    return app.category_label(group.id) + ': ' + app.t(tui_registry.explain_key(group.id)) + '\n\n' + app.t('ui_help_dash_steps')
            if row and row[0] == 'item' and model is not None:
                item = model.cats[row[1]][row[2]].items.get(row[3])
                if item is not None and item.result in ('skipped', 'failed'):
                    why, todo = app.explain(item)
                    return '\n'.join([item.name, item.path, why, app.t('ui_suggest', action=todo)])
            return app.t('ui_help_dash_steps')
        if zone == 'log':
            return app.t('ui_help_log')
        if zone == 'result':
            return app.t('ui_help_dash_result')
        if zone == 'status':
            return app.t('ui_help_status')
        return ''

    # -- actions ----------------------------------------------------------------
    def action(self, app, zone, action):
        if action.startswith('hot_'):
            self.start(app, action[4:])
            return True
        buttons = self.buttons(app)
        if zone == 'actions':
            index = self.current_button(app)
            if action == 'hmove':
                return True
            if action == 'left':
                self.button = max(0, index - 1)
            elif action == 'right':
                self.button = min(len(buttons) - 1, index + 1)
            elif action == 'down':
                app.focus_zone(self.zones(app)[1])
            elif action == 'up':
                app.focus_zone('tabs')
            elif action == 'press' and buttons:
                self.press(app, buttons[index][1])
            return True
        if zone == 'steps':
            return self.steps_action(app, action)
        if zone == 'status':
            if action in ('up', 'down'):
                self.status_scroll = max(0, self.status_scroll + (1 if action == 'down' else -1))
                return True
            return action == 'vmove'
        if zone in ('log', 'result'):
            step = {'up': 1, 'down': -1, 'pgup': 10, 'pgdn': -10, 'home': 10 ** 6, 'end': -10 ** 6}.get(action)
            if step is not None:
                if zone == 'log':
                    app.log_scroll = max(0, app.log_scroll + step)
                else:
                    self.result_scroll = max(0, self.result_scroll - step)
                return True
            if action == 'expand':
                app.log_expand_all = not app.log_expand_all
                return True
            return action in ('vmove', 'page', 'ends')
        return False

    def start(self, app, what):
        if app.run_active() or self.result_mode(app):
            return
        if what == 'scan':
            app.request_action('scan')
        elif what == 'preview':
            app.request_action('preview')
        elif what == 'clean_safe':
            app.request_action('clean_safe')
        elif what == 'clean_selected':
            app.screens[SCREENS.index('categories')].clean_selected(app)

    def press(self, app, what):
        if what in self.BUTTON_ACTIONS:
            self.start(app, what)
        elif what == 'stop':
            app.ask_stop()
        elif what == 'log':
            app.toggle_full_log()
        elif what == 'answer':
            app.reopen_prompt()
        elif what == 'done':
            app.show_result = False
            self.button = None
            app.focus_zone('actions')
        elif what == 'again':
            app.show_result = False
            action = app.last_model.action if app.last_model and app.last_model.action in ('scan', 'preview') else 'preview'
            self.button = None
            app.request_action(action)

    def click(self, app, payload, double=False):
        kind = payload[0]
        if kind == 'dash_button':
            app.focus_zone('actions')
            self.button = payload[1]
            buttons = self.buttons(app)
            if self.button < len(buttons):
                self.press(app, buttons[self.button][1])
            return True
        if kind == 'dash_row':
            app.focus_zone('steps')
            self.sel, self.follow = payload[1], False
            if double:
                self.steps_action(app, 'enter')
            return True
        return False

    def scroll(self, app, zone, delta):
        if zone == 'log':
            app.log_scroll = max(0, app.log_scroll - delta)
        elif zone == 'result':
            self.result_scroll = max(0, self.result_scroll + delta)
        elif zone == 'status':
            self.status_scroll = max(0, self.status_scroll + delta)
        else:
            self.follow = False
            self.sel = max(0, min(len(self.list_rows(app)) - 1, self.sel + delta))
        return True

    # -- step list model ------------------------------------------------------------
    def view_model(self, app):
        return app.run

    def phases(self, app):
        model = self.view_model(app)
        if model is not None and model.phase_ids:
            return model.phase_ids
        return list(ACTION_PHASES['clean_safe'])

    def is_open(self, app, key, default):
        if key in self.collapsed:
            return False
        if key in self.expanded:
            return True
        return default

    def list_rows(self, app):
        model = self.view_model(app)
        rows = []
        active = model.active_phase() if model else None
        for pid in self.phases(app):
            rows.append(('phase', pid))
            if model is None or pid not in ('scan', 'clean'):
                continue
            if not self.is_open(app, ('phase', pid), pid == active):
                continue
            for section, groups in model.sections(pid):
                rows.append(('section', pid, section))
                if not self.is_open(app, ('section', pid, section), True):
                    continue
                for group in groups:
                    rows.append(('cat', pid, group.id))
                    show_items = group.items and self.is_open(
                        app, ('cat', pid, group.id), group.state == 'running' or any(
                            i.result in ('skipped', 'failed') for i in group.items.values()))
                    if show_items:
                        rows.extend(('item', pid, group.id, ident) for ident in group.order)
        return rows

    def selected_row(self, app):
        rows = self.list_rows(app)
        if not rows:
            return None
        self.sel = max(0, min(self.sel, len(rows) - 1))
        return rows[self.sel]

    def follow_target(self, app, rows):
        model = app.run
        if model is None:
            return None
        if model.active is not None:
            gid, phase = model.active
            last = None
            for index, row in enumerate(rows):
                if row[0] in ('cat', 'item') and row[1] == phase and row[2] == gid:
                    last = index
                    if row[0] == 'item' and not model.cats[phase][gid].items[row[3]].result:
                        return index
            if last is not None:
                return last
        active = model.active_phase()
        for index, row in enumerate(rows):
            if row == ('phase', active):
                return index
        return None

    def steps_action(self, app, action):
        rows = self.list_rows(app)
        step = {'up': -1, 'down': 1, 'pgup': -10, 'pgdn': 10}.get(action)
        if step is not None:
            if action == 'up' and self.sel == 0:
                app.focus_zone('actions')
                return True
            self.follow = False
            self.sel = max(0, min(len(rows) - 1, self.sel + step))
            return True
        if action in ('home', 'end'):
            self.sel = 0 if action == 'home' else len(rows) - 1
            self.follow = action == 'end' and app.run_active()
            return True
        row = self.selected_row(app)
        if action == 'enter' and row and row[0] in ('phase', 'section', 'cat'):
            key = row if row[0] != 'cat' else row
            key = tuple(row)
            model = self.view_model(app)
            if row[0] == 'phase':
                default = model is not None and row[1] == model.active_phase()
            elif row[0] == 'cat':
                group = model.cats[row[1]].get(row[2]) if model else None
                default = bool(group and group.state == 'running')
            else:
                default = True
            if self.is_open(app, key, default):
                self.expanded.discard(key)
                self.collapsed.add(key)
            else:
                self.collapsed.discard(key)
                self.expanded.add(key)
            return True
        return action in ('vmove', 'page', 'ends', 'enter')

    # -- drawing ---------------------------------------------------------------------
    def render(self, app, c, main, side):
        if self.result_mode(app):
            area = main if side is None else (Rect(main.y, main.x, main.h, side.x + side.w - main.x)
                                              if side.y == main.y else Rect(main.y, main.x, side.y + side.h - main.y, main.w))
            self.render_result(app, c, area)
            return
        focused = self.pane_focus(app, 'actions', 'steps')
        model = app.run
        right = app.t('ui_preview_badge') if (model and model.dry_run) or app.read_only else ''
        c.box(main, app.t('ui_pane_steps'), focused, right=right)
        inner = main.inner()
        y = inner.y
        x = inner.x
        current = self.current_button(app)
        for index, (label, what) in enumerate(self.buttons(app)):
            label = app.t(label)
            if x + text_width(label) + 4 > inner.x + inner.w:
                break
            # Read-only mode refuses the cleaning buttons; they are drawn as unavailable.
            x = c.button(y, x, label, focused=(app.zone == 'actions' and index == current and app.dialog is None),
                         primary=index == 0, action=('dash_button', index),
                         disabled=bool(app.read_only and what in ('clean_safe', 'clean_selected'))) + 2
        tight = inner.h < 15
        y += 1 if tight else 2
        if model is not None:
            label = app.t('ui_overall')
            pct = int(round(model.overall() * 100))
            tail = ' %3d%%  %s' % (pct, duration(time.monotonic() - model.started))
            bar_w = max(6, inner.w - text_width(label) - text_width(tail) - 2)
            c.put(y, inner.x, label, 'strong')
            c.bar(y, inner.x + text_width(label) + 1, bar_w, model.overall())
            c.put(y, inner.x + text_width(label) + 2 + bar_w, tail.strip(), 'base')
            y += 1 if tight else 2
        else:
            y = self.render_card(app, c, Rect(y, inner.x, inner.y + inner.h - y, inner.w), tight)
        bottom = inner.y + inner.h
        y = self.render_steps(app, c, Rect(y, inner.x, bottom - y, inner.w), main, model)
        if model is None and side is None and y + 2 < bottom:
            for i, line in enumerate(self.disk_lines(app, inner.w)[:bottom - y - 1]):
                c.put(y + 1 + i, inner.x, line[0], line[1])
        if side is not None:
            if app.run_active():
                self.render_log(app, c, side)
            else:
                self.render_status(app, c, side)

    def render_card(self, app, c, rect, tight):
        """The summary card of the last run: estimated / measured / quarantined."""
        rows = app.models.history_rows()
        used = 0
        if not rows:
            c.put(rect.y, rect.x, clip(app.t('ui_card_none'), rect.w, app.glyphs['ellipsis']), 'base')
            return rect.y + (1 if tight else 2)
        last = rows[0]
        when = (last.get('started_at') or '')[:16].replace('T', ' ')
        facts = app.run_facts(last)
        kind = app.t('ui_type_' + facts.type)
        c.put(rect.y, rect.x, clip('%s  %s  %s' % (app.t('ui_last_run_title'), when, kind), rect.w, app.glyphs['ellipsis']), 'strong')
        parts = [(app.t('ui_card_estimated'), size_text(facts.estimated))]
        if facts.type in ('clean', 'apply', 'unattended'):       # a scan or preview frees and moves nothing
            parts += [(app.t('ui_card_measured'), size_text(facts.measured, unknown=app.t('ui_not_measured'))),
                      (app.t('ui_card_quarantined'), size_text(facts.quarantined_bytes))]
        line = '  '.join('%s %s' % (k, v) for k, v in parts)
        if facts.type == 'restore' and facts.restore is not None:
            line = '  '.join(restore_text(app, facts.restore))
        lines = wrap_items(line, max(10, rect.w))[:1 if tight else 2]       # wrapped, never cut off
        for i, text in enumerate(lines):
            if rect.h > 1 + i:
                c.put(rect.y + 1 + i, rect.x, clip(text, rect.w, app.glyphs['ellipsis']), 'base')
        return rect.y + (2 if tight else 3) + (1 if len(lines) > 1 else 0)

    def render_steps(self, app, c, rect, box, model):
        g = app.glyphs
        rows = self.list_rows(app)
        visible = max(1, rect.h)
        scrolling = len(rows) > visible
        width = rect.w - (2 if scrolling else 0)
        if self.follow and app.run_active():
            target = self.follow_target(app, rows)
            if target is not None:
                self.offset = max(0, min(target - visible * 2 // 3, len(rows) - visible))
                if app.zone != 'steps':
                    self.sel = target
        else:
            self.offset = scroll_window(self.sel, self.offset, visible, len(rows))
        self.offset = max(0, min(self.offset, max(0, len(rows) - visible)))
        name_w = min(max(text_width(app.t('ui_phase_' + p)) for p in self.phases(app)) + 2, max(8, width // 3))
        for line, row in enumerate(rows[self.offset:self.offset + visible]):
            index = self.offset + line
            y = rect.y + line
            selected = app.zone == 'steps' and index == self.sel and app.dialog is None
            c.region(y, rect.x, 1, width, ('dash_row', index))
            c.put(y, rect.x, (g['marker'] + ' ') if selected else '  ', 'focus_title')
            kind = row[0]
            if kind == 'phase':
                self.render_phase_row(app, c, y, rect.x + 2, width - 2, row[1], model, name_w)
            elif kind == 'section':
                self.render_section_row(app, c, y, rect.x + 4, width - 4, row, model)
            elif kind == 'cat':
                self.render_cat_row(app, c, y, rect.x + 6, width - 6, model.cats[row[1]][row[2]])
            else:
                self.render_item_row(app, c, y, rect.x + 8, width - 8, model.cats[row[1]][row[2]].items[row[3]])
        if scrolling:
            render_scrollbar(c, rect.y, rect.x + rect.w - 1, visible, self.offset, len(rows))
            label = ' %s ' % app.t('ui_range', first=self.offset + 1, last=min(len(rows), self.offset + visible), total=len(rows))
            c.put(box.y + box.h - 1, box.x + box.w - 2 - text_width(label), label, 'muted')
        return rect.y + min(visible, len(rows) - self.offset)

    def render_phase_row(self, app, c, y, x, width, pid, model, name_w):
        g = app.glyphs
        phase = model.phases.get(pid) if model else None
        state = phase.state if phase else 'pending'
        result = phase.result if phase else None
        glyph, style = status_glyph(app, 'skipped' if state == 'skipped' else state, {'ok': 'ok', 'warn': 'warn', 'error': 'failed',
                                                                                          'skipped': 'off'}.get(result), app.tick_count)
        opened = model is not None and pid in ('scan', 'clean') and self.is_open(app, ('phase', pid), pid == model.active_phase())
        marker = (g['expand'] if opened else g['collapse']) if model is not None and pid in ('scan', 'clean') else ' '
        c.put(y, x, marker, 'muted')
        c.put(y, x + 2, glyph, style)
        c.put(y, x + 4, clip(app.t('ui_phase_' + pid), name_w, g['ellipsis']), 'strong' if state in ('running', 'done') else 'muted')
        cx = x + 5 + name_w
        remaining = width - 5 - name_w
        elapsed = duration(phase.elapsed()) if phase and phase.started is not None else ''
        el_w = 6 if elapsed and remaining >= 16 else 0
        bar_w = max(0, min(20, remaining - el_w - 1 - 8))
        fraction = model.phase_fraction(pid) if model else 0.0
        info = ''
        if state == 'skipped':
            info = app.t('ui_state_skipped')
        elif state == 'pending' or state == 'off':
            info = app.t('ui_state_pending' if state == 'pending' else 'ui_state_off')
        elif state == 'running' and fraction is not None:
            info = '%d%%' % int(round(fraction * 100))
        elif state == 'running':
            info = app.t('ui_state_working')
        elif result == 'warn':
            info = app.t('ui_state_warn')
        elif result == 'error':
            info = app.t('ui_state_failed')
        if bar_w >= 4:
            if state in ('pending', 'off', 'skipped'):
                c.put(y, cx, g['bar_empty'] * bar_w, 'bar_empty')
            else:
                c.bar(y, cx, bar_w, fraction if state == 'running' else 1.0, indeterminate=app.tick_count)
            cx += bar_w + 1
        c.put(y, cx, clip(info, max(0, x + width - cx - el_w), g['ellipsis']), style if state != 'pending' else 'muted')
        if el_w:
            c.put(y, x + width - 5, pad(elapsed, 5, 'right'), 'muted')

    def render_section_row(self, app, c, y, x, width, row, model):
        g = app.glyphs
        groups = dict(model.sections(row[1])).get(row[2], [])
        opened = self.is_open(app, tuple(row), True)
        total = sum((gr.estimated or 0) for gr in groups if gr.unit == 'bytes')
        text = '%s %s (%d)' % (g['expand'] if opened else g['collapse'], app.section_label(row[2]), len(groups))
        c.put(y, x, clip(text, width - 10, g['ellipsis']), 'accent')
        if total:
            size = fmt_bytes(total)
            c.put(y, x + width - text_width(size), size, 'muted')

    def render_cat_row(self, app, c, y, x, width, group):
        g = app.glyphs
        glyph, gstyle = status_glyph(app, group.state, group.result, app.tick_count)
        c.put(y, x, glyph, gstyle)
        size = size_text(group.estimated if group.estimated is not None else (group.bytes_total() or None), group.unit,
                         unknown=g['ellipsis'])
        tier = app.t('ui_tier_short_' + group.tier)
        right = '%s  %s' % (tier, pad(size, 8, 'right'))
        label_w = max(6, width - 2 - text_width(right) - 1)
        c.put(y, x + 2, clip(app.category_label(group.id), label_w, g['ellipsis']), 'base' if group.state != 'pending' else 'muted')
        c.put(y, x + width - text_width(right), tier, TIER_STYLE.get(group.tier, 'muted'))
        c.put(y, x + width - 8, pad(size, 8, 'right'), 'base')

    def render_item_row(self, app, c, y, x, width, item):
        g = app.glyphs
        glyph, style = item_glyph(app, item.result)
        c.put(y, x, glyph, style)
        label = item.name
        tail = ''
        if item.result in ('skipped', 'failed'):
            tail = app.t('reason_' + (item.reason or 'unknown'))
        elif not item.result:
            tail = app.t('ui_item_phase_' + item.phase)
            if item.percent is not None:
                tail += ' %d%%' % int(item.percent)
        else:
            tail = app.t('ui_res_' + item.result)
        size = fmt_bytes(item.estimated) if item.estimated else ''
        tail_w = min(text_width(tail), max(0, width // 2))
        c.put(y, x + 2, clip(label, max(4, width - 2 - tail_w - 10), g['ellipsis']), 'base' if item.result else 'strong')
        c.put(y, x + width - tail_w, clip(tail, tail_w, g['ellipsis']), style if item.result else 'accent')
        if size and width - 2 - tail_w - 10 > 14:
            c.put(y, x + width - tail_w - 9, pad(size, 8, 'right'), 'muted')

    def disk_lines(self, app, width):
        """The disk overview: free/used, purgeable, snapshots, quarantine, largest folders."""
        g = app.glyphs
        doctor = app.models.doctor()
        disk = doctor.get('disk') if isinstance(doctor.get('disk'), dict) else {}
        facts = app.facts()
        free = disk.get('container_free_bytes', facts.get('disk_free'))
        total = disk.get('container_total_bytes', facts.get('disk_total'))
        out = [(app.t('ui_disk_title'), 'accent')]
        if free is None:
            out.append((app.t('ui_disk_unknown'), 'base'))
        else:
            used = (total - free) if isinstance(total, int) else None
            text = app.t('ui_disk_free', free=fmt_bytes(free)) + ((' %s ' % g['sep']) + app.t('ui_disk_used', used=fmt_bytes(used))
                                                                    if used is not None else '')
            out.append((text, 'base'))
        purgeable = disk.get('purgeable_bytes')
        snaps = (doctor.get('snapshots') or {}).get('count') if isinstance(doctor.get('snapshots'), dict) else None
        extra = []
        if purgeable is not None:
            extra.append(app.t('ui_disk_purgeable', size=fmt_bytes(purgeable)))
        if snaps is not None:
            extra.append(app.t('ui_disk_snapshots', count=snaps))
        qtot = app.models.quarantine_totals()
        if qtot.get('bytes') is not None:
            extra.append(app.t('ui_disk_quarantine', size=fmt_bytes(qtot['bytes'])))
        if extra:
            out.extend((l, 'base') for l in wrap_items('  '.join(extra), width))
        top = disk.get('home_top') if isinstance(disk.get('home_top'), list) else []
        if top:
            when = str(disk.get('scanned_at') or '')[:10]
            out.append((app.t('ui_disk_top', date=when), 'base'))
            for entry in top[:5]:
                if isinstance(entry, dict):
                    out.append(('  %s  %s' % (pad(fmt_bytes(entry.get('bytes')), 8, 'right'), entry.get('path', '')), 'base'))
        return out

    def render_log(self, app, c, rect):
        focused = self.pane_focus(app, 'log')
        lines = app.log_display_lines(rect.w - 4)
        model = app.current_model()
        right = duration(time.monotonic() - model.started) if app.run_active() and model else ''
        c.box(rect, app.t('ui_pane_log'), focused, right=right)
        inner = rect.inner()
        if not lines:
            draw_wrapped(c, inner, app.t('ui_log_empty'), 'muted')
            return
        app.log_scroll = min(app.log_scroll, max(0, len(lines) - inner.h))
        end = len(lines) - app.log_scroll
        for i, (text, style) in enumerate(lines[max(0, end - inner.h):end]):
            c.put(inner.y + i, inner.x, clip(text, inner.w, app.glyphs['ellipsis']), style)

    def status_lines(self, app, width):
        g = app.glyphs
        out = []
        rows = app.models.history_rows()
        out.append((app.t('ui_last_run_title'), 'accent'))
        if rows:
            last = rows[0]
            glyph, style = status_glyph(app, 'done', {'ok': 'ok', 'warn': 'warn', 'error': 'failed', 'cancelled': 'warn'}.get(last.get('result'), 'ok'))
            word = app.t('ui_res_run_' + str(last.get('result') if last.get('result') in ('ok', 'warn', 'error', 'cancelled') else 'unknown'))
            when = (last.get('started_at') or '')[:16].replace('T', ' ')
            out.append((clip('%s %s %s %s' % (glyph, word, g['sep'], when), width, g['ellipsis']), style))
            out.append((clip(app.t('ui_type_' + app.run_facts(last).type) + ' ' + g['sep'] + ' ' + duration(last.get('seconds')), width, g['ellipsis']), 'base'))
        else:
            out.extend((l, 'base') for l in wrap(app.t('ui_status_none'), width))
        out.append(('', 'base'))
        out.extend(self.disk_lines(app, width))
        warns = [w for w in (app.models.doctor().get('checks') or []) if isinstance(w, dict) and w.get('status') in ('warn', 'fail')]
        if warns:
            out.append(('', 'base'))
            out.append((app.t('ui_status_attention'), 'accent'))
            for w in warns[:4]:
                out.extend(((g['needs'] + ' ' if i == 0 else '  ') + l, 'warn') for i, l in enumerate(wrap(check_text(app, w), width - 2)))
        out.append(('', 'base'))
        out.append((app.t('ui_sec_schedule'), 'accent'))
        status = app.schedule()
        if status.get('state') == 'on':
            import tui_settings as ts
            nxt = ts.next_run(status)
            out.append((app.t('ui_status_next', when=time.strftime('%a %H:%M', time.localtime(nxt)) if nxt else '?'), 'ok'))
        else:
            out.append((app.t('ui_schedule_off'), 'base'))
        return out

    def render_status(self, app, c, rect):
        c.box(rect, app.t('ui_pane_status'), self.pane_focus(app, 'status'))
        inner = rect.inner()
        lines = self.status_lines(app, inner.w)
        self.status_scroll = min(self.status_scroll, max(0, len(lines) - inner.h))
        for i, (text, style) in enumerate(lines[self.status_scroll:self.status_scroll + inner.h]):
            c.put(inner.y + i, inner.x, clip(text, inner.w, app.glyphs['ellipsis']), style)

    # -- result ------------------------------------------------------------------------
    def result_lines(self, app, model, width):
        """Rows: (text, style). Steps, space, (preview) the plan, notes, counts, categories, then items."""
        g = app.glyphs
        out = []
        dry = model.type() in ('scan', 'preview') or model.dry_run
        out.append((app.t('ui_result_phases'), 'accent'))
        for pid in model.phase_ids:
            phase = model.phases[pid]
            glyph, style = status_glyph(app, 'skipped' if phase.state == 'skipped' else ('pending' if phase.state in ('pending', 'off') else 'done'),
                                        {'ok': 'ok', 'warn': 'warn', 'error': 'failed', 'skipped': 'off'}.get(phase.result))
            word = app.t('ui_phres_' + (phase.result or ('skipped' if phase.state == 'off' else 'ok')))
            took = duration(phase.elapsed()) if phase.elapsed() is not None else ''
            out.append(('  %s %s  %s  %s' % (glyph, pad(app.t('ui_phase_' + pid), 12), pad(word, 9), took), style))
        if not model.phase_ids:
            out.append(('  ' + app.t('ui_result_no_phases'), 'base'))
        out.append(('', 'base'))
        out.append((app.t('ui_result_space'), 'accent'))
        if model.type() == 'restore':
            out.extend(('  ' + l, 'base') for l in restore_text(app, model.restore_summary()))
        elif dry:
            # A scan or preview measures nothing that was freed: no "measured freed", no "quarantined".
            line = '  %s %s' % (app.t('ui_card_estimated_plan' if model.type() == 'preview' else 'ui_card_estimated'),
                               fmt_bytes(model.estimated_total()))
            info = model.informational_total()
            if info:
                line += '   %s %s' % (app.t('ui_card_report_only'), fmt_bytes(info))
            out.append((line, 'base'))
        else:
            measured = model.measured_freed()
            out.append(('  %s %s  %s %s  %s %s' % (app.t('ui_card_estimated'), fmt_bytes(model.estimated_total()),
                                                   app.t('ui_card_measured'), fmt_bytes(measured) if measured is not None else app.t('ui_not_measured'),
                                                   app.t('ui_card_quarantined'), fmt_bytes(model.quarantined_total())), 'base'))
        for key, params in ([] if model.type() == 'restore' else model.differences()):
            for i, line in enumerate(wrap(app.t('ui_why_' + key, **params), max(10, width - 4))):
                out.append((('  ' + g['arrow'] + ' ' if i == 0 else '    ') + line, 'base'))
        out.append(('', 'base'))
        if model.type() == 'preview':
            out.extend(self.plan_lines(app, model, width))
        notes = self.result_notes(app, model)
        if notes:
            out.append(('%s (%d)' % (app.t('ui_result_notes'), len(notes)), 'accent'))
            for ident, text in notes:
                label = (app.category_label(ident) + ': ') if ident else ''
                for i, line in enumerate(wrap(label + text, max(10, width - 4))):
                    out.append((('  ' + g['needs'] + ' ' if i == 0 else '    ') + line, 'warn'))
            out.append(('', 'base'))
        counts = model.counts()
        if not dry or any(counts.values()):
            out.append((app.t('ui_result_counts'), 'accent'))
            line = '  '.join('%s %d' % (app.t('ui_res_' + k), n) for k, n in counts.items() if n)
            for part in wrap_items(line or app.t('ui_result_nothing'), max(10, width - 2)):
                out.append(('  ' + part, 'base'))
            out.append(('', 'base'))
        out.append((app.t('ui_result_categories_scan' if dry else 'ui_result_categories'), 'accent'))
        groups = model.merged()
        name_w = min(max([text_width(app.category_label(gr.id)) for gr in groups] + [10]) + 2, max(14, width - 9 - 2 - 16))
        for group in groups:
            outcome = group.computed_outcome()
            if dry and group.state == 'done' and (group.action == 'report' or group.tier == 'report'):
                outcome = 'report_only'
            elif dry and outcome == 'not_run' and group.state == 'done':
                outcome = 'scanned'
            style = {'cleaned': 'ok', 'partial': 'warn', 'failed': 'fail', 'skipped': 'warn', 'not_processed': 'warn'}.get(outcome, 'base')
            reason = group.dominant_reason() if outcome in ('failed', 'skipped', 'not_processed', 'partial') else ''
            text = '  %s  %s  %s' % (pad(clip(app.category_label(group.id), name_w, g['ellipsis']), name_w),
                                     pad(size_label(app, group.estimated, group.unit, group.id), 11, 'right'),
                                     app.t('ui_outcome_' + outcome))
            if reason:
                text += ' (%s)' % app.t('reason_' + reason)
            out.append((clip(text, width, g['ellipsis']), style))
        if dry:                                         # one figure from one source: the scan's own sizes, summed
            total = sum((gr.estimated or 0) for gr in groups if gr.unit == 'bytes')
            out.append(('  ' + app.t('ui_result_scan_total', size=fmt_bytes(total), report=fmt_bytes(model.informational_total())), 'strong'))
        buckets = model.buckets()
        for key in ('failed', 'skipped', 'unavailable'):
            if buckets[key]:
                out.append(('', 'base'))
                out.append(('%s %s (%d)' % (g['fail'] if key == 'failed' else g['needs'], app.t('ui_bucket_' + key), len(buckets[key])), 'warn'))
                for gid, item in buckets[key][:40]:
                    why, todo = app.explain(item)
                    out.append((clip('  %s: %s' % (item.name, why), width, g['ellipsis']), 'base'))
                    out.extend(('      ' + l, 'accent') for l in wrap(app.t('ui_suggest', action=todo), max(10, width - 6))[:2])
        return out

    def result_notes(self, app, model):
        """[(category id or None, text)]: the warnings and advisory notes of the run. The engine's own list is
        the 'Warnings & Notes' section of the run's report; event warnings come first."""
        notes, seen = [], set()
        run_dir = (model.paths or {}).get('run_dir') or ''
        run_id = os.path.basename(run_dir.rstrip('/'))
        texts = [text or code for code, text in model.warnings]
        if tui_registry.RUN_ID_PATTERN.fullmatch(run_id):
            texts += tui_runfacts.report_warnings(app.state_dir, run_id)
        for text in texts:
            if text and text not in seen:
                seen.add(text)
                notes.append((tui_runfacts.note_category(text), text))
        return notes

    def plan_lines(self, app, model, width):
        """What Clean would do, from the run's plan.json: per category operations, size, mode and removal kind."""
        g = app.glyphs
        out = [(app.t('ui_result_plan'), 'accent')]
        path = (model.plan or {}).get('path') or ''
        if not path:
            run_dir = (model.paths or {}).get('run_dir') or ''
            path = os.path.join(run_dir, 'plan.json') if run_dir else ''
        plan = tui_plan.load_plan(path) if path else None
        if plan is None:
            out.extend(('  ' + l, 'warn') for l in wrap(app.t('ui_plan_missing'), max(10, width - 2)))
            out.append(('', 'base'))
            return out
        rows, totals = tui_plan.overview(plan, app.mode_lookup(), app.settings.get('remove_mode'))
        scanned = {gid: grp.estimated for gid, grp in model.cats['scan'].items() if grp.unit == 'bytes' and grp.estimated is not None}
        for row in rows:                                # a report-only category has one size: the one the scan measured
            if row['state'] == 'report' and row['id'] in scanned:
                row['bytes'] = scanned[row['id']]
        totals['report'] = (totals['report'][0], sum(r['bytes'] for r in rows if r['state'] == 'report'))
        if not rows:
            out.append(('  ' + app.t('ui_plan_nothing'), 'base'))
            out.append(('', 'base'))
            return out
        name_w = min(max(text_width(app.category_label(r['id'])) for r in rows) + 2, max(14, width // 3))
        style_of = dict(auto='ok', decision='warn', blocked='fail', report='base', skipped='base', permonly='base')
        for row in rows:
            state = app.t('ui_planstate_' + row['state'])
            if row['state'] in ('auto', 'decision') and row['removal']:
                state += ' ' + g['sep'] + ' ' + app.t('ui_planrm_' + row['removal'], tools=', '.join(sorted(row['tools'])) or '?')
            text = '  %s %4d  %9s  %s' % (pad(clip(app.category_label(row['id']), name_w, g['ellipsis']), name_w), row['ops'],
                                          fmt_bytes(row['bytes']), state)
            out.append((clip(text, width, g['ellipsis']), style_of[row['state']]))
        out.append(('', 'base'))
        for key, glyph, style in (('auto', g['ok'], 'ok'), ('decision', g['needs'], 'warn'), ('report', g['current'], 'base'),
                                  ('permonly', g['off'], 'base'), ('skipped', g['off'], 'base'), ('blocked', g['fail'], 'fail')):
            ops, size = totals[key]
            if ops or key in ('auto', 'decision'):
                for i, line in enumerate(wrap(app.t('ui_plan_total_' + key, ops=ops, size=fmt_bytes(size)), max(10, width - 4))):
                    out.append((('  ' + glyph + ' ' if i == 0 else '    ') + line, style))
        out.append(('', 'base'))
        return out

    def render_result(self, app, c, rect):
        g = app.glyphs
        model = app.last_model
        focused = self.pane_focus(app, 'actions', 'result')
        c.box(rect, app.t('ui_pane_result'), focused)
        inner = rect.inner()
        y = inner.y
        glyph, style = status_glyph(app, 'done', {'ok': 'ok', 'warn': 'warn', 'failed': 'failed', 'stopped': 'warn'}.get(model.result, 'ok'))
        title = 'ui_result_title_' + (model.result if model.result in ('failed', 'stopped') else 'ok')
        c.put(y, inner.x, clip('%s %s  %s' % (glyph, app.t(title), app.t('ui_type_' + model.type())), inner.w, g['ellipsis']), style)
        took = app.t('ui_result_time', time=duration((model.ended or time.monotonic()) - model.started))
        if text_width(took) + 20 < inner.w:
            c.put(y, inner.x + inner.w - text_width(took), took, 'muted')
        y += 2
        x = inner.x
        current = self.current_button(app)
        for index, (label, _) in enumerate(self.buttons(app)):
            x = c.button(y, x, app.t(label), focused=app.zone == 'actions' and index == current and app.dialog is None,
                         primary=index == 0, action=('dash_button', index)) + 2
        y += 2
        area = Rect(y, inner.x, inner.y + inner.h - y, inner.w)
        lines = self.result_lines(app, model, area.w - 2)
        self.result_scroll = max(0, min(self.result_scroll, max(0, len(lines) - area.h)))
        for i, (text, st) in enumerate(lines[self.result_scroll:self.result_scroll + area.h]):
            c.put(area.y + i, area.x, clip(text, area.w - 2, g['ellipsis']), st)
        if len(lines) > area.h:
            render_scrollbar(c, area.y, area.x + area.w - 1, area.h, self.result_scroll, len(lines))


def tui_data_type(row):
    """Run type of a history row that carries only a mode."""
    from tui_runner import run_type
    return run_type(str(row.get('mode', '')))


# ---------------------------------------------------------------------------
class Categories(Screen):
    id, tab = 'categories', 'ui_tab_categories'
    SORTS = ('order', 'size', 'name', 'tier')

    def __init__(self):
        self.list = ListState()
        self.query = ''
        self.selected = set()
        self.sort = 'order'

    def zones(self, app):
        return ['list', 'search']

    def rows(self, app):
        rows = app.models.category_rows()
        q = self.query.casefold().strip()
        if q:
            rows = [r for r in rows if q in r['id'] or q in app.category_label(r['id']).casefold()
                    or q in app.t('ui_tier_' + r['tier']).casefold()]
        if self.sort == 'size':
            rows = sorted(rows, key=lambda r: -((app.category_scan(r) or {}).get('estimated_bytes') or 0))
        elif self.sort == 'name':
            rows = sorted(rows, key=lambda r: app.category_label(r['id']).casefold())
        elif self.sort == 'tier':
            rows = sorted(rows, key=lambda r: tui_registry.TIERS.index(r['tier']) if r['tier'] in tui_registry.TIERS else 9)
        return rows

    def mode_of(self, app, row):
        mode, source, _ = app.category_mode(row)
        return mode, source

    def mode_note(self, app, row):
        """One sentence about what the current mode means and whether it can change."""
        ident = row['id']
        if not tui_registry.executable(ident):
            return ''
        mode, _, auto = app.category_mode(row)
        if auto:
            return app.t('ui_mode_is_auto')
        if tui_registry.auto_allowed(ident):
            return app.t('ui_mode_can_auto') if mode == 'review' else ''
        return app.t('ui_mode_no_auto_native' if tui_registry.native_only(ident) else 'ui_mode_no_auto_review')

    def bindings(self, app, zone):
        if zone == 'search':
            return [Binding((), 'ui_key_type', 'type', display='abc'), Binding(('down', 'enter'), 'ui_key_back', 'to_list'),
                    Binding(('backspace',), 'ui_key_clear', 'backspace')]
        return [Binding(('up', 'down'), 'ui_key_move', 'vmove'), Binding(('space',), 'ui_key_mark', 'mark'),
                Binding(('enter',), 'ui_key_details', 'open'), Binding(('x', 'X'), 'ui_btn_clean_selected', 'clean'),
                Binding(('m',), 'ui_key_mode', 'mode'), Binding(('a',), 'ui_key_select_regen', 'all'),
                Binding(('n',), 'ui_key_select_none', 'none'), Binding(('s',), 'ui_key_sort', 'sort'),
                Binding(('/',), 'ui_key_search', 'to_search'), Binding(('r',), 'ui_btn_refresh', 'refresh', show=False),
                Binding(('pgup', 'pgdn'), 'ui_key_scroll', 'page', show=False)]

    def help(self, app, zone):
        if zone == 'search':
            return app.t('ui_help_cat_search')
        # The Details pane already describes the selected category; the help adds what is not shown anywhere else.
        g = app.glyphs
        legend = app.t('ui_cat_legend', ok=g['ok'], needs=g['needs'], current=g['current'])
        return app.t('ui_help_cat_list') + '\n\n' + legend

    def action(self, app, zone, action):
        rows = self.rows(app)
        if action == 'refresh':
            app.models.refresh('categories')
            return True
        if zone == 'search':
            if action in ('down', 'enter', 'to_list'):
                app.focus_zone('list')
            elif action == 'backspace':
                self.query = self.query[:-1]
                self.list.index = 0
            elif action == 'up':
                app.focus_zone('tabs')
            else:
                return False
            return True
        if action == 'to_search':
            app.focus_zone('search')
        elif action == 'up':
            if self.list.index == 0:
                app.focus_zone('search')
            self.list.move(-1, len(rows))
        elif action == 'down':
            self.list.move(1, len(rows))
        elif action in ('pgup', 'pgdn'):
            self.list.move(-10 if action == 'pgup' else 10, len(rows))
        elif action == 'mark' and rows:
            row = rows[self.list.index]
            if not tui_registry.executable(row['id']):
                app.notify(app.t('ui_report_never_deleted'), 'status_warn')
            else:
                self.selected.symmetric_difference_update({row['id']})
                self.list.move(1, len(rows))
        elif action == 'all':
            self.selected = {r['id'] for r in app.models.category_rows() if r['tier'] == 'regenerable'}
            app.notify(app.t('ui_selected_count', count=len(self.selected)), 'status')
        elif action == 'none':
            self.selected.clear()
        elif action == 'sort':
            self.sort = self.SORTS[(self.SORTS.index(self.sort) + 1) % len(self.SORTS)]
            app.notify(app.t('ui_sort_by', by=app.t('ui_catsort_' + self.sort)), 'status')
        elif action == 'mode' and rows:
            self.cycle_mode(app, rows[self.list.index])
        elif action == 'open' and rows:
            self.open_items(app, rows[self.list.index])
        elif action == 'clean':
            self.clean_selected(app)
        else:
            return action in ('vmove', 'page')
        return True

    def text(self, app, zone, text):
        if zone == 'search':
            self.query = (self.query + text)[:40]
            self.list.index = 0
            return True
        return False

    def sizes_note(self, app):
        """Where the sizes in the Size column come from, with their age when they are not from this session."""
        info = app.scan_info()
        if info is None:
            return app.t('ui_cat_sizes_none')
        if info['session'] and not info.get('stale'):
            return app.t('ui_cat_sizes_session')
        when = time.strftime('%Y-%m-%d %H:%M', time.localtime(info['epoch'])) if info.get('epoch') else str(info.get('run_id') or '?')
        stale = info.get('stale')
        if stale:                                              # a clean or restore ran after this scan: the sizes are old
            done = time.strftime('%Y-%m-%d %H:%M', time.localtime(stale['epoch'])) if stale.get('epoch') else '?'
            return app.t('ui_cat_sizes_stale', when=when, type=app.t('ui_type_' + stale['type']), done=done)
        return app.t('ui_cat_sizes_from', when=when, age=app.relative(info.get('epoch')))

    def cycle_mode(self, app, row):
        ident = row['id']
        if not tui_registry.executable(ident):
            app.notify(app.t('ui_mode_report_fixed'), 'status_warn')
            return
        current = self.mode_of(app, row)[0]
        new = app.modes.next_mode(ident, current)
        if new == 'auto':
            self.confirm_auto(app, row)
            return
        # Auto is skipped for categories where the engine would refuse it; say so when it would have come next.
        why = ''
        if not tui_registry.auto_allowed(ident) and current == 'skip':
            why = ' ' + app.t('ui_mode_no_auto_native' if tui_registry.native_only(ident) else 'ui_mode_no_auto_review')
        self.apply_mode(app, row, new, why)

    def apply_mode(self, app, row, new, extra=''):
        try:
            app.modes.set_many([row['id']], new)
        except (OSError, ValueError) as exc:
            app.notify(app.t('ui_error', message=plain(exc)), 'status_warn')
            return
        app.notify(app.t('ui_mode_set', name=app.category_label(row['id']), mode=app.t('ui_mode_' + new)) + extra, 'status_ok')

    def confirm_auto(self, app, row):
        """Switching to auto lets the category be cleaned without asking: confirm first (default: cancel)."""
        sched = app.t('ui_confirm_mode_auto_sched_on' if app.schedule().get('state') == 'on' else 'ui_confirm_mode_auto_sched_off')
        body = app.t('ui_confirm_mode_auto', name=app.category_label(row['id'])) + '\n\n' + sched

        def done(a, value):
            if value == 'run':
                self.apply_mode(a, row, 'auto')
        app.open_dialog(ConfirmDialog(app.t('ui_dlg_confirm'), body, app.t('ui_btn_mode_auto'), app.t('ui_btn_cancel'), done))

    def clean_selected(self, app):
        if not self.selected:
            app.notify(app.t('ui_nothing_selected'), 'status_warn')
            return
        order = [i for i in tui_registry.CATEGORY_IDS if i in self.selected]
        app.request_action('clean_selected', None, ['--only', ','.join(order)])

    def category_items(self, app, row):
        """Item list for a category: its operations in the newest plan, else the model's top items."""
        items = []
        path, _ = tui_data.latest_plan(app.models, app.state_dir, max_age_hours=24 * 365)
        plan = tui_plan.load_plan(path) if path else None
        if plan:
            for op in plan.get('operations', []):
                if isinstance(op, dict) and op.get('category') == row['id'] and isinstance(op.get('path'), str) and op['path'].startswith('/'):
                    size = op.get('estimated_bytes')
                    items.append(dict(path=op['path'], bytes=size if isinstance(size, int) else 0, category=row['id']))
        if not items:
            for entry in row.get('top_items') or []:
                if isinstance(entry, dict) and isinstance(entry.get('path'), str) and entry['path'].startswith('/'):
                    items.append(dict(path=entry['path'], bytes=entry.get('bytes') if isinstance(entry.get('bytes'), int) else 0,
                                      category=row['id']))
        return items

    def open_items(self, app, row):
        items = self.category_items(app, row)
        note = app.t(tui_registry.explain_key(row['id']))
        if not tui_registry.executable(row['id']):
            note += ' ' + app.t('ui_report_why')
        il = ItemList(items, title=app.category_label(row['id']), kind='category', readonly_note=note)
        il.sort = 'size'
        app.open_items(il)

    def click(self, app, payload, double=False):
        if payload[0] == 'cat_row':
            app.focus_zone('list')
            self.list.index = payload[1]
            rows = self.rows(app)
            if payload[2] == 'check' and rows:
                self.action(app, 'list', 'mark')
            elif double and rows:
                self.open_items(app, rows[payload[1]])
            return True
        if payload[0] == 'cat_search':
            app.focus_zone('search')
            return True
        return False

    def scroll(self, app, zone, delta):
        self.list.move(delta, len(self.rows(app)))
        return True

    def models_changed(self, app, name):
        if name == 'categories':
            self.selected &= {r['id'] for r in app.models.category_rows()}

    def render(self, app, c, main, side):
        g = app.glyphs
        rows = self.rows(app)
        total = len(app.models.category_rows())
        focused = self.pane_focus(app, 'list', 'search')
        c.box(main, app.t('ui_pane_categories'), focused, right=app.t('ui_apps_count', shown=len(rows), total=total))
        inner = main.inner()
        y = inner.y
        draw_search_row(app, c, inner, y, self.query, app.t('ui_search_hint'), ('cat_search',))
        if self.selected:
            note = app.t('ui_selected_count', count=len(self.selected))
            c.put(y, inner.x + inner.w - text_width(note), note, 'accent')
        y += 1
        if app.models.error['categories'] and not app.models.get('categories'):
            c.put(y, inner.x, clip(app.t('ui_engine_missing'), inner.w, g['ellipsis']), 'warn')
        else:
            c.put(y, inner.x, clip(self.sizes_note(app), inner.w, g['ellipsis']), 'base')
        y += 1
        size_w, mode_w, tier_w = 8, 8, 6
        name_w = max(8, inner.w - 34)
        c.put(y, inner.x + 5, clip(app.t('ui_col_name'), name_w), 'muted')
        x = inner.x + 5 + name_w + 1
        c.put(y, x, app.t('ui_col_tier')[:tier_w], 'muted')
        c.put(y, x + tier_w + 1, app.t('ui_col_mode')[:mode_w], 'muted')
        c.put(y, x + tier_w + mode_w + 2, pad(app.t('ui_col_size'), size_w, 'right'), 'muted')
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
            can = tui_registry.executable(row['id'])
            mark = (g['check_on'] if row['id'] in self.selected else g['check_off']) if can else '   '
            c.put(y, inner.x + 1, mark if len(mark) == 3 else mark, style if selected else ('ok' if row['id'] in self.selected else 'muted'))
            mode, source = self.mode_of(app, row)
            c.put(y, inner.x + 5, clip(app.category_label(row['id']), name_w, g['ellipsis']), style)
            x = inner.x + 5 + name_w + 1
            c.put(y, x, clip(app.t('ui_tier_short_' + row['tier']), tier_w), style if selected else TIER_STYLE.get(row['tier'], 'muted'))
            mode_text = app.t('ui_mode_' + mode) + ('*' if source == 'user' else '')
            c.put(y, x + tier_w + 1, clip(mode_text, mode_w), style if selected else ('muted' if mode == 'skip' else 'base'))
            scan = app.category_scan(row)
            size = size_label(app, scan.get('estimated_bytes') if scan else None, row.get('unit', 'bytes'), row['id'])
            outdated = bool(scan) and bool((app.scan_info() or {}).get('stale'))         # measured before a run that changed the disk
            c.put(y, x + tier_w + mode_w + 2, pad(size, size_w, 'right'), style if selected else ('muted' if outdated else 'base'))
            if outdated:
                c.put(y, x + tier_w + mode_w + 1, '~', style if selected else 'warn')
            undo = g['ok'] if row.get('undo') == 'quarantine' else (g['current'] if row.get('action') == 'report' else g['needs'])
            c.put(y, inner.x + inner.w - 2, undo, style if selected else (
                'ok' if row.get('undo') == 'quarantine' else ('muted' if row.get('action') == 'report' else 'warn')))
            c.region(y, inner.x, 1, inner.w, ('cat_row', i, 'row'))
            c.region(y, inner.x + 1, 1, 3, ('cat_row', i, 'check'))
            y += 1
        if side is not None:
            self.render_detail(app, c, side, rows)

    def render_detail(self, app, c, rect, rows):
        g = app.glyphs
        c.box(rect, app.t('ui_pane_details'))
        inner = rect.inner()
        if not rows:
            return
        row = rows[min(self.list.index, len(rows) - 1)]
        y = inner.y
        c.put(y, inner.x, clip(app.category_label(row['id']), inner.w, g['ellipsis']), 'strong')
        y += 1
        mode, source = self.mode_of(app, row)
        pairs = [(app.t('ui_col_tier'), app.t('ui_tier_' + row['tier'])),
                 (app.t('ui_col_mode'), app.t('ui_mode_' + mode) + ('*' if source == 'user' else '')),
                 (app.t('ui_col_undo'), app.t('ui_undo_' + ('report' if row.get('action') == 'report' else (
                     'quarantine' if row.get('undo') == 'quarantine' else 'permanent'))))]
        scan = app.category_scan(row)
        if scan:
            pairs.append((app.t('ui_col_size'), size_label(app, scan.get('estimated_bytes'), row.get('unit', 'bytes'), row['id']) + (
                ' ~' if scan.get('partial') else '') + (
                ' (%s)' % app.t('ui_cat_size_stale') if (app.scan_info() or {}).get('stale') else '')))
            if scan.get('items'):        # a scan that sized the category without counting says nothing here
                pairs.append((app.t('ui_col_items'), str(scan.get('items'))))
        if row.get('native_cmd') or tui_registry.info(row['id'])['native_cmd']:
            pairs.append((app.t('ui_col_command'), row.get('native_cmd') or tui_registry.info(row['id'])['native_cmd']))
        label_w = max(text_width(k) for k, _ in pairs) + 2
        for key, value in pairs:
            if y + 1 >= inner.y + inner.h:
                break
            y += 1
            c.put(y, inner.x, key + ':', 'muted')
            c.put(y, inner.x + label_w, clip(value, inner.w - label_w, g['ellipsis']), 'base')
        kind = 'report' if row.get('action') == 'report' else ('quarantine' if row.get('undo') == 'quarantine' else 'permanent')
        mark = {'report': g['current'], 'quarantine': g['ok'], 'permanent': g['needs']}[kind]
        y += 1
        for line in wrap(app.t('ui_undo_mark_' + kind, glyph=mark), inner.w):
            if y + 1 >= inner.y + inner.h:
                break
            y += 1
            c.put(y, inner.x, line, 'base')
        y += 2
        text = app.t(tui_registry.explain_key(row['id']))
        if not tui_registry.executable(row['id']):
            text += '\n' + app.t('ui_report_why')
        else:
            note = self.mode_note(app, row)
            if note:
                text += '\n' + note
        for line in wrap(text, inner.w):
            if y >= inner.y + inner.h:
                break
            c.put(y, inner.x, line, 'base')
            y += 1
        tops = row.get('top_items') or []
        if tops and y + 2 < inner.y + inner.h:
            y += 1
            c.put(y, inner.x, app.t('ui_top_items'), 'accent')
            for entry in tops[:inner.y + inner.h - y - 1]:
                if isinstance(entry, dict):
                    y += 1
                    c.put(y, inner.x, clip('%s  %s' % (pad(size_text(entry.get('bytes')), 8, 'right'), entry.get('path', '')), inner.w, g['ellipsis']),
                          'base')


def make_screens():
    from tui_screens_data import About, Diagnostics, History, Quarantine
    from tui_screens_settings import SettingsScreen
    return [Dashboard(), Categories(), Quarantine(), History(), SettingsScreen(), Diagnostics(), About()]
