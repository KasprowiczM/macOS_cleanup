"""Semantic theme: glyph sets and colour styles for the terminal interface.

Styles are names ("ok", "focus_border", ...). Rendering code never picks raw
colours; this module maps names to curses attributes for 256-colour,
16-colour and NO_COLOR terminals, in a dark and a light variant.
"""
import os
import re

GLYPHS_UNICODE = dict(
    tl='╭', tr='╮', bl='╰', br='╯', h='─', v='│', tee_l='├', tee_r='┤',
    marker='▶', ok='✓', current='•', needs='!', fail='✗', stopped='■', running='⟳', pending='○', off='–',
    check_on='[✓]', check_off='[ ]', radio_on='●', radio_off='○', arrow='→', ellipsis='…',
    bar_full='█', bar_empty='─', bar_parts=('', '▏', '▎', '▍', '▌', '▋', '▊', '▉'),
    # Progress bars are one slim heavy line: the fill and the track are the same glyph and differ by colour;
    # a half-cell cap smooths the leading edge, and the travelling highlight reuses the fill glyph.
    bar_fill='━', bar_track='━', bar_cap='╸', bar_cap_r='╺', bar_pulse='━',
    spinner=('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'), expand='▾', collapse='▸',
    spark=('▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'), sep='·', up='↑', down='↓',
)
GLYPHS_ASCII = dict(
    tl='+', tr='+', bl='+', br='+', h='-', v='|', tee_l='+', tee_r='+',
    marker='>', ok='+', current='=', needs='!', fail='x', stopped='#', running='*', pending='o', off='-',
    check_on='[x]', check_off='[ ]', radio_on='(*)', radio_off='( )', arrow='->', ellipsis='...',
    bar_full='#', bar_empty='.', bar_parts=('',) * 8,
    bar_fill='#', bar_track='-', bar_cap='', bar_cap_r='', bar_pulse='=',
    spinner=('|', '/', '-', '\\'), expand='v', collapse='>',
    spark=('_', '_', '.', '.', '-', '-', '^', '^'), sep='|', up='^', down='v',
)

ACCENTS = ('blue', 'violet', 'amber', 'green', 'rose', 'graphite')
STYLES = ('base', 'muted', 'accent', 'ok', 'warn', 'fail', 'sel', 'sel_focus', 'border', 'focus_border',
          'title', 'focus_title', 'header', 'header_accent', 'keybar', 'keybar_key', 'btn', 'btn_focus',
          'btn_primary', 'bar_track', 'bar_run', 'bar_ok', 'bar_warn', 'bar_fail', 'bar_pulse', 'dialog', 'dialog_border', 'input',
          'status', 'status_ok', 'status_warn', 'tab', 'tab_active', 'strong')

THEME_CHOICES = ('auto', 'dark', 'light')
OSC11_TIMEOUT = 0.25

# 256-colour palette: (dark, light)
# Accents are deliberately desaturated so none reads as a status colour:
# blue #5f87af, violet #8787d7, amber #d7af87, green (sage) #87af87, rose #d7879f, graphite #bcbcbc.
_ACCENT_256 = dict(blue=(67, 25), violet=(104, 61), amber=(180, 94), green=(108, 65), rose=(175, 132),
                   graphite=(250, 240))
_ACCENT_16 = dict(blue=4, violet=5, amber=3, green=2, rose=5, graphite=7)
# Semantic colours stay independent of the accent: bright ok green, amber warn, red fail.
# ``base`` text is the terminal's own foreground (default colour) in BOTH variants, so body text can never
# be washed out; ``fg_on_bg`` / ``strong_on_bg`` are for the few styles that paint their own background
# (header, selection, dialog), where the terminal foreground cannot be trusted.
# ``muted`` is only for secondary hints and keeps a contrast of at least 4.5:1 on a plain background
# (dark 247 = #9e9e9e on black, light 240 = #585858 on white).
_SEM_256 = dict(ok=(77, 28), warn=(214, 130), fail=(203, 160), muted=(247, 240), fg_on_bg=(253, 236),
                strong_on_bg=(255, 232), sel_bg=(237, 253), header_bg=(236, 254), dialog_bg=(235, 255))
# Progress bar track: a quiet line the fill runs over (dark 238, light 253).
_BAR_TRACK_256 = (238, 253)
# The travelling highlight of a running bar: per accent, a brighter colour than the accent on the dark scheme
# and a lighter one that still reads on white on the light scheme.
_PULSE_256 = dict(blue=(75, 33), violet=(147, 98), amber=(222, 100), green=(151, 28), rose=(211, 168),
                  graphite=(255, 244))


GLYPHS_UNICODE_MONO = dict(GLYPHS_UNICODE, bar_track='─')   # no colours: the track must differ by shape


def glyphs(ascii_only=False, mono=False):
    if ascii_only:
        return GLYPHS_ASCII
    return GLYPHS_UNICODE_MONO if mono else GLYPHS_UNICODE


def parse_osc11(reply):
    """'dark' or 'light' from a terminal's answer to the OSC 11 background query
    (``ESC ] 11 ; rgb:RRRR/GGGG/BBBB BEL``, 1 to 4 hex digits per channel, or ``#RRGGBB``); None when
    the text holds no colour."""
    if not isinstance(reply, str):
        return None
    match = re.search(r'rgb:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})', reply)
    if match:
        parts = match.groups()
        channels = [int(p, 16) / float((16 ** len(p)) - 1) for p in parts]
    else:
        match = re.search(r'#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})', reply)
        if not match:
            return None
        channels = [int(p, 16) / 255.0 for p in match.groups()]
    luminance = 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    return 'light' if luminance > 0.5 else 'dark'


def parse_colorfgbg(value):
    """'dark' or 'light' from COLORFGBG ('15;0', '0;default;15'): the last field is the background
    colour number; 0-6 and 8 are dark, 7 and 9-15 are light."""
    if not isinstance(value, str) or not value.strip():
        return None
    last = value.strip().split(';')[-1]
    if not last.isdigit():
        return None
    number = int(last)
    if number > 15:
        return None
    return 'dark' if number in (0, 1, 2, 3, 4, 5, 6, 8) else 'light'


def query_terminal_background(timeout=OSC11_TIMEOUT, fd=None):
    """Ask the terminal for its background colour (OSC 11) and return 'dark', 'light' or None. Must run
    before curses takes the terminal. Needs a real terminal on stdin and gives up after ``timeout``."""
    import select
    import sys
    import termios
    import tty
    try:
        fd = sys.stdin.fileno() if fd is None else fd
        if not os.isatty(fd) or not os.isatty(sys.stdout.fileno()):
            return None
        saved = termios.tcgetattr(fd)
    except (OSError, ValueError, termios.error, AttributeError):
        return None
    reply = ''
    try:
        tty.setcbreak(fd)
        os.write(sys.stdout.fileno(), b'\x1b]11;?\x07')
        deadline = timeout
        while deadline > 0:
            ready, _, _ = select.select([fd], [], [], deadline)
            if not ready:
                break
            chunk = os.read(fd, 64).decode('latin-1')
            reply += chunk
            if '\x07' in reply or '\x1b\\' in reply:
                break
            deadline = timeout / 2.0
    except (OSError, ValueError):
        return None
    finally:
        try:
            termios.tcsetattr(fd, termios.TCSAFLUSH, saved)
        except (termios.error, OSError):
            pass
    return parse_osc11(reply)


def detect_background(env=None, query=None):
    """Light or dark terminal: the OSC 11 answer first, then COLORFGBG, then 'dark' (the fallback is safe
    because body text always uses the terminal's own foreground)."""
    env = os.environ if env is None else env
    asked = (query or query_terminal_background)() if env.get('TERM', '') not in ('dumb', '') else None
    return asked or parse_colorfgbg(env.get('COLORFGBG')) or 'dark'


def resolve_theme(setting, detected=None, env=None):
    """'dark' or 'light' for a setting value (auto, dark, light) given a detection result."""
    if setting in ('dark', 'light'):
        return setting
    env = os.environ if env is None else env
    return detected or parse_colorfgbg(env.get('COLORFGBG')) or 'dark'


def color_disabled(env=None):
    env = os.environ if env is None else env
    return 'NO_COLOR' in env or env.get('TERM', '') in ('dumb', '')


def wants_ascii(env=None, setting=False):
    env = os.environ if env is None else env
    if setting:
        return True
    encoding = (env.get('LC_ALL') or env.get('LC_CTYPE') or env.get('LANG') or '').upper()
    return env.get('TERM', '') in ('linux', 'vt100', 'vt220') or (bool(encoding) and 'UTF' not in encoding and encoding not in ('C', 'POSIX'))


class Theme:
    """Resolves style names to curses attributes. Pure data when curses is absent."""

    def __init__(self, name='dark', accent='blue', no_color=False):
        self.name = name if name in ('dark', 'light') else resolve_theme(name)
        self.accent = accent if accent in ACCENTS else 'blue'
        self.no_color = no_color
        self.attrs = {}

    def setup(self, curses):
        """Initialise colour pairs. Safe to call again after a theme change."""
        A = curses
        self.attrs = {}
        colors = 0
        if not self.no_color:
            try:
                if curses.has_colors():
                    curses.start_color()
                    try:
                        curses.use_default_colors()
                        bg = -1
                    except curses.error:
                        bg = curses.COLOR_BLACK
                    colors = curses.COLORS
            except curses.error:
                colors = 0
        bold, dim, rev, und = A.A_BOLD, A.A_DIM, A.A_REVERSE, A.A_UNDERLINE
        if colors < 8:
            mono = dict(base=0, muted=0, accent=bold, ok=0, warn=bold, fail=bold | und, sel=rev,
                        sel_focus=rev | bold, border=dim, focus_border=bold, title=0, focus_title=bold | rev,
                        header=rev, header_accent=rev | bold, keybar=rev, keybar_key=rev | bold, btn=0,
                        btn_focus=rev | bold, btn_primary=bold, bar_track=dim, bar_run=bold, bar_ok=bold,
                        bar_warn=bold, bar_fail=bold, bar_pulse=bold | rev, dialog=0, dialog_border=bold, input=und, status=0, status_ok=bold,
                        status_warn=bold, tab=dim, tab_active=rev | bold, strong=bold)
            self.attrs = mono
            return self
        light = 1 if self.name == 'light' else 0
        pairs = {}
        nxt = [1]

        def pair(fg, bgc=None):
            key = (fg, bg if bgc is None else bgc)
            if key not in pairs:
                try:
                    curses.init_pair(nxt[0], key[0], key[1])
                except curses.error:
                    return 0
                pairs[key] = curses.color_pair(nxt[0])
                nxt[0] += 1
            return pairs[key]

        if colors >= 256:
            acc = _ACCENT_256[self.accent][light]
            s = {k: v[light] for k, v in _SEM_256.items()}
            c = dict(acc=acc, ok=s['ok'], warn=s['warn'], fail=s['fail'], muted=s['muted'], base=-1,
                     strong=-1, fg_bg=s['fg_on_bg'], strong_bg=s['strong_on_bg'], sel_bg=s['sel_bg'],
                     header_bg=s['header_bg'], dialog_bg=s['dialog_bg'], on_acc=(234 if not light else 255),
                     track=_BAR_TRACK_256[light], pulse=_PULSE_256[self.accent][light])
            dbg = c['dialog_bg']
            pulse = pair(c['pulse'])
        else:
            acc = _ACCENT_16[self.accent]
            c = dict(acc=acc, ok=2, warn=3, fail=1, base=-1, strong=-1, fg_bg=-1, strong_bg=-1,
                     muted=(7 if not light else (8 if colors >= 16 else 0)),
                     sel_bg=bg, header_bg=bg, dialog_bg=bg, on_acc=0, track=(8 if colors >= 16 and not light else 7))
            dbg = bg
            pulse = pair(c['acc']) | bold
        self.attrs = dict(
            base=pair(c['base']), muted=pair(c['muted']),
            accent=pair(c['acc']), ok=pair(c['ok']), warn=pair(c['warn']), fail=pair(c['fail']) | bold,
            sel=(pair(c['strong_bg'], c['sel_bg']) if colors >= 256 else rev),
            sel_focus=(pair(c['acc'], c['sel_bg']) | bold if colors >= 256 else rev | bold),
            border=pair(c['muted']), focus_border=pair(c['acc']) | bold,
            title=pair(c['base']), focus_title=pair(c['acc']) | bold,
            header=pair(c['fg_bg'], c['header_bg']), header_accent=pair(c['acc'], c['header_bg']) | bold,
            keybar=pair(c['fg_bg'], c['header_bg']), keybar_key=pair(c['acc'], c['header_bg']) | bold,
            btn=pair(c['base']), btn_focus=pair(c['on_acc'], c['acc']) | bold, btn_primary=pair(c['acc']) | bold,
            bar_track=pair(c['track']), bar_run=pair(c['acc']), bar_ok=pair(c['ok']), bar_warn=pair(c['warn']),
            bar_fail=pair(c['fail']), bar_pulse=pulse,
            dialog=pair(c['fg_bg'], dbg), dialog_border=pair(c['acc'], dbg) | bold,
            input=pair(c['strong_bg'], c['sel_bg']) | und,
            status=pair(c['base']), status_ok=pair(c['ok']) | bold, status_warn=pair(c['warn']) | bold,
            tab=pair(c['fg_bg']), tab_active=pair(c['on_acc'], c['acc']) | bold, strong=pair(c['strong']) | bold,
        )
        # Swatches for the accent preview in Settings.
        for name in ACCENTS:
            fg = _ACCENT_256[name][light] if colors >= 256 else _ACCENT_16[name]
            self.attrs['swatch_' + name] = pair(fg) | bold
        return self

    def attr(self, style):
        return self.attrs.get(style, 0)
