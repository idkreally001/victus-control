# victus-fan

A small **userspace** fan controller for the **HP Victus 15-fb0xxx**
(AMD Ryzen 5 5600H iGPU + NVIDIA RTX 3050 dGPU) running **Ubuntu 26.04**
(kernel 7.0) with **Secure Boot ON**.

> **No kernel module.** victus-fan uses *only* the stock, in-tree `hp-wmi`
> driver. Nothing needs to be compiled, signed, or DKMS-rebuilt, so it keeps
> working under Secure Boot and across kernel upgrades.

> **No GUI.** victus-fan is a background daemon plus a small command-line tool
> (`victus-fanctl`). Fan behaviour follows your power mode automatically; there
> is nothing to open.

## ✅ Tested &amp; verified

Built and tested **end-to-end on real hardware** — an **HP Victus 15-fb0xxx**
(hostname `jayesh-Victus`) running **Ubuntu 26.04 LTS** (kernel
`7.0.0-22-generic`, Secure Boot **ON**). Every power mode, the heat-triggered
MAX override, the manual overrides, the permission model, and the
restore-fans-to-firmware-on-stop safety path were all verified live, and it is
installed as a systemd service in daily use on that machine.

Full report: **[docs/TESTING.md](docs/TESTING.md)**.

---

## What it does

A root daemon (`victus-fand`) watches your CPU, integrated-GPU and (when awake)
discrete-GPU temperatures, your power profile and your battery state, and flips
the laptop fans between two states using the hp-wmi `pwm1_enable` knob:

* **MAX** — full speed (`pwm1_enable = 0`)
* **AUTO** — HP firmware fan curve (`pwm1_enable = 2`)

It writes a world-readable status file (`/run/victus-fan/status.json`) that the
`victus-fanctl` CLI reads to show live state.

### The hardware reality (why it is two-state)

On this machine the hp-wmi `pwm1_enable` is the **only** fan knob the firmware
exposes to Linux, and it accepts just two usable values:

| Value | Meaning                         |
|-------|---------------------------------|
| `0`   | **MAX** — fans at full speed    |
| `2`   | **AUTO** — HP firmware curve    |
| `1`   | *rejected by the driver*        |

There is **no PWM duty file** and **no fan target file** — you cannot set an
arbitrary fan percentage or a custom RPM. That means:

* **"performance"** maps to **continuous MAX** — exact and under our control.
* **Heat-triggered MAX** (the hysteresis below) is exact and under our control.
* **"quiet" / "cool" / "off"** are *delegated to the HP firmware's own AUTO
  curve* — we simply leave the fans in AUTO and let the firmware be quiet. We
  cannot make them quieter than HP's firmware already does, because there is no
  finer knob to turn.

So victus-fan's job is precise where it can be (force MAX on heat or on
performance) and otherwise gets out of the way (hand back to firmware AUTO).

### Sensors used

* **CPU** — `hwmon` named `k10temp` → `temp1_input` (Tctl). Fallbacks:
  `coretemp`, `zenpower`.
* **iGPU (Radeon)** — `hwmon` named `amdgpu` → `temp1_input` (edge).
* **dGPU (NVIDIA)** — NVIDIA exposes **no hwmon**, so temperature is read with
  `nvidia-smi`. See the no-wake note below.
* **Battery / AC** — `/sys/class/power_supply/*`.
* **Power profile** — `/sys/firmware/acpi/platform_profile` (read only; owned by
  `power-profiles-daemon`). victus-fan **never writes** the platform profile —
  it only ever writes `pwm1_enable`.

### NVIDIA no-wake note

The discrete GPU spends most of its life runtime-suspended to save battery.
victus-fan **only** calls `nvidia-smi` when the NVIDIA PCI device is already
`active` (its `power/runtime_status`), so polling the fan controller never wakes
the dGPU and never drains your battery. When the dGPU is suspended, the status
reports `dgpu: null` and `dgpu_state: "suspended"`, and it is simply excluded
from the fan decision. `nvidia-smi` calls are also guarded by a 2-second timeout
and tolerate the tool being absent.

---

## Per-power-mode behaviour

The active power profile (from `platform_profile`) is mapped to an internal
policy via `profile_map`, then that policy decides the fans:

| Power profile (`platform_profile`) | Internal policy | Fan behaviour                                   |
|------------------------------------|-----------------|-------------------------------------------------|
| `performance`                      | `performance`   | **Always MAX** (full speed)                     |
| `balanced`                         | `balanced`      | **AUTO**, forced to **MAX** on heat (hysteresis)|
| `quiet`                            | `power-saver`   | **AUTO**, forced to MAX only at high temps      |
| `cool`                             | `power-saver`   | **AUTO**, forced to MAX only at high temps      |

> Note: GNOME's **power-saver** mode sets `platform_profile` to `quiet`, which
> maps to the `power-saver` policy above.

Two extra rules sit on top:

* **Low battery** — when on battery **and** capacity ≤ `low_battery_pct`
  (default 20%), the policy is pushed to `power-saver` regardless of the power
  profile, so a hot moment on a near-empty battery still spins the fans, but the
  quiet thresholds apply.
* **Manual override** — you can force `max` or `auto` with `victus-fanctl`. The
  daemon **resets the override to `policy` on startup**, so a forced state never
  silently persists across a reboot.

### Hysteresis (heat-triggered MAX)

For every *present* sensor (CPU always; iGPU if available; dGPU only when
awake), the active policy defines an **on** and **off** threshold:

* If **any** present sensor is **≥ its `_on`** threshold → **MAX**.
* Else, if currently MAX **and every** present sensor is **≤ its `_off`**
  threshold → drop back to **AUTO**.
* Otherwise keep the current state (this gap between on/off prevents flapping).

Default thresholds (°C):

| Policy        | CPU on/off | iGPU on/off | dGPU on/off |
|---------------|-----------:|------------:|------------:|
| `balanced`    | 85 / 75    | 70 / 60     | 72 / 62     |
| `power-saver` | 90 / 80    | 78 / 68     | 80 / 70     |
| `performance` | always MAX | always MAX  | always MAX  |

---

## Project layout

```
victus-fan/                  # this folder, inside the victus-control repo
├── daemon/
│   ├── victus-fand          # root systemd daemon — the policy engine
│   └── victus-fanctl        # command-line control + status tool
├── packaging/
│   ├── victus-fan.service   # systemd unit (runs the daemon as root)
│   ├── victus-fan.tmpfiles  # creates /run/victus-fan
│   └── config.default.json  # default thresholds / settings
├── docs/
│   └── TESTING.md           # hardware verification report
├── install.sh               # Ubuntu installer (re-execs itself with sudo)
├── uninstall.sh             # restores firmware fan control + removes files
└── README.md
```

> **License:** `victus-fan` is part of [victus-control](../) and is distributed
> under the **GNU GPL v3.0 or later**, the same license as the parent repository.

## Install

From the `victus-fan/` directory (inside a clone of the victus-control repo):

```bash
sudo ./install.sh
```

The installer (re-execs itself with `sudo` if needed) will:

1. Ensure `python3` is present (the daemon and CLI are pure Python stdlib —
   there are no other dependencies).
2. Create the system group **`victusfan`** and add **you** (the `SUDO_USER`)
   to it.
3. Install the daemon and CLI to their system paths (see below).
4. Create `/etc/victus-fan/` (`root:victusfan`, mode `2775`) and install the
   default `config.json` **only if one does not already exist**.
5. Install + enable the systemd service and the tmpfiles runtime dir, then
   start the daemon.

> **Log out and back in** (or reboot) afterwards so that your **`victusfan`
> group** membership takes effect. That is only needed to edit the config with
> `victus-fanctl` as your normal user — running it with `sudo` works immediately,
> and the daemon itself works the moment it is installed.

### Install targets

| Component     | Path                                                     | Mode / owner            |
|---------------|----------------------------------------------------------|-------------------------|
| daemon        | `/usr/lib/victus-fan/victus-fand`                        | `0755` root             |
| CLI           | `/usr/bin/victus-fanctl`                                 | `0755`                  |
| service       | `/etc/systemd/system/victus-fan.service`                | runs as **root**        |
| tmpfiles      | `/etc/tmpfiles.d/victus-fan.conf`                        | `0644`                  |
| config dir    | `/etc/victus-fan/`                                       | `root:victusfan` `2775` |
| config file   | `/etc/victus-fan/config.json`                            | `root:victusfan` `0664` |
| runtime dir   | `/run/victus-fan/`                                       | `0755 root root`        |
| status file   | `/run/victus-fan/status.json`                           | `0644` (world-readable) |

### Privilege model

* The **daemon runs as root** because it must write sysfs (`pwm1_enable`) and
  `/run/victus-fan`.
* **`victus-fanctl` runs as you.** It only **reads** `/run/victus-fan/status.json`
  (world-readable) and **writes** `/etc/victus-fan/config.json`. That config
  directory is group `victusfan` with the **setgid** bit so any member can
  atomically replace the file (write a temp file in the same dir, then `rename`).
  This is why you must be in the `victusfan` group (and have re-logged in) to
  change settings without `sudo`; otherwise a config write fails with a clear
  "you must be in the 'victusfan' group and re-login" message.

---

## Uninstall

```bash
sudo ./uninstall.sh
```

This stops and disables the service, writes `2` (AUTO) to the hp-wmi
`pwm1_enable` to hand the fans back to firmware, and removes the installed
program files. It **leaves** `/etc/victus-fan/` and the `victusfan` group in
place; to remove those too:

```bash
sudo rm -rf /etc/victus-fan
sudo groupdel victusfan
```

---

## Configuration

Edit `/etc/victus-fan/config.json` (you must be in the `victusfan` group, or use
`sudo`). The daemon merges your file over its built-in defaults and **re-reads it
every poll loop**, so changes take effect within `poll_interval_sec` — no restart
needed.

```json
{
  "enabled": true,
  "poll_interval_sec": 2,
  "low_battery_pct": 20,
  "override": "policy",
  "profile_map": {
    "performance": "performance",
    "balanced": "balanced",
    "quiet": "power-saver",
    "cool": "power-saver",
    "low-power": "power-saver"
  },
  "profiles": {
    "performance": { "always_max": true },
    "balanced":    { "cpu_on": 85, "cpu_off": 75, "igpu_on": 70, "igpu_off": 60, "dgpu_on": 72, "dgpu_off": 62 },
    "power-saver": { "cpu_on": 90, "cpu_off": 80, "igpu_on": 78, "igpu_off": 68, "dgpu_on": 80, "dgpu_off": 70 }
  }
}
```

| Key                 | Meaning                                                                 |
|---------------------|-------------------------------------------------------------------------|
| `enabled`           | Master switch. `false` → leave fans in AUTO and do nothing.              |
| `poll_interval_sec` | Seconds between evaluations.                                            |
| `low_battery_pct`   | At/below this % on battery, force the `power-saver` policy.              |
| `override`          | `policy` (normal), `max` (force full speed), `auto` (force firmware).    |
| `profile_map`       | Maps `platform_profile` values to a policy name.                        |
| `profiles.*`        | `performance` is `always_max`; the others give per-sensor on/off °C.     |

> `override` is reset to `policy` every time the daemon starts, so a forced
> state cannot survive a reboot.

---

## `victus-fanctl` usage

```bash
victus-fanctl status                  # pretty-print the current status.json
victus-fanctl get                     # print the effective (merged) config
victus-fanctl override max            # force fans to MAX
victus-fanctl override auto           # force firmware AUTO
victus-fanctl override policy         # return to automatic policy
victus-fanctl set balanced cpu_on 80  # tune a single threshold
victus-fanctl enable                  # master switch on
victus-fanctl disable                 # master switch off (leaves fans in AUTO)
```

`override` / `set` / `enable` / `disable` work by atomically rewriting
`/etc/victus-fan/config.json`, so they require `victusfan` group membership (or
`sudo`). If you see a permission error, you are not yet in the group (or have not
re-logged in since installing).

---

## Troubleshooting

* **"PermissionError" / cannot save config from `victus-fanctl`** — you are not
  in the `victusfan` group yet, or you have not logged out and back in since
  installing. Check with `id` (look for `victusfan`), or just prefix the command
  with `sudo`.

* **Service / daemon logs**:

  ```bash
  systemctl status victus-fan.service
  journalctl -u victus-fan -f
  ```

* **Fans seem stuck** — check the live decision:

  ```bash
  victus-fanctl status        # shows fan.state, override, decision_reason
  ```

  Remember `performance` is *always* MAX by design. To hand control fully back
  to firmware, run `victus-fanctl override auto` (temporary) or set
  `enabled: false`.

* **dGPU temp shows `null`** — that is expected when the NVIDIA GPU is
  runtime-suspended; victus-fan deliberately does not wake it. The temperature
  appears once something is using the dGPU.

* **Reset to firmware quickly** — `victus-fanctl override auto`, or stop the
  service: `sudo systemctl stop victus-fan` (the daemon writes AUTO on exit).
