#!/usr/bin/env bash
# Update this plugin and finish the install, or check whether that is due.
#
#   update.sh           omarchy plugin update (shows the diff, asks), then
#                       install.sh (the new CLI and daemon), then a shell
#                       restart if the plugin itself changed
#   update.sh --check   one JSON line: is the published version ahead of
#                       this checkout? Read-only: nothing here is written.
#
# Why this exists: `omarchy plugin update` moves the plugin checkout but not
# the copy of the CLI in ~/.local/bin that the daemon and the widget run, and
# Omarchy never tells anyone a third-party plugin has an update at all. v1.2.5
# shipped a daemon crash fix that only installed with a second, easily missed
# step. The widget runs --check once a day and offers this script behind one
# button, so an update is one click and one confirmation.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check() {
  # ls-remote asks the remote for its HEAD and writes nothing locally: no
  # FETCH_HEAD, no objects. That matters inside ~/.config/omarchy/plugins,
  # where the shell watches every write, and older shells did not yet ignore
  # .git (basecamp/omarchy#10702). Absolute paths for the same reason
  # restartSampler() uses one: this runs from the shell's inherited PATH.
  local here remote
  here="$(/usr/bin/git -C "$dir" rev-parse HEAD 2>/dev/null)" || {
    printf '{"status":"error","reason":"not a git checkout"}\n'; return 1; }
  remote="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -oBatchMode=yes" \
    /usr/bin/timeout 20 /usr/bin/git -C "$dir" ls-remote --quiet origin HEAD 2>/dev/null \
    | /usr/bin/awk 'NR == 1 { print $1 }')" || true
  if [[ ! $remote =~ ^[0-9a-f]{40}$ ]]; then
    # No `origin` (a development checkout), offline, or the host is down.
    # Not an update, and not worth a notice: tomorrow's check will say.
    printf '{"status":"error","reason":"remote not reachable"}\n'
    return 1
  fi
  local update=true
  if [[ $remote == "$here" ]]; then
    update=false
  elif /usr/bin/git -C "$dir" cat-file -e "$remote^{commit}" 2>/dev/null \
      && /usr/bin/git -C "$dir" merge-base --is-ancestor "$remote" HEAD 2>/dev/null; then
    # This checkout already contains the published commit: it is ahead, which
    # only a development checkout ever is.
    update=false
  fi
  printf '{"status":"ok","update":%s,"local":"%s","remote":"%s"}\n' "$update" "$here" "$remote"
}

update() {
  local omarchy="${OMARCHY_PATH:-/usr/share/omarchy}"
  local id before after
  id="$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$dir/manifest.json")"
  before="$(git -C "$dir" rev-parse HEAD)"

  # GIT_PAGER=cat: without `delta`, omarchy-plugin-update shows the diff in
  # git's pager and its confirmation prompt waits behind it, invisible until
  # the pager is quit (basecamp/omarchy#12332).
  GIT_PAGER=cat "$omarchy/bin/omarchy-plugin-update" "$id"
  after="$(git -C "$dir" rev-parse HEAD)"

  # Always, even when the plugin was already current or the update was
  # declined: a daemon left behind by an earlier update is the other thing
  # the widget sends people here for, and install.sh is idempotent.
  "$dir/install.sh"

  if [[ $before != "$after" ]]; then
    # A mounted bar widget keeps its old QML until the shell restarts, and a
    # panel's component cache survives even the plugin rescan
    # (basecamp/omarchy#12767).
    "$omarchy/bin/omarchy-restart-shell"
  fi
  echo
  echo "Energy Meter is up to date."
}

# Everything runs from inside a function called on the last line. The update
# replaces this file while it is running, and bash reads a script as it goes:
# by the time main returns, the rest of the old file has already been parsed.
main() {
  case "${1:-}" in
    --check) check ;;
    "") update ;;
    -h | --help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) echo "usage: update.sh [--check]" >&2; return 2 ;;
  esac
}
main "$@"; exit $?
