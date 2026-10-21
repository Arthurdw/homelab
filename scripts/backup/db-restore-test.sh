#!/usr/bin/env bash
# Non-destructive restore test for a database dump CronJob (immich, authentik, seafile).
#
# "A dump is not verified because the job wrote a file." This restores the newest dump on the app's
# `<app>-db-backups` PVC into a throwaway postgres (seafile: mariadb) pod in a scratch namespace,
# compares the restored table count with what the dump says it contains, prints row counts, and deletes
# the scratch namespace and the reader pod on exit. The live database is never touched.
#
# Usage: db-restore-test.sh <immich|authentik|seafile>
#
# Needs kubectl pointing at the cluster. The server image is read from the dump CronJob, so the
# restore uses the same server and extensions (vectorchord for Immich) as the dump.
#
# Seafile (`seafile-*.sql.gz`, mariadb-dump of ccnet_db, seafile_db and seahub_db) also checks that the
# gzip stream is intact and ends with mariadb-dump's completion marker (a truncated dump fails here),
# that all three databases exist, and that ccnet_db.EmailUser (the accounts) and the seahub_db migration
# history have rows.
#
# Optional:
#   DUMP_FILE        file name on the PVC to restore (default: newest `<app>-*.dump`, seafile `.sql.gz`)
#   RESTORE_TIMEOUT  seconds to wait for each pod (default: 300)
set -euo pipefail

app="${1:?usage: db-restore-test.sh <immich|authentik|seafile>}"
case "$app" in
  immich | authentik | seafile) ;;
  *)
    echo "unknown app: $app (expected immich, authentik or seafile)" >&2
    exit 2
    ;;
esac

timeout="${RESTORE_TIMEOUT:-300}"
scratch="restore-test-$app-$(date +%s)"
reader="restore-test-reader-${scratch##*-}"
pvc="$app-db-backups"

log() { printf '%s %s\n' "$(date -Is)" "$*"; }

cleanup() {
  kubectl -n "$app" delete pod "$reader" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  kubectl delete namespace "$scratch" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

image="$(kubectl -n "$app" get cronjob "$app-db-dump" \
  -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].image}')"
log "app=$app image=$image pvc=$pvc scratch=$scratch"

kubectl create namespace "$scratch" >/dev/null

if [ "$app" = seafile ]; then
  # Reader: the backups PVC read-only in the app namespace (a PVC cannot cross namespaces).
  kubectl -n "$app" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $reader
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 999, runAsGroup: 999, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: reader
      image: $image
      imagePullPolicy: IfNotPresent
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: backups, mountPath: /backups, readOnly: true}]
  volumes:
    - name: backups
      persistentVolumeClaim: {claimName: $pvc, readOnly: true}
YAML
  # Target: a scratch mariadb that exists only in this pod. Not the image entrypoint: its temporary init
  # server times out on a loaded node. A throwaway datadir with no grant tables and no networking,
  # reachable only through kubectl exec.
  kubectl -n "$scratch" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: db
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 999, runAsGroup: 999, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: mariadb
      image: $image
      imagePullPolicy: IfNotPresent
      command:
        - bash
        - -c
        - mariadb-install-db --skip-test-db --datadir=/var/lib/mysql >/dev/null && exec mariadbd --skip-grant-tables --skip-networking --innodb-buffer-pool-size=64M
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      readinessProbe: {exec: {command: [mariadb-admin, ping, --silent]}, periodSeconds: 3}
YAML
  kubectl -n "$app" wait --for=condition=Ready "pod/$reader" --timeout="${timeout}s" >/dev/null
  kubectl -n "$scratch" wait --for=condition=Ready pod/db --timeout="${timeout}s" >/dev/null

  dump="${DUMP_FILE:-$(kubectl -n "$app" exec "$reader" -- bash -c "ls -1t /backups/$app-*.sql.gz | head -n 1" | xargs -r basename)}"
  [ -n "$dump" ] || { echo "no $app-*.sql.gz on PVC $pvc" >&2; exit 1; }
  size="$(kubectl -n "$app" exec "$reader" -- stat -c %s "/backups/$dump")"
  log "restoring $dump ($size bytes)"

  # Integrity first: gzip -t catches a truncated file, the marker catches a dump cut at a line boundary.
  kubectl -n "$app" exec "$reader" -- gzip -t "/backups/$dump" || { echo "$dump is not a valid gzip stream" >&2; exit 1; }
  kubectl -n "$app" exec "$reader" -- bash -c "zcat /backups/$dump | tail -n 3 | grep -q -- '-- Dump completed'" ||
    { echo "$dump has no 'Dump completed' trailer (truncated)" >&2; exit 1; }

  # Streamed reader -> workstation -> scratch pod; nothing is written to disk here.
  kubectl -n "$app" exec "$reader" -- zcat "/backups/$dump" |
    kubectl -n "$scratch" exec -i db -- mariadb -uroot

  sql() { kubectl -n "$scratch" exec db -- mariadb -uroot -N -B -e "$1"; }

  dbs="$(sql "select group_concat(schema_name order by schema_name) from information_schema.schemata where schema_name in ('ccnet_db','seafile_db','seahub_db')")"
  log "databases restored: $dbs"
  [ "$dbs" = "ccnet_db,seafile_db,seahub_db" ] || { echo "expected ccnet_db, seafile_db and seahub_db" >&2; exit 1; }

  expected="$(kubectl -n "$app" exec "$reader" -- bash -c "zcat /backups/$dump | grep -c '^CREATE TABLE '")"
  restored="$(sql "select count(*) from information_schema.tables where table_type='BASE TABLE' and table_schema in ('ccnet_db','seafile_db','seahub_db')")"
  log "tables in dump: $expected, restored: $restored"
  [ "$expected" -gt 0 ] || { echo "dump lists no tables" >&2; exit 1; }
  [ "$expected" -eq "$restored" ] || { echo "table count mismatch" >&2; exit 1; }

  # Key tables must exist with at least this many rows (a fresh install has one admin and ~100 migrations).
  min_users="${MIN_USERS:-1}"
  min_migrations="${MIN_MIGRATIONS:-50}"
  users="$(sql "select count(*) from ccnet_db.EmailUser")"
  migrations="$(sql "select count(*) from seahub_db.django_migrations")"
  repos="$(sql "select count(*) from seafile_db.Repo")"
  log "ccnet_db.EmailUser: $users (min $min_users), seahub_db.django_migrations: $migrations (min $min_migrations), seafile_db.Repo: $repos"
  [ "$users" -ge "$min_users" ] || { echo "too few accounts in ccnet_db.EmailUser" >&2; exit 1; }
  [ "$migrations" -ge "$min_migrations" ] || { echo "too few rows in seahub_db.django_migrations" >&2; exit 1; }

  log "largest tables by row count (estimate):"
  sql "select concat(table_schema,'.',table_name,' ',table_rows) from information_schema.tables
       where table_schema in ('ccnet_db','seafile_db','seahub_db') and table_type='BASE TABLE'" | sort -k2 -n -r | head -10
  log "OK: $dump restores cleanly"
  exit 0
fi


# Reader: mounts the backups PVC read-only in the app namespace (a PVC cannot cross namespaces).
kubectl -n "$app" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $reader
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 999, runAsGroup: 999, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: reader
      image: $image
      imagePullPolicy: IfNotPresent
      command: [sleep, "3600"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      volumeMounts: [{name: backups, mountPath: /backups, readOnly: true}]
  volumes:
    - name: backups
      persistentVolumeClaim: {claimName: $pvc, readOnly: true}
YAML

# Target: a scratch server with a throwaway password that exists only in this pod.
kubectl -n "$scratch" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: pg
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 999, runAsGroup: 999, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: postgres
      image: $image
      imagePullPolicy: IfNotPresent
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      env:
        - {name: POSTGRES_PASSWORD, value: restore-test-only}
        - {name: POSTGRES_DB, value: restoretest}
      readinessProbe: {exec: {command: [pg_isready, -q, -U, postgres]}, periodSeconds: 3}
YAML

kubectl -n "$app" wait --for=condition=Ready "pod/$reader" --timeout="${timeout}s" >/dev/null
kubectl -n "$scratch" wait --for=condition=Ready pod/pg --timeout="${timeout}s" >/dev/null

dump="${DUMP_FILE:-$(kubectl -n "$app" exec "$reader" -- bash -c "ls -1t /backups/$app-*.dump | head -n 1" | xargs -r basename)}"
[ -n "$dump" ] || { echo "no $app-*.dump on PVC $pvc" >&2; exit 1; }
size="$(kubectl -n "$app" exec "$reader" -- stat -c %s "/backups/$dump")"
log "restoring $dump ($size bytes)"

# The dump is streamed reader -> workstation -> scratch pod; nothing is written to disk here.
kubectl -n "$app" exec "$reader" -- cat "/backups/$dump" |
  kubectl -n "$scratch" exec -i pg -- pg_restore --exit-on-error --no-owner --no-privileges \
    -U postgres -d restoretest

psql() { kubectl -n "$scratch" exec pg -- psql -U postgres -d restoretest -At -c "$1"; }

expected="$(kubectl -n "$app" exec "$reader" -- pg_restore --list "/backups/$dump" | grep -E '^[0-9]+; [0-9]+ [0-9]+ TABLE ' | grep -vc ' TABLE DATA ')"
restored="$(psql "select count(*) from information_schema.tables where table_type='BASE TABLE' and table_schema not in ('pg_catalog','information_schema')")"
log "tables in dump: $expected, restored: $restored"
[ "$expected" -gt 0 ] || { echo "dump lists no tables" >&2; exit 1; }
[ "$expected" -eq "$restored" ] || { echo "table count mismatch" >&2; exit 1; }

log "largest tables by row count (exact):"
psql "select schemaname||'.'||relname||' '||(xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, relname), false, true, '')))[1]::text
      from pg_stat_user_tables order by 1 limit 400" | sort -k2 -n -r | head -10
log "OK: $dump restores cleanly"
