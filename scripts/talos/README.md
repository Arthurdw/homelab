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
./scripts/talos/validate.sh               # validates talos/out/controlplane.yaml + worker.yaml
just talos-validate                        # the same via the Justfile
```

`TALOS_INPUTS` selects the inputs file (default `talos/inputs.env`; the lab uses `talos/inputs.lab.env`).
`TALOS_OUT_DIR` overrides the output directory and `WORKER_PATCH` the worker patch (empty skips it).

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
