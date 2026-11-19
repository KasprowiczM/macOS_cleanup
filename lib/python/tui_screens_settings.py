"""The Settings screen. One SCHEMA table (tui_settings) drives the rows, the
saved files and the engine's environment. Sections with headers, search by
typing, Enter/Space to edit (toggle, choice dialog, validated input), the
current value and the default on every row, a description for the selected
setting, reset of one setting or all, and a note when a change applies from
the next run. Nothing typed here can become a shell fragment: values are
coerced to their kind and reach the engine only as environment variables."""
import json
import os

import tui_registry
import tui_settings as ts
from tui_dialogs import ChoiceDialog, ConfirmDialog, Dialog, InputDialog, MultiDialog
from tui_keymap import Binding
from tui_screens import ListState, Screen, SCREENS, draw_search_row, draw_wrapped
from tui_widgets import Rect, clip, clip_middle, pad, plain, scroll_window, text_width, wrap

INFO_KEYS = ('review_policy', 'unattended_scope', 'schedule_status', 'path_program', 'path_config', 'path_state',
             'path_quarantine', 'install_mode', 'legacy_data')


class SettingsScreen(Screen):
    id, tab = 'settings', 'ui_tab_settings'

    def __init__(self):
        self.list = ListState()
        self.query = ''

    def zones(self, app):
        return ['list', 'search']

    # -- rows ---------------------------------------------------------------------
    def label(self, app, setting):
        if setting.key == 'schedule':
            return app.t('ui_set_schedule_off' if app.schedule().get('state') == 'on' else 'ui_set_schedule_on')
        return app.t(setting.label)

    def matches(self, app, setting, q):
        return not q or q in self.label(app, setting).casefold() or q in app.t(setting.help).casefold() \
            or q in setting.key.replace('_', ' ')

    def rows(self, app):
        """('warn',) | ('section', id) | ('setting', Setting) rows after the search filter."""
        q = self.query.casefold().strip()
        out = []
        store = app.settings
        if (store.unknown or store.invalid) and (not q or q in app.t('ui_set_warning').casefold()):
            out.append(('warn', None))
        for section in ts.SECTIONS:
            items = [s for s in ts.SCHEMA if s.section == section and s.key not in ts.NOT_SHOWN
                     and self.matches(app, s, q)]
            if items:
                out.append(('section', section))
                out.extend(('setting', s) for s in items)
        return out

    def selectable(self, rows):
        return [i for i, r in enumerate(rows) if r[0] != 'section']

    def current(self, app):
        rows = self.rows(app)
        sel = self.selectable(rows)
        if not sel:
            return rows, None
        if self.list.index not in sel:
            self.list.index = min(sel, key=lambda i: abs(i - self.list.index))
        return rows, rows[self.list.index]

    def path_value(self, app, key):
        if key in ts.PATH_KEYS:
            return app.paths[ts.PATH_KEYS[key]]
        return ''

    def value_text(self, app, setting, value=None):
        key, kind = setting.key, setting.kind
        value = app.settings.get(key) if value is None and key in ts.VALUE_KEYS else value
        if kind == 'bool':
            return app.t('ui_on') if value else app.t('ui_off')
        if kind == 'choice':
            if key in ('language', 'report_language'):
                if value in ('system', 'same'):
                    return app.t('ui_ch_%s_%s' % (key, value))
                return ts.NATIVE_NAMES.get(value, value)
            return app.t('ui_ch_%s_%s' % (key, value))
        if kind == 'multi':
            return app.t('ui_multi_count', n=len(value), total=len(setting.choices))
        if kind in ('int', 'time'):
            return str(value)
        if key == 'schedule':
            return app.t('ui_installed') if app.schedule().get('state') == 'on' else app.glyphs['arrow']      # an action row like the others
        if key == 'check_updates':
            state = app.update_state
            return app.t('ui_upd_mark_' + {'checking': 'checking', 'failed': 'failed', 'dev': 'dev', 'current': 'current',
                                           'available': 'available'}.get(state.get('status'), 'idle'),
                         version=state.get('current', ''), latest=state.get('latest', ''))
        if key == 'excludes':
            return app.t('ui_entries', count=len(app.excluded))
        if key == 'category_modes':
            return app.t('ui_overridden', count=app.modes.overridden())
        if key in ts.PATH_KEYS:
            return self.path_value(app, key)
        if key == 'install_mode':
            return app.t('ui_mode_install_' + app.paths.get('mode', 'default'))
        if key == 'schedule_status':
            return self.schedule_text(app)
        if key == 'legacy_data':
            return app.t('ui_legacy_found' if self.legacy(app) else 'ui_legacy_none')
        if key == 'review_policy':
            return app.t('ui_review_policy_short')
        if key == 'unattended_scope':
            return app.t('ui_unattended_short')
        return app.glyphs['arrow']

    def legacy(self, app):
        legacy = app.models.doctor().get('legacy')
        if isinstance(legacy, dict) and legacy:
            return bool(legacy.get('checkout') or legacy.get('logs') or legacy.get('reports') or legacy.get('orphan_manifests'))
        return ts.legacy_detected(app.environ)

    def schedule_text(self, app):
        status = app.schedule()
        if status.get('state') == 'on':
            nxt = ts.next_run(status)
            import time
            return app.t('ui_sched_on', when='%02d:%02d' % (int(status.get('hour') or 0), int(status.get('minute') or 0)),
                         next=time.strftime('%a %d %b %H:%M', time.localtime(nxt)) if nxt else '?')
        if status.get('state') == 'unknown':
            return app.t('ui_schedule_unknown')
        return app.t('ui_schedule_off')

    def default_text(self, app, setting):
        if setting.key not in ts.VALUE_KEYS:
            return ''
        return self.value_text(app, setting, setting.default)

    # -- keys -----------------------------------------------------------------------
    def bindings(self, app, zone):
        if zone == 'search':
            return [Binding((), 'ui_key_type', 'type', display='abc'), Binding(('down', 'enter'), 'ui_key_back', 'to_list'),
                    Binding(('backspace',), 'ui_key_clear', 'backspace')]
        rows, row = self.current(app)
        out = [Binding(('up', 'down'), 'ui_key_move', 'vmove')]
        setting = row[1] if row and row[0] == 'setting' else None
        kind = setting.kind if setting else None
        if kind == 'bool':
            out.append(Binding(('enter', 'space'), 'ui_key_toggle', 'activate'))
        elif kind in ('choice', 'int', 'time', 'multi'):
            out += [Binding(('enter',), 'ui_key_change', 'activate')]
            if kind in ('choice', 'int'):
                out.append(Binding(('left', 'right'), 'ui_key_adjust', 'adjust'))
        elif kind in ('action', 'info') or row is not None:
            out.append(Binding(('enter',), 'ui_key_open', 'activate'))
        if setting is not None and setting.key in ts.VALUE_KEYS:
            out.append(Binding(('d',), 'ui_key_default', 'default'))
        out.append(Binding(('/',), 'ui_key_search', 'to_search'))
        out.append(Binding(('pgup', 'pgdn'), 'ui_key_scroll', 'page', show=False))
        return out

    def help(self, app, zone):
        if zone == 'search':
            return app.t('ui_settings_search_hint')
        rows, row = self.current(app)
        if not row:
            return app.t('ui_help_settings')
        if row[0] == 'warn':
            return app.t('ui_help_settings')              # the Details pane already shows the warning's text
        s = row[1]
        # The Details pane describes the setting; the help adds what it does not show: value, default, origin, when.
        text = ''
        if s.key in ts.PATH_KEYS:
            text = self.path_value(app, s.key) + '\n\n'
        if s.key in ts.VALUE_KEYS:
            text = app.t('ui_setting_detail', value=self.value_text(app, s), default=self.default_text(app, s))
            text += '\n' + app.t('ui_origin_label', origin=app.t('ui_origin_' + app.settings.origin.get(s.key, 'default')))
            if s.env and s.key in ts.ENGINE_CONF_KEYS:
                text += '\n' + app.t('ui_env_var', name=s.env)
            text += '\n' + app.t('ui_applies_' + s.when) + '\n\n'
        return text + app.t('ui_help_settings')

    def action(self, app, zone, action):
        if zone == 'search':
            if action in ('down', 'enter', 'to_list'):
                app.focus_zone('list')
            elif action == 'backspace':
                self.query = self.query[:-1]
            elif action == 'up':
                app.focus_zone('tabs')
            else:
                return False
            return True
        rows, row = self.current(app)
        sel = self.selectable(rows)
        if action in ('up', 'down', 'pgup', 'pgdn'):
            if not sel:
                return True
            pos = sel.index(self.list.index) if self.list.index in sel else 0
            if action == 'up' and pos == 0:
                app.focus_zone('search')
                return True
            self.list.index = sel[max(0, min(len(sel) - 1, pos + {'up': -1, 'down': 1, 'pgup': -8, 'pgdn': 8}[action]))]
            return True
        if action == 'to_search':
            app.focus_zone('search')
            return True
        if row is None:
            return action in ('vmove', 'page')
        if action in ('left', 'right'):
            self.adjust(app, row, -1 if action == 'left' else 1)
            return True
        if action == 'activate':
            self.activate(app, row)
            return True
        if action == 'default' and row[0] == 'setting':
            self.reset_one(app, row[1])
            return True
        return action in ('vmove', 'page', 'adjust')

    def text(self, app, zone, text):
        if zone == 'search':
            self.query = (self.query + text)[:40]
            self.list.index = 0
            return True
        return False

    # -- editing ----------------------------------------------------------------------
    def save(self, app, key, value):
        setting = ts.BY_KEY[key]
        try:
            app.settings.set(key, value)
        except PermissionError as exc:
            app.notify(app.t('ui_env_locked', env=str(exc)), 'status_warn')
            return False
        except (OSError, ValueError) as exc:
            app.notify(app.t('ui_error', message=plain(exc)), 'status_warn')
            return False
        app.after_setting(key)
        note = app.t('ui_saved', name=self.label(app, setting))
        if setting.when == 'next_run':
            note += ' ' + app.t('ui_applies_next_run_short')
        if key in ('schedule_time', 'schedule_weekday') and app.schedule().get('state') == 'on':
            note += ' ' + app.t('ui_schedule_reinstall_note')
        app.notify(note, 'status_ok')
        return True

    def reset_one(self, app, setting):
        try:
            app.settings.reset_one(setting.key)
        except PermissionError as exc:
            app.notify(app.t('ui_env_locked', env=str(exc)), 'status_warn')
            return
        except (OSError, ValueError) as exc:
            app.notify(app.t('ui_error', message=plain(exc)), 'status_warn')
            return
        app.after_setting(setting.key)
        app.notify(app.t('ui_reset_one', name=self.label(app, setting)), 'status_ok')

    def adjust(self, app, row, delta):
        if row[0] != 'setting':
            return
        s = row[1]
        if s.kind == 'int':
            self.save(app, s.key, max(s.low, min(s.high, app.settings.get(s.key) + delta * s.step)))
        elif s.kind == 'choice':
            self.choose(app, s, s.choices[(s.choices.index(app.settings.get(s.key)) + delta) % len(s.choices)])
        elif s.kind == 'bool':
            self.save(app, s.key, not app.settings.get(s.key))
        else:
            app.notify(app.t('ui_unknown_key', keys='Enter'), 'status')

    def choose(self, app, setting, value):
        """Save a choice; a value that needs confirmation asks first."""
        if setting.confirm and value == setting.confirm and app.settings.get(setting.key) != value:
            def done(a, v):
                if v == 'run':
                    self.save(a, setting.key, value)
            app.open_dialog(ConfirmDialog(app.t('ui_confirm_title_setting'), app.t('ui_confirm_' + setting.key + '_' + value),
                                          app.t('ui_btn_apply'), app.t('ui_btn_cancel'), done))
            return
        self.save(app, setting.key, value)

    def activate(self, app, row):
        if row[0] == 'warn':
            store = app.settings
            lines = []
            if store.unknown:
                lines.append(app.t('ui_set_warning_unknown') + ' ' + ', '.join(plain(k) for k in store.unknown[:20]))
            if store.invalid:
                lines.append(app.t('ui_set_warning_invalid') + ' ' + ', '.join(store.invalid[:20]))
            app.open_dialog(Dialog(app.t('ui_set_warning'), '\n\n'.join(lines), [(app.t('ui_btn_ok'), None)], None))
            return
        s = row[1]
        if s.kind == 'bool':
            self.save(app, s.key, not app.settings.get(s.key))
        elif s.kind == 'choice':
            entries = [(self.value_text(app, s, c), c) for c in s.choices]
            app.open_dialog(ChoiceDialog(self.label(app, s), entries, lambda a, v: v is not None and self.choose(a, s, v),
                                         current=app.settings.get(s.key), body=app.t(s.help)))
        elif s.kind == 'int':
            def validate(text):
                try:
                    ts.coerce(s, text)
                except ValueError:
                    return app.t('ui_number_invalid', low=s.low, high=s.high)
                return ''
            app.open_dialog(InputDialog(self.label(app, s), app.t('ui_number_prompt', low=s.low, high=s.high), '> ',
                                        lambda a, v: v not in (None, 'timeout') and self.save(a, s.key, int(v.strip())),
                                        validate=validate, initial=str(app.settings.get(s.key)),
                                        ok_label=app.t('ui_btn_apply'), cancel_label=app.t('ui_btn_cancel')))
        elif s.kind == 'time':
            def validate_time(text):
                try:
                    ts.parse_hhmm(text)
                except ValueError:
                    return app.t('ui_time_invalid')
                return ''
            app.open_dialog(InputDialog(self.label(app, s), app.t('ui_time_prompt'), '> ',
                                        lambda a, v: v not in (None, 'timeout') and self.save(a, s.key, v.strip()),
                                        validate=validate_time, initial=app.settings.get(s.key),
                                        ok_label=app.t('ui_btn_apply'), cancel_label=app.t('ui_btn_cancel')))
        elif s.kind == 'multi':
            entries = [(app.section_label(c), c) for c in s.choices]
            app.open_dialog(MultiDialog(self.label(app, s), entries,
                                        lambda a, v: v is not None and self.save(a, s.key, v),
                                        checked=app.settings.get(s.key), body=app.t(s.help)))
        elif s.kind == 'action':
            app.settings_action(s.key, self)
        elif s.kind == 'info':
            self.show_info(app, s)

    def show_info(self, app, s):
        text = app.t(s.help)
        buttons = [(app.t('ui_btn_ok'), None)]
        if s.key in ts.PATH_KEYS:
            path = self.path_value(app, s.key)
            text = path + '\n\n' + text
            buttons = [(app.t('ui_btn_copy'), 'copy'), (app.t('ui_btn_ok'), None)]

            def done(a, v):
                if v == 'copy':
                    a.copy_text(path)
            app.open_dialog(Dialog(self.label(app, s), text, buttons, done, default=1))
            return
        if s.key == 'legacy_data':
            text = app.t('ui_legacy_text' if self.legacy(app) else 'ui_legacy_none_text')
        elif s.key == 'schedule_status':
            text = self.schedule_text(app) + '\n\n' + text
        app.open_dialog(Dialog(self.label(app, s), text, buttons, None))

    def click(self, app, payload, double=False):
        if payload[0] == 'set_row':
            app.focus_zone('list')
            self.list.index = payload[1]
            if double:
                rows, row = self.current(app)
                if row:
                    self.activate(app, row)
            return True
        if payload[0] == 'set_search':
            app.focus_zone('search')
            return True
        return False

    def scroll(self, app, zone, delta):
        self.action(app, 'list', 'down' if delta > 0 else 'up')
        return True

    # -- drawing ------------------------------------------------------------------------
    def render(self, app, c, main, side):
        g = app.glyphs
        rows, row = self.current(app)
        c.box(main, app.t('ui_pane_settings'), self.pane_focus(app, 'list', 'search'))
        inner = main.inner()
        y = inner.y
        draw_search_row(app, c, inner, y, self.query, app.t('ui_settings_search_hint'), ('set_search',))
        y += 2
        compact = app.settings.get('density') == 'compact'
        lines = []
        for i, r in enumerate(rows):
            if r[0] == 'section':
                if lines and not compact:
                    lines.append((None, '', '', '', 'blank'))
                lines.append((None, app.t(ts.SECTION_LABELS[r[1]]), '', '', 'section'))
            elif r[0] == 'warn':
                store = app.settings
                lines.append((i, app.t('ui_set_warning'), app.t('ui_set_warning_count', n=len(store.unknown) + len(store.invalid)), '', 'warn'))
            else:
                s = r[1]
                dflt = ''
                if s.key in ts.VALUE_KEYS and inner.w >= 64:
                    dflt = app.t('ui_default_mark') if app.settings.is_default(s.key) else app.t('ui_default_is', value=self.default_text(app, s))
                lines.append((i, self.label(app, s), self.value_text(app, s), dflt, s.kind))
        value_w = max([text_width(l[2]) for l in lines if l[0] is not None] + [4])
        value_w = min(value_w, max(10, inner.w // 2 - 2))
        default_w = min(max([text_width(l[3]) for l in lines if l[0] is not None] + [0]), max(0, inner.w // 3))
        label_w = max(8, inner.w - value_w - (default_w + 2 if default_w else 0) - 5)
        display = []
        for entry in lines:
            index, text, value, dflt, kind = entry
            if index is None or text_width(text) <= label_w:
                display.append(entry + (0,))
            else:
                parts = wrap(text, label_w)
                display.append((index, parts[0], value, dflt, kind, 0))
                display.extend((index, part, '', '', kind, 1) for part in parts[1:])
        visible = inner.y + inner.h - y
        sel_line = next((n for n, d in enumerate(display) if d[0] == self.list.index and d[5] == 0), 0)
        self.list.offset = scroll_window(sel_line, self.list.offset, visible, len(display))
        for index, text, value, dflt, kind, cont in display[self.list.offset:self.list.offset + visible]:
            if kind == 'section':
                c.put(y, inner.x, text, 'accent')
                c.put(y, inner.x + text_width(text) + 1, g['h'] * max(0, inner.w - text_width(text) - 1), 'border')
            elif kind != 'blank':
                selected = index == self.list.index
                style = ('sel_focus' if app.zone == 'list' and app.dialog is None else 'sel') if selected else 'base'
                if selected:
                    c.fill(y, inner.x, 1, inner.w, style)
                    if not cont:
                        c.put(y, inner.x, g['marker'], style)
                c.put(y, inner.x + 2, text, style if selected else ('warn' if kind == 'warn' else 'base'))
                if value:
                    vstyle = style if selected else ('ok' if value == app.t('ui_on') else ('warn' if kind == 'warn' else 'accent'))
                    is_path = rows[index][0] == 'setting' and rows[index][1].key in ts.PATH_KEYS
                    c.put(y, inner.x + 2 + label_w + 1, (clip_middle if is_path else clip)(value, value_w, g['ellipsis']), vstyle)
                if dflt and default_w:
                    c.put(y, inner.x + inner.w - default_w, pad(clip(dflt, default_w, g['ellipsis']), default_w, 'right'),
                          style if selected else ('muted' if dflt == app.t('ui_default_mark') else 'warn'))
                c.region(y, inner.x, 1, inner.w, ('set_row', index))
            y += 1
        if side is not None:
            self.render_side(app, c, side, row)

    def render_side(self, app, c, side, row):
        g = app.glyphs
        c.box(side, app.t('ui_pane_details'))
        si = side.inner()
        if not row:
            return
        if row[0] == 'warn':
            draw_wrapped(c, Rect(si.y, si.x, si.h, si.w), app.t('ui_set_warning_help'), 'base')
            return
        s = row[1]
        c.put(si.y, si.x, clip(self.label(app, s), si.w, g['ellipsis']), 'strong')
        used = draw_wrapped(c, Rect(si.y + 2, si.x, si.h - 2, si.w), app.t(s.help), 'base')
        if s.key in ts.PATH_KEYS:                                # the row cuts a long path in the middle: the whole path is here
            used += 1 + draw_wrapped(c, Rect(si.y + 3 + used, si.x, max(0, si.h - 3 - used), si.w), self.path_value(app, s.key), 'accent')
        if s.key == 'accent':
            self.render_accent_preview(app, c, Rect(si.y + 3 + used, si.x, si.h - 3 - used, si.w))

    def render_accent_preview(self, app, c, rect):
        g = app.glyphs
        if rect.h < 2:
            return
        c.put(rect.y, rect.x, app.t('ui_accent_preview'), 'accent')
        current = app.settings.get('accent')
        choices = ts.BY_KEY['accent'].choices
        name_w = max(text_width(app.t('ui_ch_accent_' + a)) for a in choices)
        for i, accent in enumerate(choices[:rect.h - 1]):
            y = rect.y + 1 + i
            mark = g['radio_on'] if accent == current else g['radio_off']
            c.put(y, rect.x, '%s %s' % (mark, pad(app.t('ui_ch_accent_' + accent), name_w)), 'swatch_' + accent)
            x = rect.x + 3 + name_w
            if x + 14 <= rect.x + rect.w:
                c.bar(y, x, 10, 0.7, style='swatch_' + accent)
                x += 11
            sample = '[ %s ]' % app.t('ui_accent_sample')
            if x + text_width(sample) <= rect.x + rect.w:
                c.put(y, x, sample, 'swatch_' + accent)


# ---------------------------------------------------------------------------
def perform_action(app, key, screen):
    t = app.t
    if key == 'category_modes':
        app.switch(SCREENS.index('categories'))
    elif key == 'reset_modes':
        if not app.modes.overridden():
            app.notify(t('ui_modes_none'), 'status')
            return

        def done(a, v):
            if v == 'run':
                try:
                    a.modes.reset()
                    a.notify(a.t('ui_modes_reset'), 'status_ok')
                except OSError as exc:
                    a.notify(a.t('ui_error', message=plain(exc)), 'status_warn')
        app.open_dialog(ConfirmDialog(t('ui_set_reset_modes'), t('ui_confirm_reset_modes', count=app.modes.overridden()),
                                      t('ui_btn_reset'), t('ui_btn_cancel'), done))
    elif key == 'excludes':
        excludes_dialog(app)
    elif key == 'check_updates':
        app.check_updates(origin='settings')
    elif key == 'prune_now':
        app.request_action('prune_artifacts')
    elif key == 'schedule':
        if app.schedule().get('state') == 'on':
            app.request_action('schedule', 'remove')
        else:
            app.request_action('schedule', 'install', ['--time', app.settings.get('schedule_time')])
    elif key in ('export', 'import'):
        default = os.path.join(app.home, 'macos-cleanup-settings.json')
        app.open_dialog(InputDialog(t('ui_set_' + key), t('ui_%s_prompt' % key), '> ',
                                    do_export if key == 'export' else do_import, initial=default,
                                    ok_label=t('ui_btn_apply'), cancel_label=t('ui_btn_cancel')))
    elif key == 'reset':
        def done_reset(a, v):
            if v == 'run':
                try:
                    a.settings.reset()
                    a.theme_dirty = True
                    a.notify(a.t('ui_reset_done'), 'status_ok')
                except OSError as exc:
                    a.notify(a.t('ui_error', message=plain(exc)), 'status_warn')
        app.open_dialog(ConfirmDialog(t('ui_set_reset'), t('ui_reset_confirm'), t('ui_set_reset'), t('ui_btn_cancel'), done_reset))


def excludes_dialog(app):
    """Add or remove excluded paths (excludes.txt)."""
    t = app.t
    paths = ts.read_excludes(app.config_dir)
    entries = [(t('ui_excludes_add'), '__add__')] + [(p, p) for p in paths]
    if not paths:
        entries.append((t('ui_excludes_empty'), None))

    def chosen(a, value):
        if value is None:
            return
        if value == '__add__':
            def add(a2, text):
                if text in (None, 'timeout'):
                    return
                try:
                    ts.add_exclude(a2.config_dir, text.strip())
                    a2.reload_excludes()
                    a2.notify(a2.t('ui_exclude_saved', path=text.strip()), 'status_ok')
                except (OSError, ValueError) as exc:
                    a2.notify(a2.t('ui_error', message=plain(exc)), 'status_warn')
            a.open_dialog(InputDialog(a.t('ui_excludes_add'), a.t('ui_excludes_prompt'), '> ', add,
                                      validate=lambda s: '' if ts.valid_exclude(s) else a.t('ui_exclude_invalid'),
                                      ok_label=a.t('ui_btn_apply'), cancel_label=a.t('ui_btn_cancel')))
            return

        def remove(a2, v):
            if v == 'run':
                try:
                    ts.remove_exclude(a2.config_dir, value)
                    a2.reload_excludes()
                    a2.notify(a2.t('ui_exclude_removed', path=value), 'status_ok')
                except OSError as exc:
                    a2.notify(a2.t('ui_error', message=plain(exc)), 'status_warn')
        a.open_dialog(ConfirmDialog(a.t('ui_excludes_remove'), a.t('ui_excludes_remove_body', path=value),
                                    a.t('ui_btn_remove'), a.t('ui_btn_cancel'), remove))
    app.open_dialog(ChoiceDialog(t('ui_set_excludes'), entries, chosen, body=t('ui_set_excludes_help')))


def do_export(app, path):
    if not path or path == 'timeout':
        return
    path = os.path.expanduser(path.strip())
    try:
        data = app.settings.export_data(app.modes.export_rows())
        ts.atomic_write(path, (json.dumps(data, indent=1, ensure_ascii=False) + '\n').encode('utf-8'))
        app.notify(app.t('ui_exported', path=path), 'status_ok')
    except OSError as exc:
        app.notify(app.t('ui_error', message=plain(exc)), 'status_warn')


def do_import(app, path):
    if not path or path == 'timeout':
        return
    path = os.path.expanduser(path.strip())
    try:
        raw = ts.read_private(path, 1024 * 1024)
        if raw is None:
            raise OSError('missing')
        data = json.loads(raw.decode('utf-8'))
        rows = app.settings.import_data(data)
        count = app.modes.import_rows(rows)
        app.theme_dirty = True
        app.notify(app.t('ui_imported', count=count), 'status_ok')
    except (OSError, ValueError) as exc:
        app.notify(app.t('ui_error', message=plain(exc)), 'status_warn')
