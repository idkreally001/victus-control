#!/usr/bin/env python3
"""Victus Control temperature monitor.

Runs as a per-user systemd service inside the desktop session and watches the
backend's temperature / fan / mode state over the control socket. Fires desktop
notifications when the machine is hot but cooling is not engaged, or when a
temperature is critically high.

It intentionally lives in the user session (not the privileged backend):
- notify-send needs the session D-Bus, which the user already has.
- The backend only samples temperatures while Better Auto is running, so it
  cannot observe the "hot while in MANUAL mode" case this monitor is meant to
  catch. Polling here covers every fan mode.

No root, no sudo, no desktop-specific assumptions beyond a running notification
daemon (KDE, GNOME, etc. all provide one).
"""

import os
import shutil
import socket
import struct
import subprocess
import sys
import time

SOCKET_PATH = "/run/victus-control/victus_backend.sock"
POLL_INTERVAL_S = 3.0

# Per-component thresholds (°C). GPU numbers are lower than CPU because a mobile
# dGPU thermal-throttles far earlier (~87°C on an RTX 4060), so a 100°C GPU
# "critical" would never fire.
CPU_HOT_C = 83.0        # cooling-not-engaged warning trigger
GPU_HOT_C = 83.0
CPU_CRITICAL_C = 95.0
GPU_CRITICAL_C = 85.0

# A fan is considered "not spinning up" below this RPM.
FAN_IDLE_RPM = 2200

# Hysteresis: after a category fires, it re-arms only once the driving
# temperature falls this far below the threshold, so readings that hover near a
# limit don't produce a stream of notifications.
REARM_MARGIN_C = 5.0

# Hard rate limit per category regardless of hysteresis (seconds).
RATE_LIMIT_S = 60.0

APP_NAME = "Victus Control"


def _recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("socket closed")
        buf += chunk
    return buf


def query(command):
    """Send one command over the control socket and return the trimmed reply.

    Returns None on any I/O error (backend down, socket missing, etc.) so the
    caller can simply skip a tick rather than crash the service.
    """
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(4.0)
            s.connect(SOCKET_PATH)
            payload = command.encode()
            s.sendall(struct.pack("<I", len(payload)) + payload)
            (resp_len,) = struct.unpack("<I", _recv_exact(s, 4))
            if resp_len == 0 or resp_len > 4096:
                return None
            return _recv_exact(s, resp_len).decode(errors="replace").strip()
    except (OSError, ConnectionError, struct.error):
        return None


def parse_temp(reply):
    """Backend returns an integer, 'IDLE' (suspended GPU), or 'ERROR: ...'."""
    if reply is None or reply == "IDLE" or reply.startswith("ERROR"):
        return None
    try:
        return float(reply)
    except ValueError:
        return None


def parse_rpm(reply):
    if reply is None or reply.startswith("ERROR"):
        return None
    try:
        return int(reply)
    except ValueError:
        return None


def notify(summary, body, critical):
    urgency = "critical" if critical else "normal"
    subprocess.Popen(
        ["notify-send", "-a", APP_NAME, "-u", urgency,
         "-i", "sensors-temperature-symbolic", summary, body],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )


class Category:
    """Tracks per-alert hysteresis + rate limiting."""

    def __init__(self, threshold_c):
        self.threshold_c = threshold_c
        self.armed = True
        self.last_fired = 0.0

    def should_fire(self, driving_temp_c, now):
        if driving_temp_c is None:
            return False
        # Re-arm once we've cooled well below the threshold.
        if not self.armed and driving_temp_c <= self.threshold_c - REARM_MARGIN_C:
            self.armed = True
        if not self.armed:
            return False
        if driving_temp_c < self.threshold_c:
            return False
        if now - self.last_fired < RATE_LIMIT_S:
            return False
        self.armed = False
        self.last_fired = now
        return True


def main():
    if shutil.which("notify-send") is None:
        print("victus-monitor: notify-send not found (install libnotify); exiting",
              file=sys.stderr)
        return 1

    cooling = Category(min(CPU_HOT_C, GPU_HOT_C))
    cpu_crit = Category(CPU_CRITICAL_C)
    gpu_crit = Category(GPU_CRITICAL_C)

    print("victus-monitor: watching temperatures", file=sys.stderr)

    while True:
        now = time.monotonic()

        cpu = parse_temp(query("GET_CPU_TEMP"))
        gpu = parse_temp(query("GET_GPU_TEMP"))
        mode = query("GET_FAN_MODE")
        fan1 = parse_rpm(query("GET_FAN_SPEED 1"))
        fan2 = parse_rpm(query("GET_FAN_SPEED 2"))

        # Critical temperature alerts (per component, mode-independent).
        if cpu_crit.should_fire(cpu, now):
            notify("CPU temperature critical",
                   f"CPU is at {cpu:.0f} °C — this is very hot. Close heavy "
                   f"workloads or check cooling.", critical=True)

        if gpu_crit.should_fire(gpu, now):
            notify("GPU temperature critical",
                   f"GPU is at {gpu:.0f} °C — this is very hot. Close heavy "
                   f"workloads or check cooling.", critical=True)

        # Cooling-not-engaged warning: hot, but the fans aren't ramping — either
        # they're idling or the user is in MANUAL mode with low fan speeds.
        hottest = max([t for t in (cpu, gpu) if t is not None], default=None)
        fans_idle = (
            (fan1 is not None and fan1 < FAN_IDLE_RPM) and
            (fan2 is not None and fan2 < FAN_IDLE_RPM)
        )
        cooling_not_engaged = fans_idle or (mode == "MANUAL")

        if hottest is not None and cooling_not_engaged and cooling.should_fire(hottest, now):
            reason = "fan mode is MANUAL" if mode == "MANUAL" else "the fans are barely spinning"
            notify("Cooling may not keep up",
                   f"{'CPU' if hottest == cpu else 'GPU'} is at {hottest:.0f} °C "
                   f"but {reason}. Consider Better Auto or a higher fan speed.",
                   critical=False)

        time.sleep(POLL_INTERVAL_S)

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
