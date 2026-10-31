# The GPU fan controller on the Proxmox host (docs/runbooks/gpu-fan-control.md): one motherboard fan header
# driven from the Tesla P4's temperature. The card is passed through to a Talos VM (gpu.tf), so the host
# cannot read the temperature itself; the controller asks the in-cluster exporter on that VM
# (kubernetes/infrastructure/nvidia-device-plugin/gpu-exporter.yaml) and writes the header's PWM duty.
#
# bpg/proxmox has no resource for files or services on the host, so this installs them over SSH with
# provisioners, through the same ssh-agent the provider uses (providers.tf):
#   /usr/local/sbin/gpu-fan-control            scripts/fan-control/gpu-fan-control.sh
#   /etc/systemd/system/gpu-fan-control.service scripts/fan-control/gpu-fan-control.service
#   /etc/default/gpu-fan-control               generated below from var.gpu_fan_control
#   /etc/modules-load.d/gpu-fan-control.conf   only with kernel_module; plus /etc/modprobe.d/ for its options
# Any change to those contents replaces the resource: the old install is removed (header handed back to
# the BIOS), then the new one is installed and started. The install fails, and the apply with it, if the
# chip or header is not found or the service does not stay up.
#
# Null (the default, and the L1 fixture) installs nothing. Destroying the resource, or setting it back to
# null, stops the service and returns the header to the mode the BIOS had it in.

locals {
  # The first host in the API endpoint, e.g. 10.10.1.1 from https://10.10.1.1:8006/.
  proxmox_endpoint_host = one(regex("^https?://([^:/]+)", var.proxmox_endpoint))

  gpu_fan_control_exporter_url = var.gpu_fan_control == null ? null : try(coalesce(
    var.gpu_fan_control.exporter_url,
    "http://${split("/", local.talos_nodes[var.gpu_passthrough.vm].ipv4)[0]}:9835/metrics",
  ), null)

  gpu_fan_control_staging = "/root/.cache/gpu-fan-control-staging"

  gpu_fan_control_files = var.gpu_fan_control == null ? null : {
    script  = file("${path.module}/../../../../scripts/fan-control/gpu-fan-control.sh")
    service = file("${path.module}/../../../../scripts/fan-control/gpu-fan-control.service")
    env     = <<-EOT
      # Managed by OpenTofu (infrastructure/environments/homelab/proxmox/fan-control.tf). Edits here are
      # overwritten on the next apply; change var.gpu_fan_control instead.
      HWMON_NAME="${var.gpu_fan_control.hwmon_name}"
      PWM_CHANNEL="${var.gpu_fan_control.pwm_channel}"
      EXPORTER_URL="${coalesce(local.gpu_fan_control_exporter_url, "-")}"
      CURVE="${join(" ", [for p in var.gpu_fan_control.curve : "${p.temp}:${p.percent}"])}"
      INTERVAL="${var.gpu_fan_control.interval_seconds}"
      STALE_AFTER="${var.gpu_fan_control.stale_after_seconds}"
      STEP_DOWN="${var.gpu_fan_control.step_down_percent}"
      STALL_RPM="${var.gpu_fan_control.stall_rpm}"
      STOP_AT="${var.gpu_fan_control.stop_at}"
      START_AT="${var.gpu_fan_control.start_at}"
      TEXTFILE="${var.host_metrics == null ? "" : "${local.host_metrics_textfile_dir}/gpu-fan-control.prom"}"
    EOT
    module  = coalesce(var.gpu_fan_control.kernel_module, "-")
    options = coalesce(var.gpu_fan_control.kernel_module_options, "-")
  }
}

resource "terraform_data" "gpu_fan_control" {
  count = var.gpu_fan_control == null ? 0 : 1

  triggers_replace = { for k, v in local.gpu_fan_control_files : k => sha256(v) }

  # The destroy provisioner can only read `self`, so the connection details are kept here.
  input = {
    host = coalesce(var.gpu_fan_control.ssh_host, local.proxmox_endpoint_host)
    user = var.proxmox_ssh_username
  }

  connection {
    type  = "ssh"
    host  = self.input.host
    user  = self.input.user
    agent = true
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p -m 0700 ${local.gpu_fan_control_staging}"]
  }

  provisioner "file" {
    content     = local.gpu_fan_control_files.script
    destination = "${local.gpu_fan_control_staging}/gpu-fan-control.sh"
  }

  provisioner "file" {
    content     = local.gpu_fan_control_files.service
    destination = "${local.gpu_fan_control_staging}/gpu-fan-control.service"
  }

  provisioner "file" {
    content     = local.gpu_fan_control_files.env
    destination = "${local.gpu_fan_control_staging}/gpu-fan-control.env"
  }

  provisioner "remote-exec" {
    inline = concat(
      [
        "set -eu",
        "command -v curl >/dev/null || { echo 'gpu-fan-control needs curl on the host' >&2; exit 1; }",
        "cd ${local.gpu_fan_control_staging}",
        "install -m 0755 gpu-fan-control.sh /usr/local/sbin/gpu-fan-control",
        "install -m 0644 gpu-fan-control.service /etc/systemd/system/gpu-fan-control.service",
        "install -m 0644 gpu-fan-control.env /etc/default/gpu-fan-control",
      ],
      var.gpu_fan_control.kernel_module == null ? [] : [
        "echo '${var.gpu_fan_control.kernel_module}' > /etc/modules-load.d/gpu-fan-control.conf",
      ],
      var.gpu_fan_control.kernel_module_options == null ? [] : [
        "echo 'options ${var.gpu_fan_control.kernel_module} ${var.gpu_fan_control.kernel_module_options}' > /etc/modprobe.d/gpu-fan-control.conf",
      ],
      var.gpu_fan_control.kernel_module == null ? [] : [
        "modprobe ${var.gpu_fan_control.kernel_module}",
      ],
      [
        # Fails here, before anything is enabled, if the chip or the pwm files are missing.
        "/usr/local/sbin/gpu-fan-control check",
        "systemctl daemon-reload",
        "systemctl enable gpu-fan-control.service",
        "systemctl restart gpu-fan-control.service",
        "sleep 5",
        "systemctl is-active --quiet gpu-fan-control.service || { journalctl -u gpu-fan-control.service -n 30 --no-pager; exit 1; }",
        "journalctl -u gpu-fan-control.service -n 5 --no-pager",
        "rm -rf ${local.gpu_fan_control_staging}",
      ],
    )
  }

  # Stop the service (its ExecStopPost leaves the header at 100%), then hand the header back to the BIOS.
  provisioner "remote-exec" {
    when = destroy
    inline = [
      "if [ -x /usr/local/sbin/gpu-fan-control ]; then systemctl disable --now gpu-fan-control.service || true; /usr/local/sbin/gpu-fan-control release || true; fi",
      "rm -f /usr/local/sbin/gpu-fan-control /etc/systemd/system/gpu-fan-control.service /etc/default/gpu-fan-control /etc/modules-load.d/gpu-fan-control.conf /etc/modprobe.d/gpu-fan-control.conf",
      "systemctl daemon-reload",
    ]
  }

  lifecycle {
    precondition {
      condition     = local.gpu_fan_control_exporter_url != null
      error_message = "gpu_fan_control needs exporter_url when gpu_passthrough gives the card to no Talos VM."
    }
    precondition {
      condition     = var.proxmox_ssh_username == "root"
      error_message = "gpu_fan_control installs into /usr/local/sbin and /etc/systemd over SSH, so proxmox_ssh_username must be root."
    }
    precondition {
      condition     = var.gpu_fan_control.kernel_module_options == null || var.gpu_fan_control.kernel_module != null
      error_message = "gpu_fan_control.kernel_module_options needs kernel_module."
    }
  }
}
