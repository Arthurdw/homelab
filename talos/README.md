# Talos configuration

Phase 5 groundwork for the Kubernetes nodes that will run on Proxmox host `poseidon`. This directory
holds the **inputs** and **machine-config patches**; the machine configs themselves are **generated**
locally and never committed, because they embed the cluster PKI and secrets.

> **Status: scaffolded, not applied.** No VM exists yet (that is Proxmox/Phase 4 work) and no node has
> been bootstrapped. The version pair is verified against upstream — see below — but nothing here has
> touched real hardware. The bootstrap gate is **GATE 5** (docs/PROJECT-PLAN.md §6).

## Version pin

`versions.yaml` is authoritative; the generator reads it and does not duplicate the pins.

| Component | Pin | Verification |
|---|---|---|
| Talos | `v1.14.4` | GitHub release `siderolabs/talos` tag `v1.14.4`, published 2026-10-16 |
| Kubernetes | `v1.37.1` | the same Talos v1.14.4 release bundles `kube-apiserver:v1.37.1`, `kubelet:v1.37.1`, `etcd:v3.7.2` |

The locally installed `talosctl` is older than the pin (`v1.14.0` at time of writing). That is fine for
`gen config` (it is passed `--talos-version v1.14.4`) but the mismatch is reported, not hidden — upgrade
the client before touching a live node.

## Layout

| Path | Committed? | Purpose |
|---|---|---|
| `inputs.env` | yes | The single place for every undecided value. `TODO(GATE 0)` markers explain each decision. |
| `patches/common.yaml` | yes | Applied to every node; disables the bundled Flannel. |
| `patches/controlplane.yaml` | yes | **Comments-only template.** Not applied while empty — see the file. |
| `patches/worker.yaml` | yes | **Applied to workers only:** the `local-path-provisioner` user volume. Never applied to the control plane — see the file. |
| `out/` | **no** (gitignored) | Generated `controlplane.yaml`, `worker.yaml`, `talosconfig`. Contains secrets. |

Patches are Talos 1.14 **multi-document** documents (matched by `apiVersion`/`kind`), not the legacy
`machine:`/`cluster:` paths — those now collide with the generated documents and make
`talosctl validate` fail. `gen-configs.sh` only passes a patch file that has non-comment content, which
is why `patches/controlplane.yaml` can sit here as an inactive template; `patches/worker.yaml` now
carries real content, so `--config-patch-worker` is applied.

## Generating and validating

The two scripts are offline: they write and read local files only. They never contact a node, the
Proxmox API, or any other host.

```sh
./scripts/talos/gen-configs.sh            # generate into talos/out/ (refuses to clobber)
./scripts/talos/gen-configs.sh --dry-run  # print the command, write nothing
./scripts/talos/gen-configs.sh --force    # regenerate (REPLACES the cluster PKI/secrets)
./scripts/talos/validate.sh               # talosctl validate --mode metal on every config
just talos-validate                        # same as validate.sh
```

`gen-configs.sh` is idempotent: if `talos/out/` already holds a `talosconfig`, a plain re-run is a no-op.
It never talks to hardware. **`talos/out/` must never be committed** — the machine configs carry the
cluster secrets; verify with `git check-ignore -v talos/out/controlplane.yaml`.

## Booting and bootstrapping

**Not here.** VM creation is owned by OpenTofu (Proxmox, Phase 4) and the bootstrap itself is a gated
live operation. The procedure, including rollback limitations, is
`docs/runbooks/talos-bootstrap.md`. Guarded helpers live in `scripts/talos/`.

## Open values (TODO(GATE 0))

Every undecided value is a variable in `inputs.env` (or a marked entry in a patch) rather than a
hard-coded literal scattered around the tree:

- `CLUSTER_ENDPOINT` — API endpoint / VIP (placeholder is an RFC 5737 documentation address).
- `INSTALL_DISK` — VirtIO disk-bus device (`/dev/sda` vs `/dev/vda`).
- `INSTALL_IMAGE` — vanilla installer vs image-factory schematic.
- `ADDITIONAL_SANS` — API server DNS names.
- NTP sources — left at the Talos default; nothing is set yet.
- CNI choice — `patches/common.yaml` deletes the bundled Flannel document; which CNI is installed is
  undecided (see `docs/architecture.md` §6).

The list of owner questions is `docs/PROJECT-PLAN.md` §10.
