# Runbook: Ollama and Open WebUI

[Ollama](https://ollama.com) runs local language models on the Tesla P4; [Open WebUI](https://openwebui.com) is the
chat page in front of it at `https://chat.lab.ardw.be` and the place to pull, try and delete models
(`docs/decisions.md` §5.18). Manifests: `kubernetes/apps/ollama/`, in both overlays; the lab runs Ollama on the
CPU.

## What lives where

- **In the cluster:** namespace `ollama`, two pods on `talos-wk-1`.
  - `ollama`: the model server, one time-sliced `nvidia.com/gpu`. Models live on the `ollama-models` volume
    (`local-path`, 50 GiB). Internal only: a ClusterIP Service on 11434, no Ingress.
  - `open-webui`: the web page. Its SQLite database (users, chats, settings) and embedding model live on
    `open-webui-data` (`local-path`, 5 GiB).
- **Login:** Authentik forward-auth (any Authentik user, application **Chat** in the Apps group). Open WebUI
  takes the user from the `X-authentik-email`/`X-authentik-name` headers; it has no password of its own.
- **NetworkPolicies:** only Traefik reaches Open WebUI, only Open WebUI reaches Ollama. Ollama's API has no login,
  and Open WebUI believes whatever user the headers name, so neither may be reachable from other pods.
- **Not backed up** (`docs/backup-matrix.md`): models are pulled again; losing Open WebUI's data loses chats and
  settings and makes the next login admin again.

## Pre-checks

- [ ] `chat.lab.ardw.be` resolves to the Traefik VIP (Technitium's wildcard).
- [ ] `kubectl -n ollama get pods` shows `ollama` and `open-webui` Ready. Open WebUI's first start downloads its
      embedding model (about 0.9 GB) and can take a few minutes.
- [ ] `kubectl get node talos-wk-1 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'` returns `6`. With `4`,
      the device plugin still runs the old time-slicing config and Ollama may stay Pending.
- [ ] Authentik shows the **Chat** application and the embedded outpost lists the `Chat` provider. If not, the
      blueprint has not been re-applied yet: restart the Authentik worker.

## First login

The first account Open WebUI creates becomes its admin; every later one is a plain `user`.

1. Open `https://chat.lab.ardw.be/` (or the **Chat** tile on Homepage) **as the owner first**, and sign in to
   Authentik. Open WebUI creates the account from the headers and logs straight in.
2. Check **Admin Panel → Users**: your account has role `admin`.
3. Optional: **Admin Panel → Settings → General** to change the default role for new users (`pending` makes new
   accounts wait for approval). After the first start this setting lives in the database; the
   `DEFAULT_USER_ROLE` environment variable no longer changes it.

Sign-out in Open WebUI also ends the Authentik session; otherwise the headers would log you straight back in.

## Trying a model

1. Pick a model on [ollama.com/library](https://ollama.com/library). The P4 has 8 GB, Ollama leaves 2 GiB for
   Immich, so a download of up to about 5 GB stays fully on the card; bigger ones run partly on the CPU. As of
   2026-10: `qwen3.5:4b` (3.3 GB, fully on the card) as the everyday model, `qwen3.5:9b` (6.6 GB, smarter but
   a few layers on the CPU). Tag sizes on ollama.com include the vision part of multimodal models.
2. **Admin Panel → Settings → Models → Manage** (the download icon), type the name with its tag
   (`qwen3.5:4b`) and pull. Progress shows in the page.
3. Start a new chat and pick the model at the top. The first answer takes longer while the model loads onto the
   card.
4. Delete a model in the same **Manage** dialog; that frees the volume, not just the card.

Equivalent CLI (the owner runs it): `kubectl -n ollama exec deploy/ollama -- ollama pull qwen3.5:4b`, `ollama
list`, `ollama rm <model>`.

## VRAM sharing with Immich

Time-slicing shares the card's time, not its memory: every pod sees all 8 GB and nothing caps Immich.

- Ollama keeps one model loaded and unloads it 15 min after the last request (`OLLAMA_KEEP_ALIVE`). With nothing
  loaded, Immich has the whole card.
- When it loads a model, Ollama checks what is free right then and leaves 2 GiB (`OLLAMA_GPU_OVERHEAD`) for
  Immich ML. Layers that do not fit run on the CPU: the model works, just slower. `ollama ps` shows the split
  (`100% GPU`, or e.g. `27%/73% CPU/GPU`).
- Immich ML unloads its models after 5 min idle. If both are busy at once and the card runs out, the request
  that hit it fails (Immich retries its job; ask the chat again); nothing is lost.
- If that happens often: lower Immich's ML concurrency (**Administration → Settings → Job Settings**, Smart
  Search and Face Detection to 1), or use a smaller model.

Watch it in Grafana **GPU & cooling** (memory used, load) or with
`kubectl -n ollama exec deploy/ollama -- ollama ps`.

## Verification

- `kubectl -n ollama exec deploy/ollama -- ollama ps` while a chat runs lists the model with `100% GPU` (or a
  CPU/GPU split when Immich holds memory).
- `kubectl -n ollama logs deploy/ollama` shows `inference compute ... library=cuda ... name="Tesla P4"` at start.
  `library=cpu` means no GPU (normal in the lab).
- A private window on `chat.lab.ardw.be` lands on the Authentik login first.
- From another pod, `curl http://ollama.ollama.svc.cluster.local:11434` times out (NetworkPolicy).
- Not done at the time of writing: the first production login.

## Operations

- **Restart:** `kubectl -n ollama rollout restart deploy/ollama` (or `deploy/open-webui`). Both use `Recreate`, so
  each is briefly down.
- **Full volume:** delete models in Open WebUI, or raise the PVC size (`local-path` does not expand; recreate the
  PVC and pull again).
- **Upgrade:** Renovate opens PRs for both images (`versions.yaml`, `app_images.ollama` and
  `app_images.open_webui`); no automerge. Open WebUI migrates its database on start, so read its release notes
  for breaking changes first.

## Rollback

Remove `ollama` from `kubernetes/apps/kustomization.yaml`, the Chat entries from the Authentik blueprint, the
outpost Ingress (`forward-auth.yaml`) and Homepage, and the Ollama patch from the lab overlay. Flux prunes the
namespace. `local-path` is `Retain`, so `Released` PVs and their directories stay behind on the node; delete the
PVs to free the space. The device plugin's 6 slots can stay.
