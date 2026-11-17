"""One schema table drives the Settings screen, the saved files and the
environment handed to the engine.

Two stores, both in the config directory (lib/python/mc_paths.py):

    settings.conf       ``KEY=VALUE`` lines using the engine's variable names. The
                        engine reads the same file in plain CLI runs, so the
                        interface and the CLI always agree. It is parsed, never
                        sourced; only keys of this schema are honoured. Unknown
                        lines are kept as they are and reported, never used.
    tui-settings.json   interface-only look and feel (theme, accent, ...).

Nothing a user types becomes part of a command line: values are coerced to the
row's kind (bool, choice, int, time, list of known ids) and reach the engine
only as environment variables.
"""
import json
import os
import plistlib
import re
import stat
import tempfile
import time

import tui_registry

LANGUAGES = ('en', 'pl', 'de', 'es', 'fr', 'it', 'pt')
LANGUAGE_CHOICES = ('system',) + LANGUAGES
NATIVE_NAMES = dict(en='English', pl='Polski', de='Deutsch', es='Español', fr='Français', it='Italiano',
                    pt='Português')
CONF_FILE = 'settings.conf'
LOCAL_FILE = 'tui-settings.json'
CONF_HEADER = ('# macos-cleanup settings: KEY=VALUE, one per line. Read by the engine and the interface.\n'
               '# Edit in the interface (Settings) or by hand; unknown keys are ignored.\n')
SECTIONS = ('look', 'safety', 'rules', 'performance', 'history', 'schedule', 'paths', 'system')
SECTION_LABELS = {s: 'ui_sec_' + s for s in SECTIONS}
WEEKDAYS = ('daily', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun')
DASH_ACTIONS = ('scan', 'preview', 'clean_safe')
SAFE_VALUE = re.compile(r'[A-Za-z0-9_.:,/@+-]*')
SCHEDULE_LABEL = 'com.github.kasprowiczm.macos-cleanup'


class Setting:
    """kind: bool | choice | int | time | multi | action | info.

    ``env`` names the engine variable (store ``conf``); ``store`` is ``conf``,
    ``local`` or None (action/info rows). ``confirm`` names the value that needs
    an explicit confirmation dialog before it is saved. ``when`` tells when a
    change takes effect: ``next_run`` (engine setting) or ``now``."""
    __slots__ = ('key', 'kind', 'default', 'env', 'section', 'label', 'help', 'choices', 'low', 'high', 'step',
                 'store', 'confirm', 'when', 'to_env', 'from_env')

    def __init__(self, key, kind, default, section, label=None, help=None, env=None, choices=(), low=0, high=0,
                 step=1, store=None, confirm=None, when='next_run', to_env=None, from_env=None):
        self.key, self.kind, self.default, self.section = key, kind, default, section
        self.label = label or 'ui_set_' + key
        self.help = help or 'ui_set_%s_help' % key
        self.env, self.choices = env, tuple(choices)
        self.low, self.high, self.step = low, high, step
        self.store = store if store is not None else ('conf' if env else ('local' if kind in ('bool', 'choice', 'int')
                                                                         else None))
        self.confirm, self.when, self.to_env, self.from_env = confirm, when, to_env, from_env


def _b(value):
    return '1' if value else '0'


def _from_b(text):
    value = text.strip().lower()
    if value in ('1', 'true', 'yes', 'on'):
        return True
    if value in ('0', 'false', 'no', 'off'):
        return False
    raise ValueError('bool')


ALL_SECTIONS = tuple(s for s in tui_registry.SECTIONS)
_P = 'MACOS_CLEANUP_'


def _csv(value):
    return ','.join(value)


def _from_csv(text):
    return tuple(p for p in text.strip().split(',') if p)


SCHEMA = [
    # -- look (interface only, except the language) -----------------------------------
    Setting('language', 'choice', 'system', 'look', env=_P + 'LANG', choices=LANGUAGE_CHOICES, when='now'),
    Setting('theme', 'choice', 'auto', 'look', choices=('auto', 'dark', 'light'), when='now'),
    Setting('accent', 'choice', 'blue', 'look', choices=('blue', 'violet', 'amber', 'green', 'rose', 'graphite'),
            when='now'),
    Setting('density', 'choice', 'comfortable', 'look', choices=('comfortable', 'compact'), when='now'),
    Setting('ascii', 'bool', False, 'look', when='now'),
    Setting('mouse', 'bool', True, 'look', when='now'),
    Setting('auto_resize', 'bool', True, 'look', when='now'),
    Setting('animate', 'bool', True, 'look', when='now'),
    Setting('help_open', 'bool', True, 'look', when='now'),
    Setting('default_action', 'choice', 'preview', 'look', choices=DASH_ACTIONS, when='now'),
    # -- safety ---------------------------------------------------------------------------
    Setting('remove_mode', 'choice', 'quarantine', 'safety', env=_P + 'REMOVE_MODE',
            choices=('quarantine', 'permanent'), confirm='permanent'),
    Setting('confirm_style', 'choice', 'full', 'safety', choices=('full', 'compact'), when='now'),
    Setting('quarantine_retention_days', 'int', 30, 'safety', env=_P + 'QUARANTINE_RETENTION_DAYS', low=1, high=365),
    Setting('recent_days', 'int', 0, 'safety', env=_P + 'RECENT_DAYS', low=0, high=90),
    Setting('backup_max_age_days', 'int', 14, 'safety', env=_P + 'BACKUP_MAX_AGE_DAYS', low=1, high=90),
    Setting('redact', 'bool', False, 'safety', env=_P + 'REDACT', to_env=_b, from_env=_from_b),
    Setting('min_free_gb', 'int', 20, 'safety', store='local', low=1, high=500, step=5),
    Setting('require_typing_path', 'bool', True, 'safety', store='local'),
    Setting('review_policy', 'info', None, 'safety'),
    Setting('unattended_scope', 'info', None, 'safety'),
    # -- rules ----------------------------------------------------------------------------
    Setting('default_sections', 'multi', tuple(s for s in ALL_SECTIONS if s != 'overview'), 'rules',
            store='local', choices=ALL_SECTIONS),
    Setting('large_file_mb', 'int', 500, 'rules', store='local', low=10, high=10240, step=50),
    Setting('log_max_age_days', 'int', 30, 'rules', env=_P + 'LOG_MAX_AGE_DAYS', low=1, high=365),
    Setting('dmg_max_age_days', 'int', 30, 'rules', env=_P + 'DMG_MAX_AGE_DAYS', low=1, high=365),
    Setting('device_support_min_age_days', 'int', 180, 'rules', env=_P + 'DEVICE_SUPPORT_MIN_AGE_DAYS',
            low=30, high=720, step=30),
    Setting('excludes', 'action', None, 'rules'),
    Setting('category_modes', 'action', None, 'rules'),
    Setting('reset_modes', 'action', None, 'rules'),
    # -- performance ----------------------------------------------------------------------
    Setting('log_level', 'choice', 'INFO', 'performance', store='local', choices=('DEBUG', 'INFO', 'WARN', 'ERROR')),
    Setting('scan_jobs', 'int', 4, 'performance', env=_P + 'SCAN_JOBS', low=1, high=8),
    Setting('home_top_timeout', 'int', 20, 'performance', env=_P + 'HOME_TOP_TIMEOUT', low=1, high=120, step=5),
    # -- history --------------------------------------------------------------------------
    Setting('artifact_retention_days', 'int', 30, 'history', env=_P + 'ARTIFACT_RETENTION_DAYS', low=0, high=365),
    Setting('prune_now', 'action', None, 'history'),
    Setting('report_language', 'choice', 'same', 'history', store='local', choices=('same',) + LANGUAGES),
    # -- schedule (opt-in, off by default) ------------------------------------------------
    Setting('schedule_status', 'info', None, 'schedule'),
    Setting('schedule', 'action', None, 'schedule'),
    Setting('schedule_time', 'time', '10:30', 'schedule', env=_P + 'SCHEDULE_TIME'),
    Setting('schedule_weekday', 'choice', 'sun', 'schedule', env=_P + 'SCHEDULE_WEEKDAY', choices=WEEKDAYS),
    # -- paths (read-only) ----------------------------------------------------------------
    Setting('path_program', 'info', None, 'paths'),
    Setting('path_config', 'info', None, 'paths'),
    Setting('path_state', 'info', None, 'paths'),
    Setting('path_quarantine', 'info', None, 'paths'),
    Setting('install_mode', 'info', None, 'paths'),
    Setting('legacy_data', 'info', None, 'paths'),
    # -- system ---------------------------------------------------------------------------
    Setting('export', 'action', None, 'system'),
    Setting('import', 'action', None, 'system'),
    Setting('reset', 'action', None, 'system'),
]
# Kept in the schema (stored values and the engine's own scan_jobs key stay valid) but not shown:
# nothing reads these seven yet, and a setting without an effect must not be offered on the screen.
NOT_SHOWN = ('min_free_gb', 'require_typing_path', 'default_sections', 'large_file_mb', 'log_level', 'scan_jobs',
             'report_language')
# What the engine really reads (lib/paths.sh _MC_SETTING_KEYS): these keys, in settings.conf under their
# MACOS_CLEANUP_* names. Any other key in that file makes the engine print an "unknown key" warning on every
# run, so settings the engine does not read live in tui-settings.json (store 'local'). The environment is
# honoured for all of them except remove_mode, which the engine takes only from settings.conf or a flag.
ENGINE_CONF_KEYS = ('language', 'remove_mode', 'quarantine_retention_days', 'recent_days', 'backup_max_age_days',
                    'redact', 'log_max_age_days', 'dmg_max_age_days', 'device_support_min_age_days', 'scan_jobs',
                    'home_top_timeout', 'artifact_retention_days', 'schedule_time', 'schedule_weekday')
ENGINE_ENV_KEYS = tuple(k for k in ENGINE_CONF_KEYS if k != 'remove_mode')
BY_KEY = {s.key: s for s in SCHEMA}
BY_ENV = {s.env: s for s in SCHEMA if s.env}
VALUE_KEYS = tuple(s.key for s in SCHEMA if s.kind in ('bool', 'choice', 'int', 'time', 'multi'))
CONF_KEYS = tuple(s.key for s in SCHEMA if s.store == 'conf' and s.key in VALUE_KEYS)
LOCAL_KEYS = tuple(s.key for s in SCHEMA if s.store == 'local' and s.key in VALUE_KEYS)
PATH_KEYS = dict(path_program='program', path_config='config', path_state='state', path_quarantine='quarantine')


def coerce(setting, value):
    """Return a valid value for ``setting`` or raise ValueError."""
    kind = setting.kind
    if kind == 'bool':
        if type(value) is bool:
            return value
        raise ValueError('bool')
    if kind == 'choice':
        value = str(value)
        if value in setting.choices:
            return value
        raise ValueError('choice')
    if kind == 'int':
        if type(value) is bool:
            raise ValueError('int')
        if isinstance(value, str) and not re.fullmatch(r'\s*[0-9]{1,6}\s*', value):
            raise ValueError('int')
        value = int(value)
        if setting.low <= value <= setting.high:
            return value
        raise ValueError('range')
    if kind == 'time':
        hour, minute = parse_hhmm(value)
        return '%02d:%02d' % (hour, minute)
    if kind == 'multi':
        if isinstance(value, str):
            value = _from_csv(value)
        if not isinstance(value, (list, tuple)) or not all(isinstance(v, str) for v in value):
            raise ValueError('multi')
        if any(v not in setting.choices for v in value):
            raise ValueError('multi')
        ordered = tuple(c for c in setting.choices if c in value)
        if not ordered:
            raise ValueError('multi')
        return ordered
    raise ValueError('kind')


def parse_hhmm(text):
    """'9:05' / '09:05' -> (9, 5); anything else raises ValueError."""
    match = re.fullmatch(r'\s*([01]?\d|2[0-3]):([0-5]\d)\s*', str(text))
    if not match:
        raise ValueError('time')
    return int(match.group(1)), int(match.group(2))


def to_text(setting, value):
    """The text written to settings.conf / the child environment."""
    if setting.to_env:
        return setting.to_env(value)
    if setting.kind == 'bool':
        return _b(value)
    return str(value)


def from_text(setting, text):
    value = setting.from_env(text) if setting.from_env else text.strip()
    if setting.kind == 'bool' and isinstance(value, str):
        value = _from_b(value)
    return coerce(setting, value)


def defaults():
    return {key: BY_KEY[key].default for key in VALUE_KEYS}


def system_language(environ, home=None):
    """The Mac's language when the user has not chosen one: MACOS_CLEANUP_LANG
    (session override), then AppleLanguages/AppleLocale, then LANG/LC_*; else English."""
    hint = environ.get(_P + 'LANG')
    if hint in LANGUAGES:
        return hint
    path = os.path.join(home or os.path.expanduser('~'), 'Library', 'Preferences', '.GlobalPreferences.plist')
    try:
        if os.path.isfile(path) and os.path.getsize(path) < 4 * 1024 * 1024:
            with open(path, 'rb') as handle:
                prefs = plistlib.load(handle)
            languages = prefs.get('AppleLanguages') or []
            for value in list(languages[:1]) + [prefs.get('AppleLocale') or '']:
                code = str(value)[:2].lower()
                if code in LANGUAGES:
                    return code
    except Exception:   # unreadable preferences: fall through to the environment
        pass
    for name in ('LC_ALL', 'LC_MESSAGES', 'LANG'):
        code = str(environ.get(name) or '')[:2].lower()
        if code in LANGUAGES and code != 'c':
            return code
    return 'en'


def parse_conf(data):
    """Parse settings.conf text. Returns (values, unknown, invalid, lines):
    ``values`` maps schema keys to coerced values, ``unknown`` lists keys that are
    not in the schema, ``invalid`` lists schema keys whose value was rejected and
    ``lines`` is the list of (kind, text) rows to preserve (kind ``other`` for
    comments, blanks and unknown keys)."""
    values, unknown, invalid, keep = {}, [], [], []
    for raw in data.splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            keep.append(('other', raw))
            continue
        if '=' not in line:
            unknown.append(line[:40])
            keep.append(('other', raw))
            continue
        name, text = line.split('=', 1)
        name, text = name.strip(), text.strip()
        setting = BY_ENV.get(name)
        if setting is None or setting.key not in CONF_KEYS:
            unknown.append(name[:60])
            keep.append(('other', raw))
            continue
        if not SAFE_VALUE.fullmatch(text):
            invalid.append(setting.key)
            keep.append(('managed', name))
            continue
        try:
            values[setting.key] = from_text(setting, text)
        except (ValueError, TypeError):
            invalid.append(setting.key)
        keep.append(('managed', name))
    return values, unknown, invalid, keep


class SettingsStore:
    """Values, where each came from (default/file/env), and atomic saving."""

    def __init__(self, config_dir=None, environ=None, home=None):
        self.config_dir = config_dir
        self.home = home
        self.environ = dict(os.environ if environ is None else environ)
        self.values = defaults()
        self.origin = {key: 'default' for key in VALUE_KEYS}
        self.file = {}               # what is written to disk (keys the user set)
        self.unknown = []
        self.invalid = []
        self.error = None
        self._conf_lines = []
        self.load()

    # -- paths ---------------------------------------------------------------
    @property
    def directory(self):
        if self.config_dir:
            return self.config_dir
        import mc_paths
        try:
            return mc_paths.config_dir()
        except mc_paths.PathError:
            return os.path.join(os.path.expanduser('~/.config'), mc_paths.NAME)

    @property
    def conf_path(self):
        return os.path.join(self.directory, CONF_FILE)

    @property
    def local_path(self):
        return os.path.join(self.directory, LOCAL_FILE)

    # -- loading -------------------------------------------------------------
    def load(self):
        self.values, self.origin = defaults(), {key: 'default' for key in VALUE_KEYS}
        self.file, self.unknown, self.invalid, self.error = {}, [], [], None
        self._conf_lines = []
        try:
            data = read_private(self.conf_path, 65536)
            if data is not None:
                values, self.unknown, self.invalid, self._conf_lines = parse_conf(data.decode('utf-8', 'replace'))
                for key, value in values.items():
                    self.values[key] = value
                    self.origin[key] = 'file'
                    self.file[key] = value
        except OSError as exc:      # unsafe or unreadable: defaults, never a crash
            self.error = str(exc)
        try:
            data = read_private(self.local_path, 65536)
            raw = json.loads(data.decode('utf-8')) if data is not None else {}
            raw = raw if isinstance(raw, dict) else {}
        except (OSError, ValueError) as exc:
            self.error = self.error or str(exc)
            raw = {}
        for key in LOCAL_KEYS:
            if key in raw:
                try:
                    self.values[key] = coerce(BY_KEY[key], raw[key])
                    self.origin[key] = 'file'
                    self.file[key] = self.values[key]
                except (ValueError, TypeError):
                    self.invalid.append(key)
        # Environment wins over the files (CLI flag > env > settings.conf > default).
        for setting in SCHEMA:
            if setting.env and setting.key in VALUE_KEYS and setting.key != 'remove_mode':
                text = self.environ.get(setting.env)
                if text is None or text == '' or not SAFE_VALUE.fullmatch(text):
                    continue
                try:
                    self.values[setting.key] = from_text(setting, text)
                    self.origin[setting.key] = 'env'
                except (ValueError, TypeError):
                    continue

    # -- access --------------------------------------------------------------
    def get(self, key):
        return self.values[key]

    def effective_language(self):
        value = self.values['language']
        return system_language(self.environ, self.home) if value == 'system' else value

    def is_default(self, key):
        return self.values[key] == BY_KEY[key].default

    def set(self, key, value, save=True):
        setting = BY_KEY[key]
        if self.origin.get(key) == 'env':
            raise PermissionError(setting.env)
        self.values[key] = coerce(setting, value)
        self.file[key] = self.values[key]
        self.origin[key] = 'file'
        if save:
            self.save(setting.store)

    def reset_one(self, key, save=True):
        setting = BY_KEY[key]
        if self.origin.get(key) == 'env':
            raise PermissionError(setting.env)
        self.values[key] = setting.default
        self.origin[key] = 'default'
        self.file.pop(key, None)
        if save:
            self.save(setting.store)

    def reset(self):
        for key in VALUE_KEYS:
            if self.origin.get(key) != 'env':
                self.values[key] = BY_KEY[key].default
                self.origin[key] = 'default'
        self.file = {}
        self.save()

    # -- saving --------------------------------------------------------------
    def save(self, store=None):
        if store in (None, 'conf'):
            self._save_conf()
        if store in (None, 'local'):
            self._save_local()

    def _save_conf(self):
        lines = []
        for key in CONF_KEYS:
            if key in self.file and not (key == 'language' and self.file[key] == 'system'):
                lines.append('%s=%s' % (BY_KEY[key].env, to_text(BY_KEY[key], self.file[key])))
        # Comments and unknown keys the user wrote stay exactly as they were.
        extra = []
        for kind, text in self._conf_lines:
            if kind == 'other' and text.strip() and not text.startswith('# macos-cleanup settings') \
                    and not text.startswith('# Edit in the interface'):
                extra.append(text)
        body = CONF_HEADER + ''.join(l + '\n' for l in lines) + ''.join(l + '\n' for l in extra)
        atomic_write(self.conf_path, body.encode('utf-8'), private_root=True)
        self._conf_lines = [('managed', l.split('=')[0]) for l in lines] + [('other', l) for l in extra]

    def _save_local(self):
        data = {key: self.file[key] for key in LOCAL_KEYS if key in self.file}
        atomic_write(self.local_path, (json.dumps(data, ensure_ascii=True, sort_keys=True, indent=1) + '\n').encode(),
                     private_root=True)

    # -- settings passed to the engine ----------------------------------------
    def child_env(self):
        """Environment variables for the engine. Only valid, schema-checked values;
        a value that does not coerce is skipped, never passed on."""
        env = {}
        for key in CONF_KEYS:
            setting = BY_KEY[key]
            if key == 'language' or key not in ENGINE_ENV_KEYS:
                continue
            try:
                value = coerce(setting, self.values[key])
            except (ValueError, TypeError):
                continue
            text = to_text(setting, value)
            if SAFE_VALUE.fullmatch(text):
                env[setting.env] = text
        env[_P + 'LANG'] = self.effective_language()
        return env

    # -- export / import --------------------------------------------------------
    def export_data(self, modes):
        return dict(format='macos-cleanup-settings', version=1,
                    settings={key: (list(self.values[key]) if isinstance(self.values[key], tuple) else self.values[key])
                              for key in VALUE_KEYS},
                    modes=[list(row) for row in modes])

    def import_data(self, data):
        if not isinstance(data, dict) or data.get('format') != 'macos-cleanup-settings':
            raise ValueError('not_a_settings_file')
        settings = data.get('settings')
        if not isinstance(settings, dict):
            raise ValueError('not_a_settings_file')
        for key, value in settings.items():
            if key in BY_KEY and key in VALUE_KEYS and self.origin.get(key) != 'env':
                try:
                    self.values[key] = coerce(BY_KEY[key], value)
                    self.origin[key] = 'file'
                    self.file[key] = self.values[key]
                except (ValueError, TypeError):
                    continue
        self.save()
        rows = data.get('modes', [])
        return rows if isinstance(rows, list) else []


def read_private(path, limit):
    """Read a config file: regular, owned by the user, not a symlink, bounded.
    Returns None when it does not exist; raises OSError when it is unsafe."""
    if not os.path.lexists(path):
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as exc:
        raise OSError('unsafe config file: ' + os.path.basename(path)) from exc
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        os.close(fd)
        raise OSError('unsafe config file: ' + os.path.basename(path))
    with os.fdopen(fd, 'rb') as handle:
        data = handle.read(limit + 1)
    if len(data) > limit:
        raise OSError('config file too large: ' + os.path.basename(path))
    return data


def atomic_write(path, data, mode=0o600, private_root=False):
    directory = os.path.dirname(path)
    if os.path.islink(directory):
        raise OSError('refusing a symlinked folder: ' + directory)
    if private_root:
        import mc_paths
        mc_paths.make_private_dirs(directory)
    else:
        os.makedirs(directory, mode=0o700, exist_ok=True)
    if os.path.islink(path) or (os.path.exists(path) and os.stat(path).st_nlink != 1):
        raise OSError('refusing to replace a link: ' + path)
    fd, temporary = tempfile.mkstemp(prefix='.tmp-', dir=directory)
    try:
        with os.fdopen(fd, 'wb') as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


# -- excludes file (one path per line) ----------------------------------------------
def read_excludes(config_dir):
    path = os.path.join(config_dir, 'excludes.txt')
    try:
        data = read_private(path, 256 * 1024)
    except OSError:
        return []
    out = []
    for line in (data or b'').decode('utf-8', 'replace').splitlines():
        if line.strip() and not line.lstrip().startswith('#'):
            out.append(line.strip())
    return out


def valid_exclude(text):
    text = text.strip()
    return bool(text) and len(text) <= 1024 and '\n' not in text and '\t' not in text and '\0' not in text \
        and (text.startswith('/') or text.startswith('~/')) and '/../' not in text + '/' and text not in ('/', '~')


def write_excludes(config_dir, paths):
    body = '# One path per line (~ allowed). Written by macos-cleanup.\n' + ''.join(p + '\n' for p in paths)
    atomic_write(os.path.join(config_dir, 'excludes.txt'), body.encode('utf-8'), private_root=True)


def add_exclude(config_dir, path):
    """Append exactly ``path`` (and nothing else) to excludes.txt. Existing lines,
    comments included, are kept. Returns False when it was already listed."""
    if not valid_exclude(path):
        raise ValueError('invalid_exclude')
    target = os.path.join(config_dir, 'excludes.txt')
    data = read_private(target, 256 * 1024)
    text = (data or b'').decode('utf-8', 'replace')
    if path in [l.strip() for l in text.splitlines()]:
        return False
    if not text:
        text = '# One path per line (~ allowed). Written by macos-cleanup.\n'
    elif not text.endswith('\n'):
        text += '\n'
    atomic_write(target, (text + path.strip() + '\n').encode('utf-8'), private_root=True)
    return True


def remove_exclude(config_dir, path):
    """Drop the lines equal to ``path``; every other line stays as it was."""
    target = os.path.join(config_dir, 'excludes.txt')
    data = read_private(target, 256 * 1024)
    if data is None:
        return False
    lines = data.decode('utf-8', 'replace').splitlines()
    kept = [l for l in lines if l.strip() != path]
    if len(kept) == len(lines):
        return False
    atomic_write(target, (''.join(l + '\n' for l in kept)).encode('utf-8'), private_root=True)
    return True


# -- schedule (LaunchAgent file; read-only here) ------------------------------------
def launchagent_path(home=None):
    return os.path.join(home or os.path.expanduser('~'), 'Library', 'LaunchAgents', SCHEDULE_LABEL + '.plist')


def schedule_status(home=None):
    """Read the LaunchAgent that ``--schedule install`` writes (files only, no
    launchctl). Returns dict(state='on'|'off'|'unknown', hour, minute, weekday, plist)."""
    path = launchagent_path(home)
    try:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 262144:
            raise ValueError('not a plain plist')
        with open(path, 'rb') as handle:
            data = plistlib.load(handle)
    except FileNotFoundError:
        return dict(state='off', plist=path)
    except Exception:
        return dict(state='unknown', plist=path)
    cal = data.get('StartCalendarInterval')
    if isinstance(cal, list) and cal:
        cal = cal[0]
    cal = cal if isinstance(cal, dict) else {}
    return dict(state='on', hour=cal.get('Hour', 0), minute=cal.get('Minute', 0), weekday=cal.get('Weekday'),
                plist=path)


def next_run(status, now=None):
    """Epoch of the next scheduled run, or None."""
    if status.get('state') != 'on':
        return None
    now = time.time() if now is None else now
    import datetime
    base = datetime.datetime.fromtimestamp(now)
    for add in range(0, 9):
        day = base + datetime.timedelta(days=add)
        candidate = day.replace(hour=int(status.get('hour') or 0), minute=int(status.get('minute') or 0), second=0,
                                microsecond=0)
        weekday = status.get('weekday')
        if isinstance(weekday, int) and (candidate.isoweekday() % 7) != (weekday % 7):
            continue
        if candidate.timestamp() > now:
            return candidate.timestamp()
    return None


def legacy_detected(environ=None):
    """True when MACOS_CLEANUP_LEGACY_DIR points at a v3 checkout that still has
    logs/ or reports/ (the migrate hint). The doctor read model reports the
    default legacy location as well; the interface prefers that."""
    environ = os.environ if environ is None else environ
    path = environ.get(_P + 'LEGACY_DIR') or ''
    return bool(path) and os.path.isdir(os.path.join(path, '.git')) and (
        os.path.isdir(os.path.join(path, 'reports')) or os.path.isdir(os.path.join(path, 'logs')))
