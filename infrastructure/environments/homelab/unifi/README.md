# UniFi root configuration

Manages UniFi network resources for the homelab.

**Status:** scaffold — no resources defined yet. Provider is pinned and validated; nothing is applied.

> ⚠️ **Additive-only, plan-only.** The homelab shares this UniFi controller with **house appliances and
> other people's networks**. Rules:
>
> - **Never** modify or delete objects we did not create; **never** import existing objects.
> - **Add** new objects with names prefixed `hl-`; wire them in explicitly.
> - Always review a `plan` and treat **any** update/destroy to an unowned object as a stop-and-ask event.
> - Applies are gated; never `-auto-approve`.
>
> ⚠️ The API key is **full-access** (no read-only key available). It is handled as enforced least privilege
> by process (`docs/secrets-and-state.md` §4, risk R19). Keep it in the environment, never in the repo.

## Usage

```sh
cd infrastructure/environments/homelab/unifi

export TF_VAR_unifi_api_key='...'

cp terraform.tfvars.example terraform.tfvars   # then edit; tfvars is gitignored
tofu init -backend=false
tofu validate
tofu plan                                      # review carefully
```

## Notes

- Provider: `ubiquiti-community/unifi` (validated against OpenTofu 1.13.1). Supports API-key auth.
- Migration is incremental and additive (`docs/PROJECT-PLAN.md`, decision D2).
