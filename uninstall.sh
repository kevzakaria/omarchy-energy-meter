#!/usr/bin/env bash
# Remove the energy-meter backend installed by install.sh.
# Does not delete the energy database or config unless --purge is given.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--no-udev] [--purge] [--help]

Remove the omarchy-energy-meter backend.

Options:
  --no-udev   Leave the RAPL udev rule in place
  --purge     Also delete ~/.local/share/omarchy-energy (the energy history)
              and ~/.config/omarchy-energy (config.json)
  -h, --help  Show this help

By default the energy database and the config directory are kept: the
history cannot be regenerated. --purge is required to delete them.

The bar widget is not removed by this script. After uninstalling the
backend, run:
  omarchy plugin remove io.github.kevzakaria.energy-meter
EOF
}

NO_UDEV=0
PURGE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-udev) NO_UDEV=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

DEST_CLI=$HOME/.local/bin/omaenergy
DEST_UNIT=$HOME/.config/systemd/user/omarchy-energy.service
DEST_UDEV=/etc/udev/rules.d/99-omarchy-energy-rapl.rules
STATE_DIR=$HOME/.local/share/omarchy-energy
CONFIG_DIR=$HOME/.config/omarchy-energy

printf 'Stopping and disabling omarchy-energy.service\n'
systemctl --user disable --now omarchy-energy.service 2>/dev/null || true
if [[ -e "$DEST_UNIT" ]]; then
  rm -f "$DEST_UNIT"
  printf 'removed %s\n' "$DEST_UNIT"
fi
systemctl --user daemon-reload

if [[ -e "$DEST_CLI" ]]; then
  rm -f "$DEST_CLI"
  printf 'removed %s\n' "$DEST_CLI"
fi

if [[ $NO_UDEV -eq 1 ]]; then
  printf 'leaving udev rule in place (--no-udev)\n'
elif [[ -e "$DEST_UDEV" ]]; then
  if [[ -t 0 && -t 1 ]] && command -v sudo >/dev/null 2>&1; then
    printf 'Removing %s via sudo...\n' "$DEST_UDEV"
    if sudo rm -f "$DEST_UDEV" \
      && sudo udevadm control --reload-rules; then
      printf 'udev rule removed\n'
    else
      printf 'sudo declined or failed; udev rule left at %s\n' "$DEST_UDEV" >&2
    fi
  else
    printf 'no terminal or sudo unavailable; udev rule left at %s\n' "$DEST_UDEV" >&2
    printf '%s\n' \
      'Remove later with:' \
      "  sudo rm -f $DEST_UDEV" \
      '  sudo udevadm control --reload-rules'
  fi
else
  printf 'udev rule not present at %s\n' "$DEST_UDEV"
fi

if [[ $NO_UDEV -eq 0 ]]; then
  printf '%s\n' \
    'Removing the udev rule does not restore permissions on an already-created' \
    'sysfs attribute. The energy_uj grant stays until the device is recreated' \
    'or the machine reboots. To revoke it now, restore the kernel default of' \
    'root-only on every RAPL zone (an older version of this rule also touched' \
    'the per-core sub-zone, so do not filter by name here):' \
    '' \
    '  for z in /sys/class/powercap/intel-rapl:*; do' \
    '    [ -e "$z/energy_uj" ] || continue' \
    '    sudo chgrp root "$z/energy_uj" && sudo chmod 0400 "$z/energy_uj"' \
    '  done' \
    '' \
    'Skip that if another rule or policy on this machine also grants access:' \
    'it would be reverting their change, not ours.'
fi

if [[ -e "$STATE_DIR" ]]; then
  size=$(du -sh "$STATE_DIR" | awk '{print $1}')
  printf 'Energy history: %s (%s)\n' "$STATE_DIR" "$size"
  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$STATE_DIR"
    printf 'purged %s\n' "$STATE_DIR"
  else
    printf '%s\n' \
      'Not deleting the energy database (irreplaceable history).' \
      'Delete it later with:' \
      "  rm -rf $STATE_DIR"
  fi
else
  printf 'No energy history directory at %s\n' "$STATE_DIR"
fi

if [[ -e "$CONFIG_DIR" ]]; then
  printf 'Config: %s\n' "$CONFIG_DIR"
  if [[ $PURGE -eq 1 ]]; then
    rm -rf "$CONFIG_DIR"
    printf 'purged %s\n' "$CONFIG_DIR"
  else
    printf '%s\n' \
      'Not deleting the config directory.' \
      'Delete it later with:' \
      "  rm -rf $CONFIG_DIR"
  fi
else
  printf 'No config directory at %s\n' "$CONFIG_DIR"
fi

printf '%s\n' \
  'The bar widget is removed with:' \
  '  omarchy plugin remove io.github.kevzakaria.energy-meter'
