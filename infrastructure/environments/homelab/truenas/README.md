# TrueNAS root configuration

Manages TrueNAS SCALE resources (datasets, shares, snapshot/replication tasks) for the homelab.

**Status:** scaffold — no resources defined yet. Provider is pinned and validated; nothing is applied.

> ⚠️ **Data safety:** this root can destroy pools/datasets. Treat every `plan` as write-capable. Applies are
> gated (see `docs/PROJECT-PLAN.md`) and require explicit owner approval. Never `-auto-approve`.

## Usage

```sh
cd infrastructure/environments/homelab/truenas

# Keep the API key in the environment, not on disk:
export TF_VAR_truenas_api_key='...'

cp terraform.tfvars.example terraform.tfvars   # then edit; tfvars is gitignored
tofu init -backend=false
tofu validate
tofu plan                                      # review only
```

## Notes

- Provider: `truenas/truenas` (validated against OpenTofu 1.13.1).
- Prefer importing/creating datasets and shares here only after the pool design is confirmed
  (`docs/storage.md`).
