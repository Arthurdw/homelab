# Prometheus node-exporter on the Proxmox host: the host's own temperatures and fan speeds (hwmon), and,
# through the textfile collector, the GPU fan controller's duty, reading, fan rpm and state (fan-control.tf).
# Prometheus in the cluster scrapes it (kubernetes/infrastructure/configs/proxmox-host-scrapeconfig.yaml);
# the "GPU & cooling" Grafana dashboard shows it.
#
# Debian's prometheus-node-exporter package, installed over SSH like the fan controller. Its settings are a
# systemd drop-in, not the package's /etc/default conffile, so package upgrades never stop on a changed conffile:
#   /etc/systemd/system/prometheus-node-exporter.service.d/homelab.conf
# It listens on the management address only. Any change replaces the resource: purge, then install again.
#
# Null (the default) installs nothing. Destroying the resource, or setting it back to null, purges the package.

locals {
  host_metrics_textfile_dir = "/var/lib/prometheus/node-exporter"

  host_metrics_listen_address = var.host_metrics == null ? null : coalesce(
    var.host_metrics.listen_address,
    "${local.proxmox_endpoint_host}:9100",
  )

  host_metrics_dropin = var.host_metrics == null ? null : <<-EOT
    # Managed by OpenTofu (infrastructure/environments/homelab/proxmox/host-metrics.tf). Edits here are
    # overwritten on the next apply; change var.host_metrics instead.
    [Service]
    ExecStart=
    ExecStart=/usr/bin/prometheus-node-exporter --web.listen-address=${local.host_metrics_listen_address} --collector.textfile.directory=${local.host_metrics_textfile_dir}
  EOT

  host_metrics_dropin_dir = "/etc/systemd/system/prometheus-node-exporter.service.d"
}

resource "terraform_data" "host_metrics" {
  count = var.host_metrics == null ? 0 : 1

  triggers_replace = sha256(local.host_metrics_dropin)

  # The destroy provisioner can only read `self`, so the connection details are kept here.
  input = {
    host = coalesce(var.host_metrics.ssh_host, local.proxmox_endpoint_host)
    user = var.proxmox_ssh_username
  }

  connection {
    type  = "ssh"
    host  = self.input.host
    user  = self.input.user
    agent = true
  }

  provisioner "remote-exec" {
    inline = ["mkdir -p ${local.host_metrics_dropin_dir}"]
  }

  # In place before the package, so its first start already listens on the right address only.
  provisioner "file" {
    content     = local.host_metrics_dropin
    destination = "${local.host_metrics_dropin_dir}/homelab.conf"
  }

  provisioner "remote-exec" {
    inline = [
      "set -eu",
      "systemctl daemon-reload",
      "apt-get update -q",
      "DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends prometheus-node-exporter",
      "mkdir -p ${local.host_metrics_textfile_dir}",
      "systemctl enable prometheus-node-exporter.service",
      "systemctl restart prometheus-node-exporter.service",
      "sleep 3",
      "systemctl is-active --quiet prometheus-node-exporter.service || { journalctl -u prometheus-node-exporter.service -n 30 --no-pager; exit 1; }",
      "curl -fsS http://${local.host_metrics_listen_address}/metrics | grep -E '^node_(exporter_build_info|textfile_scrape_error)'",
    ]
  }

  provisioner "remote-exec" {
    when = destroy
    inline = [
      "DEBIAN_FRONTEND=noninteractive apt-get purge -y -q prometheus-node-exporter || true",
      "rm -rf /etc/systemd/system/prometheus-node-exporter.service.d",
      "systemctl daemon-reload",
    ]
  }

  lifecycle {
    precondition {
      condition     = var.proxmox_ssh_username == "root"
      error_message = "host_metrics installs a package over SSH, so proxmox_ssh_username must be root."
    }
  }
}
