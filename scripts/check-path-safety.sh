#!/usr/bin/env bash
# Assert that managed config and state paths refuse a planted symlink.
#
# Marketplace review (omacom/omarchy-plugin-marketplace#6694) found that
# bin/omaenergy created and wrote those paths by pathname, so a symlink
# planted at config.json, energy.db, or either managed directory was
# followed or replaced. The CLI now has to walk and retain directory
# descriptors, open files relative to them with O_NOFOLLOW, and refuse
# with UnsafePathError. This script is the runtime half of that check.
#
# No RAPL, GPU, systemd, or network: only `status` and `config`, pointed
# at a throwaway XDG home. Green on a GitHub runner.
#
# Run before pushing. CI runs it too.
set -euo pipefail

cd "$(dirname "$0")/.."
fail=0

note() { printf '  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
ok() { printf 'ok    %s\n' "$1"; }

cli=bin/omaenergy
if [ ! -e "$cli" ]; then
  printf 'FAIL  %s is missing\n' "$cli"
  exit 1
fi
if [ ! -x "$cli" ]; then
  printf 'FAIL  %s is not executable\n' "$cli"
  exit 1
fi

# Isolated XDG so a developer running this against their real home cannot
# have their own config rewritten, and so the planted-symlink cases have a
# directory we own and can throw away.
workdir="$(mktemp -d)"
cleanup() { rm -rf "$workdir"; }
trap cleanup EXIT

home=""
config_dir=""
state_dir=""
rc=0
stdout=""
stderr=""

fresh_home() {
  home="$(mktemp -d "$workdir/home.XXXXXX")"
  export XDG_DATA_HOME="$home/data"
  export XDG_CONFIG_HOME="$home/config"
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
  config_dir="$XDG_CONFIG_HOME/omarchy-energy"
  state_dir="$XDG_DATA_HOME/omarchy-energy"
}

run_cli() {
  local out err
  out="$workdir/.stdout"
  err="$workdir/.stderr"
  rc=0
  "$cli" "$@" >"$out" 2>"$err" || rc=$?
  stdout="$(cat "$out")"
  stderr="$(cat "$err")"
}

assert_mode() {
  local path="$1" want="$2" label="$3"
  local got
  if [ ! -e "$path" ]; then
    bad "$label does not exist: $path"
    return
  fi
  if [ -L "$path" ]; then
    bad "$label is a symlink: $path"
    return
  fi
  got="$(stat -c '%a' "$path")"
  if [ "$got" = "$want" ]; then
    ok "$label is mode $want"
  else
    bad "$label is mode $got, want $want"
  fi
}

# Dump stderr on a refused-path miss so a wording drift is visible rather
# than a bare "didn't refuse".
assert_refused() {
  local label="$1"
  if [ "$rc" -ne 1 ]; then
    bad "$label: exit $rc, want 1"
    note "stderr: $stderr"
  elif ! printf '%s\n' "$stderr" | grep -q 'refusing to use'; then
    bad "$label: stderr lacks 'refusing to use'"
    note "stderr: $stderr"
  else
    ok "$label: refused with exit 1"
  fi
}

assert_still_symlink() {
  local path="$1" label="$2"
  if [ -L "$path" ]; then
    ok "$label is still a symlink"
  else
    bad "$label is no longer a symlink"
  fi
}

assert_victim_untouched() {
  local victim="$1" before="$2" label="$3"
  if cmp -s "$victim" "$before"; then
    ok "$label victim bytes unchanged"
  else
    bad "$label victim was written or truncated"
  fi
}

# --------------------------------------------------------------------------
# 1. Happy path in a clean temp home.
#
# `status` must work with no RAPL, no GPU and no database -- that is what
# makes this check runnable on a GitHub runner. `config` is the write
# that has to be atomic and owner-only. The rewrite also mkdir's the
# state dir on every start; today's tree only creates it when the
# database is opened, so a missing state dir is not a failure of this
# control. Whichever managed directories exist must be 0700.
# --------------------------------------------------------------------------
fresh_home
run_cli status
if [ "$rc" -eq 0 ]; then
  ok "status exits 0 on a clean temp home"
else
  bad "status exited $rc on a clean temp home"
  note "stderr: $stderr"
fi

run_cli config tariff=0.42
if [ "$rc" -eq 0 ]; then
  ok "config tariff=0.42 exits 0"
else
  bad "config tariff=0.42 exited $rc"
  note "stderr: $stderr"
fi

run_cli config --json
if [ "$rc" -eq 0 ] && printf '%s\n' "$stdout" | grep -q '0\.42'; then
  ok "config --json persists tariff=0.42"
else
  bad "config --json does not show tariff=0.42"
  note "stdout: $stdout"
  note "stderr: $stderr"
fi

assert_mode "$config_dir" 700 "config dir"
assert_mode "$config_dir/config.json" 600 "config.json"
if [ -e "$state_dir" ] || [ -L "$state_dir" ]; then
  assert_mode "$state_dir" 700 "state dir"
fi

# A successful write must not leave the predictable config.json.tmp the
# finding named, nor any other *.tmp residue. The rewrite uses an
# unpredictable exclusive temp and os.replace; leftover temps mean the
# rename never happened or the name became predictable again.
tmp_residue=0
for f in "$config_dir"/*.tmp "$config_dir"/config.json.tmp; do
  if [ -e "$f" ] || [ -L "$f" ]; then
    bad "leftover temp after config write: $f"
    tmp_residue=1
  fi
done
if [ "$tmp_residue" -eq 0 ]; then
  ok "config dir has no *.tmp residue"
fi

# --------------------------------------------------------------------------
# 2. Pre-existing 0644 artifacts are tightened in place on every start.
#
# Existing installs were created under umask 0022. That in-place chmod is
# documented behaviour and the descriptor-relative rewrite must not lose
# it by refusing a file whose only crime is a wide mode.
# --------------------------------------------------------------------------
fresh_home
mkdir -p "$config_dir"
printf '%s\n' '{"tariff": 0.30}' > "$config_dir/config.json"
chmod 644 "$config_dir/config.json"
run_cli status
if [ "$rc" -eq 0 ]; then
  ok "status exits 0 on a pre-existing 0644 config.json"
else
  bad "status exited $rc on a pre-existing 0644 config.json"
  note "stderr: $stderr"
fi
assert_mode "$config_dir/config.json" 600 "tightened config.json"

# --------------------------------------------------------------------------
# 3. config.json replaced by a symlink to a victim outside the config dir.
#
# The finding: write_private_file opened with O_TRUNC and no O_NOFOLLOW,
# and save_config used the predictable config.json.tmp pathname then
# renamed onto the destination. Either following the symlink or replacing
# it is a failure. The victim's bytes must be identical to before, the
# planted symlink must still be a symlink, and the CLI must refuse.
# --------------------------------------------------------------------------
fresh_home
mkdir -p "$config_dir"
victim="$home/victim-config"
printf '%s\n' '{"marker":"VICTIM_DO_NOT_TOUCH","tariff":0.01}' > "$victim"
chmod 600 "$victim"
cp -a "$victim" "$victim.before"
ln -s "$victim" "$config_dir/config.json"
run_cli config tariff=0.99
assert_refused "config.json symlink"
assert_still_symlink "$config_dir/config.json" "config.json"
assert_victim_untouched "$victim" "$victim.before" "config.json"
if printf '%s\n' "$stderr" | grep -q 'is a symbolic link'; then
  ok "config.json symlink reason is 'is a symbolic link'"
elif [ "$rc" -eq 1 ]; then
  bad "config.json symlink: refusal reason is not 'is a symbolic link'"
  note "stderr: $stderr"
fi

# --------------------------------------------------------------------------
# 4. The config directory itself is a symlink to an attacker-controlled dir.
#
# mkdir(exist_ok=True) and pathname writes follow a directory symlink, so
# the managed files would land in a directory we do not hold a trusted
# descriptor on. Any command must refuse; this uses `config` because that
# is the write that would otherwise create config.json through the link.
# --------------------------------------------------------------------------
fresh_home
attacker="$home/attacker-config"
mkdir -p "$attacker"
printf 'marker\n' > "$attacker/.marker"
ln -s "$attacker" "$config_dir"
run_cli config tariff=0.99
assert_refused "config dir symlink"
assert_still_symlink "$config_dir" "config dir"
if [ -f "$attacker/.marker" ] && [ ! -e "$attacker/config.json" ]; then
  ok "attacker config dir was not written through"
else
  bad "wrote through the planted config dir symlink"
fi
if printf '%s\n' "$stderr" | grep -q 'is a symbolic link'; then
  ok "config dir symlink reason is 'is a symbolic link'"
elif [ "$rc" -eq 1 ]; then
  bad "config dir symlink: refusal reason is not 'is a symbolic link'"
  note "stderr: $stderr"
fi

# --------------------------------------------------------------------------
# 5. The state directory itself is a symlink.
#
# Same shape as the config dir, against STATE_DIR. `status` is enough: it
# must not follow the planted directory even when there is no database
# yet, because the rewrite holds the state-dir descriptor for the process
# lifetime and creates the directory on start.
# --------------------------------------------------------------------------
fresh_home
attacker="$home/attacker-state"
mkdir -p "$attacker"
printf 'marker\n' > "$attacker/.marker"
ln -s "$attacker" "$state_dir"
run_cli status
assert_refused "state dir symlink"
assert_still_symlink "$state_dir" "state dir"
if [ -f "$attacker/.marker" ] && [ ! -e "$attacker/energy.db" ]; then
  ok "attacker state dir was not written through"
else
  bad "wrote through the planted state dir symlink"
fi
if printf '%s\n' "$stderr" | grep -q 'is a symbolic link'; then
  ok "state dir symlink reason is 'is a symbolic link'"
elif [ "$rc" -eq 1 ]; then
  bad "state dir symlink: refusal reason is not 'is a symbolic link'"
  note "stderr: $stderr"
fi

# --------------------------------------------------------------------------
# 6. energy.db is a symlink to a victim file.
#
# SQLite opens the database by pathname, so the protection is that the
# state directory is verified owner-only and the database (and sidecars)
# are verified non-symlink, regular and owner-owned through that
# descriptor immediately before connect. A planted symlink must be
# refused, not followed into the victim, and not replaced.
# --------------------------------------------------------------------------
fresh_home
mkdir -p "$state_dir"
victim="$home/victim-db"
printf 'VICTIM_DB_DO_NOT_TOUCH\n' > "$victim"
chmod 600 "$victim"
cp -a "$victim" "$victim.before"
ln -s "$victim" "$state_dir/energy.db"
run_cli status
assert_refused "energy.db symlink"
assert_still_symlink "$state_dir/energy.db" "energy.db"
assert_victim_untouched "$victim" "$victim.before" "energy.db"
if printf '%s\n' "$stderr" | grep -q 'is a symbolic link'; then
  ok "energy.db symlink reason is 'is a symbolic link'"
elif [ "$rc" -eq 1 ]; then
  bad "energy.db symlink: refusal reason is not 'is a symbolic link'"
  note "stderr: $stderr"
fi

# --------------------------------------------------------------------------
# 7. The state directory is a *dangling* symlink.
#
# Path.exists() is False for a dangling link, which is how the old code
# walked straight into it: mkdir -p saw nothing there, the create
# succeeded through the link, and the attacker chose where. The rewrite
# has to refuse on the link itself rather than on whether its target
# resolves, so this case is separate from case 5.
# --------------------------------------------------------------------------
fresh_home
ln -s "$home/nowhere" "$state_dir"
run_cli daemon --once
assert_refused "dangling state dir symlink"
assert_still_symlink "$state_dir" "dangling state dir"
if [ ! -e "$home/nowhere" ]; then
  ok "dangling symlink target was not created"
else
  bad "created the dangling symlink's target"
fi

# --------------------------------------------------------------------------
# 8. config.json is a FIFO.
#
# A symlink is not the only way to hijack a pathname. A FIFO planted at
# config.json would block an O_RDONLY open forever, which turns the bar
# widget's CLI call into a hang rather than an error, so the managed stat
# rejects a non-regular file before any open and the open itself passes
# O_NONBLOCK. `timeout` here is the assertion: this case must not hang.
# --------------------------------------------------------------------------
fresh_home
mkdir -p -m 700 "$config_dir"
mkfifo "$config_dir/config.json"
rc=0
timeout 10 "$cli" config tariff=0.5 >"$workdir/.stdout" 2>"$workdir/.stderr" || rc=$?
stderr="$(cat "$workdir/.stderr")"
if [ "$rc" -eq 124 ]; then
  bad "FIFO at config.json: the CLI hung instead of refusing"
elif [ "$rc" -eq 1 ] && printf '%s\n' "$stderr" | grep -q 'refusing to use'; then
  ok "FIFO at config.json: refused with exit 1, no hang"
else
  bad "FIFO at config.json: exit $rc, want 1"
  note "stderr: $stderr"
fi
if printf '%s\n' "$stderr" | grep -q 'is not a regular file'; then
  ok "FIFO reason is 'is not a regular file'"
else
  bad "FIFO refusal reason is not 'is not a regular file'"
  note "stderr: $stderr"
fi
if [ -p "$config_dir/config.json" ]; then
  ok "the planted FIFO is still a FIFO"
else
  bad "the planted FIFO was replaced"
fi

# --------------------------------------------------------------------------
# 9. A hard link planted at config.json.
#
# O_NOFOLLOW does not help here because a hard link is not a symlink, so
# the open succeeds and every later operation lands on a file we did not
# create. This was measured, not theoretical: a hard link planted at
# config.json took the fchmod that tightens our own files and silently
# changed an unrelated file's mode from 0644 to 0600. The nlink check
# refuses that inode; the victim's mode staying 0644 is the regression.
# --------------------------------------------------------------------------
fresh_home
mkdir -p "$config_dir"
victim="$home/victim-hardlink"
printf '%s\n' '{"marker":"VICTIM_DO_NOT_TOUCH","tariff":0.01}' > "$victim"
chmod 644 "$victim"
cp -a "$victim" "$victim.before"
ln "$victim" "$config_dir/config.json"
run_cli config tariff=0.99
assert_refused "config.json hard link"
assert_victim_untouched "$victim" "$victim.before" "config.json hard link"
if printf '%s\n' "$stderr" | grep -q 'has 2 hard links, not 1'; then
  ok "config.json hard link reason is 'has 2 hard links, not 1'"
elif [ "$rc" -eq 1 ]; then
  bad "config.json hard link: refusal reason is not 'has 2 hard links, not 1'"
  note "stderr: $stderr"
fi
assert_mode "$victim" 644 "hard-link victim"

# --------------------------------------------------------------------------
# 10. An oversized config.json.
#
# A managed file is JSON config of a few hundred bytes, so anything of
# that size is not ours. The reader refuses when st_size exceeds 1 MiB
# and also caps the stream itself, because the stat is a promise about
# the file as it was, not as it is -- a writer can keep appending while
# we read. energy.db never goes through that reader, so a database
# larger than the cap must still work; without RAPL we cannot prove a
# live sampler, but we can prove the cap does not fire on energy.db.
# --------------------------------------------------------------------------
fresh_home
mkdir -p "$config_dir"
head -c $((2 << 20)) /dev/zero | tr '\0' 'A' > "$config_dir/config.json"
run_cli status
assert_refused "oversized config.json"
if printf '%s\n' "$stderr" | grep -q 'is larger than 1048576 bytes'; then
  ok "oversized config.json reason is 'is larger than 1048576 bytes'"
elif [ "$rc" -eq 1 ]; then
  bad "oversized config.json: refusal reason is not 'is larger than 1048576 bytes'"
  note "stderr: $stderr"
fi

fresh_home
mkdir -p "$state_dir"
head -c $((2 << 20)) /dev/zero | tr '\0' 'A' > "$state_dir/energy.db"
run_cli status
if printf '%s\n' "$stderr" | grep -q 'is larger than'; then
  bad "energy.db over 1 MiB was size-refused"
  note "stderr: $stderr"
else
  ok "energy.db over 1 MiB is not size-refused"
fi

exit "$fail"
