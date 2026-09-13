#!/usr/bin/env bash
# Install the energy-meter backend (CLI + user systemd unit + optional udev).
# Idempotent: safe to re-run. Copies files, never symlinks.
#
# Never writes into /usr/share/omarchy/ and never edits shell.json:
# bar placement is `omarchy plugin enable`, not this installer.
set -euo pipefail
# The CLI shebang is #!/usr/bin/python3 (stdlib only; nothing to pip). Do not
# switch it to /usr/bin/env python3: env may resolve to a user-managed
# interpreter that the systemd service cannot see.

usage() {
  cat <<'EOF'
Usage: install.sh [--no-udev] [--help]

Install the omarchy-energy-meter backend for the current user.

Options:
  --no-udev   Skip the RAPL udev rule (the only step that needs root).
              This does not give a GPU-only meter: without a readable
              RAPL package zone the daemon exits non-zero and the unit
              retries because Restart=always.
  -h, --help  Show this help

Installs:
  CLI     ~/.local/bin/omaenergy                         (copy, mode 755)
  unit    ~/.config/systemd/user/omarchy-energy.service
  state   ~/.local/share/omarchy-energy/                 (directory, mode 0700)
  config  ~/.config/omarchy-energy/                      (directory, mode 0700)
  udev    /etc/udev/rules.d/99-omarchy-energy-rapl.rules (root)

The udev rule grants the wheel group read-only access to RAPL energy_uj
on package-* zones only so the daemon can sample CPU package energy.
It does not match the per-core sub-zone (the higher-resolution PLATYPUS
domain). Upstream keeps energy_uj root-only because of CVE-2020-8694
It grants no write access and no new command; what it does remove is the
sudo authentication step, so any process running as you can then read the
package counter directly, at any rate it likes.
Without a readable RAPL package zone the daemon refuses to start.

Requires /usr/bin/python3 (the CLI shebang; stdlib only, no pip).
EOF
}

NO_UDEV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-udev) NO_UDEV=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_CLI=$SCRIPT_DIR/bin/omaenergy
SRC_UNIT=$SCRIPT_DIR/systemd/omarchy-energy.service
SRC_UDEV=$SCRIPT_DIR/udev/99-omarchy-energy-rapl.rules

DEST_CLI=$HOME/.local/bin/omaenergy
DEST_UNIT=$HOME/.config/systemd/user/omarchy-energy.service
DEST_UDEV=/etc/udev/rules.d/99-omarchy-energy-rapl.rules
STATE_DIR=$HOME/.local/share/omarchy-energy
CONFIG_DIR=$HOME/.config/omarchy-energy

for src in "$SRC_CLI" "$SRC_UNIT" "$SRC_UDEV"; do
  if [[ ! -f "$src" ]]; then
    printf 'install.sh: missing source file: %s\n' "$src" >&2
    exit 1
  fi
done

if [[ ! -x /usr/bin/python3 ]]; then
  printf '%s\n' \
    'install.sh: /usr/bin/python3 is missing or not executable.' \
    'The CLI shebang is #!/usr/bin/python3 so the systemd user service can' \
    'start it without depending on PATH or a user-managed interpreter.' >&2
  exit 1
fi

printf '%s\n' \
  'This will install:' \
  "  CLI     $SRC_CLI  ->  $DEST_CLI  (copy, mode 755)" \
  "  unit    $SRC_UNIT  ->  $DEST_UNIT" \
  "  state   $STATE_DIR  (create if missing, mode 0700)" \
  "  config  $CONFIG_DIR  (create if missing, mode 0700)"
if [[ $NO_UDEV -eq 0 ]]; then
  printf '%s\n' "  udev    $SRC_UDEV  ->  $DEST_UDEV  (sudo)"
else
  printf '%s\n' '  udev    skipped (--no-udev)'
fi
printf '\n'

# ReadWritePaths in the unit names these directories; systemd will refuse to
# start the service if they do not exist at unit start time. Mode 0700 so
# energy history and config.json are not group/world readable.
mkdir -p "$HOME/.local/bin" \
  "$HOME/.config/systemd/user"
mkdir -p -m 0700 "$STATE_DIR" "$CONFIG_DIR"
chmod 0700 "$STATE_DIR" "$CONFIG_DIR"

cli_changed=0
unit_changed=0

if [[ -f "$DEST_CLI" ]] && cmp -s "$SRC_CLI" "$DEST_CLI"; then
  printf 'CLI already installed and identical\n'
else
  cp -f "$SRC_CLI" "$DEST_CLI"
  chmod 755 "$DEST_CLI"
  cli_changed=1
  printf 'installed CLI -> %s\n' "$DEST_CLI"
fi

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    printf 'WARNING: %s is not on PATH; add it or omaenergy will not resolve\n' \
      "$HOME/.local/bin" >&2
    ;;
esac

if [[ -f "$DEST_UNIT" ]] && cmp -s "$SRC_UNIT" "$DEST_UNIT"; then
  printf 'unit already installed and identical\n'
else
  cp -f "$SRC_UNIT" "$DEST_UNIT"
  unit_changed=1
  printf 'installed unit -> %s\n' "$DEST_UNIT"
fi

if [[ $unit_changed -eq 1 ]]; then
  systemctl --user daemon-reload
fi

udev_later() {
  printf '%s\n' \
    'The daemon refuses to start without a readable RAPL package zone.' \
    '--no-udev only defers the root step; it does not give a GPU-only meter.' \
    'Install the rule later with:' \
    "  sudo cp $SRC_UDEV $DEST_UDEV" \
    '  sudo udevadm control --reload-rules' \
    '  sudo udevadm trigger --subsystem-match=powercap --action=add'
}

if [[ $NO_UDEV -eq 1 ]]; then
  printf 'skipping udev rule (--no-udev)\n'
else
  if [[ -f "$DEST_UDEV" ]] && cmp -s "$SRC_UDEV" "$DEST_UDEV"; then
    printf 'udev rule already installed and identical; skipping\n'
  else
    printf '%s\n' \
      'The RAPL energy_uj sysfs file is root-only upstream (CVE-2020-8694 /' \
      'PLATYPUS, a power side channel). This rule grants the wheel group' \
      'READ-ONLY access to energy_uj on package-* zones only so the' \
      'user-session daemon can sample CPU package energy. It does not match' \
      'the per-core sub-zone. No write access and no new command: what it' \
      'removes is the sudo step, so anything running as you can then read the' \
      'package counter directly, at any rate.'
    if [[ -t 0 && -t 1 ]] && command -v sudo >/dev/null 2>&1; then
      printf 'Installing %s via sudo...\n' "$DEST_UDEV"
      if sudo cp -f "$SRC_UDEV" "$DEST_UDEV" \
        && sudo udevadm control --reload-rules \
        && sudo udevadm trigger --subsystem-match=powercap --action=add; then
        printf 'udev rule installed\n'
      else
        printf 'sudo declined or failed; continuing without the udev rule.\n' >&2
        udev_later
      fi
    else
      printf 'no terminal or sudo unavailable; skipping udev rule.\n' >&2
      udev_later
    fi
  fi
fi

printf 'Checking RAPL package energy_uj readability...\n'
rapl_ok=0
rapl_found=0
for zone in /sys/class/powercap/*; do
  if [[ ! -f "$zone/name" ]]; then
    continue
  fi
  name=$(cat "$zone/name" 2>/dev/null || true)
  case "$name" in
    package-*)
      rapl_found=1
      if [[ -r "$zone/energy_uj" ]]; then
        rapl_ok=1
        printf '  readable: %s (%s)\n' "$zone/energy_uj" "$name"
      else
        printf '  NOT readable: %s (%s)\n' "$zone/energy_uj" "$name"
      fi
      ;;
  esac
done
if [[ $rapl_found -eq 0 ]]; then
  printf '  no package-* RAPL zone found under /sys/class/powercap\n' >&2
fi
if [[ $rapl_ok -eq 1 ]]; then
  printf 'RAPL package energy_uj is readable by this user.\n'
else
  printf 'RAPL package energy_uj is NOT readable by this user, so the daemon will refuse to start.\n' >&2
  # Three different causes, and telling the user the wrong one costs them an
  # afternoon. The rule grants access to `wheel`, which is the admin group on
  # Arch and Omarchy; on a distribution that uses another group, edit the rule.
  if [[ ! -f $DEST_UDEV ]]; then
    printf '  Cause: the udev rule is not installed. Re-run this script without --no-udev.\n' >&2
  elif [[ " $(id -nG) " != *" wheel "* ]]; then
    printf '  Cause: the rule is installed, but you are not in the "wheel" group it grants read access to.\n' >&2
    printf '    sudo usermod -aG wheel %s\n' "$(id -un)" >&2
    printf '  Group membership only applies to new sessions, so log out and back in afterwards.\n' >&2
  else
    printf '  Cause: the rule is installed and you are in "wheel", so it has probably not been applied yet.\n' >&2
    printf '    sudo udevadm trigger --subsystem-match=powercap --action=add\n' >&2
  fi
fi

# enable --now is a no-op on an already-active unit and would leave a stale
# process running the pre-copy CLI. Restart only when the CLI or unit bytes
# actually changed; say so when they did not.
systemctl --user enable omarchy-energy.service
if [[ $cli_changed -eq 1 && $unit_changed -eq 1 ]]; then
  printf 'CLI and unit changed; restarting omarchy-energy.service\n'
  systemctl --user restart omarchy-energy.service
elif [[ $cli_changed -eq 1 ]]; then
  printf 'CLI changed; restarting omarchy-energy.service\n'
  systemctl --user restart omarchy-energy.service
elif [[ $unit_changed -eq 1 ]]; then
  printf 'unit changed; restarting omarchy-energy.service\n'
  systemctl --user restart omarchy-energy.service
else
  printf 'CLI and unit unchanged; not restarting omarchy-energy.service\n'
fi
svc=$(systemctl --user is-active omarchy-energy.service || true)
printf 'service omarchy-energy.service: %s\n' "$svc"
printf '%s\n' \
  'Live reading:  omaenergy now' \
  'Logs:          journalctl --user -u omarchy-energy.service -f'
