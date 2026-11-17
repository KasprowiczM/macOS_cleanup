"""Single source of truth for the four toolkit directories (standard library only).

Four roots, one owner each:

    program     replaced wholesale by an upgrade; nothing writes inside it at runtime
    config      user-owned settings, never touched by installers or upgrades
    state       disposable: run folders, caches, keys, backups
    quarantine  the user's restore point; not disposable, stays on the HOME volume

The shell twin is lib/paths.sh. Both print identical results for identical
input; tests/fixtures/ui/paths_cases.json is the shared table both sides are
tested against, so a change here needs the same change there.

Resolution order, first match wins:

    program     $MACOS_CLEANUP_HOME
                this toolkit's own root when it is a git checkout (mode checkout)
                or an installed tree (it carries .install-info, mode installed)
                ~/.local/share/macos-cleanup (mode default)
    config      $MACOS_CLEANUP_CONFIG_DIR, $XDG_CONFIG_HOME/macos-cleanup, ~/.config/macos-cleanup
    state       $MACOS_CLEANUP_STATE_DIR, $XDG_STATE_HOME/macos-cleanup, ~/.local/state/macos-cleanup
    quarantine  $MACOS_CLEANUP_QUARANTINE_DIR, legacy $QUARANTINE_ROOT,
                ~/Library/Application Support/macOS_cleanup/quarantine

MACOS_CLEANUP_* overrides must be absolute paths (a relative one is an error,
exit 2). XDG_* values must be absolute too; per the XDG spec a relative value is
ignored. Trailing slashes are dropped. Symlinks are never resolved in the
returned paths, except for the toolkit root, which is always the physical
directory. The quarantine path must be absolute, contain no "." or ".."
component and end in "quarantine".

``resolve`` is a pure function of the environment (plus the .git/.install-info
probe of the toolkit root). The same-volume rule for the quarantine is a
filesystem check and lives in ``check_quarantine_volume``.
"""
import os
import sys

NAME = "macos-cleanup"
INSTALL_MARKER = ".install-info"
KINDS = ("program", "config", "state", "quarantine")
QUARANTINE_DEFAULT = "Library/Application Support/macOS_cleanup/quarantine"


class PathError(ValueError):
    """A path setting is unusable. The message is one sentence."""


def _clean(path):
    cleaned = path.rstrip("/")
    return cleaned or "/"


def _home(env):
    home = env.get("HOME", "")
    if not home:
        raise PathError("HOME is not set, so the toolkit folders cannot be located.")
    if not home.startswith("/"):
        raise PathError("HOME must be an absolute path.")
    return _clean(home)


def _override(env, name):
    value = env.get(name, "")
    if not value:
        return None
    if not value.startswith("/"):
        raise PathError("%s must be an absolute path." % name)
    return _clean(value)


def _xdg(env, name):
    value = env.get(name, "")
    if value.startswith("/"):
        return _clean(value)
    return None


def toolkit_root():
    """The physical directory that contains lib/python/mc_paths.py's lib/."""
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.dirname(os.path.dirname(here))


def validate_quarantine(path, name="The quarantine folder"):
    """Absolute, no "." or ".." component, last component "quarantine"."""
    parts = path.split("/")
    if not path.startswith("/") or "." in parts or ".." in parts or parts[-1] != "quarantine":
        raise PathError("%s must be an absolute path without . or .. that ends in quarantine." % name)
    return path


def resolve(env=None, root=None):
    """Return {'program','config','state','quarantine','mode'} for this environment.

    mode says where the program directory came from: env, checkout, installed
    or default.
    """
    env = os.environ if env is None else env
    home = _home(env)
    root = os.path.realpath(root) if root else toolkit_root()

    program = _override(env, "MACOS_CLEANUP_HOME")
    if program:
        mode = "env"
    elif os.path.exists(os.path.join(root, ".git")):
        program, mode = root, "checkout"
    elif os.path.isfile(os.path.join(root, INSTALL_MARKER)):
        program, mode = root, "installed"
    else:
        program, mode = home + "/.local/share/" + NAME, "default"

    config = _override(env, "MACOS_CLEANUP_CONFIG_DIR")
    if not config:
        base = _xdg(env, "XDG_CONFIG_HOME")
        config = (base or home + "/.config") + "/" + NAME
    state = _override(env, "MACOS_CLEANUP_STATE_DIR")
    if not state:
        base = _xdg(env, "XDG_STATE_HOME")
        state = (base or home + "/.local/state") + "/" + NAME
    quarantine = _override(env, "MACOS_CLEANUP_QUARANTINE_DIR")
    if quarantine:
        validate_quarantine(quarantine, "MACOS_CLEANUP_QUARANTINE_DIR")
    else:
        legacy = env.get("QUARANTINE_ROOT", "")
        if legacy:
            quarantine = validate_quarantine(_clean(legacy), "QUARANTINE_ROOT")
        else:
            quarantine = home + "/" + QUARANTINE_DEFAULT
    return {"program": program, "config": config, "state": state, "quarantine": quarantine, "mode": mode}


def program_dir(env=None, root=None):
    return resolve(env, root)["program"]


def config_dir(env=None, root=None):
    return resolve(env, root)["config"]


def state_dir(env=None, root=None):
    return resolve(env, root)["state"]


def quarantine_dir(env=None, root=None):
    return resolve(env, root)["quarantine"]


def run_dir(run_id, env=None, root=None):
    """<state>/runs/<run_id>; the id must look like YYYY-MM-DD_HHMMSS_PID."""
    import re
    if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}_[0-9]+", str(run_id)):
        raise PathError("The run id is not well formed.")
    return resolve(env, root)["state"] + "/runs/" + run_id


def quarantine_run_override(env=None, root=None):
    """MACOS_CLEANUP_QUARANTINE_RUN_DIR (or legacy QUARANTINE_RUN_DIR), when set,
    must be an immediate child of the quarantine folder. Returns it or None."""
    env = os.environ if env is None else env
    value = env.get("MACOS_CLEANUP_QUARANTINE_RUN_DIR") or env.get("QUARANTINE_RUN_DIR") or ""
    if not value:
        return None
    paths = resolve(env, root)
    cleaned = _clean(value)
    if not cleaned.startswith("/") or os.path.dirname(cleaned) != paths["quarantine"] \
            or os.path.basename(cleaned) in ("", ".", ".."):
        raise PathError("The quarantine run folder must be an immediate child of the quarantine folder.")
    return cleaned


def _device_of_nearest(path):
    current = path
    while current and not os.path.exists(current):
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    return os.stat(current).st_dev


def check_quarantine_volume(env=None, root=None):
    """Quarantine is a rename(2): it must be on the same volume as $HOME."""
    env = os.environ if env is None else env
    paths = resolve(env, root)
    try:
        same = _device_of_nearest(paths["quarantine"]) == _device_of_nearest(_home(env))
    except OSError:
        same = False
    if not same:
        raise PathError("The quarantine folder must be on the same volume as your home folder.")
    return paths["quarantine"]


def make_private_dirs(path):
    """mkdir -p where every directory created is 0700 (os.makedirs gives
    intermediate directories the umask default, which the state checks refuse)."""
    missing = []
    current = os.path.abspath(path)
    while current and not os.path.isdir(current):
        missing.append(current)
        parent = os.path.dirname(current)
        if parent == current:
            break
        current = parent
    for directory in reversed(missing):
        try:
            os.mkdir(directory, 0o700)
        except FileExistsError:
            continue
        os.chmod(directory, 0o700)
    return path


def _physical(path):
    """realpath that tolerates a path that does not exist yet."""
    return os.path.realpath(path)


def _inside(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


def ensure_dir(kind, env=None, root=None):
    """Create the config, state or quarantine directory (0700) and return its path.

    Refuses a directory that lives inside, or is a symlink into, the program
    directory: the program tree is replaced wholesale and must stay read-only
    at runtime. The quarantine must also be on the HOME volume.
    """
    if kind not in ("config", "state", "quarantine"):
        raise PathError("Only the config, state and quarantine folders are created on demand.")
    env = os.environ if env is None else env
    paths = resolve(env, root)
    target = paths[kind]
    if _inside(_physical(target), _physical(paths["program"])):
        raise PathError(
            "The %s folder is inside the program folder, which is replaced on every update." % kind
        )
    if kind == "quarantine":
        check_quarantine_volume(env, root)
    try:
        make_private_dirs(target)
    except OSError:
        raise PathError("The %s folder %s cannot be created." % (kind, target))
    if _inside(_physical(target), _physical(paths["program"])):
        raise PathError(
            "The %s folder is a link into the program folder, which is replaced on every update." % kind
        )
    return target


def _main(argv):
    root = None
    args = list(argv)
    if "--root" in args:
        i = args.index("--root")
        try:
            root = args[i + 1]
        except IndexError:
            print("--root needs a directory.", file=sys.stderr)
            return 2
        del args[i : i + 2]
    command = args[0] if args else "print"
    try:
        if command == "print":
            paths = resolve(root=root)
            for key in KINDS + ("mode",):
                print("%s=%s" % (key, paths[key]))
        elif command in KINDS or command == "mode":
            print(resolve(root=root)[command])
        elif command == "ensure" and len(args) == 2:
            print(ensure_dir(args[1], root=root))
        else:
            print("Usage: mc_paths.py [print|program|config|state|quarantine|mode|ensure config|state|quarantine] "
                  "[--root DIR]", file=sys.stderr)
            return 2
    except PathError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))
