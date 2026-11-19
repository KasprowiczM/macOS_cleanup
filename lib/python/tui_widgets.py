"""Off-screen canvas and drawing primitives (boxes, bars, buttons, lists).

Everything renders into a ``Canvas`` of characters plus style names, so a
frame can be dumped as text in tests and blitted to curses at runtime.
"""
import re
import unicodedata

from tui_theme import GLYPHS_UNICODE

ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]|\x1b[()][A-Z0-9]|\x1b[=>]')


def plain(value, limit=4000):
    """Printable single-line text; strips ANSI and control characters."""
    text = ANSI.sub('', str(value))[:limit]
    return ''.join(c if c.isprintable() else ' ' for c in text.replace('\t', '    '))


def char_width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ('W', 'F') else 1


def text_width(text):
    return sum(char_width(c) for c in text)


def clip_middle(text, width, ellipsis='…'):
    """Clip to a display width by cutting out the middle, so both ends of a path stay visible."""
    if width <= 0:
        return ''
    if text_width(text) <= width:
        return text
    room = width - text_width(ellipsis)
    if room < 2:
        return clip(text, width, ellipsis)
    head, tail = (room + 1) // 2, room // 2
    left, right = [], []
    used = 0
    for ch in text:
        if used + char_width(ch) > head:
            break
        left.append(ch)
        used += char_width(ch)
    used = 0
    for ch in reversed(text):
        if used + char_width(ch) > tail:
            break
        right.append(ch)
        used += char_width(ch)
    return ''.join(left) + ellipsis + ''.join(reversed(right))


def clip(text, width, ellipsis='…'):
    """Clip to a display width; adds an ellipsis only when text was cut."""
    if width <= 0:
        return ''
    if text_width(text) <= width:
        return text
    out, used, limit = [], 0, max(0, width - text_width(ellipsis))
    for ch in text:
        w = char_width(ch)
        if used + w > limit:
            break
        out.append(ch)
        used += w
    return ''.join(out) + (ellipsis if width >= text_width(ellipsis) else '')


def wrap(text, width):
    """Word-wrap into lines no wider than width; honours explicit newlines."""
    lines = []
    width = max(1, width)
    for para in str(text).split('\n'):
        line = ''
        for word in para.split(' '):
            while text_width(word) > width:
                if line:
                    lines.append(line)
                    line = ''
                cut, used = 0, 0
                for i, ch in enumerate(word):
                    if used + char_width(ch) > width:
                        break
                    used += char_width(ch)
                    cut = i + 1
                lines.append(word[:cut])
                word = word[cut:]
            candidate = word if not line else line + ' ' + word
            if text_width(candidate) <= width:
                line = candidate
            else:
                lines.append(line)
                line = word
        lines.append(line)
    return lines


def wrap_items(text, width, sep='  '):
    """Wrap a list of items separated by ``sep`` without breaking an item."""
    lines, line = [], ''
    for item in text.split(sep):
        candidate = item if not line else line + sep + item
        if text_width(candidate) <= width or not line:
            line = candidate
        else:
            lines.append(line)
            line = item
    if line:
        lines.append(line)
    return lines


def pad(text, width, align='left'):
    gap = max(0, width - text_width(text))
    if align == 'right':
        return ' ' * gap + text
    if align == 'center':
        return ' ' * (gap // 2) + text + ' ' * (gap - gap // 2)
    return text + ' ' * gap


def duration(seconds):
    if seconds is None:
        return ''
    seconds = int(max(0, seconds))
    if seconds >= 3600:
        return '%d:%02d:%02d' % (seconds // 3600, seconds // 60 % 60, seconds % 60)
    return '%d:%02d' % (seconds // 60, seconds % 60)


class Rect:
    __slots__ = ('y', 'x', 'h', 'w')

    def __init__(self, y, x, h, w):
        self.y, self.x, self.h, self.w = y, x, max(0, h), max(0, w)

    def inner(self):
        return Rect(self.y + 1, self.x + 2, self.h - 2, self.w - 4)

    def __repr__(self):
        return 'Rect(%d,%d,%d,%d)' % (self.y, self.x, self.h, self.w)


class Canvas:
    def __init__(self, height, width, glyphs=None):
        self.h, self.w = height, width
        self.g = glyphs or GLYPHS_UNICODE
        self.cells = [[' '] * width for _ in range(height)]
        self.styles = [['base'] * width for _ in range(height)]
        self.regions = []      # (y, x, h, w, action) — later entries win
        self.cursor = None

    def put(self, y, x, text, style='base', width=None):
        """Write text clipped to ``width`` (and the canvas). Returns end x."""
        if y < 0 or y >= self.h:
            return x
        limit = self.w if width is None else min(self.w, x + width)
        for ch in str(text):
            cw = char_width(ch)
            if cw == 0:
                continue
            if x + cw > limit:
                break
            if x >= 0:
                self.cells[y][x] = ch
                self.styles[y][x] = style
                if cw == 2 and x + 1 < self.w:
                    self.cells[y][x + 1] = ''
                    self.styles[y][x + 1] = style
            x += cw
        return x

    def fill(self, y, x, h, w, style='base', ch=' '):
        for row in range(max(0, y), min(self.h, y + h)):
            for col in range(max(0, x), min(self.w, x + w)):
                self.cells[row][col] = ch
                self.styles[row][col] = style

    def restyle(self, y, x, w, style):
        if 0 <= y < self.h:
            for col in range(max(0, x), min(self.w, x + w)):
                self.styles[y][col] = style

    def region(self, y, x, h, w, action):
        self.regions.append((y, x, h, w, action))

    def hit(self, y, x):
        for ry, rx, rh, rw, action in reversed(self.regions):
            if ry <= y < ry + rh and rx <= x < rx + rw:
                return action
        return None

    def lines(self):
        return [''.join(row).rstrip() for row in self.cells]

    def text(self):
        return '\n'.join(self.lines())

    def box(self, rect, title='', focused=False, right='', style=None, fill_style=None):
        """Rounded panel; the title sits in the top border. Focus adds a marker."""
        g = self.g
        y, x, h, w = rect.y, rect.x, rect.h, rect.w
        if h < 2 or w < 4:
            return
        border = style or ('focus_border' if focused else 'border')
        if fill_style:
            self.fill(y, x, h, w, fill_style)
        self.put(y, x, g['tl'] + g['h'] * (w - 2) + g['tr'], border)
        for row in range(y + 1, y + h - 1):
            self.put(row, x, g['v'], border)
            self.put(row, x + w - 1, g['v'], border)
        self.put(y + h - 1, x, g['bl'] + g['h'] * (w - 2) + g['br'], border)
        used = 0
        if title:
            label = (' %s %s ' % (g['marker'], title)) if focused else (' %s ' % title)
            label = clip(label, w - 4, g['ellipsis'])
            used = text_width(label)
            self.put(y, x + 2, label, 'focus_title' if focused else 'title')
        if right:
            r = ' %s ' % right
            if used + text_width(r) + 6 <= w:
                self.put(y, x + w - 2 - text_width(r), r, 'muted')

    def bar(self, y, x, width, fraction, phase=None, tone='run', style=None):
        """Slim progress bar: one heavy line glyph for fill and track, told apart by colour (one colour per
        state: run, ok, warn, fail; never by position), with a half-cell cap on the leading edge.

        ``phase`` is the animation counter and is given only while something runs; ``None`` keeps the bar
        still. A running determinate bar then carries a brighter 3-cell pulse travelling along its fill; with
        ``fraction`` None (nothing measurable yet) a 4-cell segment glides to and fro over the track.
        ``style`` replaces the fill colour (the accent swatches in Settings)."""
        g = self.g
        if width <= 0:
            return
        fill = style or 'bar_' + (tone if tone in ('run', 'ok', 'warn', 'fail') else 'run')
        cap, cap_r = g.get('bar_cap', ''), g.get('bar_cap_r', '')
        if fraction is None:
            for i in range(width):
                self.put(y, x + i, g['bar_track'], 'bar_track')
            seg = min(4 if width >= 10 else 3, width)
            span = width - seg
            step = (phase or 0) % (2 * span) if span else 0
            pos = step if step <= span else 2 * span - step
            for i in range(seg):
                edge = cap_r if i == 0 else cap if i == seg - 1 else ''
                self.put(y, x + pos + i, edge or g['bar_pulse'], 'bar_run')
            return
        fraction = min(1.0, max(0.0, fraction))
        halves = int(round(fraction * width * 2)) if cap else int(round(fraction * width)) * 2
        if fraction > 0:
            halves = max(1 if cap else 2, halves)
        if fraction < 1:
            halves = min(halves, 2 * width - (1 if cap else 2))
        full, half = divmod(halves, 2)
        for i in range(width):
            if i < full:
                self.put(y, x + i, g['bar_fill'], fill)
            elif i == full and half:
                self.put(y, x + i, cap, fill)
            else:
                self.put(y, x + i, g['bar_track'], 'bar_track')
        if phase is not None and tone == 'run' and full:
            lead = (phase % (full + 3)) - 3
            for i in range(max(0, lead), min(full, lead + 3)):
                self.put(y, x + i, g['bar_pulse'], 'bar_pulse')

    def button(self, y, x, label, focused=False, primary=False, action=None, disabled=False):
        # Focus is visible without colour too: "▶ Label ◀" versus "[ Label ]".
        if focused:
            text = ('> %s <' if self.g['tl'] == '+' else '▶ %s ◀') % label
        else:
            text = '[ %s ]' % label
        style = 'btn_focus' if focused else ('btn_primary' if primary else ('muted' if disabled else 'btn'))
        end = self.put(y, x, text, style)
        if action is not None:
            self.region(y, x, 1, end - x, action)
        return end


def button_width(label):
    return text_width(label) + 4


def scroll_window(selected, offset, visible, total):
    """Keep ``selected`` inside a viewport of ``visible`` rows."""
    if visible <= 0:
        return 0
    if selected < offset:
        offset = selected
    elif selected >= offset + visible:
        offset = selected - visible + 1
    return max(0, min(offset, max(0, total - visible)))
