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
  --no-udev   Skip the RAPL udev rule (the only step that needs root)
  -h, --help  Show this help

Installs:
  CLI     ~/.local/bin/omaenergy                         (copy, mode 755)
  unit    ~/.config/systemd/user/omarchy-energy.service
  state   ~/.local/share/omarchy-energy/                 (directory)
  config  ~/.config/omarchy-energy/                      (directory)
  udev    /etc/udev/rules.d/99-omarchy-energy-rapl.rules (root)

The udev rule grants the wheel group read-only access to RAPL energy_uj
so the daemon can sample CPU package energy. Upstream keeps energy_uj
root-only because of CVE-2020-8694 (PLATYPUS). The rule adds no privilege
wheel does not already hold.

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
  "  state   $STATE_DIR  (create if missing)" \
  "  config  $CONFIG_DIR  (create if missing)"
if [[ $NO_UDEV -eq 0 ]]; then
  printf '%s\n' "  udev    $SRC_UDEV  ->  $DEST_UDEV  (sudo)"
else
  printf '%s\n' '  udev    skipped (--no-udev)'
fi
printf '\n'

# ReadWritePaths in the unit names these directories; systemd will refuse to
# start the service if they do not exist at unit start time.
mkdir -p "$HOME/.local/bin" \
  "$HOME/.config/systemd/user" \
  "$STATE_DIR" \
  "$CONFIG_DIR"

cp -f "$SRC_CLI" "$DEST_CLI"
chmod 755 "$DEST_CLI"
printf 'installed CLI -> %s\n' "$DEST_CLI"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    printf 'WARNING: %s is not on PATH; add it or omaenergy will not resolve\n' \
      "$HOME/.local/bin" >&2
    ;;
esac

cp -f "$SRC_UNIT" "$DEST_UNIT"
printf 'installed unit -> %s\n' "$DEST_UNIT"
systemctl --user daemon-reload

udev_later() {
  printf '%s\n' \
    'The daemon cannot sample CPU energy until the RAPL udev rule is installed.' \
    'Install it later with:' \
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
      'READ-ONLY access to energy_uj so the user-session daemon can sample CPU' \
      'package energy. It confers no privilege wheel does not already hold.'
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
  printf 'RAPL package energy_uj is NOT readable by this user; CPU sampling will fail until the udev rule is installed and triggered.\n' >&2
fi

systemctl --user enable --now omarchy-energy.service
svc=$(systemctl --user is-active omarchy-energy.service || true)
printf 'service omarchy-energy.service: %s\n' "$svc"
printf '%s\n' \
  'Live reading:  omaenergy now' \
  'Logs:          journalctl --user -u omarchy-energy.service -f'
