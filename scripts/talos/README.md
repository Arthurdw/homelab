# `scripts/talos` — Talos helpers

Helpers for the Talos nodes. See `talos/README.md` for the configuration itself
and `docs/runbooks/talos-bootstrap.md` for the end-to-end procedure.

| Script | Contacts hardware? | Purpose |
|---|---|---|
| `gen-configs.sh` | **No** — writes local files only | Generate machine configs + talosconfig into the gitignored `talos/out/`. |
| `validate.sh` | **No** — reads local files only | `talosctl validate --mode metal` on every generated config. |
| `bootstrap.sh` | **Yes** — guarded | `talosctl bootstrap` the control plane. |
| `kubeconfig.sh` | **Yes** — guarded | Retrieve the admin kubeconfig into `talos/out/`. |

## Safe, offline helpers

```sh
./scripts/talos/gen-configs.sh            # idempotent; refuses to clobber without --force
./scripts/talos/gen-configs.sh --dry-run  # print the talosctl command, write nothing
./scripts/talos/gen-configs.sh --regen    # rebuild controlplane/worker*.yaml with the SAME PKI
./scripts/talos/validate.sh               # validates talos/out/controlplane.yaml + worker*.yaml
just talos-validate                        # the same via the Justfile
```

`TALOS_INPUTS` selects the inputs file (default `talos/inputs.env`; the lab uses `talos/inputs.lab.env`).
`TALOS_OUT_DIR` overrides the output directory and `WORKER_PATCH` the worker patch (empty skips it);
`CONTROLPLANE_NETWORK_PATCH` / `WORKER_NETWORK_PATCH` the production storage-NIC patches (the lab empties them).
`WORKER_NODES` (default `talos-wk-1 talos-wk-2`) names the production workers: each gets
`<out>/worker-<node>.yaml`, the shared `worker.yaml` patched with `talos/patches/node-<node>.yaml`, and
`GPU_WORKER_NODE` (default `talos-wk-1`) also gets `GPU_WORKER_PATCH`. The lab empties `WORKER_NODES`.

`--regen` is for a running cluster. It reads the secrets bundle (`TALOS_SECRETS`, default `<out>/secrets.yaml`),
refuses if it is missing, and never writes it. It copies the old `controlplane.yaml` and `worker*.yaml` to `<out>/backup-<UTC time>/`, replaces them, and
leaves `talosconfig` alone. `--force` and `--regen` are exclusive.

## Guarded, live helpers

`bootstrap.sh` and `kubeconfig.sh` talk to a real node. They are safe by default:

- both require `--node <ip>` — there is no default node;
- both print the command they would run and **refuse** unless `--confirm` (or the matching
  `TALOS_*_CONFIRM=1` env var) is given;
- `--dry-run` prints the command and exits without contacting anything.

```sh
./scripts/talos/bootstrap.sh  --node <control-plane-ip> --confirm
./scripts/talos/kubeconfig.sh --node <control-plane-ip> --confirm
```

These are convenience wrappers, not a substitute for the runbook. Read
`docs/runbooks/talos-bootstrap.md` (including its rollback limitations) before using them.
