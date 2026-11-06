# BIOS fan curves on the Proxmox host (docs/runbooks/fan-curves.md): rewrites the Super I/O chip's own automatic
# curve (Smart Fan IV) for some headers at every boot. The chip then drives those fans from its temperature input
# (the CPU's PECI reading on poseidon) by itself, so nothing has to keep running, and the BIOS needs no screen.
#
# Same install as fan-control.tf, over SSH with provisioners:
#   /usr/local/sbin/fan-curves              scripts/fan-control/fan-curves.sh
#   /etc/systemd/system/fan-curves.service  scripts/fan-control/fan-curves.service (oneshot at boot)
#   /etc/default/fan-curves                 generated below from var.fan_curves
#   /etc/modules-load.d/fan-curves.conf     only with kernel_module
# Any change to those contents replaces the resource: the old curves are put back, then the new ones written.
# The install fails, and the apply with it, if the chip or a header's curve is not found or a write does not read
# back.
#
# Null (the default, and the L1 fixture) installs nothing. Destroying the resource, or setting it back to null,
# puts back the curves the BIOS wrote at the last boot.

locals {
  fan_curves_staging = "/root/.cache/fan-curves-staging"

  fan_curves_files = var.fan_curves == null ? null : {
    script  = file("${path.module}/../../../../scripts/fan-control/fan-curves.sh")
    service = file("${path.module}/../../../../scripts/fan-control/fan-curves.service")
    env     = <<-EOT
      # Managed by OpenTofu (infrastructure/environments/homelab/proxmox/fan-curves.tf). Edits here are
      # overwritten on the next apply; change var.fan_curves instead.
      HWMON_NAME="${var.fan_curves.hwmon_name}"
      CHANNELS="${join(" ", sort(keys(var.fan_curves.headers)))}"
      ${join("\n", [for k in sort(keys(var.fan_curves.headers)) : "CURVE_${k}=\"${join(" ", [for p in var.fan_curves.headers[k] : "${p.temp}:${p.percent}"])}\""])}
    EOT
    module  = coalesce(var.fan_curves.kernel_module, "-")
  }
}

resource "terraform_data" "fan_curves" {
  count = var.fan_curves == null ? 0 : 1

  triggers_replace = { for k, v in local.fan_curves_files : k => sha256(v) }

  # The destroy provisioner can only read `self`, so the connection details are kept here.
  input = {
    host = coalesce(var.fan_curves.ssh_host, local.proxmox_endpoint_host)
    user = var.proxmox_ssh_username
  }

  connection {
    type  = "ssh"
    host  = self.input.host
    user  = self.input.user
    agent = true
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p -m 0700 ${local.fan_curves_staging}"]
  }

  provisioner "file" {
    content     = local.fan_curves_files.script
    destination = "${local.fan_curves_staging}/fan-curves.sh"
  }

  provisioner "file" {
    content     = local.fan_curves_files.service
    destination = "${local.fan_curves_staging}/fan-curves.service"
  }

  provisioner "file" {
    content     = local.fan_curves_files.env
    destination = "${local.fan_curves_staging}/fan-curves.env"
  }

  provisioner "remote-exec" {
    inline = concat(
      [
        "set -eu",
        "cd ${local.fan_curves_staging}",
        "install -m 0755 fan-curves.sh /usr/local/sbin/fan-curves",
        "install -m 0644 fan-curves.service /etc/systemd/system/fan-curves.service",
        "install -m 0644 fan-curves.env /etc/default/fan-curves",
      ],
      var.fan_curves.kernel_module == null ? [] : [
        "echo '${var.fan_curves.kernel_module}' > /etc/modules-load.d/fan-curves.conf",
        "modprobe ${var.fan_curves.kernel_module}",
      ],
      [
        "systemctl daemon-reload",
        "systemctl enable fan-curves.service",
        # restart, not start: a oneshot with RemainAfterExit stays active, and start would not run it again.
        "systemctl restart fan-curves.service || { journalctl -u fan-curves.service -n 30 --no-pager; exit 1; }",
        "journalctl -u fan-curves.service -n 10 --no-pager",
        "rm -rf ${local.fan_curves_staging}",
      ],
    )
  }

  # Put back what the BIOS wrote at boot, then remove the files.
  provisioner "remote-exec" {
    when = destroy
    inline = [
      "if [ -x /usr/local/sbin/fan-curves ]; then /usr/local/sbin/fan-curves release || true; systemctl disable fan-curves.service || true; fi",
      "rm -f /usr/local/sbin/fan-curves /etc/systemd/system/fan-curves.service /etc/default/fan-curves /etc/modules-load.d/fan-curves.conf",
      "systemctl daemon-reload",
    ]
  }

  lifecycle {
    precondition {
      condition     = var.proxmox_ssh_username == "root"
      error_message = "fan_curves installs into /usr/local/sbin and /etc/systemd over SSH, so proxmox_ssh_username must be root."
    }
    precondition {
      condition     = var.gpu_fan_control == null || !contains(keys(var.fan_curves.headers), tostring(try(var.gpu_fan_control.pwm_channel, -1)))
      error_message = "fan_curves.headers lists the header gpu_fan_control drives (pwm_channel); a header has one owner."
    }
  }
}
