# Runbook: BIOS fan curves

The BIOS on `poseidon` sets the CPU_FAN header (`pwm2`) to "Full Speed": 100 % at every point of its curve, so
the CPU fan runs at full rpm at any temperature. Changing that in the BIOS needs a screen and keyboard on the
host. Instead, a small service on the host rewrites the points of that curve at every boot
(`infrastructure/environments/homelab/proxmox/fan-curves.tf`). It sets the case fans' header (`pwm1`, CHA_FAN1,
the ARCTIC hub) the same way, so both curves are in the repo and survive a BIOS reset.

The fan speed still follows the CPU temperature. Each header stays in the chip's own automatic mode
(`pwmN_enable` = 5, Smart Fan IV on the NCT6793D), which reads the CPU's PECI temperature and ramps the duty
between the points itself. The service only changes the points. Nothing runs after boot, so the curve keeps
working if the OS hangs.

The BIOS writes its own curve again at every power-on. The service runs at boot, after the driver loads, and
writes the new points back.

## What lives where

- `/usr/local/sbin/fan-curves` (`scripts/fan-control/fan-curves.sh`): `apply`, `release` and `show`.
- `/etc/systemd/system/fan-curves.service`: a oneshot at boot that runs `fan-curves apply`.
- `/etc/default/fan-curves`: the chip name, the headers and one `CURVE_<n>` per header, generated from
  `var.fan_curves`.
- `/etc/modules-load.d/fan-curves.conf`: loads the driver at boot (`kernel_module`).
- `/run/fan-curves/`: the curve the BIOS wrote, saved by the first `apply` after boot. `release` restores it.

Each header has one owner. `gpu_fan_control` owns `pwm3`, and the plan fails if `fan_curves` lists the same
header.

## How the curve works

Each header has 5 points on this chip: 4 that the service sets and a 5th that is the chip's critical temperature
(100 % above it), which is never changed. Between points the chip ramps linearly. Below the first point, the
duty is the first point's duty (the service sets the floor to it). A curve with fewer than 4 points has its last
point repeated.

Both headers follow the CPU's PECI temperature (`pwmN_temp_sel` = 8, set by the BIOS; the i5-7400 idles around
30–40 °C). The chip cannot read the Tesla P4, which is passed through, so the case fans do not speed up for GPU
load. Their floor of 30 % is there to move the card's heat out of the case while the CPU is idle.

| Header | Curve | Before |
|---|---|---|
| `pwm2` CPU_FAN | 30 % up to 20 °C, 40 % at 50 °C, 75 % at 65 °C, 100 % from 75 °C | BIOS "Full Speed", 100 % |
| `pwm1` case fans | 30 % up to 40 °C, 45 % at 55 °C, 70 % at 65 °C, 100 % from 72 °C | BIOS: 20 % at 20 °C, 70 % at 65 °C, 100 % from 70 °C |

The case fans through the hub, measured 2026-11-06: 375 rpm at 20 %, 564 at 30 %, 745 at 40 %, 1077 at 60 %,
1624 at 100 %. They keep turning at 20 %.

If the GPU runs hot under load while the CPU is idle (the **GPU & cooling** dashboard, the `homelab.gpu`
alerts), raise the first `pwm1` point.

## Install

Add this to `infrastructure/environments/homelab/proxmox/terraform.tfvars`:

```hcl
fan_curves = {
  hwmon_name    = "nct6793"
  kernel_module = "nct6775" # poseidon: the driver does not load on its own
  headers = {
    "1" = [ # CHA_FAN1: the case fans through the hub
      { temp = 40, percent = 30 },
      { temp = 55, percent = 45 },
      { temp = 65, percent = 70 },
      { temp = 72, percent = 100 },
    ]
    "2" = [ # CPU_FAN
      { temp = 20, percent = 30 },
      { temp = 50, percent = 40 },
      { temp = 65, percent = 75 },
      { temp = 75, percent = 100 },
    ]
  }
}
```

Then, from the repo root:

```sh
just plan-proxmox    # terraform_data.fan_curves[0] to create, nothing else
just apply-proxmox
```

The apply fails if the chip or a header's curve is not found, or if a write does not read back. Its output ends
with the service's log, one line per header.

A changed curve uses the same `just apply-proxmox`. The old install is removed first, which puts the curve found
at boot back, and then the new one is written.

## Verify

```sh
ssh root@10.10.1.1 'fan-curves show; systemctl status fan-curves --no-pager'
```

`show` prints the points, the mode and the current duty and rpm:

```
pwm1: 40°C:30% 55°C:45% 65°C:70% 72°C:100% (critical 100°C) mode 5, now 30% 560 rpm
pwm2: 20°C:30% 50°C:40% 65°C:75% 75°C:100% (critical 100°C) mode 5, now 37% 1150 rpm
```

Mode 5 means the chip drives the header from the curve. At idle, both should be well below full speed.
After a reboot, the same `show` should print the same points, which proves the boot service works.

## Rollback

Set `fan_curves = null` in `terraform.tfvars` (or remove the block), then `just apply-proxmox`. That restores
the curve saved at boot and deletes the files. If nothing was saved since the last boot, the header keeps the
current curve until the next boot, when the BIOS writes its own again.

**Never delete `fan-curves.tf` first:** OpenTofu only runs the uninstall while the resource is still in the
config. If that happened, uninstall by hand:

```sh
fan-curves release; systemctl disable fan-curves
rm -f /usr/local/sbin/fan-curves /etc/systemd/system/fan-curves.service /etc/default/fan-curves \
  /etc/modules-load.d/fan-curves.conf
systemctl daemon-reload
```

## Troubleshooting

- **`no hwmon chip named ...`:** the driver is not loaded (set `kernel_module`) or the name is different. Compare
  with `grep . /sys/class/hwmon/hwmon*/name`.
- **`has no automatic curve`:** the header has no `auto_point` files on this chip. It cannot be set here.
- **`above the chip's critical point`:** a point's temperature is above the 5th point. Lower it.
- **The fan is loud again after a reboot:** check `systemctl status fan-curves` and `journalctl -b -u fan-curves`.
  The service waits up to 30 s for the driver.
- **`mode` is not 5:** something else took the header (`fancontrol`, a manual `echo 1 > pwm2_enable`). Run
  `systemctl restart fan-curves` to put it back.
