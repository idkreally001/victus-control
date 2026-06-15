# Testing &amp; Verification

`victus-fan` was built and verified **end-to-end on real hardware** before
release. This document records the exact test machine and every check that was
run, so you can reproduce them.

## Test machine

| Item         | Value                                                        |
|--------------|--------------------------------------------------------------|
| Hostname     | `jayesh-Victus`                                              |
| Model        | HP Victus 15-fb0xxx (*Victus by HP Gaming Laptop*)           |
| CPU          | AMD Ryzen 5 5600H — sensor `k10temp` (Tctl)                  |
| iGPU         | AMD Radeon Vega (Cezanne) — sensor `amdgpu` (edge)           |
| dGPU         | NVIDIA GeForce RTX 3050 Mobile — read via `nvidia-smi`       |
| OS           | **Ubuntu 26.04 LTS** (Resolute Raccoon)                      |
| Kernel       | `7.0.0-22-generic`                                           |
| Secure Boot  | **Enabled**                                                  |
| Fan driver   | stock in-tree `hp-wmi` (`pwm1_enable`, two-state)            |
| GNOME Shell  | 50                                                           |

> Because Secure Boot is on and Ubuntu ships no patched `hp-wmi` module, this
> project deliberately uses **only the stock driver** — nothing is compiled,
> signed, or DKMS-built.

## Results summary

| # | Check                                   | Result |
|---|-----------------------------------------|--------|
| 1 | Performance mode → fans MAX             | ✅ pass |
| 2 | Balanced mode → firmware AUTO when cool | ✅ pass |
| 3 | Power-saver mode → firmware AUTO        | ✅ pass |
| 4 | Manual overrides beat policy            | ✅ pass |
| 5 | Stop service → fans restored to AUTO    | ✅ pass |
| 6 | NVIDIA dGPU never woken to read temp    | ✅ pass |
| 7 | Non-root config edits (group model)     | ✅ pass |

## Details

### 1–3. Power-mode tracking

The active power profile was cycled with `powerprofilesctl` and the daemon's
effect on `pwm1_enable` was read back from sysfs each time:

| Power mode (GNOME) | `platform_profile` | Fan state | `pwm1_enable` | Measured fan RPM |
|--------------------|--------------------|-----------|---------------|------------------|
| Performance        | `performance`      | **MAX**   | `0`           | ~5400 / ~5200    |
| Balanced           | `balanced`         | **AUTO**  | `2`           | follows firmware |
| Power-saver        | `quiet`            | **AUTO**  | `2`           | follows firmware |

(GNOME's *power-saver* maps `platform_profile` to `quiet`, which the daemon's
`profile_map` resolves to the `power-saver` policy.)

### 4. Manual override (CLI)

Starting in `performance` (normally forced MAX), each override was applied and
the result read back:

| Command                      | `pwm1_enable` | Notes                          |
|------------------------------|---------------|--------------------------------|
| `victus-fanctl override auto`| `2`           | AUTO wins over performance      |
| `victus-fanctl override max` | `0`           | MAX                             |
| `victus-fanctl override policy` | `0`        | back to performance → MAX       |

### 5. Safety — restore on stop

`sudo systemctl stop victus-fan` was observed to flip `pwm1_enable` from `0`
back to `2`, with the journal line:

```
victus-fand: shutting down; restoring AUTO (pwm1_enable=2)
```

So whenever the controller stops (or crashes), the fans are handed back to the
HP firmware curve rather than being left forced.

### 6. NVIDIA no-wake

`nvidia-smi` is only invoked when the NVIDIA PCI device reports
`power/runtime_status == active`. When the dGPU is runtime-suspended the status
reports `dgpu: null` / `dgpu_state: "suspended"` and the controller never wakes
it — confirmed by instrumenting the call path.

### 7. Permission model

A non-root member of the `victusfan` group was able to change settings:

```bash
sudo -u jayesh -g victusfan victus-fanctl override auto   # succeeded, no root
```

and `/etc/victus-fan/config.json` remained group-writable (`-rw-rw-r-- … victusfan`)
afterwards, so the daemon (root) and the user can both manage it.

## Live example

A representative `victus-fanctl status` snapshot from the test machine, under
load in performance mode:

```
victus-fan status
  enabled        : True
  override       : policy
  power profile  : performance
  policy         : performance
  effective      : performance
  power source   : AC  battery 100%
  temps          : cpu 95.4 C | igpu 54.0 C | dgpu 47.0 C [active]
  fan            : MAX  (fan1 5363 rpm, fan2 5220 rpm, pwm_enable=0)
  reason         : performance: forced MAX
```

## Status

Installed and **running as a systemd service (`victus-fan.service`) in daily
use** on the machine above.
