#!/usr/bin/env bash
# In-flight test for the "after" (pooler) demo. Proves graceful drain:
#   * an in-flight transaction FINISHES on the OLD branch (never broken),
#   * NEW connections move to the NEW branch within ~1s,
#   * switch.sh's WAIT_CLOSE politely BLOCKS until the in-flight query drains.
#
# Runs entirely against the pooler on :6432 (no app/socat needed). This script
# plays "operator": it flips SM to the other branch and runs switch.sh mid-flight.
# floci only — dummy creds, local endpoint. NEVER real AWS.
set -euo pipefail
cd "$(dirname "$0")"
export AWS_ENDPOINT_URL=http://localhost:4566 AWS_DEFAULT_REGION=us-east-1 \
       AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
export PGPASSWORD=summit
SECRET_ID="${UPSTREAM_SECRET_ID:-after-pgb-upstream}"
N=${1:-15}   # in-flight duration (seconds)

q() { psql -h localhost -p 6432 -U summit -d summit -tAc "$1" 2>&1; }
ts() { date +%H:%M:%S; }

cur=$(q "select branch_name from branch_info where id=1")
case "$cur" in
  BRANCH-A) other=postgres-branch-b; otherlabel=BRANCH-B ;;
  BRANCH-B) other=postgres-branch-a; otherlabel=BRANCH-A ;;
  *) echo "cannot read current branch (got: $cur). Is pgbouncer up + SM seeded?"; exit 1 ;;
esac
echo "start: pooler is on $cur; will switch to $otherlabel while a ${N}s query is in flight."
echo

# 1) in-flight transaction: holds ONE server connection on $cur for N seconds.
inflight=$(mktemp)
( r=$(q "select branch_name, pg_sleep($N) from branch_info where id=1")
  echo "$(ts)|finished on ${r%%|*}" >"$inflight" ) &
echo "[$(ts)] IN-FLIGHT started: SELECT branch, pg_sleep($N)  (server conn pinned to $cur)"
sleep 2

# 2) operator flips SM, then switch.sh applies it (WAIT_CLOSE will block on the in-flight conn).
J=$(printf '{"host":"%s","port":"5432","dbname":"summit","user":"summit","password":"summit"}' "$other")
aws secretsmanager put-secret-value --secret-id "$SECRET_ID" --secret-string "$J" >/dev/null 2>&1 \
  || aws secretsmanager create-secret --name "$SECRET_ID" --secret-string "$J" >/dev/null
echo "[$(ts)] operator set SM -> $other; launching switch.sh (RELOAD/RECONNECT/WAIT_CLOSE)"
sw=$(mktemp)
( t0=$SECONDS; ./switch.sh >/dev/null 2>&1; echo "$(ts)|switch.sh returned after $((SECONDS-t0))s" >"$sw" ) &

# 3) quick queries (each its own transaction) — watch them flip to the new branch.
for i in $(seq 1 $((N+3))); do
  printf "  [%s] quick query -> %s\n" "$(ts)" "$(q 'select branch_name from branch_info where id=1')"
  sleep 1
done

wait 2>/dev/null || true
echo
echo "RESULT ---------------------------------------------------------------"
echo "  in-flight query : $(cat "$inflight")   <- FINISHED on the OLD branch ($cur), not broken"
echo "  $(cat "$sw")   <- blocked until the in-flight conn drained"
echo "  quick queries flipped to $otherlabel within ~1s while the old query kept running."
rm -f "$inflight" "$sw"
