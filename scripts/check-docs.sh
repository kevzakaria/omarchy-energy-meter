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

exit "$fail"
