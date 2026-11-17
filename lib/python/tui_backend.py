"""Fixed engine operations and an isolated PTY worker.

Importing this module performs no scans, launches or state writes. The engine
(cleanup_all.sh) keeps every consent, protection and mutation decision; the
interface only ever starts one of the ACTIONS below, with arguments validated
here, as ``/bin/bash <program>/cleanup_all.sh --cli <args>``.
"""
import codecs
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import termios
import time

import mc_events
import tui_registry

ENGINE = 'cleanup_all.sh'
MAX_JSON = 16 * 1024 * 1024

# args: fixed arguments; operand: kind of the single required operand (or None);
# flags: optional extra flags allowed for the action; mutating: changes user data
# or the tool's own state; pty: runs in a PTY with an event file (else captured).
ACTIONS = {
    'scan': dict(args=('--dry-run', '--non-interactive'), operand=None, flags=('--only',), mutating=False, pty=True),
    'preview': dict(args=('plan', '--non-interactive'), operand=None, flags=('--only',), mutating=False, pty=True),
    'clean_safe': dict(args=('--auto-safe',), operand=None, flags=(), mutating=True, pty=True),
    'clean_selected': dict(args=('--interactive',), operand=None, flags=('--only',), required=('--only',),
                           mutating=True, pty=True),
    'apply_plan': dict(args=('apply', '--from-plan'), operand='plan', flags=('--include-review',), mutating=True,
                       pty=True),
    'restore': dict(args=('--restore',), operand='run_id', flags=(), mutating=True, pty=True),
    'restore_items': dict(args=('--restore',), operand='run_id', flags=('--items-file',),
                          required=('--items-file',), mutating=True, pty=True),
    'restore_preview': dict(args=('--restore',), operand='run_id', flags=('--items-file',),
                            tail=('--dry-run', '--json'), mutating=False, pty=False),
    'update_check': dict(script='scripts/update_self.sh', interp='bash', args=('--check', '--json'), operand=None,
                         flags=(), mutating=False, pty=False, ok_codes=(0, 1, 3)),
    'update_self': dict(script='scripts/update_self.sh', interp='bash', args=(), operand=None, flags=(),
                        mutating=True, pty=True),
    'purge': dict(args=('--purge-quarantine',), operand='run_or_expired', flags=(), tail=('--apply',),
                  mutating=True, pty=True),
    'list_quarantine': dict(args=('--list-quarantine', '--json'), operand=None, flags=(), mutating=False, pty=False),
    'history': dict(args=('--history', '--json'), operand=None, flags=(), mutating=False, pty=False),
    'categories': dict(args=('--list-categories', '--json'), operand=None, flags=(), mutating=False, pty=False),
    'doctor': dict(args=('--doctor', '--json'), operand=None, flags=(), mutating=False, pty=False),
    'prune_artifacts': dict(args=('--prune-artifacts',), operand=None, flags=(), mutating=True, pty=True),
    'schedule': dict(args=('--schedule',), operand='schedule_verb', flags=('--time',), mutating=True, pty=True),
    'migrate_preview': dict(script='scripts/layout_migrate.py', interp='python', args=('--preview',), operand=None,
                            flags=(), mutating=False, pty=True),
    'migrate_apply': dict(script='scripts/layout_migrate.py', interp='python', args=('--apply',), operand=None,
                          flags=(), mutating=True, pty=True),
}
JSON_ACTIONS = tuple(a for a, s in ACTIONS.items() if not s['pty'])
SCHEDULE_VERBS = ('install', 'remove', 'status')
TIME = re.compile(r'([01][0-9]|2[0-3]):[0-5][0-9]')


def is_mutating(action):
    return ACTIONS[action]['mutating']


def _script(program, relative):
    try:
        root = Path(program).resolve(strict=True)
        if not root.is_dir():
            raise ValueError('invalid_program_dir')
        script = root / relative
        # Neither a symlinked script nor a symlinked scripts/ parent may escape.
        if script.is_symlink() or script.resolve(strict=True) != script or not script.is_file():
            raise ValueError('unsafe_engine_script')
    except OSError as exc:
        raise ValueError('unsafe_engine_script') from exc
    return script


def _plan_path(value, state_dir):
    """<state>/runs/<run id>/plan.json, a regular file; no symlink on the way."""
    if not isinstance(value, str) or not state_dir or '\0' in value or not value.startswith('/') or '/../' in value + '/':
        raise ValueError('invalid_plan_path')
    path = Path(value)
    real_state = os.path.realpath(state_dir)
    if path.name != 'plan.json' or not tui_registry.RUN_ID_PATTERN.fullmatch(path.parent.name):
        raise ValueError('invalid_plan_path')
    if os.path.realpath(value) != os.path.join(real_state, 'runs', path.parent.name, 'plan.json'):
        raise ValueError('invalid_plan_path')
    if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
        raise ValueError('unsafe_plan_path')
    return str(path)


def _operand(kind, value, state_dir):
    if kind == 'run_id':
        if not isinstance(value, str) or not tui_registry.RUN_ID_PATTERN.fullmatch(value):
            raise ValueError('invalid_run_id')
        return value
    if kind == 'run_or_expired':
        if value != 'expired' and (not isinstance(value, str) or not tui_registry.RUN_ID_PATTERN.fullmatch(value)):
            raise ValueError('invalid_run_id')
        return value
    if kind == 'plan':
        return _plan_path(value, state_dir)
    if kind == 'schedule_verb':
        if value not in SCHEDULE_VERBS:
            raise ValueError('invalid_schedule_verb')
        return value
    raise ValueError('invalid_operand')


ITEMS_NAME = 'items.txt'


def _items_file(value):
    """The items file the UI wrote: absolute ``items.txt`` (mode 0600, regular, not a
    symlink) inside a private (0700, owned, not a symlink) directory."""
    import stat
    if not isinstance(value, str) or not value.startswith('/') or '\0' in value:
        return False
    path = Path(value)
    if path.name != ITEMS_NAME:
        return False
    try:
        info, parent = path.lstat(), path.parent.lstat()
    except OSError:
        return False
    return (stat.S_ISREG(info.st_mode) and (info.st_mode & 0o777) == 0o600 and info.st_uid == os.getuid()
            and stat.S_ISDIR(parent.st_mode) and (parent.st_mode & 0o777) == 0o700 and parent.st_uid == os.getuid())


def _flags(spec, action, extra):
    """Validate extra tokens: only this action's flags, each with its own value rule."""
    out, tokens, i = [], list(extra), 0
    while i < len(tokens):
        flag = tokens[i]
        if not isinstance(flag, str) or flag not in spec['flags']:
            raise ValueError('invalid_argument')
        if flag == '--only':
            if i + 1 >= len(tokens) or not isinstance(tokens[i + 1], str) \
                    or not tui_registry.ID_LIST_PATTERN.fullmatch(tokens[i + 1]) \
                    or any(not tui_registry.known(c) for c in tokens[i + 1].split(',')):
                raise ValueError('invalid_category_list')
            out += [flag, tokens[i + 1]]
            i += 2
        elif flag == '--items-file':
            if i + 1 >= len(tokens) or not _items_file(tokens[i + 1]):
                raise ValueError('invalid_items_file')
            out += [flag, tokens[i + 1]]
            i += 2
        elif flag == '--time':
            if action != 'schedule' or i + 1 >= len(tokens) or not isinstance(tokens[i + 1], str) \
                    or not TIME.fullmatch(tokens[i + 1]):
                raise ValueError('invalid_time')
            out += [flag, tokens[i + 1]]
            i += 2
        else:
            out.append(flag)
            i += 1
    for needed in spec.get('required', ()):
        if needed not in out:
            raise ValueError('missing_argument')
    return out


def build_command(program, action, operand=None, extra=(), state_dir=None):
    """The fixed engine command for ``action`` plus validated operand and flags."""
    if not isinstance(action, str) or action not in ACTIONS:
        raise ValueError('invalid_action')
    spec = ACTIONS[action]
    if spec['operand'] is None and operand is not None:
        raise ValueError('invalid_operand')
    if spec['operand'] is not None and operand is None:
        raise ValueError('missing_operand')
    extra = list(extra)
    flags = _flags(spec, action, extra)
    value = _operand(spec['operand'], operand, state_dir) if spec['operand'] else None
    if action == 'schedule':
        if value == 'install' and '--time' not in flags:
            raise ValueError('invalid_time')
        if value != 'install' and '--time' in flags:
            raise ValueError('invalid_time')
    if spec.get('script'):
        script = _script(program, spec['script'])
        if spec['interp'] == 'bash':
            return ['/bin/bash', str(script), *spec['args'], *flags]
        return ['/bin/bash', '-c', 'exec python3 "$@"', 'macos-cleanup', str(script), *spec['args'], *flags]
    script = _script(program, ENGINE)
    command = ['/bin/bash', str(script), '--cli', *spec['args']]
    if value is not None:
        command.append(value)
    command += list(spec.get('tail', ()))
    command += flags
    return command


# Names that select a mode, consent or files must never leak from the user's
# shell into a child run: strip all of them, then set exactly what this job needs.
LEGACY_RESET = ('AUTO_YES', 'NON_INTERACTIVE', 'REMOVE_MODE', 'DRY_RUN', 'LOGS_DIR', 'REPORTS_DIR', 'RULES_FILE',
                'LANG_CODE', 'ARTIFACT_RETENTION_DAYS', 'HOME_TOP_DIRS_TIMEOUT')
LEGACY_PREFIXES = ('QUARANTINE_', 'CLEANUP_')


def child_environment(language='en', extra=None, paths=None, event_file=None, run_id=None, environ=None):
    environ = os.environ if environ is None else environ
    env = {}
    for key, value in environ.items():
        if key.startswith('MACOS_CLEANUP_') or key in LEGACY_RESET or key.startswith(LEGACY_PREFIXES):
            continue
        env[key] = value
    env.update(MACOS_CLEANUP_TUI_CHILD='1', MACOS_CLEANUP_LANG=language, PYTHONUNBUFFERED='1')
    for key, value in (extra or {}).items():
        if isinstance(key, str) and key.startswith('MACOS_CLEANUP_') and isinstance(value, str) \
                and key not in ('MACOS_CLEANUP_TUI_CHILD', 'MACOS_CLEANUP_EVENT_FILE', 'MACOS_CLEANUP_RUN_ID'):
            env[key] = value
    if paths:
        # The interface resolved these; the engine must agree with what it shows.
        env['MACOS_CLEANUP_CONFIG_DIR'] = paths['config']
        env['MACOS_CLEANUP_STATE_DIR'] = paths['state']
        env['MACOS_CLEANUP_QUARANTINE_DIR'] = paths['quarantine']
    if event_file:
        env['MACOS_CLEANUP_EVENT_FILE'] = event_file
    if run_id:
        env['MACOS_CLEANUP_RUN_ID'] = run_id
    return env


# Captured JSON that is not one of the tool-tagged read models.
UNTAGGED = ('restore_preview', 'update_check')


def kill_group(proc, wait=True):
    """Kill everything left in the process group of a child started with ``start_new_session``."""
    import signal
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass
    if wait:
        try:
            proc.communicate(timeout=2)
        except (subprocess.SubprocessError, OSError, ValueError):
            pass


def run_json(program, action, env=None, timeout=60, operand=None, extra=(), state_dir=None):
    """Run a JSON listing without a PTY and return its parsed JSON object.
    Raises ValueError when the output is not the expected read model."""
    if action not in JSON_ACTIONS:
        raise ValueError('invalid_action')
    command = build_command(program, action, operand, extra, state_dir)
    # Own session: the listing must never become the terminal's foreground process group (the terminal title
    # would then show whatever helper the engine runs, e.g. "sleep"); on a timeout, and when it returns, the
    # whole group is killed so no helper outlives the call.
    try:
        proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                start_new_session=True,
                                env=dict(child_environment() if env is None else env, MACOS_CLEANUP_TUI_CHILD='1'))
    except (OSError, subprocess.SubprocessError) as exc:
        raise ValueError('engine_unavailable') from exc
    try:
        stdout, _ = proc.communicate(timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        kill_group(proc)
        raise ValueError('engine_unavailable') from exc
    done = subprocess.CompletedProcess(command, proc.returncode, stdout, b'')
    if done.returncode not in ACTIONS[action].get('ok_codes', (0, 1)) or len(done.stdout) > MAX_JSON:
        raise ValueError('engine_failed')
    try:
        data = json.loads(done.stdout.decode('utf-8', 'replace'))
    except ValueError as exc:
        raise ValueError('invalid_json') from exc
    if not isinstance(data, dict) or (action not in UNTAGGED and data.get('tool') != 'macos-cleanup'):
        raise ValueError('invalid_read_model')
    return data


class _OutputFilter:
    """Discard OSC commands across arbitrary chunks without retaining payloads."""

    def __init__(self):
        self.decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self.state = 'text'

    def feed(self, raw, final=False):
        output = []
        for char in self.decoder.decode(raw, final):
            if self.state == 'text':
                if char == '\033':
                    self.state = 'escape'
                elif char == '\x9d':
                    self.state = 'osc'
                else:
                    output.append(char)
            elif self.state == 'escape':
                if char == ']':
                    self.state = 'osc'
                elif char == '\033':
                    output.append('\033')
                else:
                    output.extend(('\033', char))
                    self.state = 'text'
            elif self.state == 'osc':
                if char in ('\a', '\x9c'):
                    self.state = 'text'
                elif char == '\033':
                    self.state = 'osc_escape'
            elif char in ('\\', '\x9c'):
                self.state = 'text'
            elif char != '\033':
                self.state = 'osc'
        return ''.join(output)


def worker_main(terminal_fd, command):
    """Called only by the isolated Python child before it execs a fixed command."""
    if terminal_fd < 3 or not command or command[0] != '/bin/bash':
        return 2
    fcntl.ioctl(terminal_fd, termios.TIOCSCTTY, 0)
    os.tcsetpgrp(terminal_fd, os.getpgrp())
    for target in (0, 1, 2):
        os.dup2(terminal_fd, target)
    os.close(terminal_fd)
    os.execvpe(command[0], command, os.environ)
    return 2


class TerminalJob:
    """One explicitly started job; no auto answers, logging or forced shutdown."""

    def __init__(self, command, env=None):
        if not command or command[0] != '/bin/bash':
            raise ValueError('invalid_command')
        self.command = list(command)
        # Every engine command the interface spawns carries the marker, whatever environment the caller built.
        self.env = dict(child_environment() if env is None else env, MACOS_CLEANUP_TUI_CHILD='1')
        self._process = None
        self._master = None
        self._size = (24, 80)
        self._filter = _OutputFilter()
        self.started_at = None
        self.stop_requested = False

    @property
    def running(self):
        return self._process is not None and self._process.poll() is None

    @property
    def returncode(self):
        return None if self._process is None else self._process.poll()

    @property
    def pid(self):
        return None if self._process is None else self._process.pid

    @property
    def secret_input(self):
        if self._master is None or not self.running:
            return False
        try:
            return not bool(termios.tcgetattr(self._master)[3] & termios.ECHO)
        except OSError:
            return False

    def start(self):
        if self._process is not None:
            raise ValueError('job_already_started')
        master, slave = os.openpty()
        self._master = master
        self.resize(*self._size)
        os.set_blocking(master, False)
        helper = ('import sys; sys.path.insert(0, sys.argv[1]); '
                  'from tui_backend import worker_main; '
                  'sys.exit(worker_main(int(sys.argv[2]), sys.argv[3:]))')
        try:
            self._process = subprocess.Popen(
                [sys.executable, '-c', helper, str(Path(__file__).resolve().parent), str(slave), *self.command],
                stdin=slave, stdout=slave, stderr=slave, pass_fds=(slave,), start_new_session=True, env=self.env)
            self.started_at = time.monotonic()
        except BaseException:
            os.close(master)
            self._master = None
            raise
        finally:
            os.close(slave)
        return self

    def poll(self):
        chunks = []
        # A noisy child cannot allocate an unbounded buffer or starve UI input.
        for _ in range(16):
            if self._master is None:
                break
            try:
                raw = os.read(self._master, 4096)
            except BlockingIOError:
                break
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                raw = b''
            if not raw:
                final = self._filter.feed(b'', final=True)
                if final:
                    chunks.append(final)
                os.close(self._master)
                self._master = None
                break
            text = self._filter.feed(raw)
            if text:
                chunks.append(text)
        if self._process is not None:
            self._process.poll()
        return chunks

    def send(self, text):
        if not isinstance(text, str) or len(text) > 4096:
            raise ValueError('invalid_input')
        if self._master is None or not self.running:
            return 0
        # Forward exactly what the user submitted. Do not retain, echo or log it.
        data = text.encode('utf-8')
        sent = 0
        while sent < len(data):
            written = os.write(self._master, data[sent:])
            if written <= 0:
                break
            sent += written
        return sent

    def resize(self, rows, cols):
        if type(rows) is not int or type(cols) is not int or not (1 <= rows <= 1000 and 1 <= cols <= 1000):
            raise ValueError('invalid_terminal_size')
        self._size = (rows, cols)
        if self._master is not None:
            fcntl.ioctl(self._master, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    def interrupt(self):
        """Only the UI's explicitly confirmed cancellation may call this."""
        if self._master is None or not self.running:
            return False
        self.stop_requested = True
        # The PTY delivers this to its foreground job, not the UI process group.
        self.send('\x03')
        return True


def open_regular(path, limit):
    """Bounded read of a regular, non-symlink file owned by the user (or None)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not (info.st_mode & 0o170000) == 0o100000 or info.st_uid != os.getuid():
            return None
        with os.fdopen(fd, 'rb', closefd=False) as handle:
            data = handle.read(limit + 1)
    finally:
        os.close(fd)
    return None if len(data) > limit else data


def host_facts():
    """Cheap, read-only facts for the Status pane: free disk of the home volume."""
    facts = {}
    try:
        import shutil
        usage = shutil.disk_usage(os.path.expanduser('~'))
        facts['disk_free'], facts['disk_total'] = int(usage.free), int(usage.total)
    except OSError:
        pass
    return facts
