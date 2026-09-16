#!/usr/bin/env bash
# Assert that tightening permissions does not unlock SQLite underneath itself.
#
# The daemon took SIGBUS inside walIteratorNext during a COMMIT checkpoint
# (issue #2). The cause was not SQLite: bin/omaenergy tightened energy.db and
# its WAL sidecars *after* connecting, and tighten_managed_file() opens and
# closes a descriptor of its own. Closing any descriptor for an inode cancels
# every POSIX advisory lock the process holds on it, so the tightening pass
# silently unlocked the database the daemon was using, another connection was
# then free to reset the shared-memory file we still had mapped, and the next
# checkpoint read a page with no storage behind it.
#
# Nothing about that failure is loud. No error is raised, no lock call fails,
# and the crash lands minutes later somewhere unrelated-looking. On the tree
# that shipped it, connect() returned a connection holding no locks at all.
# So the regression is checked by watching the locks themselves, which is what
# /proc/locks is for. The fix is an ordering rule -- tighten before connect,
# only stat afterwards -- and an ordering rule is the kind of thing a later
# edit undoes by accident.
#
# No RAPL, GPU, systemd or network: a throwaway XDG home and a database this
# script creates and deletes. Green on a GitHub runner.
#
# Run before pushing. CI runs it too.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0

note() { printf '  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
ok() { printf 'ok    %s\n' "$1"; }

cli=bin/omaenergy
if [ ! -f "$cli" ]; then
  printf 'FAIL  %s is missing\n' "$cli"
  exit 1
fi

# /proc/locks is the whole instrument. Without it this script cannot tell a
# passing tree from a broken one, and a check that cannot fail must not report
# success -- say so and exit non-zero rather than print a green line.
if [ ! -r /proc/locks ]; then
  bad "/proc/locks is not readable; this check cannot observe anything"
  exit 1
fi

workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

# Each case runs in its own interpreter on its own throwaway home, because the
# control below deliberately destroys the locks it inspects.
#
# `probe.py` is shared. It loads bin/omaenergy as a module -- the file has no
# .py suffix and guards on __main__, so importing it runs no command -- and
# reports the POSIX locks this process holds on energy.db and its sidecars.
cat > "$workdir/probe.py" <<'PY'
import importlib.util
import os
import sqlite3
from importlib.machinery import SourceFileLoader


def load_cli():
    loader = SourceFileLoader("omaenergy_under_test", "bin/omaenergy")
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def db_inodes(module):
    inodes = {}
    for name in ("energy.db",) + module.db_sidecars():
        try:
            inodes[name] = os.stat(module.STATE_DIR / name).st_ino
        except FileNotFoundError:
            pass
    return inodes


def locks_held(inodes):
    """Our own POSIX locks on those inodes, as {inode: [normalized rows]}.

    A /proc/locks row is `id: POSIX ADVISORY READ <pid> <maj:min:ino> <start>
    <end>`, but a blocked waiter is printed with a `->` prefix that shifts
    every field along. Anchor on the dev:inode token rather than counting
    columns, and take the pid from the token before it.
    """
    wanted = set(inodes.values())
    found = {inode: [] for inode in wanted}
    mine = str(os.getpid())
    with open("/proc/locks") as stream:
        for line in stream:
            fields = line.split()
            for index, field in enumerate(fields):
                if index == 0 or field.count(":") != 2:
                    continue
                try:
                    inode = int(field.rsplit(":", 1)[1])
                except ValueError:
                    continue
                if inode in wanted and fields[index - 1] == mine:
                    # Drop the leading lock id: it is an allocation counter and
                    # moves for reasons that have nothing to do with us.
                    found[inode].append(" ".join(fields[index - 3:]))
                break
    return {inode: sorted(rows) for inode, rows in found.items()}


def describe(inodes, locks):
    by_inode = {inode: name for name, inode in inodes.items()}
    rows = [f"{by_inode.get(inode, inode)}: {row}"
            for inode, group in sorted(locks.items()) for row in group]
    return " | ".join(rows) or "<none>"


def bare_wal_db(module):
    """A WAL connection on the managed path, opened without the CLI's help.

    The control case must not depend on connect() being correct: on a tree
    where connect() unlocks the database before returning, a control built on
    it would have no locks to lose and would report a broken tree as an
    unobservable one.
    """
    module.STATE_DIR.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(module.DB_PATH, timeout=10.0)
    db.execute("PRAGMA journal_mode = WAL")
    db.execute("CREATE TABLE IF NOT EXISTS lock_probe(x)")
    db.commit()
    return db
PY

run_case() {
  local home="$workdir/$1" script="$2"
  mkdir -p "$home/data" "$home/config"
  rc=0
  XDG_DATA_HOME="$home/data" XDG_CONFIG_HOME="$home/config" \
    PROBE="$workdir/probe.py" python3 "$script" \
    >"$workdir/.out" 2>"$workdir/.err" || rc=$?
  out="$(cat "$workdir/.out")"
  err="$(cat "$workdir/.err")"
}

dump_out() {
  while IFS= read -r line; do
    [ -n "$line" ] && note "$line"
  done <<EOF
$out
EOF
}

# --------------------------------------------------------------------------
# 1. The instrument, and proof that the old pattern is still harmful.
#
# This case runs first because it is what licenses case 2 to be believed. It
# opens a WAL database directly, without going through connect(), then does
# the harmful thing on purpose: tighten_managed_file() against an inode the
# live connection owns, which is exactly what the shipped code did. The locks
# must visibly vanish. If they do not, then either SQLite stopped taking file
# locks here, /proc/locks stopped reporting them, or the parser above matches
# nothing -- and in all three cases this script has no instrument and must not
# report a pass.
# --------------------------------------------------------------------------
cat > "$workdir/control.py" <<'PY'
import os

exec(open(os.environ["PROBE"]).read())

os.umask(0o077)
module = load_cli()
db = bare_wal_db(module)

inodes = db_inodes(module)
if "energy.db-shm" not in inodes:
    print("BLIND no -shm sidecar exists; WAL mode did not engage")
    raise SystemExit(2)
before = locks_held(inodes)
if not any(before.values()):
    print("BLIND a live WAL connection shows no POSIX locks at all")
    raise SystemExit(2)

module.tighten_managed_file(module.state_dir_fd(create=False), "energy.db-shm")

after = locks_held(inodes)
print("BEFORE", describe(inodes, before))
print("AFTER ", describe(inodes, after))
db.close()
raise SystemExit(0 if before != after else 1)
PY
run_case home-control "$workdir/control.py"
case "$rc" in
  0) ok "control: closing a spare descriptor still drops SQLite's locks" ;;
  1) bad "control: the open/close pattern dropped no lock"
     note "This script can no longer tell a fixed tree from a broken one."
     dump_out ;;
  2) bad "lock check went blind: $(printf '%s' "$out" | sed -n 's/^BLIND //p')" ;;
  *) bad "control crashed (exit $rc)"
     note "stderr: $(printf '%s' "$err" | tail -3 | tr '\n' ' ')" ;;
esac

# --------------------------------------------------------------------------
# 2. connect() must return a locked connection, and the tightening pass that
#    runs afterwards must leave it that way.
#
# Two assertions, because the bug broke both. connect() itself tightened after
# connecting, so on the shipped tree it handed back a connection holding no
# locks whatsoever; run_daemon() then called tighten_managed_paths() a few
# lines later and would have dropped them again. The second assertion is not
# "no exception" -- there never was one -- but that the lock set is identical
# across the pass and across a commit that checkpoints the WAL, which is the
# operation that crashed.
# --------------------------------------------------------------------------
cat > "$workdir/live.py" <<'PY'
import os

exec(open(os.environ["PROBE"]).read())

os.umask(0o077)
module = load_cli()
db = module.connect()

inodes = db_inodes(module)
if "energy.db-shm" not in inodes:
    print("NOSHM no -shm sidecar exists after connect(); WAL mode did not engage")
    raise SystemExit(3)

before = locks_held(inodes)
print("AFTER connect():", describe(inodes, before))
if not any(before.values()):
    print("UNLOCKED connect() returned a connection holding no POSIX locks")
    raise SystemExit(4)

# Exactly what run_daemon() does once its meta rows are written.
module.tighten_managed_paths(db_files=False)
# And a write that checkpoints the WAL: the operation that took SIGBUS.
db.execute("CREATE TABLE IF NOT EXISTS lock_probe(x)")
db.execute("INSERT INTO lock_probe VALUES (1)")
db.commit()

after = locks_held(inodes)
print("AFTER tighten: ", describe(inodes, after))
db.close()
raise SystemExit(0 if before == after else 1)
PY
run_case home-live "$workdir/live.py"
case "$rc" in
  0) ok "connect() stays locked across the post-connect tightening pass" ;;
  1) bad "the post-connect tightening pass dropped SQLite locks"
     dump_out ;;
  3) bad "cannot check: $(printf '%s' "$out" | sed -n 's/^NOSHM //p')" ;;
  4) bad "connect() returned an unlocked connection"
     note "It tightened the database inodes after opening them; tighten first."
     dump_out ;;
  *) bad "live check crashed (exit $rc)"
     note "stderr: $(printf '%s' "$err" | tail -3 | tr '\n' ' ')" ;;
esac

exit "$fail"
