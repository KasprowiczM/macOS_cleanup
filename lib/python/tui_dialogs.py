"""Modal dialogs: confirm, choice popup, number/text input, engine prompts and
the masked password dialog. A dialog owns the keyboard while it is open.

``ConfirmDialog`` is the only gate in front of a mutating action: it states
what will happen and whether it can be undone, and its default button cancels."""
import time

from tui_keymap import Binding
from tui_widgets import Rect, clip, text_width, wrap


class Dialog:
    """Buttons: list of (label, value). ``on_done(app, value)`` gets the value,
    or ``cancel_value`` for Esc, or 'timeout' when a countdown expires."""
    kind = 'confirm'

    def __init__(self, title, body, buttons, on_done, default=0, cancel_value=None, timeout=None,
                 default_label=None, ident=None, help_key='ui_help_dialog'):
        self.title, self.body, self.buttons = title, body, list(buttons)
        self.on_done, self.selected = on_done, max(0, min(default, len(self.buttons) - 1))
        self.cancel_value = cancel_value
        self.timeout = timeout
        self.opened = time.monotonic()
        self.default_label = default_label
        self.ident = ident
        self.help_key = help_key
        self.closed = False

    # -- behaviour ---------------------------------------------------------
    def remaining(self):
        if not self.timeout:
            return None
        return max(0, int(round(self.timeout - (time.monotonic() - self.opened))))

    def tick(self, app):
        if self.timeout and not self.closed and time.monotonic() - self.opened >= self.timeout:
            self.finish(app, 'timeout')

    def finish(self, app, value):
        if self.closed:
            return
        self.closed = True
        if app.dialog is self:
            app.dialog = None
        if self.on_done:
            self.on_done(app, value)

    def bindings(self):
        return [Binding(('left', 'right'), 'ui_key_choose', 'move'), Binding(('enter',), 'ui_key_select', 'enter'),
                Binding(('esc',), 'ui_key_close', 'esc'), Binding(('tab', 'btab'), 'ui_key_choose', 'move', show=False)]

    def key(self, app, name):
        if name in ('left', 'btab', 'up'):
            self.selected = (self.selected - 1) % len(self.buttons)
        elif name in ('right', 'tab', 'down'):
            self.selected = (self.selected + 1) % len(self.buttons)
        elif name in ('enter', 'space'):
            self.finish(app, self.buttons[self.selected][1])
        elif name == 'esc':
            self.finish(app, self.cancel_value)
        else:
            return self.shortcut(app, name)
        return True

    def shortcut(self, app, name):
        for label, value in self.buttons:
            if len(name) == 1 and label[:1].lower() == name.lower():
                self.finish(app, value)
                return True
        return False

    def click(self, app, value):
        if isinstance(value, int) and 0 <= value < len(self.buttons):
            self.selected = value
            self.finish(app, self.buttons[value][1])

    # -- drawing -------------------------------------------------------------
    def body_lines(self, width):
        return wrap(self.body, width) if self.body else []

    def extra_lines(self, app, width):
        return []

    def size(self, canvas):
        width = min(canvas.w - 4, max(44, min(72, max([text_width(self.title) + 8] + [text_width(l) + 6 for l in self.body.split('\n')]))))
        return max(20, width)

    def render(self, app, canvas):
        width = self.size(canvas)
        inner = width - 4
        lines = self.body_lines(inner)
        extra = self.extra_lines(app, inner)
        height = min(canvas.h - 2, len(lines) + len(extra) + 5)
        y = max(0, (canvas.h - height) // 2)
        x = max(0, (canvas.w - width) // 2)
        rect = Rect(y, x, height, width)
        canvas.fill(y, x, height, width, 'dialog')
        canvas.box(rect, self.title, focused=True, style='dialog_border')
        canvas.region(y, x, height, width, ('dialog', None))
        row = y + 1
        room = height - 4
        for line in (lines + extra)[:room]:
            if isinstance(line, tuple):
                canvas.put(row, x + 2, line[0], line[1], inner)
            else:
                canvas.put(row, x + 2, line, 'dialog', inner)
            row += 1
        self.render_buttons(app, canvas, y + height - 2, x + 2, inner)
        return rect

    def render_buttons(self, app, canvas, y, x, width):
        total = sum(text_width(label) + 6 for label, _ in self.buttons)
        cx = x + max(0, (width - total) // 2) if total <= width else x
        for index, (label, _) in enumerate(self.buttons):
            cx = canvas.button(y, cx, label, focused=index == self.selected, action=('dialog', index)) + 2
        left = self.remaining()
        if left is not None and self.default_label:
            note = app.t('ui_dlg_countdown', answer=self.default_label, seconds=left)
            canvas.put(y - 1, x + max(0, width - text_width(note)), note, 'muted', width)


class ConfirmDialog(Dialog):
    """Explicit confirmation of a mutating action. The safe button (cancel) is
    the default; only the run button's value ``'run'`` lets the caller proceed.
    ``extra`` buttons (label, value) may sit between run and cancel."""
    kind = 'mutation'

    def __init__(self, title, body, run_label, cancel_label, on_done, extra=(), ident=None):
        buttons = [(run_label, 'run')] + list(extra) + [(cancel_label, None)]
        Dialog.__init__(self, title, body, buttons, on_done, default=len(buttons) - 1, cancel_value=None,
                        ident=ident, help_key='ui_help_confirm')

    def shortcut(self, app, name):
        return False          # no one-letter shortcut may confirm a mutation


class ChoiceDialog(Dialog):
    """Vertical list; entries are (label, value) or (header_text, None)."""
    kind = 'choice'

    def __init__(self, title, entries, on_done, current=None, cancel_value=None, body=''):
        self.entries = list(entries)
        selectable = [i for i, (_, v) in enumerate(self.entries) if v is not None]
        self.current = current
        start = next((i for i in selectable if self.is_current(self.entries[i][1])), selectable[0] if selectable else 0)
        Dialog.__init__(self, title, body, [], on_done, cancel_value=cancel_value)
        self.index = start
        self.current = current

    def is_current(self, value):
        if isinstance(self.current, frozenset):
            return value in self.current
        return value is not None and value == self.current

    def bindings(self):
        return [Binding(('up', 'down'), 'ui_key_move', 'move'), Binding(('enter',), 'ui_key_select', 'enter'),
                Binding(('esc',), 'ui_key_close', 'esc')]

    def _step(self, delta):
        n = len(self.entries)
        i = self.index
        for _ in range(n):
            i = (i + delta) % n
            if self.entries[i][1] is not None:
                self.index = i
                return

    def key(self, app, name):
        if name in ('up', 'btab', 'left'):
            self._step(-1)
        elif name in ('down', 'tab', 'right'):
            self._step(1)
        elif name in ('enter', 'space'):
            self.finish(app, self.entries[self.index][1])
        elif name == 'esc':
            self.finish(app, self.cancel_value)
        else:
            return False
        return True

    def click(self, app, value):
        if isinstance(value, int) and 0 <= value < len(self.entries) and self.entries[value][1] is not None:
            self.index = value
            self.finish(app, self.entries[value][1])

    def size(self, canvas):
        widest = max([text_width(self.title) + 8] + [text_width(label) + 10 for label, _ in self.entries]
                     + [min(60, text_width(self.body) + 6)])
        return max(24, min(canvas.w - 4, max(36, widest)))

    def render(self, app, canvas):
        g = canvas.g
        width = self.size(canvas)
        inner = width - 4
        body = wrap(self.body, inner) if self.body else []
        height = min(canvas.h - 2, len(self.entries) + len(body) + 2 + (1 if body else 0))
        y = max(0, (canvas.h - height) // 2)
        x = max(0, (canvas.w - width) // 2)
        canvas.fill(y, x, height, width, 'dialog')
        canvas.box(Rect(y, x, height, width), self.title, focused=True, style='dialog_border')
        canvas.region(y, x, height, width, ('dialog', None))
        row = y + 1
        for line in body:
            canvas.put(row, x + 2, line, 'dialog', inner)
            row += 1
        if body:
            row += 1
        visible = height - 2 - (len(body) + 1 if body else 0)
        offset = max(0, self.index - visible + 1)
        for i, (label, value) in enumerate(self.entries[offset:offset + visible], offset):
            if value is None:
                canvas.put(row, x + 2, label, 'dialog', inner)
            else:
                on = self.is_current(value)
                mark = g['radio_on'] if on else g['radio_off']
                focused = i == self.index
                text = '%s %s %s' % (g['marker'] if focused else ' ', mark, label)
                canvas.put(row, x + 2, clip(text, inner, g['ellipsis']), 'sel_focus' if focused else 'dialog', inner)
                if focused:
                    canvas.restyle(row, x + 2, inner, 'sel_focus')
                canvas.region(row, x + 1, 1, width - 2, ('dialog', i))
            row += 1


class MultiDialog(Dialog):
    """Check list: Space ticks, Enter applies the ticked values (at least one),
    Esc cancels. ``on_done(app, tuple_of_values)``; ``None`` when cancelled."""
    kind = 'multi'

    def __init__(self, title, entries, on_done, checked=(), body=''):
        self.entries = list(entries)
        self.checked = set(checked)
        Dialog.__init__(self, title, body, [], on_done, cancel_value=None)
        self.index = 0
        self.error = ''

    def bindings(self):
        return [Binding(('up', 'down'), 'ui_key_move', 'move'), Binding(('space',), 'ui_key_toggle', 'toggle'),
                Binding(('enter',), 'ui_key_select', 'enter'), Binding(('esc',), 'ui_key_close', 'esc')]

    def key(self, app, name):
        n = len(self.entries)
        if name in ('up', 'btab', 'left'):
            self.index = (self.index - 1) % n
        elif name in ('down', 'tab', 'right'):
            self.index = (self.index + 1) % n
        elif name == 'space':
            value = self.entries[self.index][1]
            self.checked.symmetric_difference_update({value})
            self.error = ''
        elif name == 'enter':
            if not self.checked:
                self.error = app.t('ui_multi_need_one')
                return True
            self.finish(app, tuple(v for _, v in self.entries if v in self.checked))
        elif name == 'esc':
            self.finish(app, None)
        else:
            return False
        return True

    def click(self, app, value):
        if isinstance(value, int) and 0 <= value < len(self.entries):
            self.index = value
            self.key(app, 'space')

    def size(self, canvas):
        widest = max([text_width(self.title) + 8] + [text_width(label) + 10 for label, _ in self.entries])
        return max(30, min(canvas.w - 4, max(40, widest)))

    def render(self, app, canvas):
        g = canvas.g
        width = self.size(canvas)
        inner = width - 4
        body = wrap(self.body, inner) if self.body else []
        height = min(canvas.h - 2, len(self.entries) + len(body) + 4 + (1 if self.error else 0))
        y = max(0, (canvas.h - height) // 2)
        x = max(0, (canvas.w - width) // 2)
        canvas.fill(y, x, height, width, 'dialog')
        canvas.box(Rect(y, x, height, width), self.title, focused=True, style='dialog_border')
        canvas.region(y, x, height, width, ('dialog', None))
        row = y + 1
        for line in body:
            canvas.put(row, x + 2, line, 'dialog', inner)
            row += 1
        visible = height - 2 - len(body) - (1 if self.error else 0)
        offset = max(0, self.index - visible + 1)
        for i, (label, value) in enumerate(self.entries[offset:offset + visible], offset):
            focused = i == self.index
            mark = g['check_on'] if value in self.checked else g['check_off']
            text = '%s %s %s' % (g['marker'] if focused else ' ', mark, label)
            canvas.put(row, x + 2, clip(text, inner, g['ellipsis']), 'sel_focus' if focused else 'dialog', inner)
            if focused:
                canvas.restyle(row, x + 2, inner, 'sel_focus')
            canvas.region(row, x + 1, 1, width - 2, ('dialog', i))
            row += 1
        if self.error:
            canvas.put(row, x + 2, self.error, 'fail', inner)


class InputDialog(Dialog):
    """Single-line input; ``secret`` masks it. The value lives only here and
    is wiped as soon as the dialog closes."""
    kind = 'input'

    def __init__(self, title, body, label, on_done, secret=False, validate=None, initial='', help_key='ui_help_dialog',
                 ok_label='OK', cancel_label='Cancel', ident=None, timeout=None):
        Dialog.__init__(self, title, body, [(ok_label, 'ok'), (cancel_label, None)], on_done, ident=ident,
                        help_key=help_key, timeout=timeout)
        self.label, self.secret, self.validate = label, secret, validate
        self.value = initial
        self.error = ''

    def bindings(self):
        return [Binding((), 'ui_key_type', 'type', display='abc'), Binding(('enter',), 'ui_key_send', 'enter'),
                Binding(('esc',), 'ui_key_close', 'esc'), Binding(('backspace',), 'ui_key_clear', 'backspace')]

    def finish(self, app, value):
        if value == 'ok':
            text = self.value
            if self.validate:
                problem = self.validate(text)
                if problem:
                    self.error = problem
                    self.closed = False
                    return
            result = text
        else:
            result = None if value != 'timeout' else 'timeout'
        self.value = ''          # never keep the secret around
        Dialog.finish(self, app, result)

    def key(self, app, name):
        if name == 'enter':
            self.finish(app, 'ok' if self.selected == 0 else None)
        elif name == 'esc':
            self.finish(app, None)
        elif name == 'backspace':
            self.value = self.value[:-1]
        elif name == 'ctrl-u':
            self.value = ''
        elif name in ('tab', 'btab', 'left', 'right'):
            self.selected = 1 - self.selected
        elif name == 'space':
            self.value += ' '
        elif len(name) == 1:
            if len(self.value) < 512:
                self.value += name
        else:
            return False
        return True

    def text_input(self, text):
        self.value = (self.value + text)[:512]

    def extra_lines(self, app, width):
        shown = ('•' if app.glyphs['tl'] != '+' else '*') * len(self.value) if self.secret else self.value
        field = clip(self.label + shown + '▏', width) if app.glyphs['tl'] != '+' else clip(self.label + shown + '_', width)
        lines = ['', (field, 'input')]
        if self.error:
            lines.append((self.error, 'fail'))
        return lines


def prompt_dialog(app, prompt):
    """Build the dialog for an engine prompt event (or a detected PTY prompt)."""
    kind = prompt.get('kind')
    text = prompt.get('text') or app.t('ui_detected_question')
    timeout = prompt.get('timeout')
    if kind == 'sudo':
        body = app.t('ui_dlg_password_why') + ('\n\n' + text if text else '')
        return InputDialog(app.t('ui_dlg_password'), body, app.t('ui_dlg_password_label'),
                           lambda a, v: a.answer_prompt(prompt, v, secret=True), secret=True,
                           help_key='ui_help_password', ok_label=app.t('ui_btn_send'),
                           cancel_label=app.t('ui_btn_cancel'), ident=prompt['id'], timeout=timeout)
    if kind == 'text':
        return InputDialog(app.t('ui_dlg_question'), text, app.t('ui_dlg_text_label'),
                           lambda a, v: a.answer_prompt(prompt, v), help_key='ui_help_dialog_text',
                           ok_label=app.t('ui_btn_send'), cancel_label=app.t('ui_btn_cancel'),
                           ident=prompt['id'], timeout=timeout)
    options = [o for o in prompt.get('options') or [] if o]
    default = prompt.get('default') or ''
    if kind == 'choice' and options:
        entries = [(o, o) for o in options]
        dlg = ChoiceDialog(app.t('ui_dlg_question'), entries, lambda a, v: a.answer_prompt(prompt, v),
                           current=default or None, body=text)
        dlg.timeout, dlg.ident = timeout, prompt['id']
        dlg.default_label = default
        return dlg
    lowered = [o.lower() for o in options]
    buttons = [(app.t('ui_btn_yes'), 'y'), (app.t('ui_btn_no'), 'n')]
    if 's' in lowered or 'skip' in lowered:
        buttons.append((app.t('ui_btn_skip'), 's' if 's' in lowered else 'skip'))
    index = next((i for i, (_, v) in enumerate(buttons) if v == default.lower()[:len(v)] and default), 1)
    label = dict((v, l) for l, v in buttons).get(default.lower(), '') if default else ''
    return Dialog(app.t('ui_dlg_question'), text, buttons, lambda a, v: a.answer_prompt(prompt, v),
                  default=index, cancel_value=None, timeout=timeout, default_label=label, ident=prompt['id'])
