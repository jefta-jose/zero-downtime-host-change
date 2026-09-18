#!/usr/bin/env bash
#
# Continuously probe each ECS service's running task and print which branch it is talking to 

set -u

: "${AWS_ENDPOINT_URL:?set AWS_ENDPOINT_URL, e.g. http://floci:4566}"
CLUSTER="${CLUSTER:?set CLUSTER}"
SERVICES="${SERVICES:?set SERVICES (space-separated service names)}"
PORT="${APP_PORT:-8080}"
INTERVAL="${INTERVAL:-0.5}"
PROBE_PATH="${PROBE_PATH:-/db-info}"

aws_ecs() { aws --endpoint-url "$AWS_ENDPOINT_URL" ecs "$@"; }

# Echo a reachable address for the service's running task, or "" if none.
# On floci that address is the spawned task container's DNS name,
# floci-ecs-<taskId>-<containerName>, resolvable over the shared Docker network.
resolve_host() {
  local svc="$1" arn taskid cname
  arn=$(aws_ecs list-tasks --cluster "$CLUSTER" --service-name "$svc" \
        --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null)
  if [ -z "$arn" ] || [ "$arn" = "None" ]; then echo ""; return; fi
  # taskId is the last ARN path segment; the container name comes from the task.
  taskid="${arn##*/}"
  cname=$(aws_ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" \
          --query 'tasks[0].containers[0].name' --output text 2>/dev/null)
  if [ -z "$cname" ] || [ "$cname" = "None" ]; then echo ""; return; fi
  echo "floci-ecs-${taskid}-${cname}"
}

echo "loadgen -> cluster=$CLUSTER services=[$SERVICES] port=$PORT path=$PROBE_PATH interval=${INTERVAL}s"
while true; do
  ts=$(date +%H:%M:%S.%3N)
  for svc in $SERVICES; do
    host=$(resolve_host "$svc")
    if [ -z "$host" ] || [ "$host" = "None" ]; then
      printf '%s  %-26s  NO-RUNNING-TASK\n' "$ts" "$svc"
      continue
    fi
    start=$(date +%s%3N)
    body=$(curl -s -m 2 "http://$host:$PORT$PROBE_PATH" 2>/dev/null); rc=$?
    ms=$(( $(date +%s%3N) - start ))
    if [ $rc -ne 0 ] || [ -z "$body" ]; then
      printf '%s  %-26s  ERR(rc=%s) addr=%s %dms\n' "$ts" "$svc" "$rc" "$host" "$ms"
    else
      branch=$(echo "$body" | jq -r '.branch // .error // "?"' 2>/dev/null)
      printf '%s  %-26s  OK branch=%-8s addr=%s %dms\n' "$ts" "$svc" "$branch" "$host" "$ms"
    fi
  done
  sleep "$INTERVAL"
done
