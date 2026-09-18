#!/usr/bin/env bash
# Live proof that the switch happens at the POOLER, not the app.
#
# Shows, once a second:
#   (1) SHOW DATABASES  -> the current UPSTREAM branch (host column) + how many
#                          server connections pgbouncer is holding to it. This is
#                          the line switch.sh moves.
#   (2) SHOW SERVERS     -> the live upstream connections (by addr) and state.
#   (3) pg_stat_activity -> how many connections each branch DB is actually
#                          serving right now. Under load you see this migrate
#                          A->B at the switch while the apps never restart.
#
# Run this in one pane; in another, update the after-pgb-upstream secret then run
# `./switch.sh`. Keep the loadgen (or a
# psql loop) running so there is traffic to migrate.
#
# Requires psql + aws on the host. Admin console :6432, branch A :5433, branch B :5434.
set -u
export PGPASSWORD=summit
# floci Secrets Manager (source of truth) — dummy creds, local endpoint. NEVER real AWS.
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
SECRET_ID="${UPSTREAM_SECRET_ID:-after-pgb-upstream}"

count_on() {  # count_on <port>
  psql -h localhost -p "$1" -U summit -d summit -tAc \
    "select count(*) from pg_stat_activity
      where datname='summit' and query not ilike '%pg_stat_activity%'" 2>/dev/null
}

sm_upstream() {  # what the SECRET says the branch is (the source of truth)
  local j
  j=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ID" \
        --query SecretString --output text 2>/dev/null) || { echo "  (secret not found)"; return; }
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$j" | jq -r '"  host=\(.host) port=\(.port) db=\(.dbname)"'
  else  # no jq on the host — pull the fields out with sed
    local host port db
    host=$(printf '%s' "$j" | sed -E 's/.*"host":"([^"]*)".*/\1/')
    port=$(printf '%s' "$j" | sed -E 's/.*"port":"([^"]*)".*/\1/')
    db=$(printf '%s'   "$j" | sed -E 's/.*"dbname":"([^"]*)".*/\1/')
    echo "  host=$host port=$port db=$db"
  fi
}

while true; do
  clear
  echo "==== SOURCE OF TRUTH — Secrets Manager ($SECRET_ID) ===="
  sm_upstream
  echo
  echo "==== current upstream (SHOW DATABASES) — 'host' is the live branch ===="
  psql -h localhost -p 6432 -U summit pgbouncer -x -c "SHOW DATABASES;" 2>/dev/null \
    | grep -E 'name|host|pool_mode|current_connections' | sed 's/^/  /'
  echo
  echo "==== open upstream connections (SHOW SERVERS) ===="
  psql -h localhost -p 6432 -U summit pgbouncer -c "SHOW SERVERS;" 2>/dev/null \
    | awk 'NR==1||NR==2||NR>2{print}' | sed 's/^/  /' | head -8
  echo
  echo "==== connections on each branch DB (pg_stat_activity) ===="
  printf "  BRANCH-A (:5433): %s\n" "$(count_on 5433)"
  printf "  BRANCH-B (:5434): %s\n" "$(count_on 5434)"
  echo
  echo "(Ctrl-C to stop. Update the $SECRET_ID secret in SM, then run ./switch.sh in another pane to adopt it.)"
  sleep 1
done
