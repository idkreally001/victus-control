#!/usr/bin/env bash
#
# victus-fan uninstaller
# ----------------------
# Stops and disables the service, hands the fans back to the HP firmware
# (writes "2"/AUTO to pwm1_enable), and removes all installed files.
#
# Policy (ask-free, per contract): remove program files but LEAVE the user's
# configuration (/etc/victus-fan) and the 'victusfan' group in place, with a
# note on how to remove them manually. This is idempotent and safe to re-run.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Re-exec with sudo if not root; keep SUDO_USER for the extension cleanup.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo ">> Re-executing with sudo for root privileges..."
    exec sudo "$0" "$@"
fi

# ---------------------------------------------------------------------------
# 1. Stop and disable the service (best effort).
# ---------------------------------------------------------------------------
echo ">> Stopping and disabling victus-fan.service ..."
systemctl disable --now victus-fan.service >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 2. Hand fans back to firmware: write "2" (AUTO) to the hp-wmi pwm1_enable.
#    The daemon normally does this on SIGTERM, but do it here too in case the
#    daemon had already died. Discover the hwmon dir generically.
# ---------------------------------------------------------------------------
echo ">> Restoring firmware fan control (pwm1_enable = 2 / AUTO) ..."
restored=0
for d in /sys/devices/platform/hp-wmi/hwmon/hwmon*/; do
    if [[ -w "${d}pwm1_enable" ]]; then
        if echo 2 > "${d}pwm1_enable" 2>/dev/null; then
            echo "   wrote AUTO to ${d}pwm1_enable"
            restored=1
        fi
    fi
done
[[ "$restored" -eq 0 ]] && echo "   (no writable hp-wmi pwm1_enable found; skipping)"

# ---------------------------------------------------------------------------
# 3. Remove installed program files (idempotent).
# ---------------------------------------------------------------------------
echo ">> Removing installed files ..."
rm -f  /usr/lib/victus-fan/victus-fand            || true
rmdir  /usr/lib/victus-fan 2>/dev/null            || true
rm -f  /usr/bin/victus-fanctl                     || true
rm -f  /etc/systemd/system/victus-fan.service     || true
rm -f  /etc/tmpfiles.d/victus-fan.conf            || true

# Reload systemd so the removed unit disappears, and clean the runtime dir.
systemctl daemon-reload 2>/dev/null || true
rm -rf /run/victus-fan 2>/dev/null  || true

# ---------------------------------------------------------------------------
# 4. Leave config + group, with guidance.
# ---------------------------------------------------------------------------
cat <<EOF

============================================================================
 victus-fan removed. Fans are back under HP firmware (AUTO) control.

 Left in place on purpose:
   * /etc/victus-fan/         (your configuration)
   * group 'victusfan'        (system group + your membership)

 To remove them too:
   sudo rm -rf /etc/victus-fan
   sudo groupdel victusfan

 You may need to log out and back in for group changes to fully clear.
============================================================================
EOF
