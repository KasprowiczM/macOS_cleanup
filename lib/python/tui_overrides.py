"""Per-category modes: ``<config>/category-modes.tsv`` (lib/python/mc_paths.py).

Line format: ``id<TAB>mode<TAB>source``. The mode is ``auto``, ``review`` or
``skip``; the source is ``user`` for a line written here. A category without a
line has the default mode of contract 13 (auto only for app-caches, review for
every other category, skip for report-only). ``auto`` is accepted only for a
regenerable category that goes to quarantine; the engine refuses it elsewhere.

The file is read leniently (bad lines are counted, never fatal) and written
atomically with mode 0600.
"""
import os

import tui_registry
from tui_settings import atomic_write, read_private

MODES = tui_registry.MODES
FILENAME = 'category-modes.tsv'
HEADER = '# id\tmode\tsource - written by the macos-cleanup interface; read by the engine\n'


def _valid(ident, mode):
    if not tui_registry.known(ident) or mode not in MODES:
        return False
    if mode == 'auto' and not tui_registry.auto_allowed(ident):
        return False
    if mode != 'skip' and tui_registry.info(ident)['tier'] == 'report':
        return False
    return True


class ModeStore:
    def __init__(self, config_dir):
        self.path = os.path.join(config_dir, FILENAME)
        self.rows = {}          # id -> mode (only deviations the user chose)
        self.bad = 0
        self.error = None
        self.load()

    def load(self):
        self.rows, self.bad, self.error = {}, 0, None
        try:
            data = read_private(self.path, 1024 * 1024)
        except OSError as exc:
            self.error = str(exc)
            return
        if data is None:
            return
        for line in data.decode('utf-8', 'replace').splitlines():
            if not line.strip() or line.startswith('#'):
                continue
            parts = [p.strip() for p in line.split('\t')]
            if len(parts) >= 2 and _valid(parts[0], parts[1]):
                self.rows[parts[0]] = parts[1]
            else:
                self.bad += 1

    def get(self, ident):
        """(mode, source) with source ``default`` or ``user``."""
        if ident in self.rows:
            return self.rows[ident], 'user'
        return tui_registry.default_mode(ident), 'default'

    def effective_auto(self, ident):
        """True only for an auto-allowed category whose mode is auto (contract 13)."""
        mode, _ = self.get(ident)
        return mode == 'auto' and tui_registry.auto_allowed(ident)

    def allowed_modes(self, ident):
        """The modes the interface offers for a category, in cycle order."""
        if tui_registry.info(ident)['tier'] == 'report':
            return ('skip',)
        return ('review', 'skip', 'auto') if tui_registry.auto_allowed(ident) else ('review', 'skip')

    def next_mode(self, ident, current=None):
        """The next mode in the cycle; auto is skipped where the engine would refuse it."""
        mode = current or self.get(ident)[0]
        modes = self.allowed_modes(ident)
        if mode not in modes:
            return modes[0]
        return modes[(modes.index(mode) + 1) % len(modes)]

    def set_many(self, idents, mode):
        if mode not in MODES:
            raise ValueError('invalid_mode')
        for ident in idents:
            if not tui_registry.known(ident):
                raise ValueError('invalid_category')
            if not _valid(ident, mode):
                raise ValueError('invalid_mode')
        for ident in idents:
            if mode == tui_registry.default_mode(ident):
                self.rows.pop(ident, None)
            else:
                self.rows[ident] = mode
        self.save()

    def reset(self):
        self.rows = {}
        self.save()

    def overridden(self):
        return len(self.rows)

    def save(self):
        order = {i: n for n, i in enumerate(tui_registry.CATEGORY_IDS)}
        body = HEADER + ''.join('%s\t%s\tuser\n' % (i, m) for i, m in sorted(self.rows.items(), key=lambda r: order[r[0]]))
        atomic_write(self.path, body.encode('utf-8'), mode=0o600, private_root=True)

    def export_rows(self):
        return [[i, m] for i, m in sorted(self.rows.items())]

    def import_rows(self, rows):
        imported = {}
        for row in rows:
            if isinstance(row, list) and len(row) >= 2 and all(isinstance(x, str) for x in row[:2]) \
                    and _valid(row[0], row[1]) and row[1] != tui_registry.default_mode(row[0]):
                imported[row[0]] = row[1]
        self.rows = imported
        self.save()
        return len(imported)
