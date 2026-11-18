"""Read models the screens show: history, categories, quarantine listing and
doctor. Each is loaded by the engine's JSON listing (no PTY) on a worker thread
so the interface never blocks; a failure leaves the model empty with the error
text kept for the screen's empty state. Files under <state>/runs are read
directly (bounded, regular files, no symlinks).
"""
import json
import os
import threading

import tui_backend
import tui_registry

NAMES = ('history', 'categories', 'list_quarantine', 'doctor')
MAX_RUN_JSON = 1024 * 1024


class Models:
    def __init__(self, program, env_factory, loader=None):
        self.program = program
        self.env_factory = env_factory
        self.loader = loader or self._default_loader
        self.data = {n: None for n in NAMES}
        self.error = {n: '' for n in NAMES}
        self.loading = set()
        self.version = {n: 0 for n in NAMES}
        self._lock = threading.Lock()
        self._done = []

    def _default_loader(self, name):
        return tui_backend.run_json(self.program, name, env=self.env_factory())

    def refresh(self, name, wait=False):
        if name not in NAMES or name in self.loading:
            return False
        self.loading.add(name)

        def work():
            try:
                result = (name, self.loader(name), '')
            except Exception as exc:              # engine missing, bad JSON, timeout ...
                result = (name, None, str(exc)[:80])
            with self._lock:
                self._done.append(result)
        thread = threading.Thread(target=work, daemon=True)
        thread.start()
        if wait:
            thread.join(70)
            self.poll()
        return True

    def poll(self):
        """Move finished loads into place; returns the names that changed."""
        with self._lock:
            done, self._done = self._done, []
        changed = []
        for name, data, error in done:
            self.loading.discard(name)
            if data is not None:
                self.data[name], self.error[name] = data, ''
            else:
                self.error[name] = error or 'unavailable'
            self.version[name] += 1
            changed.append(name)
        return changed

    def get(self, name):
        return self.data.get(name)

    # -- typed accessors ---------------------------------------------------------
    def history_rows(self):
        data = self.data['history'] or {}
        rows = data.get('runs') if isinstance(data.get('runs'), list) else []
        return [r for r in rows if isinstance(r, dict) and tui_registry.RUN_ID_PATTERN.fullmatch(str(r.get('run_id', '')))]

    def category_rows(self):
        data = self.data['categories'] or {}
        rows = data.get('categories') if isinstance(data.get('categories'), list) else []
        rows = [r for r in rows if isinstance(r, dict) and tui_registry.ID_PATTERN.fullmatch(str(r.get('id', '')))]
        if rows:
            return rows
        return [dict(c, mode=tui_registry.default_mode(c['id']), mode_source='default',
                     effective_auto=tui_registry.default_mode(c['id']) == 'auto' and tui_registry.auto_allowed(c['id']),
                     last_scan=None, top_items=[], static=True) for c in tui_registry.CATEGORIES]

    def quarantine_runs(self):
        data = self.data['list_quarantine'] or {}
        rows = data.get('runs') if isinstance(data.get('runs'), list) else []
        return [r for r in rows if isinstance(r, dict) and tui_registry.RUN_ID_PATTERN.fullmatch(str(r.get('run_id', '')))]

    def quarantine_totals(self):
        data = self.data['list_quarantine'] or {}
        return data.get('totals') if isinstance(data.get('totals'), dict) else {}

    def doctor(self):
        return self.data['doctor'] or {}


def read_run_json(state_dir, run_id):
    """<state>/runs/<run_id>/run.json as a dict, or None."""
    if not tui_registry.RUN_ID_PATTERN.fullmatch(str(run_id)):
        return None
    raw = tui_backend.open_regular(os.path.join(state_dir, 'runs', run_id, 'run.json'), MAX_RUN_JSON)
    if raw is None:
        return None
    try:
        data = json.loads(raw.decode('utf-8', 'replace'))
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def read_text_file(path, limit=512 * 1024, tail=True):
    """Text of a regular file (last ``limit`` bytes when ``tail``), or None."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if (info.st_mode & 0o170000) != 0o100000:
            return None
        if tail and info.st_size > limit:
            os.lseek(fd, info.st_size - limit, os.SEEK_SET)
        data = os.read(fd, limit) if limit < 1 << 30 else b''
    finally:
        os.close(fd)
    return data.decode('utf-8', 'replace')


def read_unreadable(state_dir, run_id):
    """Paths the run could not read: <state>/runs/<run>/unreadable.tsv (first column)."""
    if not run_id or not tui_registry.RUN_ID_PATTERN.fullmatch(str(run_id)):
        return []
    text = read_text_file(os.path.join(state_dir, 'runs', run_id, 'unreadable.tsv'), 1024 * 1024, tail=False)
    out = []
    for line in (text or '').splitlines():
        if line.strip() and not line.startswith('#'):
            out.append(line.split('\t')[0].strip())
    return out[:5000]


def dry_run_row(row, type_of=None):
    """True for a history row of a scan or preview (a dry run): the only runs whose plan.json covers every
    category. A cleaning run writes its own plan, narrowed to its --only list, so its plan is not the plan a
    later Clean safe would act on. ``type_of(row)`` gives the run type (the app's facts, which also read the
    event stream); without it the row's mode decides. Known gap: a CLI ``--dry-run --only x`` run qualifies
    too, because the --only ids are recorded nowhere the interface can read."""
    from tui_runfacts import type_from_mode
    kind = type_of(row) if type_of else type_from_mode(row.get('mode'))
    return kind in ('scan', 'preview') or bool(row.get('dry_run'))


def latest_plan(models, state_dir, max_age_hours=24, now=None, type_of=None):
    """(plan_path, run_id) of the newest dry run whose plan is younger than max_age_hours."""
    import time
    from tui_plan import known_plan_path
    now = time.time() if now is None else now
    for row in models.history_rows():
        if not dry_run_row(row, type_of):
            continue
        run_id = row['run_id']
        path = os.path.join(state_dir, 'runs', run_id, 'plan.json')
        if not os.path.isfile(path) or os.path.islink(path) or not known_plan_path(path, state_dir):
            continue
        try:
            age = now - os.stat(path).st_mtime
        except OSError:
            continue
        if age <= max_age_hours * 3600:
            return path, run_id
    return None, None
