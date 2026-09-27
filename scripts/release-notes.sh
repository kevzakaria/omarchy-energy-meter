#!/usr/bin/env bash
# Draft the GitHub Release body for a version, from CHANGELOG.md.
#
# The first six releases were written by hand, and two things went wrong that
# a script does not forget. The prose was hard-wrapped at 80 columns, and a
# release body renders every newline as <br>, so each paragraph came out
# ragged. And v1.2.5 told readers to "update" when its fix was in the daemon:
# `omarchy plugin update` does not replace ~/.local/bin/omaenergy, so anyone
# who followed it kept the crashing daemon. Which step a release needs is a
# fact about which files changed, so it is computed here, not remembered.
#
# usage: scripts/release-notes.sh <version> [<target>] > notes.md
#   <version>  1.2.6 (no leading v). Uses `## 1.2.6` from CHANGELOG.md, or
#              `## Unreleased` before the cut renames it.
#   <target>   what the tag will point at, as GitHub knows it: a pushed branch
#              or SHA. Default `release`.
#
# The draft opens with a TODO for the one or two sentences only a person can
# write. Edit it, then publish without --generate-notes (the PR list is
# already in the draft):
#   gh release create v1.2.6 --target main --title v1.2.6 --notes-file notes.md
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
  sed -n '12,17p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
version="${1#v}"
target="${2:-release}"
tag="v$version"

# This script does not update the local refs itself. The marketplace's security
# baseline scans every file in the repository, this one included, and reads
# a fetch followed by `python3 -` as running code pulled from a remote. So it
# only asks GitHub, and stops when the local refs are behind.
stale() { echo "release-notes: $1 Fetch origin with its tags first." >&2; exit 1; }

# A name is read as origin/<name> only when GitHub has a branch by that name.
# `HEAD` used to resolve to origin/HEAD, which is main, so a draft for an
# unpushed cut was diffed against the previous release and came out empty.
remote_rev="$(git ls-remote --quiet origin "refs/heads/$target" | cut -f1)"
if [ -n "$remote_rev" ]; then
  target_rev="$(git rev-parse --verify --quiet "origin/$target" || true)"
  [ "$target_rev" = "$remote_rev" ] || stale "origin/$target is behind GitHub."
else
  target_rev="$(git rev-parse --verify --quiet "$target^{commit}")" \
    || { echo "release-notes: unknown target '$target'" >&2; exit 1; }
fi

# A tag missing locally would make an older one "previous" without a word.
while read -r t; do
  [ -z "$t" ] || git rev-parse --verify --quiet "refs/tags/$t" >/dev/null || stale "tag $t is not here."
done <<EOF
$(git ls-remote --quiet --tags --refs origin 'v*' | sed 's|.*refs/tags/||')
EOF

# The newest tag that is an ancestor of the target and is not this version.
prev=""
for t in $(git tag -l 'v*' --sort=-v:refname); do
  [ "$t" = "$tag" ] && continue
  if git merge-base --is-ancestor "$t" "$target_rev"; then prev="$t"; break; fi
done
[ -n "$prev" ] || { echo "release-notes: no earlier v* tag below $target" >&2; exit 1; }

changed="$(git diff --name-only "$prev" "$target_rev")"
has() { grep -qE "$1" <<<"$changed"; }
daemon=0; udev=0; qml=0
has '^(bin/omaenergy|systemd/)' && daemon=1
has '^udev/' && udev=1
has '\.qml$' && qml=1

generated="$(gh api -X POST 'repos/{owner}/{repo}/releases/generate-notes' \
  -f tag_name="$tag" -f target_commitish="$target" -f previous_tag_name="$prev" \
  --jq .body)"
owner="$(gh repo view --json owner --jq .owner.login)"
plugin_id="$(python3 -c 'import json; print(json.load(open("manifest.json"))["id"])')"

echo "release-notes: $prev..$target -> $tag" >&2
[ "$udev" = 1 ] && echo "release-notes: udev/ changed. If only comments changed, replace the sudo sentence in the Upgrade line." >&2

VERSION="$version" DAEMON="$daemon" UDEV="$udev" QML="$qml" \
GENERATED="$generated" OWNER="$owner" PLUGIN_ID="$plugin_id" \
python3 - <<'PY'
import os, re, sys

env = os.environ
version = env["VERSION"]

# --- the changelog section ------------------------------------------------
lines = open("CHANGELOG.md", encoding="utf-8").read().split("\n")
def section(name):
    try:
        start = lines.index(f"## {name}") + 1
    except ValueError:
        return None
    end = next((i for i in range(start, len(lines)) if lines[i].startswith("## ")), len(lines))
    return "\n".join(lines[start:end]).strip("\n")

body = section(version)
if body is None:
    body = section("Unreleased")
    if body is None:
        sys.exit(f"release-notes: CHANGELOG.md has neither '## {version}' nor '## Unreleased'")
    print("release-notes: using '## Unreleased'; the cut renames it to the version", file=sys.stderr)

# `**Added**` alone on a line is the changelog's subheading.
body = re.sub(r"^\*\*([A-Z][A-Za-z ]+)\*\*$", r"### \1", body, flags=re.M)

BLOCK = re.compile(r"^\s*(#{1,6}\s|[-*+]\s|\d+[.)]\s|>|\||<|```|~~~)")
ITEM = re.compile(r"^\s*([-*+]|\d+[.)])\s")

def unwrap(text):
    """Join hard-wrapped paragraph and list-item lines. Fences, headings,
    tables, quotes and HTML are left exactly as they are."""
    out, fence, joinable = [], False, False
    for line in text.split("\n"):
        s = line.strip()
        if s.startswith(("```", "~~~")):
            fence = not fence
            out.append(line); joinable = False; continue
        if fence or not s:
            out.append(line); joinable = False; continue
        if BLOCK.match(line):
            out.append(line.rstrip()); joinable = bool(ITEM.match(line)); continue
        if joinable:
            out[-1] = out[-1].rstrip() + " " + s
        else:
            out.append(line.rstrip()); joinable = True
    return "\n".join(out)

body = unwrap(body)

# --- what a reader has to do ------------------------------------------------
install = f"~/.config/omarchy/plugins/{env['PLUGIN_ID']}/install.sh"
if env["DAEMON"] == "1" or env["UDEV"] == "1":
    upgrade = "**Upgrade:** after `omarchy plugin update`, re-run the installer."
    if env["DAEMON"] == "1":
        upgrade += (" The daemon runs its own copy at `~/.local/bin/omaenergy`, which a plugin "
                    "update does not replace; the installer copies it and restarts the service.")
    if env["UDEV"] == "1":
        upgrade += " It asks for `sudo` to replace the udev rule."
    if env["QML"] == "1":
        upgrade += " Then run `omarchy restart shell`, since a mounted widget keeps its old code."
    upgrade += f"\n\n```bash\n{install}\n```"
elif env["QML"] == "1":
    upgrade = ("**Upgrade:** `omarchy plugin update`, then `omarchy restart shell`. "
               "A mounted widget keeps running its old code until the shell restarts.")
else:
    upgrade = "**Upgrade:** nothing to do beyond `omarchy plugin update`."

# --- who to thank -------------------------------------------------------------
generated = env["GENERATED"].strip()
prs = re.findall(r"by @([\w-]+(?:\[bot\])?) in https://github\.com/\S+/pull/(\d+)", generated)
credit = {}
for who, num in prs:
    if who == env["OWNER"] or who.endswith("[bot]"):
        continue
    credit.setdefault(who, []).append(f"#{num}")
thanks = ""
if credit:
    names = [f"@{w} ({', '.join(n)})" for w, n in credit.items()]
    joined = names[0] if len(names) == 1 else ", ".join(names[:-1]) + " and " + names[-1]
    thanks = f"Thanks to {joined}."

# With no merged PRs in range, GitHub returns only its marker comment and the
# compare link; keep the link.
if "## What's Changed" not in generated:
    generated = "\n".join(l for l in generated.split("\n") if l.startswith("**Full Changelog**"))

parts = ["## Highlights", upgrade,
         "TODO: one or two sentences on what this release means for a reader.",
         thanks, body, generated]
print("\n\n".join(p for p in parts if p).rstrip() + "\n")
PY
