# RIPE Atlas software probe

What this runs (`docs/decisions.md` §5.19): one RIPE Atlas software probe in the homelab cluster
(`kubernetes/apps/ripe-atlas/`), IPv4 only, in a Kata microVM. It dials RIPE's registration and controller
servers over SSH and runs the pings, traceroutes, DNS, HTTP and TLS measurements they hand it. Nothing
connects to it.

| Piece | File |
|---|---|
| Deployment, one replica, `Recreate`, `runtimeClassName: kata` | `kubernetes/apps/ripe-atlas/deployment.yaml` |
| Egress to public IPv4 only, no ingress | `kubernetes/apps/ripe-atlas/networkpolicy.yaml` |
| The one ingress exception: ICMP errors from public routers | `kubernetes/apps/ripe-atlas/ciliumnetworkpolicy.yaml` |
| The probe key (its identity), SOPS | `kubernetes/overlays/homelab/apps/ripe-atlas-probe-key.sops.yaml` |
| Image pin | `versions.yaml` `app_images.ripe_atlas`; Renovate never automerges it (`renovate.json5`) |

Only the homelab overlay includes the directory. The lab must never run the registered key: two probes with
one key confuse RIPE's controller. For a lab test, use a throwaway key (registration then fails, as it should).

## Pre-checks

- The homelab cluster is up and Flux is reconciling.
- The `kata` RuntimeClass exists and the nodes have `/dev/kvm`:
  `kubectl --context homelab get runtimeclass kata`.
- The probe's public key was submitted at `https://atlas.ripe.net/apply/swprobe` (done 2026-11-04) and the
  SOPS file holds its private half. Check without printing the private key:

  ```sh
  sops -d --extract '["stringData"]["probe_key.pub"]' \
    kubernetes/overlays/homelab/apps/ripe-atlas-probe-key.sops.yaml
  ```

  It must match the key on the application: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN1qFIThwrbclorH/hMELbWEidLHTt374MDCYsSVgSog homelab-atlas`.

## Owner steps

1. **Go live.** Pushing the §5.19 commit is the whole deployment: Flux creates the namespace, both policies,
   the Secret and the pod. Watch it start:

   ```sh
   flux --context homelab reconcile kustomization apps --with-source
   kubectl --context homelab -n ripe-atlas get pods -o wide -w
   ```

2. **Wait for RIPE.** A new software probe can stay unconnected until RIPE has processed the application. The
   pod keeps retrying meanwhile; nothing to do. The probe's page appears under *My Atlas > Probes* once it is
   accepted.

## Verification

**Pod and runtime.** The pod is `Running`, with no restarts piling up, and runs under Kata:

```sh
kubectl --context homelab -n ripe-atlas get pods
kubectl --context homelab -n ripe-atlas get pod -l app.kubernetes.io/name=ripe-atlas \
  -o jsonpath='{.items[0].spec.runtimeClassName}{"\n"}'          # kata
kubectl --context homelab -n ripe-atlas logs deploy/ripe-atlas --tail=50
```

The logs should show the probe reaching the registration server and then a controller. A "Ping failed" line at
startup is harmless: it only sets the status LEDs (`/usr/sbin/ripe-atlas` in the image).

The probe picks a registration address at random from RIPE's IPv4 and IPv6 lists. An IPv6 pick ends in
`255  REGINIT exit with error`, because the pod has no IPv6, and it retries about three minutes later. Within a
few rounds it picks IPv4 and logs `Got good controller info`, then `initiating KEEP connection to -R 2023 ...
ctr-<site>.atlas.prod.ripe.net`. After that the log goes quiet, and that is the connected state. The
`condmv: not moving` lines are harmless as well: results waiting for the controller to collect them.

**RIPE's side.** At atlas.ripe.net the probe shows *Connected*, with ASN 6848 (Telenet) and IPv4 only.
Built-in measurements start reporting results within the hour.

**Measurements and isolation.** These checks are run by the owner; they exec into the live pod. First, the
measurement binary keeps its raw-socket capability (Kata needs virtiofsd's `--xattr` for that, set by the pod
annotation), and ping and ICMP traceroute work:

```sh
kubectl --context homelab -n ripe-atlas exec -i deploy/ripe-atlas -- sh -s <<'EOF'
for p in /proc/[0-9]*; do
  [ "$(cat "$p/comm" 2>/dev/null)" = eperd ] && grep -E 'CapPrm|CapEff' "$p/status"
done
B=/usr/libexec/ripe-atlas/measurement/busybox
$B evping -4 -c 2 1.1.1.1; echo "ping rc=$?"
$B evtraceroute -4 -I -m 12 -c 1 1.1.1.1; echo "traceroute rc=$?"
EOF
```

Expected:
- eperd shows `CapPrm`/`CapEff` `0000000000002000` (only `CAP_NET_RAW`).
- The ping RESULT JSON has `"rcvd":2`.
- The traceroute shows the public Telenet hops by address and the private first hops as `*`.

If every ping fails with "socket failed: Operation not permitted", the annotation did not reach Kata (see Risks).

Then the network is internet only. Every line must print `BLOCKED` except the last one:

```sh
POD=$(kubectl --context homelab -n kube-system get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].status.podIP}')
kubectl --context homelab -n ripe-atlas exec -i deploy/ripe-atlas -- env POD="$POD" bash -s <<'EOF'
t() { timeout 4 bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null && echo "OPEN    $1:$2 ($3)" || echo "BLOCKED $1:$2 ($3)"; }
t "$POD"       53    "a pod (CoreDNS)"
t 10.96.0.10   53    "kube-dns Service"
t 10.96.0.1    443   "API server Service"
t 10.20.0.11   6443  "node: API server"
t 10.20.0.11   50000 "node: talos apid"
t 10.20.0.11   10250 "node: kubelet"
t 10.20.0.1    443   "K8S VLAN gateway (UDM)"
t 10.20.0.100  443   "Traefik LoadBalancer"
t 10.20.0.101  53    "Technitium LoadBalancer"
t 10.10.1.1    8006  "poseidon (Proxmox)"
t 10.10.1.10   443   "hercules-nas (TrueNAS)"
t 10.0.0.1     443   "HOME VLAN gateway"
t 169.254.169.254 80 "link-local metadata"
t 1.1.1.1      443   "public internet: must be OPEN"
EOF
```

And nothing reaches the probe. A throwaway pod in another namespace (it is deleted on exit):

```sh
IP=$(kubectl --context homelab -n ripe-atlas get pod -l app.kubernetes.io/name=ripe-atlas -o jsonpath='{.items[0].status.podIP}')
kubectl --context homelab -n default run atlas-ingress-test --rm -i --restart=Never \
  --image=docker.io/library/busybox:1.37 -- sh -c "ping -c 2 -W 2 $IP; nc -w 3 $IP 2023 </dev/null && echo OPEN || echo BLOCKED"
```

Expected: 100% packet loss and `BLOCKED`. Port 2023 is the measurement telnetd, which listens inside the pod.

## Key rotation or a lost key

The key pair is the probe's identity, so its private half has to stay secret. Rotate it if it may have leaked
(plaintext ever on a shared disk, in a log, in a commit). Losing it is no emergency: the SOPS file is the only
copy, and recovering the age key recovers it (`docs/runbooks/secrets.md`).

RIPE's process for a new key is not verified here. A thread on RIPE's atlas-sw-probes list (January 2020) says
the apply form refuses a key that is already in use, and that a way to replace the key of an existing probe
was planned. So check the probe's page at atlas.ripe.net for a key option first. If there is none, apply for a
new probe with the new key, and mail `atlas@ripe.net` to retire the old probe ID.

1. Generate the pair in a private temporary directory:

   ```sh
   umask 077; d="$(mktemp -d)"
   ssh-keygen -t ed25519 -N '' -C homelab-atlas -f "$d/probe_key"
   cat "$d/probe_key.pub"      # this goes to RIPE
   ```

2. Build the Secret there and encrypt it in place. Run this from the repo root so sops finds `.sops.yaml`:

   ```sh
   kubectl create secret generic ripe-atlas-probe-key -n ripe-atlas \
     --from-file=probe_key="$d/probe_key" --from-file=probe_key.pub="$d/probe_key.pub" \
     --dry-run=client -o yaml >"$d/ripe-atlas-probe-key.sops.yaml"
   sops --encrypt --in-place "$d/ripe-atlas-probe-key.sops.yaml"
   grep -c 'ENC\[' "$d/ripe-atlas-probe-key.sops.yaml"    # 2: both values encrypted
   ```

   This writes `data` (base64) rather than `stringData`; both work. Copy the file over
   `kubernetes/overlays/homelab/apps/ripe-atlas-probe-key.sops.yaml`, put the header comment back with the new
   date, then `rm -rf "$d"`.

3. Register the new public key with RIPE (the probe's page, or `apply/swprobe` as above), then commit and
   push. Flux updates the Secret, but the pod copies the key only at startup, so restart it:
   `kubectl --context homelab -n ripe-atlas rollout restart deployment ripe-atlas`.
4. Run the verification above. The probe should come up *Connected* under the new key.

## Rollback

1. **Stop the probe:** remove both ripe-atlas lines from `kubernetes/overlays/homelab/apps/kustomization.yaml`
   (`- ../../../apps/ripe-atlas` and `- ripe-atlas-probe-key.sops.yaml`), commit and push. Flux prunes the
   namespace with the pod, both policies and the Secret. On atlas.ripe.net the probe turns *Disconnected*;
   its credits and history stay.
2. **For good:** also delete `kubernetes/apps/ripe-atlas/`, the SOPS file, `app_images.ripe_atlas` in
   `versions.yaml` and its rule in `renovate.json5`, and ask RIPE to retire the probe (`atlas@ripe.net`), or
   the account keeps an orphaned, disconnected probe.

## Risks and notes

- **Untrusted work.** Strangers choose the targets and the probe parses their replies with `CAP_NET_RAW`. The
  layers are Kata, internet-only egress, no ingress except the ICMP errors, non-root, read-only root and no
  service-account token. A probe that misbehaves on the internet still does so from the household's public
  IP; if RIPE or the ISP complains, take step 1 of the rollback first.
- **The `--xattr` annotation** replaces the Talos kata extension's `virtio_fs_extra_args` wholesale. Its first
  two entries copy the extension's defaults (checked 2026-11-04). After a Talos or kata extension upgrade,
  compare them with `/usr/local/share/kata-containers/configuration.toml` on a node, and rerun the
  capability check above. If the extension ever drops `virtio_fs_extra_args` from `enable_annotations`, the
  pod still starts but every measurement fails.
- **Seccomp is not applied** inside the guest (`disable_guest_seccomp=true` in the kata extension). The pod's
  `RuntimeDefault` is there for PSA; the VM boundary stands in for it.
- **Traceroutes show only public hops.** The private hops (the cluster gateway, the ISP modem) stay `*` on
  purpose. UDP and TCP traceroutes go silent past the ISP modem even without any policy (lab test,
  2026-11-04); that is outside the cluster. ICMP traceroutes work.
- **Hairpin to the own public IP** is reachable and accepted: no port is forwarded (§5.2).
- **The image** is a community build, pinned by digest. Renovate never automerges it; read the upstream
  changes before merging, then rerun the verification.
- **One pod, ever.** Never scale it, never run the real key anywhere else (the lab, a laptop, docker).
- **IPv6** is not measured. A dual-stack probe would be a separate VM (`docs/future-work.md`).
