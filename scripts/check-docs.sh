#!/usr/bin/env bash
# Assert that what the repository says matches what it ships.
#
# Four audits before v1.2.0 found no leak and a pile of documentation that
# promised things the code refuses to do. Those were fixed by hand, and by
# v1.2.3 the udev rule was still carrying the exact sentence the audits were
# about, because the README was corrected and the rule file was not. Prose
# cannot be kept honest by remembering to keep it honest.
#
# Run before pushing. CI runs it too.
set -euo pipefail

cd "$(dirname "$0")/.."
self="scripts/$(basename "$0")"
fail=0

note() { printf '  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }
ok() { printf 'ok    %s\n' "$1"; }

# --------------------------------------------------------------------------
# 1. The README embeds a copy of the udev rule. Two copies, one truth.
# --------------------------------------------------------------------------
rule_file=udev/99-omarchy-energy-rapl.rules
rule_line=""
if [ -f "$rule_file" ]; then
  rule_line="$(grep -m1 '^ACTION==' "$rule_file" || true)"
fi
if [ ! -f "$rule_file" ] || [ ! -f README.md ] || [ -z "$rule_line" ]; then
  bad "cannot compare the udev rule against README.md"
  note "missing or ruleless: $rule_file / README.md"
elif grep -qF -- "$rule_line" README.md; then
  ok "README quotes the shipped udev rule verbatim"
else
  bad "README's copy of the udev rule has drifted from $rule_file"
  note "shipped: $rule_line"
  note "README does not contain that line. Update the fenced block in README.md."
fi

# --------------------------------------------------------------------------
# 2. Claims this repository has already made and had to retract.
#
# The rule removes the sudo authentication step for RAPL package reads. That
# is a real change in what an unauthenticated process can do, and every
# phrasing below denies it.
#
# Matching is done on a whitespace-flattened copy of each file, not line by
# line. The sentence this check exists for was wrapped across two comment
# lines -- "...confers no" / "privilege the wheel group..." -- and a line-based
# grep walks straight past it. That is not hypothetical: the first version of
# this script passed clean on the v1.2.2 tree that still carried the claim.
#
# CHANGELOG.md is exempt, and has to be: its job is to quote the sentence that
# was withdrawn and say when. Everything else is in scope, including files
# added later, so a new document is covered by default rather than when
# someone remembers to list it.
# --------------------------------------------------------------------------
claims_ok=1
while IFS= read -r phrase; do
  [ -n "$phrase" ] || continue
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    grep -Iq . "$f" 2>/dev/null || continue   # skip binaries
    flat="$(sed 's/^[[:space:]]*#\{1,\}[[:space:]]\{0,1\}//' "$f" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
    case "${flat,,}" in
      *"$phrase"*)
        bad "retracted claim is back in $f: \"$phrase\""
        claims_ok=0
        ;;
    esac
  done <<EOF
$(git ls-files -- . ":(exclude)$self" ":(exclude)CHANGELOG.md")
EOF
done <<'PHRASES'
confers no privilege
no privilege the wheel group
grants no new privilege
no new privileges are granted
requires no sudo
no sudo is required
PHRASES
if [ "$claims_ok" -eq 1 ]; then ok "no retracted privilege claim is present"; fi

# --------------------------------------------------------------------------
# 3. manifest.json's version against the newest cut in the changelog.
#
# 1.2.1 was cut on main by mistake, which made the --ff-only merge a silent
# no-op. A version that never passed through the changelog is the same class
# of mistake seen from the other end.
# --------------------------------------------------------------------------
# A missing file is a failed check, not an aborted script: `set -o pipefail`
# turns sed's "can't read" into a mid-run exit 2 that reads like a crash.
manifest_version=""
changelog_version=""
[ -f manifest.json ] && manifest_version="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' manifest.json | head -1)"
[ -f CHANGELOG.md ] && changelog_version="$(sed -n 's/^## \([0-9][0-9.]*\)[[:space:]]*$/\1/p' CHANGELOG.md | head -1)"
if [ -z "$manifest_version" ] || [ -z "$changelog_version" ]; then
  bad "cannot compare versions: manifest.json=${manifest_version:-<none>} CHANGELOG.md=${changelog_version:-<none>}"
elif [ "$manifest_version" = "$changelog_version" ]; then
  ok "manifest version $manifest_version matches the newest changelog entry"
else
  bad "manifest.json says $manifest_version, newest changelog entry is $changelog_version"
  note "Cut from release, and move both in the same commit."
fi

# --------------------------------------------------------------------------
# 4. Managed I/O in bin/omaenergy must not go by pathname.
#
# The marketplace reviewer's finding was that ensure_private_dir /
# write_private_file / save_config / _chmod_owned inspected one inode and
# then operated on a path, so a symlink planted between the two was
# followed. A future edit that brings Path.read_text on CONFIG_PATH, a
# predictable .json.tmp, or chmod-by-path back would reintroduce that
# silently. This audit is the static half of that check.
#
# Sysfs Path.read_text() calls (RAPL energy_uj, hwmon power1_*, DMI
# chassis_type) are deliberately out of scope. Those are world-readable
# firmware interfaces, not files we create, and the finding was about
# config.json / energy.db and the directories that hold them.
# --------------------------------------------------------------------------
py=bin/omaenergy
if [ ! -f "$py" ]; then
  bad "bin/omaenergy is missing"
else
  path_ok=1
  check_offenders() {
    local needle="$1" blurb="$2" matches
    matches="$(grep -nF -- "$needle" "$py" || true)"
    if [ -n "$matches" ]; then
      bad "$blurb"
      while IFS= read -r line; do
        note "$line"
      done <<EOF
$matches
EOF
      path_ok=0
    fi
  }
  check_offenders 'CONFIG_PATH.read_text' 'bin/omaenergy reads config.json by pathname (CONFIG_PATH.read_text)'
  check_offenders 'CONFIG_PATH.write_text' 'bin/omaenergy writes config.json by pathname (CONFIG_PATH.write_text)'
  check_offenders 'DB_PATH.exists(' 'bin/omaenergy follows energy.db via DB_PATH.exists('
  check_offenders 'with_suffix(".json.tmp")' 'bin/omaenergy uses the predictable config.json.tmp pathname'
  check_offenders 'os.chmod(' 'bin/omaenergy chmods by pathname (os.chmod)'
  # write_private_file's bug was O_TRUNC without O_NOFOLLOW, so every open in
  # this file has to be accounted for. Two line-oriented greps, on purpose: a
  # clever multiline matcher would be harder to explain when it fails than the
  # finding it exists to catch.
  #
  # First, every os.open must be dir-relative, which is the safe layer's whole
  # primitive. Two lines are exempt and say so on the line itself: the
  # BrokenPipeError redirect to os.devnull, which is not a managed path, and
  # the single open of the XDG *parent* directory, which may legitimately be a
  # symlink on a user's machine (/home, a linked ~/.config).
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *os.devnull*|*trusted-parent-open*) continue ;;
    esac
    case "$line" in
      *dir_fd=*) ;;
      *) bad "os.open that is not dir-relative: $line"; path_ok=0; continue ;;
    esac
    # Second, a dir-relative open must take its flags from the `flags` local
    # audited below, or carry O_NOFOLLOW on the call itself.
    case "$line" in
      *O_NOFOLLOW*|*flags*) continue ;;
    esac
    bad "dir-relative os.open with unaudited flags: $line"
    path_ok=0
  done <<EOF
$(grep -n 'os\.open(' "$py" || true)
EOF
  # Every managed open composes its flags into a local named `flags`. That is
  # the line the missing O_NOFOLLOW would be missing from.
  flag_lines="$(grep -n '^[[:space:]]*flags [|]\{0,1\}= os\.O_' "$py" || true)"
  if [ -z "$flag_lines" ]; then
    bad "bin/omaenergy composes no open flags in a 'flags' local; this audit went blind"
    path_ok=0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *O_NOFOLLOW*) continue ;;
    esac
    bad "open flags without O_NOFOLLOW: $line"
    path_ok=0
  done <<EOF
$flag_lines
EOF
  if [ "$path_ok" -eq 1 ]; then ok "bin/omaenergy has no pathname-based managed I/O"; fi
fi


exit "$fail"
