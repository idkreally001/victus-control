#!/usr/bin/env bash
#
# victus-fan installer
# --------------------
# Userspace fan controller for an HP Victus 15-fb0xxx on Ubuntu 26.04
# (kernel 7.0, Secure Boot ON). NO kernel module — stock hp-wmi only.
#
# This script installs:
#   daemon  -> /usr/lib/victus-fan/victus-fand            (root, 0755)
#   cli     -> /usr/bin/victus-fanctl                     (0755)
#   service -> /etc/systemd/system/victus-fan.service     (runs as root)
#   tmpfiles-> /etc/tmpfiles.d/victus-fan.conf
#   config  -> /etc/victus-fan/config.json   root:victusfan 0664 (in dir 2775)
#
# It also creates the system group "victusfan" and adds the installing desktop
# user to it so the CLI can atomically replace /etc/victus-fan/config.json.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve our own location FIRST, before any privilege juggling, so the source
# tree is found no matter where the script is invoked from.
# ---------------------------------------------------------------------------
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Re-exec with sudo if we are not root. We preserve $0 and arguments so the
# re-exec'd copy points back at the same script in the same source tree.
# sudo keeps SUDO_USER set to the invoking user, which is exactly what we use
# below to find the desktop user.
# ---------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo ">> Re-executing with sudo for root privileges..."
    exec sudo "$0" "$@"
fi

# ---------------------------------------------------------------------------
# Detect the desktop user via SUDO_USER. When the script is run directly as
# root (e.g. in a root shell) SUDO_USER is empty; warn but continue with the
# system-wide parts.
# ---------------------------------------------------------------------------
DESKTOP_USER="${SUDO_USER:-}"
if [[ -z "$DESKTOP_USER" || "$DESKTOP_USER" == "root" ]]; then
    echo "!! WARNING: could not resolve a non-root desktop user via SUDO_USER."
    echo "!!          Group membership and the GNOME extension will be skipped."
    echo "!!          Re-run with: sudo ./install.sh   (from your user session)."
    DESKTOP_USER=""
fi

# Resolve the desktop user's HOME from the password database (do not trust the
# inherited $HOME, which is root's under sudo).
DESKTOP_HOME=""
if [[ -n "$DESKTOP_USER" ]]; then
    DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
    if [[ -z "$DESKTOP_HOME" ]]; then
        echo "!! WARNING: could not resolve home directory for '$DESKTOP_USER'."
    fi
fi

echo ">> Source tree:  $SRC_DIR"
echo ">> Desktop user: ${DESKTOP_USER:-<none>}"

# ---------------------------------------------------------------------------
# 1. Dependencies. The daemon and CLI are pure stdlib python3, which is part of
#    a base Ubuntu install; we make sure it is present but never abort if apt is
#    momentarily busy — there is nothing else to install.
# ---------------------------------------------------------------------------
echo ">> Ensuring python3 is present ..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y python3 || \
        echo "!! WARNING: apt-get failed; python3 is normally already present."
else
    echo "!! WARNING: apt-get not found; skipping dependency check."
fi

# ---------------------------------------------------------------------------
# 2. System group + membership.
# ---------------------------------------------------------------------------
echo ">> Ensuring system group 'victusfan' exists..."
if ! getent group victusfan >/dev/null 2>&1; then
    groupadd --system victusfan
    echo "   created group 'victusfan'."
else
    echo "   group 'victusfan' already exists."
fi

if [[ -n "$DESKTOP_USER" ]]; then
    echo ">> Adding '$DESKTOP_USER' to group 'victusfan'..."
    usermod -aG victusfan "$DESKTOP_USER"
fi

# ---------------------------------------------------------------------------
# 3. Install program files.
# ---------------------------------------------------------------------------
echo ">> Installing daemon and CLI..."
install -D -m 0755 "$SRC_DIR/daemon/victus-fand"   /usr/lib/victus-fan/victus-fand
install -D -m 0755 "$SRC_DIR/daemon/victus-fanctl" /usr/bin/victus-fanctl
install -D -m 0644 "$SRC_DIR/README.md" /usr/share/doc/victus-fan/README.md

# ---------------------------------------------------------------------------
# 4. Config directory + default config.
#    Dir: root:victusfan 2775 (setgid + group-writable) so UIs can atomically
#    replace files via rename. Config: root:victusfan 0664, installed ONLY if
#    it does not already exist (never clobber a user's tuning).
# ---------------------------------------------------------------------------
echo ">> Setting up /etc/victus-fan ..."
mkdir -p /etc/victus-fan
chown root:victusfan /etc/victus-fan
chmod 2775 /etc/victus-fan

if [[ ! -e /etc/victus-fan/config.json ]]; then
    install -m 0664 "$SRC_DIR/packaging/config.default.json" \
            /etc/victus-fan/config.json
    chown root:victusfan /etc/victus-fan/config.json
    echo "   installed default config.json."
else
    echo "   keeping existing /etc/victus-fan/config.json (not overwritten)."
fi

# ---------------------------------------------------------------------------
# 5. systemd unit + tmpfiles runtime dir.
# ---------------------------------------------------------------------------
echo ">> Installing systemd service and tmpfiles config..."
install -D -m 0644 "$SRC_DIR/packaging/victus-fan.service" \
        /etc/systemd/system/victus-fan.service
install -D -m 0644 "$SRC_DIR/packaging/victus-fan.tmpfiles" \
        /etc/tmpfiles.d/victus-fan.conf

echo ">> Creating runtime directory and (re)loading systemd..."
systemd-tmpfiles --create /etc/tmpfiles.d/victus-fan.conf
systemctl daemon-reload
systemctl enable --now victus-fan.service
echo "   victus-fan.service enabled and started."

# ---------------------------------------------------------------------------
# Done — final guidance.
# ---------------------------------------------------------------------------
cat <<EOF

============================================================================
 victus-fan installed.

 Service:   systemctl status victus-fan.service
 Logs:      journalctl -u victus-fan -f
 CLI:       victus-fanctl status        (try also: override max / auto / policy)

 Fan behavior follows your power mode automatically (performance = full speed,
 balanced/power-saver = quiet until the CPU/GPU get hot). There is no UI to open.

 IMPORTANT: to change settings with 'victus-fanctl' as your normal user, log out
 and back in once so your new membership in the 'victusfan' group takes effect
 (running it with sudo works immediately).
============================================================================
EOF
