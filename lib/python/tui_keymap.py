"""Key names, bindings and the key bar generated from the active keymap."""
import curses

from tui_widgets import text_width

_SPECIAL = {
    curses.KEY_UP: 'up', curses.KEY_DOWN: 'down', curses.KEY_LEFT: 'left', curses.KEY_RIGHT: 'right',
    curses.KEY_PPAGE: 'pgup', curses.KEY_NPAGE: 'pgdn', curses.KEY_HOME: 'home', curses.KEY_END: 'end',
    curses.KEY_ENTER: 'enter', curses.KEY_BACKSPACE: 'backspace', curses.KEY_DC: 'del',
    curses.KEY_BTAB: 'btab', curses.KEY_RESIZE: 'resize', curses.KEY_MOUSE: 'mouse',
    curses.KEY_F1: 'f1', curses.KEY_F10: 'f10',
}
_CHARS = {'\n': 'enter', '\r': 'enter', '\t': 'tab', '\x1b': 'esc', ' ': 'space', '\x7f': 'backspace',
          '\x08': 'backspace', '\x15': 'ctrl-u', '\x03': 'ctrl-c', '\x0c': 'ctrl-l'}
# What the key bar shows for a key name.
DISPLAY = {'up': '↑', 'down': '↓', 'left': '←', 'right': '→', 'enter': 'Enter', 'tab': 'Tab', 'btab': 'S-Tab',
           'esc': 'Esc', 'space': 'Space', 'pgup': 'PgUp', 'pgdn': 'PgDn', 'f1': 'F1', 'backspace': '⌫',
           'del': 'Del', 'home': 'Home', 'end': 'End'}
DISPLAY_ASCII = dict(DISPLAY, up='Up', down='Dn', left='Lt', right='Rt', backspace='Bksp')


def key_name(key):
    """Normalise a curses key (int or str) to a stable name."""
    if isinstance(key, int):
        if key in _SPECIAL:
            return _SPECIAL[key]
        if 0 <= key < 0x110000:
            key = chr(key)
        else:
            return 'unknown'
    if key in _CHARS:
        return _CHARS[key]
    if len(key) == 1 and key.isprintable():
        return key
    return 'unknown'


class Binding:
    __slots__ = ('keys', 'label', 'action', 'show', 'display')

    def __init__(self, keys, label, action, show=True, display=None):
        self.keys = tuple(keys)
        self.label, self.action, self.show, self.display = label, action, show, display


def key_display(binding, ascii_only=False):
    if binding.display:
        return binding.display
    table = DISPLAY_ASCII if ascii_only else DISPLAY
    names = [table.get(k, k) for k in binding.keys]
    if set(binding.keys) == {'up', 'down'}:
        return 'Up/Dn' if ascii_only else '↑↓'
    if set(binding.keys) == {'left', 'right'}:
        return 'Lt/Rt' if ascii_only else '←→'
    return '/'.join(names[:2])


def lookup(bindings, name):
    for binding in bindings:
        if name in binding.keys:
            return binding
    return None


def keybar_items(bindings, translate, width, ascii_only=False):
    """Pick bindings that fit in ``width`` without clipping any label.

    Bindings are in priority order; lower-priority ones are dropped whole."""
    items, used = [], 0
    seen = set()
    for binding in bindings:
        if not binding.show or binding.label in seen:
            continue
        key = key_display(binding, ascii_only)
        label = translate(binding.label)
        size = text_width(key) + 1 + text_width(label) + 3
        if used + size > width:
            continue
        seen.add(binding.label)
        items.append((key, label, binding.action))
        used += size
    return items
