"""A searchable, sortable, optionally grouped list of paths with sizes: the
quarantine manifest, a category's items, the report-only lists. One widget
serves all of them. It only reads; ``e`` (exclude) and ``o`` (reveal) are
requests the app confirms or performs.

The manifest reader is bounded: at most MAX_ROWS rows and MAX_BYTES bytes are
read, symlinks are never followed, and rows are decoded once.
"""
import base64
import binascii
import os

from tui_backend import open_regular
from tui_keymap import Binding
from tui_widgets import clip, pad, scroll_window, text_width

MAX_ROWS = 100000
MAX_BYTES = 48 * 1024 * 1024
SORTS = ('order', 'size', 'path', 'category')

# First matching prefix (relative to the home folder) names a category for
# manifests that carry no category column.
_GUESS = (('.Trash', 'trash'), ('Library/Logs/DiagnosticReports', 'diagnostic-reports'), ('Library/Logs', 'user-logs'),
          ('Library/Developer/Xcode/DerivedData', 'xcode-derived'), ('Library/Developer/Xcode/iOS DeviceSupport', 'device-support'),
          ('Library/Caches', 'user-caches'), ('.npm/_npx', 'npx'), ('.gradle', 'gradle'), ('.cargo', 'cargo'),
          ('Library/Caches/CocoaPods', 'cocoapods'), ('Library/Developer/Xcode/Archives', 'xcode-archives'),
          ('Library/Application Support/MobileSync/Backup', 'ios-backups'), ('Downloads', 'installers'))


def has_control(text):
    return any(ord(ch) < 32 or ord(ch) == 127 for ch in text)


def guess_category(path, home):
    rel = path[len(home) + 1:] if home and path.startswith(home + '/') else path
    for prefix, category in _GUESS:
        if rel == prefix or rel.startswith(prefix + '/'):
            return category
    return ''


def read_manifest(path, home=''):
    """[(original_path, bytes, category)] from manifest.tsv, plus a truncated flag.
    Row: base64(quarantine path) TAB base64(original path) TAB bytes [TAB category]."""
    raw = open_regular(path, MAX_BYTES)
    if raw is None:
        return [], False
    rows, truncated = [], False
    for line in raw.decode('utf-8', 'replace').splitlines():
        if len(rows) >= MAX_ROWS:
            truncated = True
            break
        parts = line.split('\t')
        if len(parts) < 3:
            continue
        try:
            original = base64.b64decode(parts[1], validate=True).decode('utf-8', 'replace')
        except (binascii.Error, ValueError):
            continue
        size = int(parts[2]) if parts[2].isdigit() else 0
        category = parts[3].strip() if len(parts) > 3 and parts[3].strip() else guess_category(original, home)
        rows.append((original, size, category))
    return rows, truncated


class ItemList:
    """Rows are dicts: path, bytes, category, plus optional extra fields."""

    def __init__(self, items, title='', kind='items', allow_exclude=True, readonly_note='', multi=False):
        self.items = list(items)
        self.multi = multi
        self.marked = set()              # paths ticked for a selective operation
        self.title, self.kind = title, kind
        self.allow_exclude = allow_exclude
        self.readonly_note = readonly_note
        self.query = ''
        self.sort = 'order'
        self.group = False
        self.index = 0
        self.offset = 0
        self.searching = False
        self._view = None
        self._key = None

    def total_bytes(self):
        return sum(i['bytes'] for i in self.items)

    def view(self):
        """Rows to show: ('item', i) and, when grouped, ('head', category, count, bytes)."""
        key = (self.query, self.sort, self.group, len(self.items))
        if key == self._key and self._view is not None:
            return self._view
        q = self.query.casefold()
        rows = [i for i in self.items if not q or q in i['path'].casefold() or q in (i.get('category') or '').casefold()]
        if self.sort == 'size':
            rows.sort(key=lambda i: -i['bytes'])
        elif self.sort == 'path':
            rows.sort(key=lambda i: i['path'])
        elif self.sort == 'category':
            rows.sort(key=lambda i: ((i.get('category') or '~'), -i['bytes']))
        out = []
        if self.group:
            order = {}
            for item in rows:
                order.setdefault(item.get('category') or '', []).append(item)
            for category in sorted(order, key=lambda c: (c == '', c)):
                members = order[category]
                out.append(('head', category, len(members), sum(m['bytes'] for m in members)))
                out.extend(('item', m) for m in members)
        else:
            out = [('item', i) for i in rows]
        self._view, self._key = out, key
        return out

    def selectable(self):
        return [n for n, row in enumerate(self.view()) if row[0] == 'item']

    def current(self):
        view = self.view()
        sel = self.selectable()
        if not sel:
            return None
        if self.index not in sel:
            self.index = min(sel, key=lambda n: abs(n - self.index))
        return view[self.index][1]

    def move(self, delta):
        sel = self.selectable()
        if not sel:
            return
        self.current()
        pos = sel.index(self.index) + delta
        self.index = sel[max(0, min(len(sel) - 1, pos))]

    def bindings(self):
        if self.searching:
            return [Binding((), 'ui_key_type', 'type', display='abc'), Binding(('enter', 'down'), 'ui_key_back', 'to_list'),
                    Binding(('backspace',), 'ui_key_clear', 'backspace')]
        out = [Binding(('up', 'down'), 'ui_key_move', 'vmove')]
        if self.multi:
            out += [Binding(('space',), 'ui_key_mark', 'mark'), Binding(('a',), 'ui_key_all_visible', 'all'),
                    Binding(('n',), 'ui_key_select_none', 'none')]
        out += [Binding(('/',), 'ui_key_search', 'search'),
               Binding(('s',), 'ui_key_sort', 'sort'), Binding(('g',), 'ui_key_group', 'group'),
               Binding(('o',), 'ui_key_reveal', 'reveal')]
        if self.allow_exclude:
            out.append(Binding(('e',), 'ui_key_exclude', 'exclude'))
        out.append(Binding(('pgup', 'pgdn'), 'ui_key_scroll', 'page', show=False))
        return out

    def action(self, app, action):
        """Handle one action; True when consumed."""
        if self.searching:
            if action in ('enter', 'down', 'to_list'):
                self.searching = False
            elif action == 'backspace':
                self.query = self.query[:-1]
            else:
                return False
            return True
        if action in ('up', 'down', 'pgup', 'pgdn'):
            self.move({'up': -1, 'down': 1, 'pgup': -10, 'pgdn': 10}[action])
        elif action in ('home', 'end'):
            sel = self.selectable()
            if sel:
                self.index = sel[0] if action == 'home' else sel[-1]
        elif action == 'mark' and self.multi:
            item = self.current()
            if item and not has_control(item['path']):
                self.marked.symmetric_difference_update({item['path']})
                self.move(1)
            elif item:
                app.notify(app.t('ui_item_not_selectable'), 'status_warn')
        elif action == 'all' and self.multi:
            self.marked |= {r[1]['path'] for r in self.view() if r[0] == 'item' and not has_control(r[1]['path'])}
        elif action == 'none' and self.multi:
            self.marked.clear()
        elif action == 'search':
            self.searching = True
        elif action == 'sort':
            self.sort = SORTS[(SORTS.index(self.sort) + 1) % len(SORTS)]
            self.index = 0
        elif action == 'group':
            self.group = not self.group
            self.index = 0
        elif action == 'reveal':
            item = self.current()
            if item:
                app.reveal(item['path'])
        elif action == 'exclude' and self.allow_exclude:
            item = self.current()
            if item:
                app.request_exclude(item['path'])
        else:
            return action in ('vmove', 'page')
        return True

    def text(self, text):
        if self.searching:
            self.query = (self.query + text)[:60]
            self.index = 0
            return True
        return False

    def detail_lines(self, app, item):
        """Three lines for the selected item: original path; size and category;
        whether the original location is free or occupied, and the date."""
        from tui_runner import fmt_bytes
        first = '%s: %s' % (app.t('ui_col_size'), fmt_bytes(item['bytes']))
        if item.get('category'):
            first += '  %s: %s' % (app.t('ui_col_category'), app.category_label(item['category']))
        third = []
        if item.get('check_original'):
            third.append(app.t('ui_original_occupied' if os.path.lexists(item['path']) else 'ui_original_free'))
        if item.get('date'):
            third.append(app.t('ui_quarantined_on', date=item['date']))
        return [item['path'], first, '  '.join(third)]

    def render(self, app, c, rect, focused=True):
        """Draw the list into ``rect`` (no box). Returns nothing; the last row of
        the rect is used for the one-line detail."""
        from tui_runner import fmt_bytes
        g = app.glyphs
        view = self.view()
        item = self.current()
        y = rect.y
        label = app.t('ui_search_label')
        field = self.query + (('▏' if g['tl'] != '+' else '_') if self.searching else '')
        c.put(y, rect.x, label, 'focus_title' if self.searching else 'muted')
        tail = '%s %s' % (app.t('ui_sort_by', by=app.t('ui_sort_' + self.sort)), g['sep'] + ' ' + app.t('ui_grouped') if self.group else '')
        if self.multi and self.marked:
            tail = app.t('ui_selected_count', count=len(self.marked)) + '  ' + tail
        tail = tail.rstrip()
        room = max(0, rect.w - text_width(label) - text_width(tail) - 1)       # the search field never runs into the sort note
        c.put(y, rect.x + text_width(label), clip(field or app.t('ui_search_hint_items'), room, g['ellipsis']),
              'input' if self.searching else ('base' if field else 'muted'))
        c.put(y, rect.x + max(0, rect.w - text_width(tail)), tail, 'muted', rect.w)
        y += 1
        detail_rows = 3 if rect.h >= 10 and item is not None else (2 if rect.h >= 8 and item is not None else 0)
        visible = rect.y + rect.h - y - detail_rows
        if visible <= 0:
            return
        self.offset = scroll_window(self.index, self.offset, visible, len(view))
        width = rect.w - (1 if len(view) > visible else 0)
        size_w = 9
        for n, row in enumerate(view[self.offset:self.offset + visible], self.offset):
            ry = y + n - self.offset
            if row[0] == 'head':
                text = '%s %s (%d, %s)' % (g['expand'], app.category_label(row[1]) if row[1] else app.t('ui_no_category'),
                                           row[2], fmt_bytes(row[3]))
                c.put(ry, rect.x, clip(text, width, g['ellipsis']), 'accent')
                continue
            it = row[1]
            selected = n == self.index
            style = ('sel_focus' if focused and app.dialog is None else 'sel') if selected else 'base'
            if selected:
                c.fill(ry, rect.x, 1, width, style)
                c.put(ry, rect.x, g['marker'], style)
            mark = '⊘' if app.is_excluded(it['path']) and g['tl'] != '+' else ('x' if app.is_excluded(it['path']) else ' ')
            c.put(ry, rect.x + 2, mark, 'warn' if not selected else style)
            box_w = 0
            if self.multi:
                box = g['check_on'] if it['path'] in self.marked else g['check_off']
                c.put(ry, rect.x + 4, box, style if selected else ('ok' if it['path'] in self.marked else 'muted'))
                box_w = 4
            c.put(ry, rect.x + 4 + box_w, pad(fmt_bytes(it['bytes']), size_w, 'right'), style if selected else 'base')
            path_x = rect.x + 4 + box_w + size_w + 1
            c.put(ry, path_x, clip(it['path'], max(4, width - (path_x - rect.x)), g['ellipsis']), style)
            c.region(ry, rect.x, 1, width, ('item_row', n))
        if len(view) > visible:
            thumb = max(1, visible * visible // len(view))
            start = (visible - thumb) * self.offset // max(1, len(view) - visible)
            for i in range(visible):
                on = start <= i < start + thumb
                c.put(y + i, rect.x + rect.w - 1, g['bar_full'] if on else g['v'], 'accent' if on else 'border')
        if not view:
            c.put(y, rect.x, app.t('ui_no_items'), 'base')
        if detail_rows and item is not None:
            lines = self.detail_lines(app, item)
            c.put(rect.y + rect.h - detail_rows, rect.x, clip(lines[0], rect.w, g['ellipsis']), 'strong')
            if detail_rows == 3:
                c.put(rect.y + rect.h - 2, rect.x, clip(lines[1], rect.w, g['ellipsis']), 'base')
                c.put(rect.y + rect.h - 1, rect.x, clip(lines[2], rect.w, g['ellipsis']), 'base')
            else:
                c.put(rect.y + rect.h - 1, rect.x, clip(lines[1], rect.w, g['ellipsis']), 'base')

    def click(self, row_index):
        if 0 <= row_index < len(self.view()) and self.view()[row_index][0] == 'item':
            self.index = row_index
            return True
        return False
