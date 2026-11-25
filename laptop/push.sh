#!/bin/bash
# Runs on the owner's laptop (macOS or Linux), never on the box. Copies the
# owner's Claude Code config, the connectors they choose by name and their git
# identity to the box user. Take it from GitHub at the commit the box runs, as
# the README gives it, never through a session on the box: the agents can
# change what a session as the box user serves.
#
#   push.sh <box user>@<box's Tailscale name> [--connectors <name,name>|none]
#           [--replace] [--exclude <path under ~/.claude>]...
#
# BOX_REPO names the checkout on the box, if it isn't /opt/cloud-box.
#
# Nothing leaves the laptop until the owner has seen what will be sent and
# answered yes. ~/.claude.json never leaves: only the definitions of the
# servers chosen by name do, and only to scripts/04-connectors.sh on the box.
#
# Written for macOS's stock bash 3.2 as well as Linux: no associative arrays,
# mapfile or ${v,,}, and an empty array is expanded as ${a[@]+"${a[@]}"}
# because set -u treats it as unset there. The work on files and JSON is in
# Python's standard library, which behaves the same on both.
set -euo pipefail

BOX_REPO=${BOX_REPO:-/opt/cloud-box}

die() {
  printf '!! %s\n' "$*" >&2
  exit 1
}
usage() {
  echo "usage: ${0##*/} <box user>@<box's Tailscale name> [--connectors <name,name>|none] [--replace] [--exclude <path under ~/.claude>]..." >&2
  exit 2
}

DEST=
CONNECTORS=
CONNECTORS_SET=
REPLACE=
EXCLUDES=()
while [ $# -gt 0 ]; do
  case $1 in
    --connectors)
      [ $# -ge 2 ] || usage
      CONNECTORS=$2
      CONNECTORS_SET=1
      shift 2
      ;;
    --replace)
      REPLACE=1
      shift
      ;;
    --exclude)
      [ $# -ge 2 ] || usage
      EXCLUDES+=("$2")
      shift 2
      ;;
    -*) usage ;;
    *)
      [ -z "$DEST" ] || usage
      DEST=$1
      shift
      ;;
  esac
done
case $DEST in *?@?*) ;; *) usage ;; esac

command -v ssh >/dev/null || die "ssh is missing on this laptop"
command -v git >/dev/null || die "git is missing on this laptop"
# On a Mac without Apple's command line tools, python3 is a stub that offers to
# install them and exits non-zero, so running it is the test.
python3 -c '' >/dev/null 2>&1 || die "python3 is missing on this laptop. On a Mac: xcode-select --install"

read -r -d '' PY <<'PYEOF' || true
import json, os, re, shutil, stat, sys, tarfile

mode = sys.argv[1]
chosen = [n.strip() for n in sys.argv[2].split(",") if n.strip()]

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
CLAUDE_JSON = os.path.join(HOME, ".claude.json")
TOP_FILES = ["CLAUDE.md", "settings.json", "keybindings.json"]
TOP_DIRS = ["skills", "agents", "commands", "rules", "output-styles", "hooks"]
SKIP = {".DS_Store", ".git", "node_modules", "__pycache__"}
HISTORY = re.compile(r"^(history\.jsonl|\.?[A-Za-z0-9_]*history|.+\.history)$", re.I)
MANIFEST = os.environ.get("PUSH_MANIFEST", "")
STAGE = os.environ.get("PUSH_STAGE", "")


def real(p):
    return os.path.realpath(p)


def under(path, root):
    root = root.rstrip("/")
    return path == root or path.startswith(root + "/")


def exclude_name(e):
    p = os.path.expanduser(e)
    if os.path.isabs(p):
        p = os.path.normpath(p)
        root = next((r for r in (CLAUDE, real(CLAUDE)) if under(p, r)), None)
        if root is None:
            sys.exit("!! --exclude %s is not under ~/.claude" % e)
        p = p[len(root) + 1:]
    p = os.path.normpath(p).strip("/")
    if p in ("", ".") or p.startswith(".."):
        sys.exit("!! --exclude %s does not name something under ~/.claude" % e)
    if not os.path.lexists(os.path.join(CLAUDE, p)):
        sys.exit("!! --exclude %s: there is no ~/.claude/%s" % (e, p))
    return p


excludes = [exclude_name(e) for e in sys.argv[3:]]


# Compared by device and inode, not by spelling: a Mac's volume ignores case,
# and a hard link has a path of its own.
def ident(p):
    try:
        st = os.stat(p)
        return (st.st_dev, st.st_ino)
    except OSError:
        return None


FORBIDDEN_FILES = {
    ident(CLAUDE_JSON): "Claude Code's own state (~/.claude.json)",
    ident(os.path.join(CLAUDE, ".credentials.json")): "Claude Code's sign-in",
}
FORBIDDEN_FILES.pop(None, None)
FORBIDDEN_DIRS = [(ident(d), why) for d, why in [
    (os.path.join(CLAUDE, "projects"), "~/.claude/projects"),
    (os.path.join(CLAUDE, "plugins"), "~/.claude/plugins"),
    (os.path.join(HOME, ".ssh"), "~/.ssh"),
] + [(os.path.join(CLAUDE, e), "the excluded ~/.claude/" + e) for e in excludes] if ident(d)]


def forbidden(rp):
    if ident(rp) in FORBIDDEN_FILES:
        return FORBIDDEN_FILES[ident(rp)]
    if os.path.isfile(rp) and HISTORY.match(os.path.basename(rp)):
        return "a history file"
    p = rp
    while True:
        i = ident(p)
        for d, why in FORBIDDEN_DIRS:
            if i == d:
                return why
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def collect():
    """Return (sent, dropped): sent is [(real path, name under ~/.claude, device,
    inode)]. A file with more than one hard link is left out: its other names
    can't be checked against what may not be sent."""
    sent, dropped = [], []

    def add(lp, name, stack):
        if any(under(name, e) for e in excludes):
            dropped.append((name, "excluded"))
            return
        if not os.path.exists(lp):
            dropped.append((name, "a broken symlink"))
            return
        rp = real(lp)
        why = forbidden(rp)
        if why:
            dropped.append((name, "points into " + why))
            return
        if os.path.isdir(lp):
            if rp in stack:
                dropped.append((name, "a symlink loop"))
                return
            for entry in sorted(os.listdir(lp)):
                if entry not in SKIP:
                    add(os.path.join(lp, entry), name + "/" + entry, stack | {rp})
        elif os.path.isfile(lp):
            st = os.stat(rp)
            if st.st_nlink > 1:
                dropped.append((name, "has other hard links, so where else it lives can't be checked"))
            else:
                sent.append((rp, name, st.st_dev, st.st_ino))
        else:
            dropped.append((name, "not a regular file"))

    for n in TOP_FILES + TOP_DIRS:
        if os.path.lexists(os.path.join(CLAUDE, n)):
            add(os.path.join(CLAUDE, n), n, frozenset())
    return sent, dropped


def load_claude_json():
    try:
        with open(CLAUDE_JSON) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def user_servers():
    servers = load_claude_json().get("mcpServers") or {}
    return servers if isinstance(servers, dict) else {}


def entry_key(name):
    parts = name.split("/")
    return parts[0] if parts[0] in TOP_FILES else "/".join(parts[:2])


def shown(key):
    lp = os.path.join(CLAUDE, key)
    rp = real(lp)
    return key + ("  -> " + rp if rp != os.path.abspath(lp) else "")


# Copies each file to be sent into the private stage directory, so what is
# sent is the bytes the preview listed, whatever happens to the originals while
# the prompt waits. The file is checked again as opened: still the one
# collect() found, still a regular file with a single hard link.
# Staged copies are numbered in manifest order rather than named, so two names
# that differ only in case can't land on one file on a case-insensitive volume.
def staged_path(i):
    return os.path.join(STAGE, str(i))


def stage(sent):
    staged, dropped = [], []
    os.makedirs(STAGE, exist_ok=True)
    for rp, name, dev, ino in sent:
        try:
            fd = os.open(rp, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        except OSError:
            dropped.append((name, "could not be read"))
            continue
        with os.fdopen(fd, "rb") as src:
            st = os.fstat(src.fileno())
            if not stat.S_ISREG(st.st_mode) or (st.st_dev, st.st_ino) != (dev, ino) or st.st_nlink > 1:
                dropped.append((name, "changed while it was being read"))
                continue
            dest = staged_path(len(staged))
            with open(dest, "wb") as out:
                shutil.copyfileobj(src, out)
            os.chmod(dest, stat.S_IMODE(st.st_mode))
        staged.append((rp, name))
    return staged, dropped


def preview():
    check_connectors()
    sent, dropped = collect()
    sent, more = stage(sent)
    dropped += more
    with open(MANIFEST, "w") as fh:
        json.dump([n for _, n in sent], fh)
    keys = list(dict.fromkeys(entry_key(n) for _, n in sent))
    print("Config, copied into ~/.claude on the box:")
    for k in keys:
        print("  " + shown(k))
    if not keys:
        print("  (nothing)")
    linked = [(n, rp) for rp, n in sent if not under(rp, real(os.path.join(CLAUDE, entry_key(n))))]
    if linked:
        print("Reached through a symlink inside those. Check each target:")
        for n, rp in linked:
            print("  %s  -> %s" % (n, rp))
    if dropped:
        print("Left out:")
        for name, why in dropped:
            print("  %s: %s" % (name, why))
    print("Connectors:")
    for n in chosen:
        print("  " + n)
    if not chosen:
        print("  (none)")


def check_connectors():
    servers = user_servers()
    unknown = [n for n in chosen if n not in servers]
    if unknown:
        sys.stderr.write("!! not a user-scope server in ~/.claude.json: %s\n" % ", ".join(unknown))
        sys.exit(1)


def strip_owner(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def approved():
    with open(MANIFEST) as fh:
        return json.load(fh)


def archive():
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as tf:
        for i, name in enumerate(approved()):
            tf.add(staged_path(i), arcname=name, recursive=False, filter=strip_owner)


IMPORT = re.compile(r"(?<![\w.@])@((?:~|\$HOME|\$\{HOME\}|\.{1,2})?/[^\s'\"`)\]>,;]+|[^\s'\"`)\]>,;@]+\.md)")
HOMEPATH = re.compile(r"(?:~|\$HOME|\$\{HOME\})/[^\s'\"`)\]>,;:*]+")


def landed(path, names):
    """True if a laptop path resolves to something that was sent."""
    path = os.path.normpath(path)
    if not under(path, CLAUDE):
        return False
    rel = path[len(CLAUDE) + 1:]
    return any(under(n, rel) for n in names)


def expand(p, base):
    for prefix in ("~/", "$HOME/", "${HOME}/"):
        if p.startswith(prefix):
            return os.path.join(HOME, p[len(prefix):])
    return p if p.startswith("/") else os.path.join(base, p)


def report():
    names = approved()
    users, outside = [], []
    for i, name in enumerate(names):
        rp = staged_path(i)
        try:
            with open(rp, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        if "/Users/" in text or HOME + "/" in text:
            users.append(name)
        base = os.path.dirname(os.path.join(CLAUDE, name))
        found, seen = [], set()
        hits = [(m.group(0), m.group(1)) for m in IMPORT.finditer(text)]
        hits += [(m.group(0), m.group(0)) for m in HOMEPATH.finditer(text)]
        for shown_as, path in hits:
            target = os.path.normpath(expand(path, base))
            if target not in seen and not landed(target, names):
                seen.add(target)
                found.append(shown_as)
        if found:
            outside.append((name, found))

    print("Copied into ~/.claude on the box:")
    for k in dict.fromkeys(entry_key(n) for n in names):
        print("  " + k)
    if users:
        print("\nMention /Users/ or this laptop's home directory, which the box doesn't have. Fix by hand:")
        for n in users:
            print("  " + n)
    if outside:
        print("\nImport or name a path outside what was sent, which loads nothing on the box. Fix by hand:")
        for n, found in outside:
            more = " (+%d more)" % (len(found) - 5) if len(found) > 5 else ""
            print("  %s: %s%s" % (n, ", ".join(found[:5]), more))
    settings = staged_path(names.index("settings.json")) if "settings.json" in names else None
    if settings:
        try:
            with open(settings) as fh:
                plugins = json.load(fh).get("enabledPlugins") or {}
        except (OSError, ValueError, AttributeError):
            plugins = {}
        on = sorted(k for k, v in plugins.items() if v) if isinstance(plugins, dict) else []
        if on:
            print("\nPlugins settings.json enables. Whether the box installs them is not known: check them in a session there:")
            print("  " + ", ".join(on))
    projects = load_claude_json().get("projects") or {}
    scoped = [(p, sorted(v.get("mcpServers") or {})) for p, v in sorted(projects.items())
              if isinstance(v, dict) and v.get("mcpServers")]
    if scoped:
        print("\nServers registered for one project on this laptop. Not sent: re-add them in that repo on the box:")
        for p, servers in scoped:
            print("  %s: %s" % (p, ", ".join(servers)))


if mode == "list":
    for n in sorted(user_servers()):
        print(n)
elif mode == "preview":
    preview()
elif mode == "connectors":
    servers = user_servers()
    json.dump({n: servers[n] for n in chosen}, sys.stdout)
elif mode == "archive":
    archive()
elif mode == "report":
    report()
else:
    sys.exit("unknown mode " + mode)
PYEOF

WORK=$(mktemp -d) || die "could not make a temporary directory"
trap 'rm -rf "$WORK"' EXIT
export PUSH_MANIFEST="$WORK/manifest.json" PUSH_STAGE="$WORK/stage"

py() {
  python3 -I -c "$PY" "$@" ${EXCLUDES[@]+"${EXCLUDES[@]}"}
}

# A command passed straight to ssh reads no ~/.profile, so finds neither claude
# nor node. Each one runs in a login shell instead.
remote() {
  # shellcheck disable=SC2029 # quoted here on purpose, for the box's shell to unquote
  ssh "$DEST" "bash -lc $(printf '%q' "$1")"
}

if [ -z "$CONNECTORS_SET" ]; then
  echo "Connectors registered at user scope on this laptop:"
  names=$(py list "")
  if [ -n "$names" ]; then printf '%s\n' "$names" | sed 's/^/  /'; else echo "  (none)"; fi
  printf 'Which to send? Names separated by commas, or none: '
  read -r CONNECTORS || CONNECTORS=
fi
case $CONNECTORS in none | "") CHOSEN= ;; *) CHOSEN=$CONNECTORS ;; esac

GIT_NAME=$(git config --global --includes user.name || true)
GIT_EMAIL=$(git config --global --includes user.email || true)

echo
py preview "$CHOSEN"
echo "Git identity:"
if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
  echo "  $GIT_NAME <$GIT_EMAIL>"
else
  echo "  (none set on this laptop)"
fi
echo
printf 'Send these to %s? [yes/NO] ' "$DEST"
read -r answer || answer=
[ "$answer" = yes ] || {
  echo "Nothing sent."
  exit 1
}

echo
echo "==> Connecting to $DEST. On a new tailnet the first connection prints a Tailscale"
echo "    link: open it in a browser, approve, and the copy carries on."

failed=0
echo "==> Config"
if ! py archive "$CHOSEN" | remote 'mkdir -p ~/.claude && tar -x -f - -C ~/.claude --no-same-owner'; then
  echo "!! Copying the config failed, so nothing else was sent. Fix the error above and run this again." >&2
  exit 1
fi

# Runs with no connector chosen too, so the status of claude.ai connectors and
# their sign-in steps still show.
echo "==> Connectors"
cmd="$(printf '%q' "$BOX_REPO/scripts/04-connectors.sh")${REPLACE:+ --replace}"
if ! py connectors "$CHOSEN" | remote "$cmd"; then
  echo "!! 04-connectors.sh did not finish cleanly – see its lines above" >&2
  failed=1
fi

echo "==> Git identity"
if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
  if ! remote "git config --global user.name $(printf '%q' "$GIT_NAME") && git config --global user.email $(printf '%q' "$GIT_EMAIL")" </dev/null; then
    echo "!! setting the git identity failed" >&2
    failed=1
  fi
else
  echo "    none on this laptop – set user.name and user.email on the box by hand"
fi

echo
py report "$CHOSEN"
exit "$failed"
