"""macOS Cleanup terminal interface: app state, layout, key/mouse dispatch and
the non-blocking curses loop. Screens live in tui_screens*, dialogs in
tui_dialogs, the run model in tui_runner and settings in tui_settings.

Rendering never grants execution authority. A mutating action (clean, apply a
plan, restore, purge, prune, schedule, migrate) starts only through
``request_action``, which shows a confirmation or the plan review first; the
engine keeps all of its own consent and protection decisions.
"""
import curses
import os
import platform
import subprocess
import sys
import tempfile
import threading
import time

import mc_paths
import tui_data
import tui_markdown
import tui_runfacts
import tui_plan
import tui_registry
import tui_settings as ts
from tui_backend import (ACTIONS, TerminalJob, build_command, child_environment, host_facts, is_mutating)
from tui_dialogs import ChoiceDialog, ConfirmDialog, Dialog, InputDialog, prompt_dialog
from tui_i18n import tr
from tui_keymap import Binding, key_display, key_name, keybar_items, lookup
from tui_overrides import ModeStore
from tui_runner import (EventTailer, LogBuffer, RunModel, detect_prompt, fmt_bytes, model_from_summary, wrap_log)
from tui_screens import SCREENS, make_screens, status_glyph
from tui_theme import Theme, color_disabled, detect_background, glyphs, resolve_theme, wants_ascii
from tui_widgets import Canvas, Rect, clip, duration, pad, plain, text_width, wrap

MIN_ROWS, MIN_COLS = 12, 40
GENERIC = ('vmove', 'hmove', 'page', 'ends', 'adjust')
NOTICE_SECONDS = 6
SIDE_RATIO = dict(dashboard=0.40, categories=0.38, quarantine=0.5, history=0.4, settings=0.36, diagnostics=0.5,
                  help=0.6)
MAIN_TARGET = dict(dashboard=66, categories=64, quarantine=52, history=54, settings=90, diagnostics=72, help=36)
NO_SIDE_PANE = ('help',)          # the Help screen is one text: it gets the whole width instead of a narrow pane beside an empty one
MIN_MAIN = dict(dashboard=50, categories=50, quarantine=44, history=46, settings=66, diagnostics=40, help=24)
VIEW_ALIASES = dict(home='dashboard', ui='dashboard', about='help')
RUN_ACTIONS = ('scan', 'preview', 'clean_safe', 'clean_selected', 'apply_plan', 'restore', 'restore_items', 'purge')
PRIMARY_ZONE = dict(dashboard='steps')
EVENT_KEEP = 20


class App:
    def __init__(self, program, initial_view='dashboard', paths=None, home=None, environ=None, sysinfo=None,
                 launch_dry_run=False, animate=True, autoload=True, loader=None, opener=None):
        self.program = os.path.realpath(program)
        self.environ = dict(os.environ if environ is None else environ)
        self.home = home or self.environ.get('HOME') or os.path.expanduser('~')
        if paths is None:
            env = dict(self.environ, HOME=self.home)
            try:
                paths = mc_paths.resolve(env, self.program)
            except mc_paths.PathError:
                paths = dict(program=self.program, config=os.path.join(self.home, '.config', mc_paths.NAME),
                             state=os.path.join(self.home, '.local', 'state', mc_paths.NAME),
                             quarantine=os.path.join(self.home, mc_paths.QUARANTINE_DEFAULT), mode='default')
        self.paths = paths
        self.state_dir, self.config_dir = paths['state'], paths['config']
        self.settings = ts.SettingsStore(self.config_dir, self.environ, home=self.home)
        self.modes = ModeStore(self.config_dir)
        self.models = tui_data.Models(self.program, self.env_for_json, loader=loader)
        self.screens = make_screens()
        view = VIEW_ALIASES.get(initial_view, initial_view)
        self.screen_index = SCREENS.index(view) if view in SCREENS else 0
        self.dialog = None
        self.overlay = None
        self.overlay_scroll = 0
        self.job = None
        self.job_kind = None
        self.job_action = None
        self.task_log = None
        self.run = None
        self.run_log = None
        self.tailer = None
        self.event_path = None
        self.run_dir = None
        self.last_model = None
        self.show_result = False
        self.prompt_hidden = None
        self.answered_detected = set()
        self.detected_count = -1
        self.log_scroll = 0
        self.log_expand_all = False
        self.help_scroll = 0
        self.help_visible = None
        self.notice = ('', 'status', 0)
        self.should_exit = False
        self.exit_mode = None
        self.exit_after_job = False
        self.read_only = bool(launch_dry_run)
        self.tick_count = 0
        self._exit_seen = None
        self._task_prompt = None
        self._tokens = set()
        self._run_serial = 0
        self.after_job = []
        self._adone, self._apending, self._alock = [], 0, threading.Lock()
        self._items_dir = None
        self.update_state = dict(status=None)
        self.mode = 'wide'
        self.animate = animate and self.settings.get('animate')
        self.theme_dirty = True
        self.terminal_bg = None            # 'light' | 'dark' as detected from the terminal at start-up
        self.last_canvas = None
        self._scan_key, self._scan = None, None
        self._facts = {}
        self.last_model_epoch = None
        self.rows, self.cols = 24, 80
        self.probe_host = sysinfo is None
        self.sysinfo = sysinfo or system_info()
        self.facts_cache, self.facts_time = None, 0.0
        self.schedule_cache = None
        self.opener = opener or _open_with_finder
        self.excluded = set()
        self.reload_excludes()
        try:
            with open(os.path.join(self.program, 'VERSION'), encoding='utf-8') as handle:
                self.version = plain(handle.read().strip())[:32]
        except OSError:
            self.version = '?'
        self.zone = self.help_target = self.screen.zones(self)[0]
        if autoload:
            for name in tui_data.NAMES:
                self.models.refresh(name)
        self.screen.on_enter(self)

    # -- basics ----------------------------------------------------------------
    @property
    def lang(self):
        return self.settings.effective_language()

    @property
    def screen(self):
        return self.screens[self.screen_index]

    @property
    def glyphs(self):
        return glyphs(wants_ascii(self.environ, self.settings.get('ascii')))

    def t(self, key, **values):
        return tr(key, self.lang, **values)

    def category_label(self, ident):
        key = tui_registry.label_key(ident)
        text = self.t(key)
        return ident if text == key else text

    def section_label(self, section):
        key = 'sect_' + section.replace('-', '_')
        text = self.t(key)
        return section if text == key else text

    def notify(self, text, style='status'):
        self.notice = (text, style, time.monotonic())

    def busy(self):
        return self.job is not None

    def run_active(self):
        return self.run is not None

    def current_model(self):
        return self.run or self.last_model

    def theme_name(self):
        """'light' or 'dark': the Colours setting, with ``auto`` resolved from the detected terminal background."""
        return resolve_theme(self.settings.get('theme'), self.terminal_bg, self.environ)

    def env_for_json(self):
        return child_environment(self.lang, self.settings.child_env(), self.paths)

    def facts(self):
        if not self.probe_host:
            return self.sysinfo.get('facts', {})
        if self.facts_cache is None or time.monotonic() - self.facts_time > 60:
            try:
                self.facts_cache = host_facts()
            except Exception:
                self.facts_cache = {}
            self.facts_time = time.monotonic()
        return self.facts_cache

    def category_mode(self, row):
        """(mode, source, effective_auto) of a categories read-model row. The engine's
        answer (``mode``, ``mode_source``, ``effective_auto``) is used as is; only a mode the
        user changed here and the engine has not reported yet takes precedence."""
        ident = row['id']
        if ident in self.modes.rows:
            return self.modes.rows[ident], 'user', self.modes.effective_auto(ident)
        mode = row.get('mode') if row.get('mode') in tui_registry.MODES else tui_registry.default_mode(ident)
        source = 'user' if row.get('mode_source') == 'user' else 'default'
        auto = mode == 'auto' and bool(row.get('effective_auto')) and tui_registry.auto_allowed(ident)
        return mode, source, auto

    # -- sizes of the latest scan (Categories) and facts of past runs (History) -------------------------------------
    def scan_info(self):
        """dict(sizes, run_id, epoch, session) for the newest measured scan: this session's finished run when it
        measured categories, else the newest run folder that did. None when nothing was ever measured."""
        model = self.last_model
        key = (id(model), self.models.version['history'])
        if key == self._scan_key:
            return self._scan
        info = None
        if model is not None and model.type() in tui_runfacts.SCAN_TYPES:
            sizes = tui_runfacts.scan_sizes_from_model(model)
            if sizes:
                run_dir = (model.paths or {}).get('run_dir') or ''
                info = dict(sizes=sizes, run_id=os.path.basename(run_dir.rstrip('/')) or None,
                            epoch=self.last_model_epoch, session=True)
        if info is None:
            found = tui_runfacts.latest_scan(self.state_dir, self.models.history_rows())
            if found:
                info = dict(sizes=found['sizes'], run_id=found['run_id'], epoch=run_epoch(found['run_id']), session=False)
        if info is None:
            for row in self.models.category_rows():          # the engine's own record of the last scan
                scan = row.get('last_scan') if isinstance(row.get('last_scan'), dict) else None
                if scan and isinstance(scan.get('run_id'), str):
                    info = dict(sizes={}, run_id=scan['run_id'], epoch=run_epoch(scan['run_id']), session=False)
                    break
        if info is not None:
            info['stale'] = self.changed_since(info.get('run_id'), model, info['session'])
        self._scan_key, self._scan = key, info
        return info

    CHANGING_TYPES = ('clean', 'apply', 'unattended', 'restore')

    def changed_since(self, scan_run_id, model, from_model):
        """The newest run that changed the disk after the scan the category sizes come from, as
        dict(type, epoch, run_id), or None. Such sizes describe the disk as it was before that run."""
        if model is not None and not from_model and model.type() in self.CHANGING_TYPES and not model.dry_run:
            return dict(type=model.type(), epoch=self.last_model_epoch, run_id=None)
        if not scan_run_id:
            return None
        for row in self.models.history_rows():                   # newest first
            if row['run_id'] <= scan_run_id:
                break
            facts = self.run_facts(row)
            if facts.type in self.CHANGING_TYPES and row.get('dry_run') is not True:
                return dict(type=facts.type, epoch=run_epoch(row['run_id']), run_id=row['run_id'])
        return None

    def category_scan(self, row):
        """dict(estimated_bytes, items, partial) of the latest scan for a categories row, or None."""
        info = self.scan_info()
        found = info['sizes'].get(row['id']) if info else None
        if found is not None and found.get('bytes') is not None:
            return dict(estimated_bytes=found['bytes'], items=found.get('items'), partial=bool(found.get('partial')))
        return row.get('last_scan') if isinstance(row.get('last_scan'), dict) else None

    def run_facts(self, row):
        """RunFacts for a history row, cached until the history is reloaded."""
        key = row['run_id']
        stamp = self.models.version['history']
        cached = self._facts.get(key)
        if cached is None or cached[0] != stamp:
            cached = self._facts[key] = (stamp, tui_runfacts.gather(self.state_dir, self.paths.get('quarantine', ''), row))
        return cached[1]

    def mode_lookup(self):
        """A function category id -> (mode, effective_auto), from the category settings."""
        rows = {r['id']: r for r in self.models.category_rows()}

        def lookup_mode(ident):
            row = rows.get(ident)
            if row is None:
                return tui_registry.default_mode(ident), False
            mode, _, auto = self.category_mode(row)
            return mode, auto
        return lookup_mode

    def schedule(self):
        if self.schedule_cache is None:
            self.schedule_cache = ts.schedule_status(self.home)
        return self.schedule_cache

    def relative(self, epoch):
        if epoch is None:
            return '?'
        delta = max(0, time.time() - epoch)
        if delta < 90:
            return self.t('ui_ago_now')
        if delta < 3600:
            return self.t('ui_ago_min', n=int(delta // 60))
        if delta < 86400:
            return self.t('ui_ago_hour', n=int(delta // 3600))
        days = int(delta // 86400)
        return self.t('ui_ago_yesterday') if days == 1 else self.t('ui_ago_days', n=days)

    def focus_zone(self, zone):
        if zone not in ('tabs', 'help', 'overlay') and zone not in self.screen.zones(self):
            zone = self.screen.zones(self)[0]
        self.zone = zone
        if zone not in ('tabs', 'help'):
            self.help_target = zone
            self.help_scroll = 0

    def switch(self, index):
        if 0 <= index < len(self.screens):
            self.screen_index = index
            self.screen.on_enter(self)
            self.focus_zone(self.screen.zones(self)[0])
            self.overlay = None

    def open_dialog(self, dialog):
        self.dialog = dialog

    # -- excludes, reveal, clipboard -----------------------------------------------
    def reload_excludes(self):
        self.excluded = set(ts.read_excludes(self.config_dir))

    def is_excluded(self, path):
        for ex in self.excluded:
            ex = os.path.expanduser(ex) if ex.startswith('~/') else ex
            if path == ex or path.startswith(ex.rstrip('/') + '/'):
                return True
        return False

    def request_exclude(self, path):
        """Ask before appending exactly ``path`` to excludes.txt."""
        if not ts.valid_exclude(path):
            self.notify(self.t('ui_exclude_invalid'), 'status_warn')
            return
        if path in self.excluded:
            self.notify(self.t('ui_exclude_already'), 'status')
            return

        def done(app, value):
            if value != 'run':
                return
            try:
                ts.add_exclude(app.config_dir, path)
                app.reload_excludes()
                app.notify(app.t('ui_exclude_saved', path=path), 'status_ok')
            except (OSError, ValueError) as exc:
                app.notify(app.t('ui_error', message=plain(exc)), 'status_warn')
        self.dialog = ConfirmDialog(self.t('ui_exclude_title'), self.t('ui_exclude_body', path=path),
                                    self.t('ui_btn_exclude'), self.t('ui_btn_cancel'), done)

    def reveal(self, path):
        """Show a path in Finder (``open -R``). Absolute, existing paths only."""
        if not isinstance(path, str) or not path.startswith('/') or '\0' in path or not os.path.lexists(path):
            self.notify(self.t('ui_reveal_missing'), 'status_warn')
            return False
        try:
            self.opener(['/usr/bin/open', '-R', path])
        except (OSError, subprocess.SubprocessError) as exc:
            self.notify(self.t('ui_error', message=plain(exc)), 'status_warn')
            return False
        self.notify(self.t('ui_revealed'), 'status')
        return True

    def copy_text(self, text):
        try:
            self.opener(['/usr/bin/pbcopy'], text)
        except (OSError, subprocess.SubprocessError) as exc:
            self.notify(self.t('ui_error', message=plain(exc)), 'status_warn')
            return False
        self.notify(self.t('ui_copied'), 'status_ok')
        return True

    # -- running actions -------------------------------------------------------------
    def next_run_id(self):
        self._run_serial += 1
        return '%s_%d' % (time.strftime('%Y-%m-%d_%H%M%S'), os.getpid() * 100 + self._run_serial)

    def _mint(self, action):
        token = object()
        self._tokens.add((action, token))
        return token

    def request_action(self, action, operand=None, extra=(), **ctx):
        """The only entry for screens. Non-mutating actions start at once; a
        mutating one opens its confirmation (or the plan review) and starts only
        from there."""
        if action not in ACTIONS:
            return False
        if not is_mutating(action):
            return self._launch(action, operand, extra, after=ctx.get('after'))
        if not self._can_start(action, operand, extra):
            return False

        after = ctx.pop('after', None)

        def go(app, value):
            if value == 'run':
                token = app._mint(action)
                app._launch(action, operand, extra, token, after)
            elif action == 'restore_items':
                app.cleanup_items()
        if action in ('clean_safe', 'clean_selected', 'apply_plan'):
            return self.open_plan_review(action, operand, extra, go, **ctx)
        title, body = self.mutation_text(action, operand, extra, ctx)
        if action == 'purge' and operand != 'expired':
            # A deliberate, run-specific confirmation: the whole run id or its last part (the digits after
            # the final underscore). The dialog says so; an empty Enter can never purge.
            short = operand.rsplit('_', 1)[-1] if '_' in operand else operand

            def matches(text):
                typed = (text or '').strip()
                return bool(typed) and typed in (operand, short)
            body += '\n\n' + self.t('ui_purge_type', short=short)
            self.dialog = InputDialog(title, body, '> ', lambda a, v: go(a, 'run') if matches(v) else (
                v is not None and a.notify(a.t('ui_purge_mismatch', short=short), 'status_warn')),
                validate=lambda text: '' if matches(text) else self.t('ui_purge_mismatch', short=short),
                ok_label=self.t('ui_btn_purge'), cancel_label=self.t('ui_btn_cancel'), help_key='ui_help_confirm')
            return True
        run_label = self.t({'restore': 'ui_btn_restore', 'purge': 'ui_btn_purge', 'prune_artifacts': 'ui_btn_prune',
                            'schedule': 'ui_btn_apply', 'migrate_apply': 'ui_btn_migrate'}.get(action, 'ui_btn_run'))
        self.dialog = ConfirmDialog(title, body, run_label, self.t('ui_btn_cancel'), go)
        return True

    def _can_start(self, action, operand, extra):
        """The checks that come before any confirmation of a mutating action."""
        if self.read_only:
            self.notify(self.t('ui_readonly'), 'status_warn')
            return False
        if self.busy():
            self.notify(self.t('ui_busy'), 'status_warn')
            return False
        try:
            build_command(self.program, action, operand, extra, self.state_dir)
        except (ValueError, OSError) as exc:
            self.notify(self.t('ui_error', message=plain(exc)), 'status_warn')
            return False
        return True

    def start_confirmed(self, action, operand, extra):
        """Start a mutating action whose confirmation was the screen the user just answered (the restore
        preview): one question, not two."""
        if action not in ACTIONS or not self._can_start(action, operand, extra):
            return False
        return self._launch(action, operand, extra, self._mint(action))

    def mutation_text(self, action, operand, extra, ctx):
        """(title, body) of the confirmation: what happens and whether it can be undone."""
        t = self.t
        permanent = t('ui_warn_permanent')
        reversible = t('ui_note_reversible')
        info = ctx.get('info') or {}
        size, count = fmt_bytes(info.get('bytes')), info.get('items', '?')
        if action == 'update_self':
            return t('ui_update_title'), t('ui_confirm_update', current=info.get('current', '?'), latest=info.get('latest', '?')) \
                + '\n\n' + reversible
        if action in ('restore', 'restore_items'):
            body = t('ui_confirm_restore', run=operand, size=size, count=count, conflicts=info.get('conflicts', '?'))
            return t('ui_btn_restore'), body + '\n\n' + t('ui_note_restore')
        if action == 'purge':
            if operand == 'expired':
                body = t('ui_confirm_purge_expired', days=self.settings.get('quarantine_retention_days'))
            else:
                body = t('ui_confirm_purge', run=operand, size=size, count=count)
            return t('ui_btn_purge'), body + '\n\n' + permanent
        if action == 'prune_artifacts':
            return t('ui_set_prune_now'), t('ui_confirm_prune', days=self.settings.get('artifact_retention_days'),
                                            path=os.path.join(self.state_dir, 'runs')) + '\n\n' + permanent
        if action == 'schedule':
            if operand == 'install':
                time_text = extra[extra.index('--time') + 1] if '--time' in extra else self.settings.get('schedule_time')
                return t('ui_set_schedule'), t('ui_confirm_schedule_on', time=time_text,
                                               day=t('ui_wd_' + self.settings.get('schedule_weekday')),
                                               plist=ts.launchagent_path(self.home))
            return t('ui_set_schedule'), t('ui_confirm_schedule_off', plist=ts.launchagent_path(self.home))
        if action == 'migrate_apply':
            return t('ui_diag_migrate'), t('ui_confirm_migrate') + '\n\n' + reversible
        return t('ui_dlg_confirm'), action

    def open_plan_review(self, action, operand, extra, go, **ctx):
        """Show the plan review for a cleaning action; its run button is the only way on."""
        include = action == 'clean_selected' or '--include-review' in extra
        only = None
        if action == 'clean_selected':
            only = set(extra[extra.index('--only') + 1].split(',')) if '--only' in extra else set()
        auto_only = {r['id'] for r in self.models.category_rows() if self.category_mode(r)[2]} \
            if action == 'clean_safe' else None
        if action == 'apply_plan':
            path = operand
        else:
            path, _ = tui_data.latest_plan(self.models, self.state_dir, type_of=lambda r: self.run_facts(r).type)
        remove_mode = self.settings.get('remove_mode')

        def open_review(app, plan_path):
            plan = tui_plan.load_plan(plan_path) if plan_path else None
            summary = tui_plan.summarize(plan or {'operations': []}, remove_mode, include, only, auto_only, home=app.home,
                                        mode_of=app.mode_lookup())
            notes = [app.t('ui_plan_note_' + action)]
            if remove_mode == 'permanent':
                notes.append(app.t('ui_plan_note_permanent_mode'))
            review = tui_plan.PlanReview(app.t('ui_plan_title'), plan, summary, go, action, notes)
            review.overlay_ref = review
            app.overlay = review
            app.overlay_scroll = 0
        if path is None and action != 'apply_plan':
            if self.busy():
                self.notify(self.t('ui_busy'), 'status_warn')
                return False
            self.notify(self.t('ui_plan_preparing'), 'status')

            def after(app, model):
                open_review(app, model.plan['path'] if model and model.plan else None)
            return self._launch('preview', None, (), after=after)
        open_review(self, path)
        return True

    def _launch(self, action, operand=None, extra=(), token=None, after=None):
        """Start a job. A mutating action needs the token minted by its confirmation."""
        if is_mutating(action):
            if (action, token) not in self._tokens or token is None:
                self.notify(self.t('ui_not_confirmed'), 'status_warn')
                return False
            self._tokens.discard((action, token))
            if self.read_only:
                self.notify(self.t('ui_readonly'), 'status_warn')
                return False
        if self.busy():
            self.notify(self.t('ui_busy'), 'status_warn')
            return False
        try:
            command = build_command(self.program, action, operand, extra, self.state_dir)
            if action in RUN_ACTIONS:
                run_id = self.next_run_id()
                self.run_dir = os.path.join(self.state_dir, 'runs', run_id)
                mc_paths.make_private_dirs(self.run_dir)
                self.event_path = os.path.join(self.run_dir, 'events.jsonl')
                fd = os.open(self.event_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                os.close(fd)
                env = child_environment(self.lang, self.settings.child_env(), self.paths, self.event_path, run_id)
            else:
                env = child_environment(self.lang, self.settings.child_env(), self.paths)
            job = TerminalJob(command, env)
            job.resize(max(10, self.rows - 6), max(40, self.cols // 2))
            job.start()
        except Exception as exc:
            self.cleanup_items()
            self.notify(self.t('ui_error', message=plain(exc)), 'status_warn')
            return False
        self.job, self.job_action = job, action
        if action in ('clean_safe', 'clean_selected', 'apply_plan', 'scan', 'preview') and self.screen_index != 0:
            # Progress and the result live on the Dashboard (screen 1); a run started elsewhere must not look
            # like nothing happened.
            self.switch(0)
        if after:
            self.after_job.append(after)
        if action in RUN_ACTIONS:
            self.job_kind = 'run'
            self.run = RunModel(action, dry_run=not is_mutating(action), selected=extra[extra.index('--only') + 1].split(',')
                                if '--only' in extra else ())
            self.run_log = LogBuffer()
            self.tailer = EventTailer(self.event_path)
            self.show_result = False
            self.prompt_hidden = None
            self.log_scroll = 0
            self.screens[0].reset_run(self)
        else:
            self.job_kind = 'task'
            self.task_log = LogBuffer()
        self.notify(self.t('ui_started', name=self.t('ui_act_' + action)), 'status')
        return True

    def current_log(self):
        return self.run_log if self.job_kind == 'run' else self.task_log

    # -- background calls, selective-restore files, updates ------------------------------
    def async_call(self, fn, done):
        """Run ``fn`` on a worker thread; ``done(app, result, error)`` runs in tick()."""
        with self._alock:
            self._apending += 1

        def work():
            try:
                outcome = (done, fn(), None)
            except Exception as exc:
                outcome = (done, None, str(exc)[:80] or 'error')
            with self._alock:
                self._adone.append(outcome)
        threading.Thread(target=work, daemon=True).start()

    def wait_async(self, timeout=20.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            with self._alock:
                if not self._apending:
                    break
            self.tick()
            time.sleep(0.01)
        self.tick()

    def write_items_file(self, paths):
        """The selected original paths, one per line, in a 0600 file inside a private
        0700 temp dir. Returns the file path; ``cleanup_items`` removes it."""
        from tui_itemlist import has_control
        if not paths or any((not isinstance(p, str)) or has_control(p) or not p.startswith('/') for p in paths):
            raise ValueError('invalid_selection')
        self.cleanup_items()
        directory = tempfile.mkdtemp(prefix='macos-cleanup-items-')
        os.chmod(directory, 0o700)
        path = os.path.join(directory, 'items.txt')
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(''.join(p + '\n' for p in paths))
        self._items_dir = directory
        return path

    def cleanup_items(self):
        directory, self._items_dir = self._items_dir, None
        if directory:
            try:
                os.unlink(os.path.join(directory, 'items.txt'))
            except OSError:
                pass
            try:
                os.rmdir(directory)
            except OSError:
                pass

    def close(self):
        self.cleanup_items()

    def begin_restore(self, run_id, paths=None, info=None):
        """Selective (or whole-run) restore: validate the run id against the listing,
        ask the engine for a dry-run preview, then show it. Nothing is restored here."""
        runs = {r['run_id']: r for r in self.models.quarantine_runs()}
        if run_id not in runs:
            self.notify(self.t('ui_restore_unknown_run'), 'status_warn')
            return False
        if self.busy():
            self.notify(self.t('ui_busy'), 'status_warn')
            return False
        extra = []
        try:
            if paths:
                extra = ['--items-file', self.write_items_file(paths)]
        except (ValueError, OSError) as exc:
            self.notify(self.t('ui_error', message=plain(exc)), 'status_warn')
            return False
        info = dict(info or {})
        self.notify(self.t('ui_restore_previewing'), 'status')

        def fetch():
            from tui_backend import run_json
            return run_json(self.program, 'restore_preview', self.env_for_json(), 60, run_id, extra, self.state_dir)

        def done(app, data, error):
            preview = data if isinstance(data, dict) and isinstance(data.get('items'), list) else None
            if preview is None:
                app.notify(app.t('ui_restore_preview_local'), 'status_warn')
                preview = info.get('local_preview') or dict(run_id=run_id, items=[], totals={})
            self.open_restore_preview(run_id, preview, extra, paths)
        self.async_call(fetch, done)
        return True

    def open_restore_preview(self, run_id, preview, extra, paths):
        from tui_runner import fmt_bytes as _fb
        items = [i for i in preview.get('items', []) if isinstance(i, dict)]
        will = [i for i in items if i.get('action') == 'restore']
        skipped = [i for i in items if i.get('action') != 'restore']
        info = dict(bytes=sum(i.get('bytes', 0) for i in will if isinstance(i.get('bytes'), int)), items=len(will),
                    conflicts=len(skipped))

        def go(app, value):
            if value != 'run':
                app.cleanup_items()
                return
            if not will:
                app.notify(app.t('ui_restore_nothing'), 'status_warn')
                app.cleanup_items()
                return
            action = 'restore_items' if extra else 'restore'
            app.start_confirmed(action, run_id, extra)
        review = tui_plan.RestorePreview(self.t('ui_restore_preview_title', run=run_id), preview, go)
        review.overlay_ref = review
        self.overlay = review
        self.overlay_scroll = 0

    def check_updates(self):
        """Manual update check (never automatic). A failed check is shown as failed,
        never as up to date."""
        if self.paths.get('mode') == 'checkout':
            self.update_state = dict(status='dev')
            self.notify(self.t('ui_update_dev'), 'status')
            return
        self.update_state = dict(status='checking')
        self.notify(self.t('ui_update_checking'), 'status')

        def fetch():
            from tui_backend import run_json
            return run_json(self.program, 'update_check', self.env_for_json(), 60)

        def done(app, data, error):
            if not isinstance(data, dict) or data.get('latest') in (None, ''):
                app.update_state = dict(status='failed')
                app.notify(app.t('ui_update_failed'), 'status_warn')
                return
            state = dict(current=plain(data.get('current', ''))[:32], latest=plain(data.get('latest'))[:32],
                         url=plain(data.get('release_url') or '')[:200])
            if data.get('update_available') is True:
                state['status'] = 'available'
                app.update_state = state
                app.request_action('update_self', info=dict(current=state['current'], latest=state['latest']),
                                   after=app.after_update)
            else:
                state['status'] = 'current'
                app.update_state = state
                app.notify(app.t('ui_update_current', version=state['current']), 'status_ok')
        self.async_call(fetch, done)

    def after_update(self, app, model):
        if app.update_state.get('status') == 'available':
            def done(a, value):
                if value == 'quit':
                    a.should_exit = True
            app.dialog = Dialog(app.t('ui_update_restart_title'), app.t('ui_update_restart_body'),
                                [(app.t('ui_btn_quit'), 'quit'), (app.t('ui_btn_later'), None)], done, default=0)

    def tick(self):
        self.tick_count += 1
        with self._alock:
            finished, self._adone = self._adone, []
            self._apending -= len(finished)
        for done, result, error in finished:
            done(self, result, error)
        for name in self.models.poll():
            self.screen.models_changed(self, name)
        job = self.job
        if job is not None:
            log = self.current_log()
            try:
                chunks = job.poll()
            except OSError:
                chunks = []
            for chunk in chunks:
                log.feed(chunk)
            if self.run is not None and self.tailer is not None:
                for event in self.tailer.read():
                    self.run.handle(event)
                    if event.get('type') in ('group_start', 'item_start') and self.run.active:
                        self.run_log.begin(self.run.active[0])
            if log.count != self.detected_count:
                self.detected_count = log.count
                self.answered_detected.clear()
            self.check_prompts(job, log)
            if not job.running:
                now = time.monotonic()
                if self._exit_seen is None:
                    self._exit_seen = now
                if job._master is None or now - self._exit_seen > 3:
                    self.finish_job()
            else:
                self._exit_seen = None
        if self.dialog is not None:
            self.dialog.tick(self)

    def check_prompts(self, job, log):
        prompt = self.run.prompt if self.run is not None else None
        if prompt is None and job.running:
            idle = time.monotonic() - log.last_output
            try:
                secret = job.secret_input
            except Exception:
                secret = False
            found = detect_prompt(log, secret, idle, allow_yesno=not (self.run is not None and self.run.prompt_events))
            if found and found['id'] not in self.answered_detected:
                prompt = found
                if self.run is not None:
                    self.run.prompt = found
                else:
                    self._task_prompt = found
            elif self._task_prompt is not None and self.run is None:
                prompt = self._task_prompt
        if prompt is None or self.prompt_hidden == prompt['id']:
            return
        if self.dialog is not None and getattr(self.dialog, 'ident', None) == prompt['id']:
            return
        self.dialog = prompt_dialog(self, prompt)

    def answer_prompt(self, prompt, value, secret=False):
        if value is None:
            self.prompt_hidden = prompt['id']
            self.notify(self.t('ui_prompt_waiting'), 'status_warn')
            return
        self.prompt_hidden = None
        self._task_prompt = None
        self.answered_detected.update(('pty-sudo', 'pty-yesno'))
        if prompt.get('detected'):
            self.answered_detected.add(prompt['id'])
        if self.run is not None:
            self.run.answered.add(prompt['id'])
            self.run.prompt = None
        if value == 'timeout':
            self.notify(self.t('ui_default_used'), 'status')
            return
        if self.job is not None:
            try:
                self.job.send(value + '\n')
            except (OSError, ValueError):
                pass
        value = None
        self.notify(self.t('ui_password_sent' if secret else 'ui_answer_sent'), 'status_ok')

    def reopen_prompt(self):
        prompt = (self.run.prompt if self.run is not None else None) or self._task_prompt
        self.prompt_hidden = None
        if prompt is not None:
            self.dialog = prompt_dialog(self, prompt)

    def finish_job(self):
        job, kind, action = self.job, self.job_kind, self.job_action
        self._exit_seen = None
        code = job.returncode
        model = None
        if kind == 'run' and self.run is not None:
            if self.tailer is not None:
                for event in self.tailer.read():
                    self.run.handle(event)
            self.run.finish(returncode=code, stopped=job.stop_requested)
            model = self.last_model = self.run
            self.last_model_epoch = time.time()
            self.run = None
            self.show_result = action != 'restore_preview'
            self.prompt_hidden = None
            self.event_path = self.tailer = None
            self.prune_events()
            if self.dialog is not None and getattr(self.dialog, 'ident', None):
                self.dialog = None
            self.notify(self.t('ui_finished' if code == 0 else 'ui_job_failed', name=self.t('ui_act_' + action)),
                        'status_ok' if code == 0 else 'status_warn')
            if self.screen_index == 0:
                self.focus_zone('actions')
        else:
            self.notify(self.t('ui_finished' if code == 0 else 'ui_job_failed', name=self.t('ui_act_' + action)),
                        'status_ok' if code == 0 else 'status_warn')
            self._task_prompt = None
            if action == 'schedule':
                self.schedule_cache = None
        self.job, self.job_kind, self.job_action = None, None, None
        self.cleanup_items()
        if is_mutating(action) or action in RUN_ACTIONS:
            for name in ('history', 'list_quarantine', 'categories', 'doctor'):
                self.models.refresh(name)
        callbacks, self.after_job = self.after_job, []
        for callback in callbacks:
            callback(self, model)
        if self.exit_after_job:
            self.should_exit = True

    def prune_events(self):
        """Keep only the newest EVENT_KEEP events files; the run dir itself is the engine's."""
        runs = os.path.join(self.state_dir, 'runs')
        try:
            names = sorted(n for n in os.listdir(runs) if tui_registry.RUN_ID_PATTERN.fullmatch(n))
            with_events = [n for n in names if os.path.isfile(os.path.join(runs, n, 'events.jsonl'))
                           and not os.path.islink(os.path.join(runs, n, 'events.jsonl'))]
            for name in with_events[:-EVENT_KEEP]:
                os.unlink(os.path.join(runs, name, 'events.jsonl'))
        except OSError:
            pass

    def ask_stop(self):
        if self.job is None:
            return

        def done(app, value):
            if value == 'stop' and app.job is not None:
                app.job.interrupt()
                app.notify(app.t('ui_stopping'), 'status_warn')
        self.dialog = Dialog(self.t('ui_dlg_stop_title'), self.t('ui_dlg_stop_body'),
                             [(self.t('ui_btn_stop_run'), 'stop'), (self.t('ui_btn_keep'), None)], done, default=1)

    def ask_quit(self):
        if self.job is None or not self.job.running:
            self.should_exit = True
            return

        def done(app, value):
            if value == 'detach':
                app.exit_mode = 'detach'
                app.should_exit = True
            elif value == 'stop' and app.job is not None:
                app.job.interrupt()
                app.exit_after_job = True
                app.notify(app.t('ui_stopping'), 'status_warn')
        self.dialog = Dialog(self.t('ui_dlg_quit_title'), self.t('ui_dlg_quit_body'),
                             [(self.t('ui_btn_keep'), None), (self.t('ui_btn_detach'), 'detach'),
                              (self.t('ui_btn_stop_run'), 'stop')], done, default=0)

    def toggle_full_log(self):
        self.overlay = None if self.overlay == 'log' else 'log'
        self.overlay_scroll = 0

    def open_viewer(self, title, lines):
        self.overlay = ('viewer', title, lines)
        self.overlay_scroll = 0

    def open_items(self, itemlist):
        self.overlay = ('items', itemlist)
        self.overlay_scroll = 0

    def view_file(self, path, title, markdown=False):
        text = tui_data.read_text_file(path, tail=not markdown)
        if text is None:
            self.notify(self.t('ui_no_file'), 'status_warn')
            return
        if markdown:                                   # a report: headings, lists and code blocks, shown from the top
            self.overlay = ('markdown', title, text)
            self.overlay_scroll = 10 ** 9
            return
        buffer = LogBuffer()
        buffer.feed(text + '\n')
        self.open_viewer(title, buffer.all_lines()[-3000:])

    # -- settings actions (implemented in tui_screens_settings) ----------------------
    def after_setting(self, key):
        if key in ('theme', 'accent', 'ascii', 'mouse'):
            self.theme_dirty = True
        if key == 'help_open':
            self.help_visible = None
        if key == 'animate':
            self.animate = bool(self.settings.get('animate'))
        if key in ('quarantine_retention_days',):
            self.models.refresh('list_quarantine')

    def settings_action(self, key, screen):
        from tui_screens_settings import perform_action
        perform_action(self, key, screen)

    # -- presentation helpers --------------------------------------------------------
    def explain(self, item):
        reason = item.reason or 'unknown'
        return self.t('reason_' + reason), self.t('reason_%s_do' % reason)

    def log_display_lines(self, width):
        log = self.run_log
        if log is None:
            return []
        g = self.glyphs
        model = self.current_model()
        out = []
        section = None
        for gid, lines in log.blocks:
            group = (model.cats['clean'].get(gid) or model.cats['scan'].get(gid)) if model and gid else None
            if group is not None:
                # The engine prints one header per section it knows; a category block is drawn under its own
                # section's name, not under whatever header was printed last.
                kind = tui_registry.info(gid)['section']
                if kind and kind != section:
                    out.append((self.t('sect_' + kind.replace('-', '_')), 'strong'))
                section = kind
                glyph, style = status_glyph(self, group.state, group.result, self.tick_count)
                running = group.state == 'running'
                collapsed = group.state == 'done' and group.result == 'ok' and not self.log_expand_all
                tail = duration(group.elapsed()) if group.started else ''
                header = '%s %s %s' % (g['collapse'] if collapsed else g['expand'], glyph, self.category_label(gid))
                if running:
                    tail = self.t('ui_log_block_running') + ' ' + tail
                out.append((pad(header, max(0, width - text_width(tail) - 1)) + ' ' + tail, style if not running else 'accent'))
                if collapsed:
                    continue
                out.extend((line, 'base') for line in wrap_log(lines, width))
            else:
                section = None
                out.extend((line, 'base') for line in wrap_log(lines, width, ''))
        partial = log.visible_partial()
        if partial.strip():
            out.extend((line, 'base') for line in wrap_log([partial], width))
        return out

    # -- layout and drawing ------------------------------------------------------------
    def help_shown(self, mode):
        if self.help_visible is not None:
            return self.help_visible
        return mode == 'wide' and self.settings.get('help_open')

    def layout(self, h, w):
        body = Rect(2, 0, h - 4, w)
        mode = 'wide' if w >= 120 and h >= 24 else ('medium' if w >= 80 and h >= 20 else 'narrow')
        ratio = SIDE_RATIO.get(self.screen.id, 0.4)
        help_rect = main = side = None
        show_help = self.help_shown(mode)
        if mode == 'wide':
            content = body
            if show_help:
                hw = max(32, min(36, w // 5))
                help_rect = Rect(body.y, w - hw, body.h, hw)
                content = Rect(body.y, 0, body.h, w - hw)
            target = MAIN_TARGET.get(self.screen.id)
            if target:                  # a wide terminal: let the list have what its longest name needs, the side pane keeps 40
                target = max(target, min(self.screen.wanted_main(self), content.w - 40))
            sw = 0 if self.screen.id in NO_SIDE_PANE else (content.w - target) if target else int(content.w * ratio)
            if target and sw < 30 and self.screen.id not in NO_SIDE_PANE:
                sw = int(content.w * ratio) if content.w - int(content.w * ratio) >= MIN_MAIN.get(self.screen.id, 40) else 0
            if sw >= 26 and content.w - sw >= MIN_MAIN.get(self.screen.id, 50):
                main = Rect(content.y, content.x, content.h, content.w - sw)
                side = Rect(content.y, content.x + content.w - sw, content.h, sw)
            else:
                main = content
        elif mode == 'medium':
            target = MAIN_TARGET.get(self.screen.id)
            sw = max(28, int(w * max(ratio, 0.38))) if ratio else 0
            if target and w - target >= 28:
                sw = w - target
            if self.screen.id in NO_SIDE_PANE:
                sw = 0
            if sw and w - sw < MIN_MAIN.get(self.screen.id, 50):
                sw = 0
            main = Rect(body.y, 0, body.h, w - sw) if sw else body
            side = Rect(body.y, w - sw, body.h, sw) if sw else None
            if show_help:
                if side is None:
                    hw = max(28, w // 3)
                    main = Rect(body.y, 0, body.h, w - hw)
                    side = Rect(body.y, w - hw, body.h, hw)
                help_rect, side = side, None
        else:
            if body.h >= 16 and ratio and self.screen.id in ('dashboard', 'diagnostics', 'quarantine'):
                mh = max(9, int(body.h * 0.6))
                if self.screen.id == 'dashboard':
                    mh = min(body.h - 5, max(mh, 13)) if self.run is not None else body.h
                main = Rect(body.y, 0, mh, w)
                side = Rect(body.y + mh, 0, body.h - mh, w) if body.h - mh >= 3 else None
            else:
                main = body
            if show_help:
                if side is None:
                    mh = max(6, body.h // 2)
                    main = Rect(body.y, 0, mh, w)
                    side = Rect(body.y + mh, 0, body.h - mh, w)
                help_rect, side = side, None
        return mode, main, side, help_rect

    def frame(self, h, w):
        self.rows, self.cols = h, w
        c = Canvas(h, w, self.glyphs)
        if h < MIN_ROWS or w < MIN_COLS:
            msg = self.t('ui_too_small', cols=MIN_COLS, rows=MIN_ROWS)
            for i, line in enumerate(wrap(msg, max(1, w - 2))[:h]):
                c.put(i, 1, line, 'warn')
            self.last_canvas = c
            return c
        mode, main, side, help_rect = self.layout(h, w)
        self.mode = mode
        zones = self.screen.zones(self)
        if self.zone not in zones and self.zone not in ('tabs', 'help'):
            self.zone = zones[0]
        if self.zone == 'help' and help_rect is None:
            self.zone = self.help_target if self.help_target in zones else zones[0]
        self.draw_header(c, w)
        self.draw_tabs(c, w)
        if main is not None:
            c.region(main.y, main.x, main.h, main.w, ('pane', zones[0]))
        if side is not None and len(zones) > 1:
            c.region(side.y, side.x, side.h, side.w, ('pane', zones[-1]))
        if self.overlay is not None:
            self.draw_overlay(c, Rect(2, 0, h - 4, w))
        else:
            self.screen.render(self, c, main, side)
        if help_rect is not None and self.overlay is None:
            c.region(help_rect.y, help_rect.x, help_rect.h, help_rect.w, ('pane', 'help'))
            self.draw_help(c, help_rect)
        if self.dialog is not None:
            self.dialog.render(self, c)
        self.draw_status(c, h - 2, w)
        self.draw_keybar(c, h - 1, w)
        self.last_canvas = c
        return c

    def draw_header(self, c, w):
        g = self.glyphs
        c.fill(0, 0, 1, w, 'header')
        x = c.put(0, 0, ' %s %s ' % (self.t('ui_app_name'), self.version), 'header_accent')
        model = self.run
        if model is not None:
            pct = int(round(model.overall() * 100))
            state = '%s %s ' % (g['spinner'][self.tick_count % len(g['spinner'])] if self.animate else g['running'],
                                self.t('ui_run_in_progress', percent=pct))
            right_style = 'header_accent'
        else:
            state = self.idle_status()
            right_style = 'header'
        if self.read_only or (model is not None and model.dry_run):      # the badge appears once
            state = self.t('ui_preview_badge') + ' ' + state
        middle = ''
        for fact in (self.sysinfo.get('host', ''), 'macOS ' + self.sysinfo.get('macos', '?')):
            candidate = (middle + '  %s  ' % g['sep'] if middle else ' ') + fact
            if x + text_width(candidate) + text_width(state) + 2 <= w:
                middle = candidate
        c.put(0, x, middle, 'header')
        if x + text_width(middle) + text_width(state) + 1 <= w:
            c.put(0, w - text_width(state), state, right_style)

    def idle_status(self):
        """Right side of the header while nothing runs: Idle plus the last run's result;
        'No runs yet' only when there is no history at all."""
        g = self.glyphs
        counts = ''
        if self.last_model is not None:
            result = {'ok': 'ok', 'warn': 'warn', 'failed': 'error', 'stopped': 'cancelled'}.get(self.last_model.result, 'unknown')
            c = self.last_model.counts()
            if self.last_model.type() not in ('scan', 'preview') and not self.last_model.dry_run:    # a scan changes nothing: no counters
                counts = ' %s%d %s%d %s%d' % (g['ok'], c['cleaned'] + c['quarantined'] + c['restored'], g['needs'], c['skipped'], g['fail'], c['failed'])
        else:
            rows = self.models.history_rows()
            if not rows:
                return self.t('ui_last_run_none') + ' '
            result = {'ok': 'ok', 'warn': 'warn', 'error': 'error', 'cancelled': 'cancelled'}.get(rows[0].get('result'), 'unknown')
        return self.t('ui_header_idle', result=self.t('ui_res_run_' + result)) + counts + ' '

    def tab_labels(self, w):
        full = [' %d %s ' % (i + 1, self.t(s.tab)) for i, s in enumerate(self.screens)]
        if sum(text_width(l) + 1 for l in full) <= w:
            return full
        return [full[i] if i == self.screen_index else ' %d ' % (i + 1) for i in range(len(full))]

    def draw_tabs(self, c, w):
        x = 0
        focused = self.zone == 'tabs' and self.dialog is None
        for i, label in enumerate(self.tab_labels(w)):
            active = i == self.screen_index
            if active and focused:
                label = label.replace(' ', self.glyphs['marker'], 1) if self.glyphs['tl'] != '+' else '>' + label[1:]
            end = c.put(1, x, label, 'tab_active' if active else 'tab')
            c.region(1, x, 1, end - x, ('tab', i))
            x = end + 1
        if x < w:
            c.put(1, x, self.glyphs['h'] * (w - x), 'border')

    def zone_help(self, zone):
        if zone == 'tabs':
            return self.t('ui_help_tabs')
        if zone == 'help':
            return self.t('ui_help_help')
        if zone == 'overlay':
            return self.t('ui_help_log')
        return self.screen.help(self, zone)

    def draw_help(self, c, rect):
        focused = self.zone == 'help' and self.dialog is None
        c.box(rect, self.t('ui_pane_help'), focused)
        inner = rect.inner()
        if self.dialog is not None:
            text = self.t(getattr(self.dialog, 'help_key', 'ui_help_dialog'))
        else:
            target = self.zone if self.zone != 'help' else self.help_target
            text = self.zone_help(target)
        intro = [(l, 'accent') for l in wrap(self.t('ui_help_this_screen'), inner.w)]
        intro += [(l, 'base') for l in wrap(self.t('ui_intro_' + self.screen.id), inner.w)]
        selected = [(l, 'accent') for l in wrap(self.t('ui_help_selected'), inner.w)]
        selected += [(l, 'base') for l in wrap(text, inner.w)]
        keys = [(l, 'accent') for l in wrap(self.t('ui_help_keys_now'), inner.w)]
        ascii_only = self.glyphs['tl'] == '+'
        seen = set()
        shown = []
        for binding in self.active_bindings():
            if binding.label in seen or not binding.label:
                continue
            seen.add(binding.label)
            shown.append((key_display(binding, ascii_only), binding))
        kw = min(max([8] + [text_width(k) + 1 for k, _ in shown]), max(8, inner.w // 2))      # the key column fits its widest key
        for key, binding in shown:
            parts = wrap(self.t(binding.label), max(4, inner.w - kw))
            keys.append((pad(key, kw - 1) + ' ' + parts[0], 'keyline'))
            keys.extend((' ' * kw + p, 'base') for p in parts[1:])
        rows = {}
        if len(intro) + len(selected) + len(keys) + 2 <= inner.h:
            for i, line in enumerate(intro):
                rows[i] = line
            for i, line in enumerate(selected):
                rows[len(intro) + 1 + i] = line
            for i, line in enumerate(keys):
                rows[inner.h - len(keys) + i] = line
        else:
            flow = intro + [('', 'base')] + selected + [('', 'base')] + keys
            self.help_scroll = min(self.help_scroll, max(0, len(flow) - inner.h))
            for i, line in enumerate(flow[self.help_scroll:self.help_scroll + inner.h]):
                rows[i] = line
        for i, (line, style) in rows.items():
            if style == 'keyline':
                kcol = min(max([8] + [text_width(k) + 1 for k, _ in shown]), max(8, inner.w // 2))
                c.put(inner.y + i, inner.x, line[:kcol - 1], 'accent', inner.w)
                c.put(inner.y + i, inner.x + kcol - 1, line[kcol - 1:], 'base', inner.w - kcol + 1)
            else:
                c.put(inner.y + i, inner.x, line, style, inner.w)

    def draw_overlay(self, c, rect):
        g = self.glyphs
        ov = self.overlay
        if isinstance(ov, tui_plan.PlanReview):
            return self.draw_plan_review(c, rect, ov)
        if ov == 'log':
            title = self.t('ui_pane_log')
            lines = self.log_display_lines(rect.w - 4) if self.run_log else []
            if self.job_kind == 'task' or (self.run_log is None and self.task_log):
                lines = [(l, 'base') for l in wrap_log(self.task_log.all_lines() if self.task_log else [], rect.w - 4, '')]
        elif ov[0] == 'items':
            il = ov[1]
            c.box(rect, il.title or self.t('ui_pane_items'), self.dialog is None,
                  right=self.t('ui_key_close') + ': Esc')
            inner = rect.inner()
            top = inner.y
            if il.readonly_note:
                for line in wrap(il.readonly_note, inner.w)[:3]:
                    c.put(top, inner.x, line, 'base')
                    top += 1
            il.render(self, c, Rect(top, inner.x, inner.y + inner.h - top, inner.w))
            return
        elif ov[0] == 'markdown':
            title = ov[1]
            lines = tui_markdown.render(ov[2], rect.w - 4, g)
        else:
            title = ov[1]
            lines = [(l, 'base') for line in ov[2] for l in (wrap(plain(line), max(8, rect.w - 4)) or [''])]
        c.box(rect, title, self.dialog is None, right=self.t('ui_key_close') + ': Esc')
        inner = rect.inner()
        self.overlay_scroll = min(self.overlay_scroll, max(0, len(lines) - inner.h))
        end = len(lines) - self.overlay_scroll
        for i, (text, style) in enumerate(lines[max(0, end - inner.h):end]):
            c.put(inner.y + i, inner.x, clip(text, inner.w, g['ellipsis']), style)

    def draw_plan_review(self, c, rect, review):
        g = self.glyphs
        c.box(rect, review.title, self.dialog is None, right=self.t('ui_plan_scroll'))
        inner = rect.inner()
        foot = 3 if review.needs_ack() else 2
        area = Rect(inner.y, inner.x, max(1, inner.h - foot), inner.w)
        lines = review.lines(self, area.w - 1)
        review.scroll = min(review.scroll, max(0, len(lines) - area.h))
        for i, (text, style) in enumerate(lines[review.scroll:review.scroll + area.h]):
            c.put(area.y + i, area.x, clip(text, area.w, g['ellipsis']), style)
        y = inner.y + inner.h - foot
        c.put(y, inner.x, g['h'] * inner.w, 'border')
        y += 1
        if review.needs_ack():
            box = g['check_on'] if review.acked else g['check_off']
            text = '%s %s' % (box, self.t('ui_plan_ack', count=review.permanent_count))
            style = 'sel_focus' if review.focus == 'ack' else 'warn'
            c.put(y, inner.x, clip(text, inner.w, g['ellipsis']), style)
            c.region(y, inner.x, 1, inner.w, ('plan', 'ack'))
            y += 1
        x = inner.x
        enabled = review.run_enabled()
        x = c.button(y, x, self.t('ui_btn_run'), focused=review.focus == 'run' and self.dialog is None,
                     primary=enabled, disabled=not enabled, action=('plan', 'run')) + 2
        c.button(y, x, self.t('ui_btn_cancel'), focused=review.focus == 'cancel' and self.dialog is None,
                 action=('plan', 'cancel'))

    def draw_status(self, c, y, w):
        text, style, when = self.notice
        g = self.glyphs
        if not text or time.monotonic() - when > NOTICE_SECONDS:
            text, style = '', 'status'
            if self.job is not None:
                log = self.current_log()
                started = self.job.started_at or time.monotonic()
                elapsed = duration(time.monotonic() - started)
                spinner = g['spinner'][self.tick_count % len(g['spinner'])] if self.animate else g['running']
                line = log.last_meaningful_line() if log else ''
                if self.prompt_hidden:
                    text, style = self.t('ui_prompt_waiting'), 'status_warn'
                elif line:
                    text = spinner + ' ' + self.t('ui_waiting_events', elapsed=elapsed, line=plain(line)[:200])
                else:
                    text = spinner + ' ' + self.t('ui_working', elapsed=elapsed)
        c.fill(y, 0, 1, w, 'status')
        c.put(y, 1, clip(text, w - 2, g['ellipsis']), style)

    def active_bindings(self):
        """Bindings valid right now, in key-bar priority order."""
        if self.dialog is not None:
            return self.dialog.bindings()
        ov = self.overlay
        if isinstance(ov, tui_plan.PlanReview):
            return [Binding(('tab', 'btab'), 'ui_key_choose', 'tab', display='Tab'),
                    Binding(('enter', 'space'), 'ui_key_select', 'enter'),
                    Binding(('up', 'down'), 'ui_key_scroll', 'vmove'), Binding(('esc',), 'ui_key_close', 'esc')]
        if ov is not None and ov != 'log' and ov[0] == 'items':
            return ov[1].bindings() + [Binding(('esc',), 'ui_key_close', 'close', display='Esc')]
        if ov is not None:
            return [Binding(('up', 'down'), 'ui_key_scroll', 'vmove'),
                    Binding(('esc', 'l', 'L'), 'ui_key_close', 'close', display='Esc'),
                    Binding(('pgup', 'pgdn'), 'ui_key_scroll', 'page', show=False)]
        if self.zone == 'tabs':
            local = [Binding(('left', 'right'), 'ui_key_switch_tab', 'hmove'), Binding(('enter', 'down'), 'ui_key_open', 'enter')]
        elif self.zone == 'help':
            local = [Binding(('up', 'down'), 'ui_key_scroll', 'vmove')]
        else:
            local = self.screen.bindings(self, self.zone)
        typing = self.typing()
        local = list(local)
        # On the result page the action keys wait until it is closed: say that Esc is Done.
        done_first = self.zone == 'actions' and self.screen.result_mode(self)
        esc_label = 'ui_btn_done' if done_first else 'ui_key_back'
        if self.zone == 'search':                      # keys type into the search field; Esc is the way out
            esc_label = 'ui_key_clear_search' if getattr(self.screen, 'query', '') else 'ui_key_leave_search'
        out = local[:2] + [Binding(('tab', 'btab'), 'ui_key_next_pane', 'tab', display='Tab'),
                           Binding(('esc',), esc_label, 'esc')] + local[2:]
        if not typing:
            out += [Binding(tuple(str(i + 1) for i in range(len(self.screens))), 'ui_key_screens', 'digit',
                            display='1-%d' % len(self.screens)),
                    Binding(('?', 'f1'), 'ui_key_help', 'help', display='?'),
                    Binding(('l', 'L'), 'ui_key_log', 'log', display='L'),
                    Binding(('q', 'ctrl-c'), 'ui_key_quit', 'quit', display='q')]
        return out

    def typing(self):
        return self.zone == 'search' and self.dialog is None and self.overlay is None

    def draw_keybar(self, c, y, w):
        c.fill(y, 0, 1, w, 'keybar')
        ascii_only = self.glyphs['tl'] == '+'
        x = 1
        for key, label, action in keybar_items(self.active_bindings(), self.t, w - 2, ascii_only):
            start = x
            x = c.put(y, x, key, 'keybar_key')
            x = c.put(y, x + 1, label, 'keybar')
            c.region(y, start, 1, x - start, ('keybar', key))
            x += 3

    # -- input -------------------------------------------------------------------------
    def key(self, raw):
        name = key_name(raw) if not isinstance(raw, str) or len(raw) == 1 else raw
        return self.key_name(name)

    def key_name(self, name):
        if name in ('resize', 'mouse'):
            return True
        if self.dialog is not None:
            dialog = self.dialog
            if dialog.key(self, name):
                return True
            if name == 'ctrl-c':
                self.ask_quit()
                return True
            return self.unknown()
        if self.overlay is not None:
            return self.overlay_key(name)
        if self.typing() and (len(name) == 1 or name == 'space'):
            if self.screen.text(self, self.zone, ' ' if name == 'space' else name):
                return True
        if self.zone == 'tabs':
            if name in ('left', 'right'):
                self.switch((self.screen_index + (1 if name == 'right' else -1)) % len(self.screens))
                self.zone = 'tabs'
                return True
            if name in ('enter', 'down', 'space'):
                self.focus_zone(self.screen.zones(self)[0])
                return True
        elif self.zone == 'help':
            if name in ('up', 'down', 'pgup', 'pgdn'):
                self.help_scroll = max(0, self.help_scroll + {'up': -1, 'down': 1, 'pgup': -8, 'pgdn': 8}[name])
                return True
        else:
            binding = lookup(self.screen.bindings(self, self.zone), name)
            if binding is not None:
                action = name if binding.action in GENERIC else binding.action
                if self.screen.action(self, self.zone, action):
                    return True
            elif name in ('up', 'down', 'left', 'right') and self.screen.action(self, self.zone, name):
                return True
        return self.global_key(name)

    def overlay_key(self, name):
        ov = self.overlay
        if isinstance(ov, tui_plan.PlanReview):
            if ov.key(self, name):
                return True
            if name == 'ctrl-c':
                self.ask_quit()
                return True
            return self.unknown()
        if ov != 'log' and ov[0] == 'items':
            il = ov[1]
            if il.searching and (len(name) == 1 or name == 'space'):
                il.text(' ' if name == 'space' else name)
                return True
            if name == 'esc' and il.searching:
                il.searching = False
                return True
            if name == 'esc' or (name in ('q',) and not il.searching):
                self.overlay = None
                return True
            binding = lookup(il.bindings(), name)
            if il.searching and name in ('enter', 'down', 'backspace'):
                return il.action(self, {'enter': 'enter', 'down': 'down', 'backspace': 'backspace'}[name])
            if binding is not None:
                action = name if binding.action in GENERIC else binding.action
                if il.action(self, action):
                    return True
            elif name in ('up', 'down', 'pgup', 'pgdn', 'home', 'end'):
                return il.action(self, name)
            if name == 'ctrl-c':
                self.ask_quit()
                return True
            return self.unknown()
        if name in ('esc', 'l', 'L', 'q', 'enter'):
            self.overlay = None
            return True
        step = {'up': 1, 'down': -1, 'pgup': 15, 'pgdn': -15, 'home': 10 ** 6, 'end': -10 ** 6}.get(name)
        if step is not None:
            self.overlay_scroll = max(0, self.overlay_scroll + step)
            return True
        if name == 'ctrl-c':
            self.ask_quit()
            return True
        return self.unknown()

    def zone_cycle(self):
        zones = list(self.screen.zones(self))
        mode, main, side, help_rect = self.layout(self.rows, self.cols)
        if help_rect is not None:
            zones.append('help')
        zones.append('tabs')
        return zones

    def global_key(self, name):
        typing = self.typing()
        if name in ('tab', 'btab'):
            zones = self.zone_cycle()
            current = zones.index(self.zone) if self.zone in zones else 0
            self.focus_zone(zones[(current + (1 if name == 'tab' else -1)) % len(zones)])
            return True
        if name == 'esc':
            return self.back()
        if not typing:
            if name.isdigit() and len(name) == 1 and 1 <= int(name) <= len(self.screens):
                self.switch(int(name) - 1)
                return True
            if name in ('?', 'f1'):
                mode = getattr(self, 'mode', 'wide')
                if mode == 'wide' and self.help_shown(mode):
                    if self.zone == 'help':
                        self.help_visible = False
                        self.focus_zone(self.help_target)
                    else:
                        self.focus_zone('help')
                else:
                    self.help_visible = not self.help_shown(mode)
                return True
            if name in ('l', 'L'):
                self.toggle_full_log()
                return True
            if name in ('q', 'ctrl-c', 'f10'):
                self.ask_quit()
                return True
        if name == 'ctrl-c':
            self.ask_quit()
            return True
        if name == 'ctrl-l':
            return True
        return self.unknown()

    def back(self):
        screen = self.screen
        zones = screen.zones(self)
        if self.zone == 'search' and getattr(screen, 'query', ''):
            screen.query = ''
            return True
        if self.screen.id == 'dashboard' and self.run is not None and self.job is not None:
            self.ask_stop()
            return True
        if self.zone not in (zones[0],):
            self.focus_zone(zones[0])
            return True
        if self.screen_index != 0:
            self.switch(0)
            return True
        if screen.result_mode(self):
            screen.press(self, 'done')
            return True
        self.notify(self.t('ui_nothing_back'), 'status')
        return True

    def unknown(self):
        ascii_only = self.glyphs['tl'] == '+'
        keys = []
        for binding in self.active_bindings():
            if binding.show:
                keys.append(key_display(binding, ascii_only))
            if len(keys) >= 5:
                break
        self.notify(self.t('ui_unknown_key', keys='  '.join(keys)), 'status_warn')
        return False

    def mouse(self, y, x, kind):
        """kind: 'click' | 'double' | 'wheel_up' | 'wheel_down'."""
        canvas = self.last_canvas
        if canvas is None or not self.settings.get('mouse'):
            return False
        payload = canvas.hit(y, x)
        if kind in ('wheel_up', 'wheel_down'):
            delta = -3 if kind == 'wheel_up' else 3
            if self.dialog is not None:
                self.dialog.key(self, 'up' if delta < 0 else 'down')
                return True
            if isinstance(self.overlay, tui_plan.PlanReview):
                self.overlay.scroll = max(0, self.overlay.scroll + delta)
                return True
            if self.overlay is not None and self.overlay != 'log' and self.overlay[0] == 'items':
                self.overlay[1].move(delta)
                return True
            if self.overlay is not None:
                self.overlay_scroll = max(0, self.overlay_scroll - delta)
                return True
            zone = payload[1] if payload and payload[0] == 'pane' else self.zone
            if zone == 'help':
                self.help_scroll = max(0, self.help_scroll + delta)
                return True
            return self.screen.scroll(self, zone if zone in self.screen.zones(self) else self.zone, delta)
        if payload is None:
            return False
        if self.dialog is not None:
            if payload[0] == 'dialog' and payload[1] is not None:
                self.dialog.click(self, payload[1])
            return True
        what = payload[0]
        if isinstance(self.overlay, tui_plan.PlanReview):
            if what == 'plan':
                self.overlay.click(self, payload[1])
            return True
        if self.overlay is not None and self.overlay != 'log' and self.overlay[0] == 'items':
            if what == 'item_row':
                self.overlay[1].click(payload[1])
            return True
        if what == 'tab':
            self.switch(payload[1])
            return True
        if what == 'keybar':
            name = {'↑↓': 'down', 'Up/Dn': 'down', '←→': 'right', 'Lt/Rt': 'right', 'Enter': 'enter', 'Tab': 'tab',
                    'Esc': 'esc', 'Space': 'space', '?': '?', 'L': 'l', 'q': 'q', 'abc': None}.get(payload[1], payload[1])
            if name and name.startswith('1-'):
                name = None
            return self.key_name(name) if name else True
        if what == 'pane':
            if payload[1] in self.screen.zones(self) or payload[1] == 'help':
                self.focus_zone(payload[1])
            return True
        return self.screen.click(self, payload, double=kind == 'double')


def run_epoch(run_id):
    """Local epoch seconds from a run id (YYYY-MM-DD_HHMMSS_pid), or None."""
    try:
        return time.mktime(time.strptime(run_id[:17], '%Y-%m-%d_%H%M%S'))
    except (ValueError, OverflowError, TypeError):
        return None


def _open_with_finder(command, text=None):
    """Run ``open -R path`` or ``pbcopy``; never through a shell."""
    ok = command[0] == '/usr/bin/pbcopy' or (command[0] == '/usr/bin/open' and (
        (len(command) == 3 and command[1] == '-R' and command[2].startswith('/')) or
        (len(command) == 2 and command[1].startswith('x-apple.systempreferences:'))))
    if not ok:
        raise ValueError('unsupported_helper')
    subprocess.run(command, input=text.encode('utf-8') if text is not None else None, timeout=10,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def system_info():
    try:
        host = os.uname().nodename.split('.')[0]
    except Exception:
        host = ''
    return dict(host=plain(host)[:40], macos=plain(platform.mac_ver()[0] or '?')[:16])


# -- curses loop -------------------------------------------------------------
_WHEEL_DOWN = getattr(curses, 'BUTTON5_PRESSED', 0) or 0x200000


def _blit(screen, canvas, theme):
    for y in range(canvas.h):
        x = 0
        row, styles = canvas.cells[y], canvas.styles[y]
        while x < canvas.w:
            style = styles[x]
            end = x + 1
            while end < canvas.w and styles[end] == style:
                end += 1
            text = ''.join(row[x:end])
            try:
                screen.addstr(y, x, text, theme.attr(style))
            except curses.error:
                pass   # writing the bottom-right cell raises after drawing
            x = end


def _mouse_kind(bstate):
    if bstate & curses.BUTTON4_PRESSED:
        return 'wheel_up'
    if bstate & _WHEEL_DOWN or bstate & 0x8000000:
        return 'wheel_down'
    if bstate & getattr(curses, 'BUTTON1_DOUBLE_CLICKED', 0):
        return 'double'
    if bstate & (curses.BUTTON1_PRESSED | curses.BUTTON1_CLICKED | curses.BUTTON1_RELEASED):
        return 'click'
    return None


def main_loop(screen, app):
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    curses.raw()
    screen.keypad(True)
    screen.timeout(100)
    theme = None
    last_click = (0.0, None)
    last_draw = 0.0
    dirty = True
    while not app.should_exit:
        if app.theme_dirty:
            theme = Theme(app.theme_name(), app.settings.get('accent'), color_disabled(app.environ)).setup(curses)
            try:
                screen.bkgd(' ', theme.attr('base'))
            except curses.error:
                pass
            if app.settings.get('mouse'):
                curses.mousemask(curses.ALL_MOUSE_EVENTS)
                curses.mouseinterval(0)
            else:
                curses.mousemask(0)
            app.theme_dirty = False
            dirty = True
        app.tick()
        now = time.monotonic()
        if dirty or now - last_draw > (0.15 if app.job else 1.0):
            h, w = screen.getmaxyx()
            canvas = app.frame(h, w)
            screen.erase()
            _blit(screen, canvas, theme)
            screen.refresh()
            last_draw = now
            dirty = False
        try:
            key = screen.get_wch()
        except curses.error:
            continue
        keys = [key]
        screen.timeout(0)
        for _ in range(64):
            try:
                keys.append(screen.get_wch())
            except curses.error:
                break
        screen.timeout(100)
        for key in keys:
            dirty = True
            if key == curses.KEY_RESIZE:
                try:
                    curses.update_lines_cols()
                except AttributeError:
                    pass
                h, w = screen.getmaxyx()
                if app.job is not None:
                    try:
                        app.job.resize(max(10, h - 6), max(40, w // 2))
                    except (OSError, ValueError):
                        pass
                continue
            if key == curses.KEY_MOUSE:
                try:
                    _, mx, my, _, bstate = curses.getmouse()
                except curses.error:
                    continue
                kind = _mouse_kind(bstate)
                if kind == 'click':
                    t0, where = last_click
                    hit = app.last_canvas.hit(my, mx) if app.last_canvas else None
                    if where == hit and hit is not None and time.monotonic() - t0 < 0.4:
                        kind = 'double'
                    last_click = (time.monotonic(), hit)
                if kind:
                    app.mouse(my, mx, kind)
                continue
            app.key(key)
    return 0


FIT_COLS, FIT_ROWS = 120, 36


def fit_window(out=None, size=None, wait=0.2):
    """Ask an xterm-compatible terminal for at least FIT_COLS x FIT_ROWS
    (CSI 8 ; rows ; cols t). Returns (original, requested) when a resize was
    requested, None when the window is already big enough or not a terminal.
    The caller restores the original size on exit only if the window still has
    the requested size (a manual resize during the session is never undone)."""
    import shutil
    import time
    out = out or sys.stdout
    try:
        if not out.isatty():
            return None
        cols, rows = size or shutil.get_terminal_size((0, 0))
    except (OSError, ValueError):
        return None
    if not cols or not rows or (cols >= FIT_COLS and rows >= FIT_ROWS):
        return None
    want = (max(cols, FIT_COLS), max(rows, FIT_ROWS))
    out.write('\x1b[8;%d;%dt' % (want[1], want[0]))
    out.flush()
    time.sleep(wait)
    return (cols, rows), want


def restore_window(fitted, out=None, size=None):
    import shutil
    if not fitted:
        return
    out = out or sys.stdout
    (cols, rows), want = fitted
    try:
        now = size or tuple(shutil.get_terminal_size((0, 0)))
        if tuple(now) == tuple(want):
            out.write('\x1b[8;%d;%dt' % (rows, cols))
            out.flush()
    except (OSError, ValueError):
        pass



def parse_launch_args(argv):
    """Only --dry-run (read-only mode) and --tui are accepted; anything else is unknown."""
    dry, unknown = False, []
    for arg in argv:
        if arg == '--dry-run':
            dry = True
        elif arg in ('--tui', ''):
            continue
        else:
            unknown.append(arg)
    return dry, unknown


def run(program, initial_view='dashboard', *argv):
    dry, unknown = parse_launch_args(argv)
    os.environ.setdefault('ESCDELAY', '25')
    app = App(program, initial_view, launch_dry_run=dry)
    result = 0
    fitted = None
    if app.settings.get('auto_resize'):
        fitted = fit_window()
        if fitted:
            import shutil
            cols, rows = shutil.get_terminal_size((0, 0))
            if cols < FIT_COLS or rows < FIT_ROWS:      # the terminal ignored the request
                fitted = None
                app.notify(app.t('ui_resize_hint', cols=FIT_COLS, rows=FIT_ROWS), 'status_warn')
    if app.settings.get('theme') == 'auto' and not color_disabled(app.environ):
        app.terminal_bg = detect_background(app.environ)        # OSC 11 query, before curses owns the terminal
    try:
        result = curses.wrapper(main_loop, app)
    except (Exception, KeyboardInterrupt) as exc:
        if app.job is not None and app.job.running:
            from tui_recovery import continue_in_terminal
            return continue_in_terminal(app.job, app.t('ui_recovery'))
        print(app.t('ui_error', message=plain(exc)), file=sys.stderr)
        restore_window(fitted)
        return 2
    restore_window(fitted)
    if app.exit_mode == 'detach' and app.job is not None and app.job.running:
        from tui_recovery import continue_in_terminal
        return continue_in_terminal(app.job, app.t('ui_recovery'))
    return result
