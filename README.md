# ortus-deploy

The Kubernetes chart for Ortus: the same program as the one-machine install, one workload per role (web, worker, mail, media).

Part of Ortus, a sovereign workspace for organisations and governments: mail, calendar, files, documents, chat, calls, tasks and approvals that an organisation runs itself.

Status: early development, not ready for use.

## Installing

The bundled database is a CloudNativePG cluster, so install the CloudNativePG operator once per cluster first:

```sh
helm install cnpg cloudnative-pg --repo https://cloudnative-pg.github.io/charts -n cnpg-system --create-namespace
helm install ortus charts/ortus -n ortus --create-namespace
```

| Setting | Default | What it does |
| --- | --- | --- |
| `database.mode` | `bundled` | `bundled`: a CloudNativePG cluster made by the chart. `external`: your PostgreSQL; set `database.external.existingSecret` to a secret with the URL under `url`. |
| `files.mode` | `bundled` | `bundled`: RustFS in the cluster. `external`: your S3 store; set `files.external.endpoint` and `files.external.existingSecret` (keys `access_key`, `secret_key`). The bucket (`files.bucket`) is made when missing. |
| `roles.<role>.replicas` | web 2, others 1 | How many of each workload. `roles.mail.enabled` and `roles.media.enabled` turn those roles off. |
| `web.ingress.*` | off | An Ingress for the web role. |
| `backup.*` | on, 03:15, keep 7 | A CronJob running `ortus backup --into` onto its own volume. Backups restore into the one-machine install too. |

With `helm --wait`, a storage class that binds volumes on first use (as most local ones do) keeps the backup volume pending until the first backup runs, so the install waits for its timeout; leave out `--wait` and check `kubectl rollout status` instead, or turn backups off.

**Upgrades and rollbacks.** Every program brings the database up to date when it starts; a program refuses a database newer than it knows. So `helm rollback` after an upgrade that changed the database leaves the older pods crash-looping: to go back, restore the backup taken before the upgrade into an empty database. Take one (`kubectl create job --from=cronjob/<release>-backup before-upgrade`) before every upgrade.

**GitOps.** Tools that render the chart without a cluster (Argo CD, Flux) cannot see the generated S3 keys of the bundled RustFS and would make new ones on every sync: set `files.bundled.existingSecret` to a secret you made (keys `access_key`, `secret_key`).

Every pod runs as a non-root user with a read-only root file system and no capabilities. The Ortus image holds one static program and nothing else.

## Checks

`ci/check.sh` runs every check CI runs: lint, every combination of settings, the image licence list (`ci/images.sh`) and `ci/chart-test.sh`, which installs the chart on a throwaway k3d cluster with its own kubeconfig, in both storage modes, upgrades it and takes a backup.

## Licence

Licensed under either of the Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE)) or the MIT license ([LICENSE-MIT](LICENSE-MIT)), at your option.

Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in this work, as defined in the Apache-2.0 licence, shall be dual licensed as above, without any additional terms or conditions.
