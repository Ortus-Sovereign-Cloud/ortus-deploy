#!/usr/bin/env bash
# Every check CI runs, in the same order. Run it before each push. The
# chart test needs Docker and k3d; it makes and deletes its own cluster.
set -euo pipefail
cd "$(dirname "$0")/.."
for script in ci/*.sh; do bash -n "$script"; done
if command -v shellcheck >/dev/null; then shellcheck -S warning ci/*.sh; fi
helm lint --strict charts/ortus
# Every combination of storage renders, and wrong settings are refused.
helm template t charts/ortus >/dev/null
helm template t charts/ortus --set database.mode=external --set database.external.existingSecret=db \
  --set files.mode=external --set files.external.endpoint=http://s3 --set files.external.existingSecret=s3 >/dev/null
helm template t charts/ortus --set web.ingress.enabled=true --set web.ingress.tlsSecret=tls --set backup.enabled=false \
  --set roles.mail.enabled=false --set roles.media.enabled=false >/dev/null
if helm template t charts/ortus --set database.mode=external >/dev/null 2>&1; then
  echo "check: an external database without a secret must be refused" >&2; exit 1
fi
if helm template t charts/ortus --set files.mode=elsewhere >/dev/null 2>&1; then
  echo "check: an unknown files.mode must be refused" >&2; exit 1
fi
# Mail and call media are reachable: their Services on the standard ports
# (465 and 993 only with a certificate), the public address and extra
# settings reach every container.
mailed="$(helm template t charts/ortus --set roles.mail.tlsSecret=mx --set roles.media.publicAddress=203.0.113.7:40000 --set publicUrl=https://ortus.example.org --set 'extraEnv[0].name=ORTUS_TRUSTED_PROXIES' --set 'extraEnv[0].value=10.0.0.0/8')"
for want in 'name: t-mail$' 'port: 25, targetPort: smtp' 'port: 993, targetPort: imaps' 'name: t-media$' 'protocol: UDP' 'value: "203.0.113.7:40000"' 'value: "https://ortus.example.org"' 'name: ORTUS_TRUSTED_PROXIES'; do
  grep -q -- "$want" <<<"$mailed" || { echo "check: the chart does not render $want" >&2; exit 1; }
done
if helm template t charts/ortus | grep -q 'port: 993'; then echo "check: 993 needs a certificate" >&2; exit 1; fi
# Restore points go to the files store (never a pod's own disk); call
# signalling is on the pod's address; DAV has a port; the TURN relay
# renders only when it is on and needs its address.
whole="$(helm template t charts/ortus)"
for want in 'name: ORTUS_BACKUP_S3_ROOT' 'value: "restore-points"' 'value: "http://$(POD_IP):7979"' 'name: dav' 'tcpSocket: {port: smtp}'; do
  grep -qF -- "$want" <<<"$whole" || { echo "check: the chart does not render $want" >&2; exit 1; }
done
grep -q 'ORTUS_TURN_LISTEN' <<<"$whole" && { echo "check: TURN must be off by default" >&2; exit 1; }
turned="$(helm template t charts/ortus --set roles.media.turn.enabled=true --set roles.media.turn.url=turns:turn.example.org:443?transport=tcp)"
for want in 'name: t-turn' 'value: "turns:turn.example.org:443?transport=tcp"'; do
  grep -qF -- "$want" <<<"$turned" || { echo "check: the chart does not render $want" >&2; exit 1; }
done
if helm template t charts/ortus --set roles.media.turn.enabled=true >/dev/null 2>&1; then
  echo "check: a TURN relay without its address must be refused" >&2; exit 1
fi
migrating="$(helm template t charts/ortus)"
for want in 'helm.sh/hook: pre-upgrade' 'args: ["migrate"]'; do
  grep -qF -- "$want" <<<"$migrating" || { echo "check: the migrate job does not render $want" >&2; exit 1; }
done
external="$(helm template t charts/ortus --set restorePoints.external.endpoint=https://s3.other.example --set restorePoints.external.bucket=points --set restorePoints.external.existingSecret=points-keys)"
grep -qF 'value: "https://s3.other.example"' <<<"$external" || { echo "check: restore points elsewhere do not render" >&2; exit 1; }

# Every workload reads the one master key; a named secret replaces the made one.
rendered="$(helm template t charts/ortus)"
workloads=$(( $(grep -c '^kind: \(Deployment\|CronJob\)' <<<"$rendered") + $(grep -c '^  name: .*-migrate$' <<<"$rendered") ))
keyed=$(grep -c 'name: ORTUS_SECRETS_KEY' <<<"$rendered")
[ "$workloads" -ge 1 ] && [ "$keyed" -eq "$workloads" ] || { echo "check: $keyed of $workloads workloads get ORTUS_SECRETS_KEY" >&2; exit 1; }
grep -q 'name: t-secrets$' <<<"$rendered" || { echo "check: the master key secret is not made" >&2; exit 1; }
if helm template t charts/ortus --set secrets.existingSecret=mine | grep -q 'name: t-secrets$'; then
  echo "check: secrets.existingSecret must replace the made secret" >&2; exit 1
fi
# No GPL, AGPL, LGPL or MPL in what the chart runs: every image is listed
# here with its licence, and an image not in the list fails the check.
ci/images.sh
ci/chart-test.sh
echo "all checks passed"
