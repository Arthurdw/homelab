# Runbook: GPU fan control

The Tesla P4 is passive: its heatsink only stays cool with air pushed through it, here by a case fan on its own
motherboard header. The card is passed through to `talos-wk-1`, so `poseidon` cannot read its temperature
itself. A small service on the host reads it from the in-cluster exporter and sets that header's PWM duty from a
curve (`docs/decisions.md` §3.8). The other header stays on the BIOS curve for the CPU.

## What lives where

- **In the cluster (Flux):** the `nvidia-gpu-exporter` DaemonSet in `nvidia-device-plugin`, on the GPU node,
  hostNetwork port 9835 (`kubernetes/infrastructure/nvidia-device-plugin/gpu-exporter.yaml`). Prometheus
  scrapes it; the `homelab.gpu` alerts fire at 75 °C, at 88 °C and when the exporter is down. The same group
  has the fan alerts (`GpuFanStalled`, `GpuFanCurveFloorTooLow`, `GpuFanControlNotOk`, `GpuFanControlStale`,
  `ProxmoxHostMetricsDown`), fed by the host's node-exporter below. The `proxmox-host` ScrapeConfig
  (`kubernetes/infrastructure/configs/proxmox-host-scrapeconfig.yaml`, target `PROXMOX_HOST_METRICS` in
  cluster-settings) scrapes it; the Grafana dashboard **GPU & cooling** shows temperature, duty, rpm and load.
- **On `poseidon` (OpenTofu, `infrastructure/environments/homelab/proxmox/fan-control.tf`):**
  - `/usr/local/sbin/gpu-fan-control` (`scripts/fan-control/gpu-fan-control.sh`)
  - `gpu-fan-control.service` (`scripts/fan-control/gpu-fan-control.service`)
  - `/etc/default/gpu-fan-control`, generated from `gpu_fan_control` in `terraform.tfvars`
  - `/etc/modules-load.d/` and `/etc/modprobe.d/gpu-fan-control.conf`, only when a kernel module is set
- **On `poseidon` (OpenTofu, `host-metrics.tf`, when `host_metrics` is set):** Debian's
  `prometheus-node-exporter` on `10.10.1.1:9100`, with a systemd drop-in
  (`/etc/systemd/system/prometheus-node-exporter.service.d/homelab.conf`). The controller writes its metrics to
  `/var/lib/prometheus/node-exporter/gpu-fan-control.prom` for the textfile collector.
- **Fail-safe:** the header starts at 100 % and stays there until a reading arrives. No reading for 30 s, a crash
  or a stop: 100 %. Speeding up is immediate; slowing down is at most 5 % per 5 s. The fan below `stall_rpm`
  (300) at less than 100 %: 100 % at once, and from then on the floor is that duty + 10 % until the service
  restarts.
- **The curve** (`45:20 55:35 62:60 67:85 70:100`): a quiet 20 % floor, 100 % from 70 °C because the duct to the
  card is printed PETG (`docs/decisions.md` §3.8). The fan never stops.

## Pre-checks

- [ ] The exporter is up and serves the temperature:
      `kubectl -n nvidia-device-plugin get pods -l app.kubernetes.io/name=nvidia-gpu-exporter` shows it Ready,
      and the Prometheus target `nvidia-gpu-exporter` is up.
- [ ] `poseidon` reaches it across VLANs: `ssh root@10.10.1.1 'curl -fsS http://10.20.0.12:9835/metrics | grep
      ^nvidia_smi_temperature_gpu'` prints one line. A timeout means the gateway blocks management → servers on
      9835; allow it (UniFi) before going on, or the fan will run at 100 % forever.
- [ ] Prometheus reaches `poseidon`'s node-exporter: the gateway allows the servers VLAN (20) → `10.10.1.1:9100`
      (UniFi). Check once it is installed (§2), from any pod:
      `kubectl run -it --rm curl --image=curlimages/curl --restart=Never -- -fsS http://10.10.1.1:9100/metrics | grep -m3 ^gpu_fan_control_`.
      Without it the fan control still works; only the dashboard and the fan alerts go blind
      (`ProxmoxHostMetricsDown`).
- [ ] The P4's fan is on its own header, not on a splitter with the CPU fan.
- [ ] In the BIOS, that header is in PWM (4-pin) mode, or DC mode for a 3-pin fan. Leave the curve as it is: it
      is what the header goes back to on uninstall.

## 1. Find the chip and the header

The fan is driven through the Super I/O chip's hwmon driver. The `hwmonN` numbers change between boots, so the
controller finds the chip by its name.

On `poseidon` (ASUS PRIME B250M-PLUS) this was done on 2026-10-31: chip `nct6793` (module `nct6775`, not loaded
on boot by itself), GPU fan on `pwm3`, CPU on `pwm2`, the case-fan hub on `pwm1` (`docs/hardware.md`). Redo it
only after moving fan cables.

```sh
ssh root@10.10.1.1
dmidecode -s baseboard-manufacturer; dmidecode -s baseboard-product-name
grep . /sys/class/hwmon/hwmon*/name
```

- **A name like `nct6798`, `nct6775`, `it8628` or `it87`:** the driver is loaded; note the name.
- **Only `coretemp`, `acpitz`, `nvme`:** no driver yet. Run `apt install lm-sensors && sensors-detect --auto`; it
  names the module (`nct6775`, `it87`). `modprobe <module>` and look again.
- **`dmesg | grep -i 'resource conflict'` shows the chip's ports claimed by ACPI:** for `it87`, the module option
  `ignore_resource_conflict=1` (and, for chips it does not know yet, `force_id=0x8628`). For `nct6775`, add
  `acpi_enforce_resources=lax` to the kernel command line (`/etc/kernel/cmdline` or GRUB), then reboot. This
  cannot be set by OpenTofu.

Find the header's channel by spinning it down for a moment and watching the fan (the GPU is safe for a minute at
idle):

```sh
hw=$(grep -l '^nct6793$' /sys/class/hwmon/hwmon*/name | xargs dirname)   # your chip name
ls $hw/pwm?                        # the channels
for n in 1 2 3; do grep . $hw/fan${n}_input; done   # which headers have a fan spinning
m=$(cat $hw/pwm2_enable)           # try one channel at a time
echo 1 > $hw/pwm2_enable; echo 60 > $hw/pwm2; sleep 10; cat $hw/fan2_input
echo $m > $hw/pwm2_enable          # put it back
```

The channel whose fan audibly slows (and whose `fanN_input` drops) is the GPU header. Reading `pwmN_enable` back as
`0` after writing `1` and `255` is the `nct6775` driver's way of saying "manual, full speed", not a failure.

Leave the header on the BIOS curve (`echo 5 > $hw/pwmN_enable`, or reboot) before installing: the controller
saves the mode it finds and restores that one on uninstall.

## 2. Install

Set the block in `infrastructure/environments/homelab/proxmox/terraform.tfvars` (the example file has every field
with its default):

```hcl
gpu_fan_control = {
  hwmon_name    = "nct6793"   # from step 1
  pwm_channel   = 3           # from step 1
  kernel_module = "nct6775"   # only if it is not loaded on boot already (poseidon: needed)
  # kernel_module_options = "..."         # it87: "ignore_resource_conflict=1"
}

host_metrics = {}   # node-exporter on 10.10.1.1:9100, for the dashboard and the fan alerts
```

Then, from the repo root:

```sh
just plan-proxmox    # terraform_data.gpu_fan_control[0] and .host_metrics[0] to create, nothing else
just apply-proxmox
```

The apply copies the files over SSH, runs `gpu-fan-control check` (it fails here if the chip or the pwm files are
not found), starts the service and fails if it does not stay up. Its output ends with the service's first log
lines.

Changing any setting (curve, channel) later is the same `just apply-proxmox`: the old install is removed and the
new one installed.

## 3. Verify

```sh
ssh root@10.10.1.1 'systemctl status gpu-fan-control --no-pager; gpu-fan-control check'
ssh root@10.10.1.1 'journalctl -u gpu-fan-control -f'
```

- `check` prints the pwm file, `exporter: http://10.20.0.12:9835/metrics -> 41°C -> 20%` and the fan's rpm.
- The journal logs `started`, then `ok: gpu 41°C, fan 20%` and a line on every 10 % change. A `stale:` line
  means the readings stopped and the fan is at 100 %.
- `curl -fsS http://10.10.1.1:9100/metrics | grep ^gpu_fan_control_` shows the duty, temperature, rpm and
  `state="ok"`; in Grafana, the **GPU & cooling** dashboard fills in within a minute.
- Under load (an Immich ML job), the temperature on the dashboard should level off well below 70 °C. After a
  long load, feel the PETG duct: warm is fine, soft or out of shape is not.
- Stop test: `systemctl stop gpu-fan-control` sends the fan to full speed at once; `systemctl start` brings it back.

## Rollback

Set `gpu_fan_control = null` in `terraform.tfvars` (or remove the block), then `just apply-proxmox`. That stops
the service, hands the header back to the BIOS mode it had before, and deletes the files.

**Never delete `fan-control.tf` first:** OpenTofu runs the uninstall only while the resource is still in the
config. Without it the state entry is dropped and the service stays on the host. If that happened, by hand:

```sh
systemctl disable --now gpu-fan-control; gpu-fan-control release
rm -f /usr/local/sbin/gpu-fan-control /etc/systemd/system/gpu-fan-control.service /etc/default/gpu-fan-control \
  /etc/modules-load.d/gpu-fan-control.conf /etc/modprobe.d/gpu-fan-control.conf
systemctl daemon-reload
```

## Troubleshooting

- **Fan always at 100 %:** `gpu-fan-control check` says no reading. Check the exporter pod and the curl from the
  pre-checks; `talos-wk-1` being off or drained has the same effect, by design.
- **`no hwmon chip named ...`:** the module is not loaded (set `kernel_module`) or the name differs; compare with
  `grep . /sys/class/hwmon/hwmon*/name`.
- **New `kernel_module_options` have no effect:** `modprobe` does not reload a module that is already loaded.
  Reboot `poseidon`, or `rmmod <module>` and apply again.
- **The duty keeps jumping back:** the BIOS or another tool (`fancontrol`, a vendor daemon) takes the header.
  The controller re-asserts manual mode every interval; stop the other tool.
- **`stalled:` in the journal, `GpuFanCurveFloorTooLow`:** the fan stopped at a low duty, so the curve's floor is
  under what this fan needs to start. Measure the lowest duty that keeps it spinning (it stops the controller
  for a minute, the fan steps through 0–40 %):

  ```sh
  ssh root@10.10.1.1 'systemctl stop gpu-fan-control; hw=$(grep -l "^nct6793$" /sys/class/hwmon/hwmon*/name | xargs dirname); echo 1 > $hw/pwm3_enable; for p in 0 10 15 20 25 30 35 40; do echo $((p*255/100)) > $hw/pwm3; sleep 8; echo "$p% $(cat $hw/fan3_input) rpm"; done; systemctl start gpu-fan-control'
  ```

  Then set a `curve` in `gpu_fan_control` whose lowest duty is at least 5 % above that, and apply.
- **`GpuFanStalled`:** under 300 rpm with a duty above 0, for a minute: the fan is dead or unplugged, or its
  cable is caught. The card has no other cooling; look now, and drain `talos-wk-1` if it cannot be fixed soon.
- **`ProxmoxHostMetricsDown`:** Prometheus cannot scrape `10.10.1.1:9100`. Check
  `systemctl status prometheus-node-exporter` on `poseidon` and the gateway rule from the pre-checks. In the lab
  it fires whenever the PVE fixture is not running.
- **Test the controller without the host:** `just fan-control-selftest` runs it against a fake sysfs.
