"""Minimal markdown for the report viewer: the subset the engine's reports use (headings, bold, inline code,
bullet lists, fenced code blocks, horizontal rules). Output is a list of (text, style) rows already wrapped
to a width; no library, no terminal control, nothing from the file reaches the terminal unfiltered."""
import re

from tui_widgets import plain, wrap

BOLD = re.compile(r'\*\*(.+?)\*\*|__(.+?)__')
CODE = re.compile(r'`([^`]+)`')
HEADING = re.compile(r'(#{1,6})\s+(.*)')
BULLET = re.compile(r'(\s*)[-*+]\s+(.*)')
NUMBERED = re.compile(r'(\s*)(\d+)[.)]\s+(.*)')
RULE = re.compile(r'\s*([-*_])(\s*\1){2,}\s*')
FENCE = re.compile(r'\s*(```|~~~)')


def inline(text):
    """Drop the emphasis markers: the viewer has one text style per row, the words stay."""
    text = BOLD.sub(lambda m: m.group(1) or m.group(2), text)
    return CODE.sub(lambda m: m.group(1), text)


def render(markdown, width, glyphs):
    """[(text, style)] for ``markdown`` at ``width`` columns. Styles: strong (title), accent (heading),
    base (text, list, code), border (rule), warn (a line that starts with a warning sign)."""
    out = []
    in_code = False
    width = max(10, width)
    bullet = '•' if glyphs.get('tl') != '+' else '*'
    rule = glyphs.get('h', '-')
    blank = True
    for raw in str(markdown).splitlines():
        line = plain(raw.rstrip(), 2000)
        if FENCE.match(line):
            in_code = not in_code
            continue
        if in_code:
            text = '    ' + line
            for i in range(0, max(1, len(text)), width):          # code keeps its spacing: cut, never re-flow
                out.append((text[i:i + width], 'base'))
            blank = False
            continue
        if not line.strip():
            if not blank:
                out.append(('', 'base'))
            blank = True
            continue
        blank = False
        if RULE.fullmatch(line):
            out.append((rule * min(width, 40), 'border'))
            continue
        match = HEADING.fullmatch(line)
        if match:
            if out and out[-1][0] != '':
                out.append(('', 'base'))
            style = 'strong' if len(match.group(1)) == 1 else 'accent'
            for part in wrap(inline(match.group(2)), width) or ['']:
                out.append((part, style))
            continue
        match = BULLET.fullmatch(line)
        numbered = NUMBERED.fullmatch(line) if not match else None
        if match or numbered:
            indent = len(match.group(1) if match else numbered.group(1))
            mark = bullet if match else numbered.group(2) + '.'
            body = inline(match.group(2) if match else numbered.group(3))
            lead = ' ' * min(indent, 8) + mark + ' '
            style = 'warn' if body.startswith('⚠') else 'base'
            parts = wrap(body, max(8, width - len(lead))) or ['']
            out.append((lead + parts[0], style))
            out.extend((' ' * len(lead) + p, style) for p in parts[1:])
            continue
        style = 'warn' if line.lstrip().startswith('⚠') else 'base'
        for part in wrap(inline(line), width) or ['']:
            out.append((part, style))
    while out and out[-1][0] == '':
        out.pop()
    return out
