"""Static copy of the category registry (contract section 3.3).

The engine owns the registry (share/categories.tsv) and reports it through
``--list-categories --json``; the interface uses this table only as a fallback
for ids, order, tier and undo before that listing is available, and to know
which group ids are valid. The seam tests compare it with the engine's list.
"""
import re

# (id, section, tier, action, undo, unit, native_cmd)
_ROWS = (
    ('trash', 'trash', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('user-caches', 'user-caches', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('app-caches', 'user-caches', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('app-caches-review', 'user-caches', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('user-logs', 'logs', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('system-logs', 'logs', 'review', 'remove', 'none', 'bytes', ''),
    ('diagnostic-reports', 'logs', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('system-caches', 'system', 'report', 'report', 'none', 'bytes', ''),
    ('tmp', 'system', 'review', 'remove', 'none', 'bytes', ''),
    ('xcode-derived', 'dev', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('xcode-archives', 'dev', 'report', 'report', 'none', 'bytes', ''),
    ('simulators', 'dev', 'review', 'native', 'none', 'bytes', 'xcrun simctl delete unavailable'),
    ('sim-runtimes', 'dev', 'review', 'native', 'none', 'bytes', 'xcrun simctl runtime delete --unusable'),
    ('device-support', 'dev', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('npm', 'dev', 'regenerable', 'native', 'none', 'bytes', 'npm cache clean --force'),
    ('npx', 'dev', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('yarn', 'dev', 'regenerable', 'native', 'none', 'bytes', 'yarn cache clean'),
    ('pnpm', 'dev', 'regenerable', 'native', 'none', 'bytes', 'pnpm store prune'),
    ('pnpm-stale', 'dev', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('pip', 'dev', 'regenerable', 'native', 'none', 'bytes', 'pip cache purge'),
    ('brew', 'dev', 'review', 'native', 'none', 'bytes', 'brew cleanup --prune=all'),
    ('gradle', 'dev', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('maven', 'dev', 'report', 'report', 'none', 'bytes', ''),
    ('cocoapods', 'dev', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('cargo', 'dev', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('swift-pm', 'dev', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('gem', 'dev', 'review', 'native', 'none', 'bytes', 'gem cleanup'),
    ('bundler', 'dev', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('composer', 'dev', 'regenerable', 'remove', 'quarantine', 'bytes', ''),
    ('android-avd', 'dev', 'report', 'report', 'none', 'bytes', ''),
    ('docker', 'dev', 'review', 'native', 'none', 'bytes', 'docker system prune -f'),
    ('app-leftovers', 'app-leftovers', 'report', 'report', 'none', 'bytes', ''),
    ('tm-snapshots', 'time-machine', 'review', 'native', 'none', 'count', 'tmutil deletelocalsnapshots <date>'),
    ('ios-backups', 'time-machine', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('installers', 'large-files', 'review', 'remove', 'quarantine', 'bytes', ''),
    ('browser-caches', 'overview', 'report', 'report', 'none', 'bytes', ''),
    ('browser-data', 'overview', 'report', 'report', 'none', 'bytes', ''),
    ('mail-data', 'overview', 'report', 'report', 'none', 'bytes', ''),
    ('mail-downloads', 'overview', 'report', 'report', 'none', 'bytes', ''),
)
FIELDS = ('id', 'section', 'tier', 'action', 'undo', 'unit', 'native_cmd')
CATEGORIES = tuple(dict(zip(FIELDS, row)) for row in _ROWS)
CATEGORY_IDS = tuple(row[0] for row in _ROWS)
BY_ID = {c['id']: c for c in CATEGORIES}
PSEUDO_GROUPS = ('restore', 'purge')          # allowed only in the restore / purge modes
GROUP_IDS = CATEGORY_IDS + PSEUDO_GROUPS
TIERS = ('regenerable', 'review', 'report')
MODES = ('auto', 'review', 'skip')
SECTIONS = ('trash', 'user-caches', 'logs', 'system', 'dev', 'app-leftovers', 'time-machine', 'large-files', 'overview')
ID_PATTERN = re.compile(r'[a-z][a-z0-9-]{1,30}')
ID_LIST_PATTERN = re.compile(r'[a-z][a-z0-9-]{1,30}(,[a-z][a-z0-9-]{1,30}){0,63}')
RUN_ID_PATTERN = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}_[0-9]+')
# Contract 13: only the application caches of known apps are cleaned without asking
# out of the box; every other regenerable category is offered for review; report-only is never touched.
DEFAULT_AUTO = ('app-caches',)


def known(ident):
    return ident in BY_ID


def info(ident):
    """Registry row for an id; a neutral row for an unknown one."""
    return BY_ID.get(ident) or dict(id=ident, section='', tier='review', action='remove', undo='none',
                                    unit='bytes', native_cmd='')


def label_key(ident):
    return 'cat_' + ident.replace('-', '_')


def explain_key(ident):
    return 'exp_' + ident.replace('-', '_')


def default_mode(ident):
    """Fallback when the categories read model is unavailable; the engine's own answer wins."""
    if info(ident)['tier'] == 'report':
        return 'skip'
    return 'auto' if ident in DEFAULT_AUTO else 'review'


def auto_allowed(ident):
    """A category may be switched to auto only if it is regenerable and goes to quarantine;
    categories handled by a native tool can never be auto (the engine refuses)."""
    row = info(ident)
    return row['tier'] == 'regenerable' and row['action'] == 'remove' and row['undo'] == 'quarantine'


def native_only(ident):
    return info(ident)['action'] == 'native'


def executable(ident):
    """Categories the engine may act on (everything except report-only)."""
    return info(ident)['action'] != 'report'
