#!/usr/bin/env bash
# Installs the chart on a throwaway k3d cluster and checks both shapes of
# storage: bundled (CloudNativePG + RustFS) and external (a PostgreSQL and
# an S3 store run beside it). Then an upgrade and a backup by the CronJob.
#
# The cluster gets its own kubeconfig in a temporary directory; this script
# never reads or writes ~/.kube and refuses any cluster that is not the one
# it made. It deletes the cluster at the end.
#
# The image: ORTUS_IMAGE (already in the local Docker) or, without it, one
# built from the ortus commit in pins.toml.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$(pwd)"
cluster="ortus-chart-test-$$"
work="$(mktemp -d)"
export KUBECONFIG="$work/kubeconfig"
unset KUBECONTEXT HELM_KUBECONTEXT

cleanup() {
  k3d cluster delete "$cluster" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

log() { echo "chart-test: $*"; }

image="${ORTUS_IMAGE:-}"
if [ -z "$image" ]; then
  rev="$(sed -n 's/^ortus = "\([0-9a-f]\{40\}\)"$/\1/p' pins.toml)"
  [ -n "$rev" ] || { echo "chart-test: no ortus pin in pins.toml" >&2; exit 1; }
  src="$root/.deps/ortus"
  if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" remote add origin https://github.com/Ortus-Sovereign-Cloud/ortus.git
  fi
  git -C "$src" fetch -q --depth 1 origin "$rev"
  git -C "$src" checkout -q --force "$rev"
  image="ortus:${rev:0:12}"
  log "building $image"
  "$src/ci/image.sh" ortus "$image" >/dev/null
fi
repo="${image%:*}"
tag="${image##*:}"

log "creating cluster $cluster"
k3d cluster create "$cluster" --no-lb --wait --timeout 180s \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false \
  --k3s-arg "--disable=traefik@server:0" \
  --k3s-arg "--kubelet-arg=eviction-hard=imagefs.available<1%,nodefs.available<1%@server:0" \
  --k3s-arg "--kubelet-arg=eviction-minimum-reclaim=imagefs.available=1%,nodefs.available=1%@server:0" >/dev/null
# (The eviction limits are lowered because a big, busy build disk would
# otherwise taint the node for "disk pressure" before anything starts.)
k3d kubeconfig get "$cluster" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"
# Refuse to go on unless the only context is the cluster made here.
[ "$(kubectl config get-contexts -o name)" = "k3d-$cluster" ] || { echo "chart-test: unexpected kubeconfig" >&2; exit 1; }
server="$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}')"
case "$server" in
  https://0.0.0.0:*|https://127.0.0.1:*|https://localhost:*|https://host.docker.internal:*) ;;
  *) echo "chart-test: $server is not a local cluster" >&2; exit 1 ;;
esac
k() { kubectl --kubeconfig "$KUBECONFIG" --context "k3d-$cluster" "$@"; }
h() { helm --kubeconfig "$KUBECONFIG" --kube-context "k3d-$cluster" "$@"; }

k3d image import -c "$cluster" "$image" >/dev/null

log "installing the CloudNativePG operator"
h install cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts --version 0.29.2 \
  -n cnpg-system --create-namespace --wait --timeout 5m >/dev/null

common=(--set "image.repository=$repo" --set "image.tag=$tag" --set image.pullPolicy=Never
  --set roles.web.replicas=1 --set database.bundled.storage=1Gi --set files.bundled.storage=1Gi
  --set backup.storage=1Gi)

health() {
  local ns="$1" release="$2" port
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
  k -n "$ns" port-forward "svc/$release-web" "$port:80" >"$work/pf.log" 2>&1 &
  local pf=$!
  local body=""
  for _ in $(seq 60); do
    body="$(curl -fsS "http://127.0.0.1:$port/api/v1/health" 2>/dev/null || true)"
    [ -n "$body" ] && break
    sleep 1
  done
  kill "$pf" 2>/dev/null || true
  wait "$pf" 2>/dev/null || true
  case "$body" in *'"status":"ok"'*) log "$ns/$release answers: $body" ;; *) echo "chart-test: $ns/$release does not answer" >&2; k -n "$ns" get pods >&2; exit 1 ;; esac
}

roles_up() {
  local ns="$1" release="$2"
  for role in web worker mail media; do
    k -n "$ns" rollout status "deploy/$release-$role" --timeout 5m >/dev/null
  done
  log "$ns/$release: web, worker, mail and media are running"
}

backup() {
  local ns="$1" release="$2" job="$2-backup-test-$RANDOM"
  k -n "$ns" create job "$job" --from="cronjob/$release-backup" >/dev/null
  k -n "$ns" wait --for=condition=complete "job/$job" --timeout 5m >/dev/null || { k -n "$ns" logs "job/$job" >&2; exit 1; }
  local out
  out="$(k -n "$ns" logs "job/$job")"
  case "$out" in *"backup of postgres"*) log "$ns/$release backup: $out" ;; *) echo "chart-test: backup said: $out" >&2; exit 1 ;; esac
}

dump_on_failure() {
  local status=$?
  if [ "$status" != 0 ]; then
    k get pods,jobs,pvc -A >&2 || true
    k get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -30 >&2 || true
    for ns in ortus ortus-ext; do
      for pod in $(k -n "$ns" get pods -o name 2>/dev/null); do
        echo "--- $ns $pod" >&2
        k -n "$ns" logs "$pod" --tail 30 >&2 || true
      done
    done
  fi
  cleanup
}
trap dump_on_failure EXIT

# No --wait: Helm would wait for the backup volume to be bound, which a
# storage class that binds on first use does only when the first backup
# runs. Each role's rollout is checked instead; Helm still waits for the
# bucket job.
log "bundled storage: install"
h install ortus charts/ortus -n ortus --create-namespace "${common[@]}" --timeout 10m >/dev/null
roles_up ortus ortus
health ortus ortus
backup ortus ortus
secret_before="$(k -n ortus get secret ortus-files -o jsonpath='{.data.secret_key}')"

log "bundled storage: upgrade"
h upgrade ortus charts/ortus -n ortus "${common[@]}" --set roles.web.replicas=2 --timeout 10m >/dev/null
roles_up ortus ortus
[ "$(k -n ortus get deploy ortus-web -o jsonpath='{.status.readyReplicas}')" = 2 ]
[ "$(k -n ortus get secret ortus-files -o jsonpath='{.data.secret_key}')" = "$secret_before" ] || { echo "chart-test: the upgrade changed the file store keys" >&2; exit 1; }
health ortus ortus
backup ortus ortus

log "external storage: PostgreSQL and S3 beside the chart"
k create namespace ortus-ext >/dev/null
k -n ortus-ext apply -f - >/dev/null <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: pg}
spec:
  selector: {matchLabels: {app: pg}}
  template:
    metadata: {labels: {app: pg}}
    spec:
      containers:
        - name: pg
          image: postgres:17-alpine
          env: [{name: POSTGRES_PASSWORD, value: extpass}, {name: POSTGRES_DB, value: ortus}]
          ports: [{containerPort: 5432}]
          readinessProbe: {exec: {command: [pg_isready, -U, postgres]}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: pg}
spec: {selector: {app: pg}, ports: [{port: 5432}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: s3}
spec:
  selector: {matchLabels: {app: s3}}
  template:
    metadata: {labels: {app: s3}}
    spec:
      containers:
        - name: s3
          image: rustfs/rustfs:1.0.6
          env: [{name: RUSTFS_ACCESS_KEY, value: extaccess}, {name: RUSTFS_SECRET_KEY, value: extsecret123}]
          ports: [{containerPort: 9000}]
          readinessProbe: {tcpSocket: {port: 9000}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata: {name: s3}
spec: {selector: {app: s3}, ports: [{port: 9000}]}
---
apiVersion: v1
kind: Secret
metadata: {name: ext-db}
stringData: {url: "postgres://postgres:extpass@pg:5432/ortus"}
---
apiVersion: v1
kind: Secret
metadata: {name: ext-s3}
stringData: {access_key: extaccess, secret_key: extsecret123}
EOF
k -n ortus-ext rollout status deploy/pg --timeout 5m >/dev/null
k -n ortus-ext rollout status deploy/s3 --timeout 5m >/dev/null
h install ortus-ext charts/ortus -n ortus-ext "${common[@]}" \
  --set database.mode=external --set database.external.existingSecret=ext-db \
  --set files.mode=external --set files.external.endpoint=http://s3:9000 --set files.external.existingSecret=ext-s3 \
  --timeout 10m >/dev/null
roles_up ortus-ext ortus-ext
health ortus-ext ortus-ext
backup ortus-ext ortus-ext
[ -z "$(k -n ortus-ext get statefulset,cluster.postgresql.cnpg.io -o name 2>/dev/null)" ] || { echo "chart-test: external mode made its own storage" >&2; exit 1; }

log "passed"
