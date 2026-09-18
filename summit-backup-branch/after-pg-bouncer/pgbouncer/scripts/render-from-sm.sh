#!/usr/bin/env bash
# Render pgbouncer's [databases] upstream FROM Secrets Manager.
#
# Reads the JSON secret {host,port,dbname,user,password} and rewrites the single
# `summit = ...` line in /etc/pgbouncer/pgbouncer.ini. Called by the entrypoint on
# boot and by switch.sh (via `docker exec`) on every branch switch, so the secret
# is always the source of truth. This does NOT reload pgbouncer — the caller sends
# RELOAD afterwards.
set -euo pipefail

ini=/etc/pgbouncer/pgbouncer.ini
SECRET_ID="${UPSTREAM_SECRET_ID:-after-pgb-upstream}"
ENDPOINT="${AWS_ENDPOINT_URL:-http://floci:4566}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# aws-cli v1 (alpine) does not honour AWS_ENDPOINT_URL, so pass it explicitly.
aws_sm() { aws --endpoint-url "$ENDPOINT" --region "$REGION" secretsmanager "$@"; }

# floci's SM may not be ready the instant this container starts; retry briefly.
json=""
for i in $(seq 1 30); do
  if json=$(aws_sm get-secret-value --secret-id "$SECRET_ID" --query SecretString --output text 2>/dev/null); then
    [ -n "$json" ] && break
  fi
  echo "render-from-sm: waiting for secret '$SECRET_ID' in SM ($i/30)..."
  sleep 2
done
[ -n "$json" ] || { echo "render-from-sm: could not read secret '$SECRET_ID' from $ENDPOINT" >&2; exit 1; }

host=$(printf '%s' "$json" | jq -r '.host')
port=$(printf '%s' "$json" | jq -r '.port')
dbname=$(printf '%s' "$json" | jq -r '.dbname')
user=$(printf '%s' "$json" | jq -r '.user')
password=$(printf '%s' "$json" | jq -r '.password')

line="summit = host=${host} port=${port} dbname=${dbname} user=${user} password=${password}"
sed -i -E "s|^summit = .*|${line}|" "$ini"

echo "render-from-sm: upstream <- SM  (host=${host} port=${port} dbname=${dbname})"
