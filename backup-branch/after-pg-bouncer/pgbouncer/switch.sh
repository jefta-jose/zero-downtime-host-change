#!/usr/bin/env bash
# Gracefully apply whatever branch Secrets Manager currently points at.
#
#   ./switch.sh
#
# This does NOT change Secrets Manager. You update the `after-pgb-upstream` secret
# yourself first (aws cli / console / IaC); this script only makes the RUNNING
# pgbouncer adopt it, with no dropped app connections:
#   1. render-from-sm.sh -> pgbouncer re-reads the secret and rewrites its upstream
#   2. RELOAD/RECONNECT/WAIT_CLOSE -> adopt it + drain the old branch's conns
#
# The apps stay pinned to host "pgbouncer" and are NOT redeployed — same task IDs
# throughout. Contrast with ../../before-pg-bouncer, where a switch force-redeploys
# both apps and drops every connection.
#
# floci only — dummy creds, local endpoint. NEVER real AWS.
set -euo pipefail
cd "$(dirname "$0")"

export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
SECRET_ID="${UPSTREAM_SECRET_ID:-after-pgb-upstream}"

if ! docker ps --format '{{.Names}}' | grep -qx pgbouncer; then
  echo "pgbouncer is not running; nothing to switch." >&2
  exit 1
fi

# Best-effort: show what SM says now (the container re-reads it authoritatively).
sm=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
       --query SecretString --output text 2>/dev/null || true)
if [ -n "$sm" ]; then
  target=$(printf '%s' "$sm" | sed -E 's/.*"host":"([^"]*)".*/\1/')
  echo "Secrets Manager currently says upstream = ${target}"
else
  echo "(could not read SM from host — pgbouncer will read it directly)"
fi

echo "1) pgbouncer re-reads SM (render-from-sm.sh)"
docker exec pgbouncer /usr/local/bin/render-from-sm.sh

echo "2) RELOAD / RECONNECT / WAIT_CLOSE"
#   RELOAD     -> new server connections use the branch SM now names
#   RECONNECT  -> close each old-branch server conn as soon as it is released
#                 (transaction mode = end of the current query, so ~instant)
#   WAIT_CLOSE -> block until the old-branch conns are actually gone (no split)
PGPASSWORD=summit psql -h localhost -p 6432 -U summit pgbouncer \
  -c "RELOAD;" -c "RECONNECT;" -c "WAIT_CLOSE;"

echo
echo "graceful switch applied${target:+ -> $target}. The apps were NOT redeployed."
echo "Watch the loadgen keep returning OK while the branch flips, and watch-pool.sh"
echo "show SM + the live upstream + the connection count move."
