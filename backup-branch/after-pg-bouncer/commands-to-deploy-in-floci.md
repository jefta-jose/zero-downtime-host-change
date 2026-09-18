# Deploy & switch — the "after pgbouncer" demo

This is the counterpart to `../before-pg-bouncer`. Same apps, same two branch DBs.
The difference: a **PgBouncer** pooler sits between the apps and the DBs, and the
current branch lives in **Secrets Manager**. A switch updates the secret; pgbouncer
re-reads it and reloads — the apps are never redeployed.

## What we're building (read this first)

There are **two secrets**, and that separation is the whole design:

- **`after-pgb-mrk`** (app-facing) — `DB_HOST=pgbouncer`, `DB_PORT=6432`. Set once,
  **never touched by a switch**. This is why the apps never redeploy.
- **`after-pgb-upstream`** (pooler-facing) — `{host,port,dbname,user,password}` for
  the **current branch**. This is the **source of truth** for which branch is live.
  A switch writes here.

PgBouncer **reads `after-pgb-upstream` from Secrets Manager** (on boot, and again on
each switch) and renders its `[databases]` upstream from it. Nothing in the repo is
the truth — the secret is.

```
   after-pgb-mrk (app secret)                 after-pgb-upstream (SOURCE OF TRUTH)
   DB_HOST = pgbouncer  ── never moves          { host: postgres-branch-a, ... }
                 │                                          │  switch.sh writes it
      ┌──────────┴──────────┐                               │
   [ js task ]        [ dotnet task ]                       ▼
      │                    │                    pgbouncer reads SM on boot + reload
      └───────► pgbouncer:6432 ◄────────┐  ── renders [databases] from the secret
                     │  STABLE endpoint  │
                     ▼
      ┌──────────────┴───────────────┐
   postgres-branch-a (:5433)   postgres-branch-b (:5434)
```

**Two separate concerns:** *you* change the branch in Secrets Manager; `switch.sh`
only gracefully applies whatever SM currently says. `switch.sh` never writes the
secret. End to end: update `after-pgb-upstream` in SM → `./switch.sh` →
`docker exec pgbouncer render-from-sm.sh` (re-reads SM) → `RELOAD; RECONNECT; WAIT_CLOSE`.
Apps untouched.

**Before vs after — the whole point:**

| | before-pg-bouncer | after-pg-bouncer |
|---|---|---|
| Source of truth for branch | the app secret | the `-upstream` secret (read by pgbouncer) |
| App's DB_HOST | a branch (changes on switch) | `pgbouncer` (never changes) |
| A switch means | edit app secret + **redeploy both apps** | update `-upstream` secret + pgbouncer RELOAD (**no app redeploy**) |
| App tasks | get new task IDs, restart | same task IDs, stay up |
| Loadgen during switch | `NO-RUNNING-TASK` / `ERR` gap = downtime | continuous `OK`, branch just flips |
| In-flight query | killed when task is torn down | finishes, then upstream moves |

> **Local note:** the upstream here is plain Postgres, not Neon/Lakebase. So the
> Neon **SNI / endpoint-in-password / SCRAM-downgrade** gotcha (research doc §3)
> does **not** apply — the secret just carries `host=<branch>`. On real Lakebase
> that secret would carry the `endpoint=<id>$<pw>` token. Everything else (secret
> as source of truth, the stable endpoint, RELOAD/RECONNECT, no app redeploy) is
> faithful. Locally pgbouncer reads SM with floci admin creds; in real AWS the
> pgbouncer task role would hold `GetSecretValue` on the `-upstream` secret.

`pool_mode = transaction` here so a switch drains within one query — that is what
makes the migration visible in seconds (see `pgbouncer/conf/pgbouncer.ini`).

---

## 0. Point your shell at floci (once per terminal)

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
aws sts get-caller-identity        # expect Account 000000000000
```

## 1. Start the two branch databases

Reuse the same DBs as the "before" demo (skip if they're already up):

```bash
cd ../before-pg-bouncer/postgres
docker compose -f docker-compose.db.yaml up -d
cd -
```

## 2. Backend images

The app is unchanged, so **reuse the images from the before demo**
(`localhost:5100/before-pgb-js:latest`, `...dotnet:latest`). If they aren't in the
registry yet, build+push them per `../before-pg-bouncer/commands-to-deploy-in-floci.md` §2.

## 3. Terraform apply (creates the secrets first)

```bash
cd terraform && terraform init && terraform apply -auto-approve && cd ..
```

Creates the `after-pgb` cluster, IAM role, the two Fargate services, and **both
secrets**:
- `after-pgb-mrk` — app secret (`DB_HOST=pgbouncer`, `DB_PORT=6432`), never touched by a switch.
- `after-pgb-upstream` — the branch pointer, initialised to `postgres-branch-a`. **pgbouncer reads this next.**

Apply this *before* starting pgbouncer so the secret exists when pgbouncer boots.
(The app tasks come up now and briefly can't reach the pooler — that's fine, they
retry and heal once pgbouncer is up in §4. Nothing is watching yet.)

## 4. Build & start PgBouncer (reads the secret)

```bash
cd pgbouncer
docker compose -f docker-compose.pgb.yaml up -d --build
# sanity: query THROUGH the pooler (expect BRANCH-A — the value pgbouncer read from SM)
PGPASSWORD=summit psql -h localhost -p 6432 -U summit -d summit -tAc \
  "select branch_name from branch_info where id=1"
cd ..
```

The entrypoint reads `after-pgb-upstream` from floci's Secrets Manager and renders
its upstream from it. `pgbouncer` is now a stable name on `floci-docker-network`
(the apps use it) and is published to your host on `6432` (admin console + switch/watch).
Confirm the app tasks are running:

```bash
aws ecs list-tasks --cluster after-pgb-cluster --desired-status RUNNING
```

## 5. Reach a backend from your host (optional)

Tasks still have no published port. Same socat bridge as before, but note it points
at the app task — and here the app task **does not change on a switch**, so you set
it up once:

```bash
JS=$(docker ps --format '{{.CreatedAt}}\t{{.Names}}' | grep 'floci-ecs.*-js$' | sort -r | head -1 | cut -f2)
docker rm -f pgb-proxy-js 2>/dev/null
docker run -d --name pgb-proxy-js --network floci-docker-network -p 8080:8080 \
  alpine/socat TCP-LISTEN:8080,fork,reuseaddr TCP:$JS:8080
curl localhost:8080/db-info
```

## 6. Watch it live

Two panes:

```bash
# pane 1 — load generator (same one as before; app is unchanged)
cd client && docker compose -f docker-compose.client.yaml up --build

# pane 2 — the pooler view: the SM secret (source of truth), the live upstream,
#          and per-branch connection counts
cd pgbouncer && ./watch-pool.sh
```

## 7. The switch (A ↔ B) — no redeploy

Two steps, two concerns. **Step 1 — you change Secrets Manager** to the branch you
want (aws cli, console, or IaC):

```bash
export AWS_ENDPOINT_URL=http://localhost:4566 AWS_DEFAULT_REGION=us-east-1 \
       AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test
aws secretsmanager put-secret-value --secret-id after-pgb-upstream \
  --secret-string '{"host":"postgres-branch-b","port":"5432","dbname":"summit","user":"summit","password":"summit"}'
#   branch-a: set "host":"postgres-branch-a"
```

**Step 2 — `switch.sh` gracefully applies it** (it does *not* touch SM):

```bash
cd pgbouncer
./switch.sh
```

It has pgbouncer re-read the secret (`render-from-sm.sh`) and runs
`RELOAD; RECONNECT; WAIT_CLOSE;`. What you'll see:

- **loadgen (pane 1):** keeps printing `OK`, branch flips `BRANCH-A` → `BRANCH-B`.
  **No `NO-RUNNING-TASK` gap** — the apps never restarted.
- **watch-pool (pane 2), top to bottom:** the **SM** line flips to
  `host=postgres-branch-b` first (the source of truth changed), then `SHOW DATABASES`
  `host` follows it, then the connection count moves from BRANCH-A to BRANCH-B.

Rollback is symmetric: point the secret back at `postgres-branch-a` and run
`./switch.sh` again.

> The apps' task IDs are unchanged before and after — confirm with
> `aws ecs list-tasks --cluster after-pgb-cluster` around a switch.

## 8. Teardown

```bash
docker rm -f pgb-proxy-js 2>/dev/null
cd terraform && terraform destroy -auto-approve && cd ..
docker compose -f pgbouncer/docker-compose.pgb.yaml down
docker compose -f client/docker-compose.client.yaml down
# leave the branch DBs if you'll reuse them, or:
# docker compose -f ../before-pg-bouncer/postgres/docker-compose.db.yaml down -v
```
