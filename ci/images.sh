#!/usr/bin/env bash
# Every container image the chart can run, with the licence of what it
# ships. A new image must be added here, with its licence checked in its
# own LICENSE file; anything not on this list fails the check.
set -euo pipefail
cd "$(dirname "$0")/.."
allowed=(
  "ghcr.io/ortus-sovereign-cloud/ortus MIT OR Apache-2.0 (a static program on scratch)"
  "rustfs/rustfs Apache-2.0"
  "amazon/aws-cli Apache-2.0"
)
values=(
  ""
  "--set database.mode=external --set database.external.existingSecret=db --set files.mode=external --set files.external.endpoint=http://s3 --set files.external.existingSecret=s3"
)
found=""
for v in "${values[@]}"; do
  # shellcheck disable=SC2086
  found+="$(helm template t charts/ortus $v | sed -n 's/^ *image: *"\{0,1\}\([^":]*\).*/\1/p')"$'\n'
done
status=0
while read -r image; do
  [ -n "$image" ] || continue
  ok=no
  for entry in "${allowed[@]}"; do
    [ "${entry%% *}" = "$image" ] && ok=yes
  done
  if [ "$ok" = no ]; then echo "images: $image is not on the allowed list" >&2; status=1; fi
done <<< "$(sort -u <<< "$found")"
# The CloudNativePG operator (Apache-2.0) is installed separately, not by this chart.
[ "$status" = 0 ] && echo "images: every image is on the allowed list"
exit "$status"
