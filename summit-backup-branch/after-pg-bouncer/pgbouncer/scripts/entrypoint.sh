#!/usr/bin/env bash
# Boot: render the upstream from Secrets Manager, then run pgbouncer on it.
# pgbouncer re-reads this same file on RELOAD, so switch.sh only has to re-render
# + RELOAD — no restart, no dropped client connections.
set -euo pipefail

# Render as root (needs to write the ini + reach SM), then drop to the pgbouncer
# user to actually run the daemon (pgbouncer refuses to run as root).
/usr/local/bin/render-from-sm.sh

echo "entrypoint: starting pgbouncer as user postgres"
exec su-exec postgres pgbouncer /etc/pgbouncer/pgbouncer.ini
