#!/usr/bin/env bash
#
# Watch server-side connections on a branch DB from the HOST, so you can see the
# backends' pooled connections and any in-flight /slow queries -- and watch them
# get cut on the old branch and reappear on the new branch during a switch.
#
# Requires psql on the host. Branch A is published on :5433, branch B on :5434.
#
#   ./watch-connections.sh a     # watch BRANCH-A (blue)
#   ./watch-connections.sh b     # watch BRANCH-B (green)
set -u

branch="${1:-a}"
port=5433
[ "$branch" = "b" ] && port=5434

export PGPASSWORD=summit
QUERY="SELECT pid, state, application_name AS app, backend_start,
              substring(query,1,45) AS query
         FROM pg_stat_activity
        WHERE datname='summit'
          AND query NOT ILIKE '%pg_stat_activity%'
        ORDER BY backend_start;"

echo "Watching BRANCH-${branch^^} on localhost:${port} (Ctrl-C to stop)"
watch -n1 "psql -h localhost -p ${port} -U summit -d summit -c \"${QUERY}\""
