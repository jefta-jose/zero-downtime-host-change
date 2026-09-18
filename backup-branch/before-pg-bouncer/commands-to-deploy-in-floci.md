# Deploy & switch — the "before pgbouncer" demo

## What we're building (read this first)

Two backends (Node `js`, .NET `dotnet`) each connect to Postgres through a pool
that **freezes the DB host when the process starts**. The DB host comes from a
shared Secrets Manager secret (`before-pgb-mrk`). There are **two databases that
already exist** — `postgres-branch-a` and `postgres-branch-b` — and "switching a
branch" means: repoint the secret's `DB_HOST` at one of those two, then redeploy
the apps so they re-read it.

```
        secret before-pgb-mrk
        DB_HOST = postgres-branch-a   ← switch flips this to -a OR -b
                 │
      ┌──────────┴──────────┐
   [ js task ]          [ dotnet task ]     (ECS/Fargate, port 8080)
      │                     │
      └───────── DB_HOST ───┴──────────┐
                                       ▼
        postgres-branch-a (:5433)   postgres-branch-b (:5434)   ← the ONLY valid hosts
```

> ⚠️ **The switch target must be `postgres-branch-a` or `postgres-branch-b` — nothing else.**
> Setting `DB_HOST` to any other value makes the apps come up but fail to find a
> DB (`Name or service not known`). That's not a floci bug, just a bad host.

The whole point of the demo: because the host is frozen at startup, a switch
**forces a full redeploy** and drops in-flight connections. That downtime is what
the next phase (`../after-pg-bouncer/`, a PgBouncer pooler) removes.

## The one floci quirk to keep in mind

floci fakes AWS by running each "Fargate task" as a **plain Docker container** on
the shared network `floci-docker-network`. Two consequences:

- It **renames** things: a task becomes a container called
  `floci-ecs-<taskId>-<containerName>` (e.g. `floci-ecs-9a3f…-js`). The `-js` /
  `-dotnet` suffix is your task-def container name; floci adds the rest. The
  `<taskId>` changes on **every deployment**.
- It **doesn't publish a host port**, so you can't hit `localhost:8080` directly —
  you reach tasks from *inside* that network (see step 4).

---

## 0. Point your shell at floci (once per terminal)

```bash
export AWS_ENDPOINT_URL=http://localhost:4566
export AWS_DEFAULT_REGION=us-east-1
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
aws sts get-caller-identity        # expect Account 000000000000
```

floci console (UI) is at **http://localhost:4500** — we use it to edit the secret later.

## 1. Start the two branch databases

```bash
cd postgres
docker compose -f docker-compose.db.yaml up -d
docker exec postgres-branch-a psql -U summit -d summit -c "SELECT branch_name FROM branch_info;"  # BRANCH-A
docker exec postgres-branch-b psql -U summit -d summit -c "SELECT branch_name FROM branch_info;"  # BRANCH-B
cd ..
```

## 2. Build & push the backend images

floci pulls task images from its registry published at `localhost:5100`.

```bash
docker build -t localhost:5100/before-pgb-js:latest .
docker push localhost:5100/before-pgb-js:latest

docker build -t localhost:5100/before-pgb-dotnet:latest .
docker push localhost:5100/before-pgb-dotnet:latest

curl -s http://localhost:5100/v2/_catalog     # both repos should be listed
```

Both backends serve on port **8080**:

| Endpoint              | What it tells you                                        |
|-----------------------|----------------------------------------------------------|
| `GET /health`         | Is the DB reachable? Shows the frozen `dbHost`.          |
| `GET /db-info`        | Which branch am I on — `BRANCH-A` / `BRANCH-B`.           |
| `GET /slow?seconds=N` | Holds one DB connection open N seconds (an in-flight query). |
| `GET /pool-stats`     | Pool counters + the frozen host.                         |

## 3. Terraform apply

```bash
cd terraform && terraform init && terraform apply -auto-approve && cd ..
```

Creates the ECR repos, IAM role, the secret `before-pgb-mrk` (starts on
`postgres-branch-a`), the cluster, and the two Fargate services (`desired_count = 1`).
Wait for tasks to be running:

```bash
aws ecs list-tasks --cluster before-pgb-cluster --desired-status RUNNING
```

## 4. Reach a backend from your host

Tasks have no published port, so use a small `socat` bridge that forwards a host
port to the task container (js → 8080, dotnet → 8081). This grabs whatever the
current task containers are named:

```bash
JS=$(docker ps --format '{{.Names}}' | grep 'floci-ecs.*-js' | head -1)
DOTNET=$(docker ps --format '{{.Names}}' | grep 'floci-ecs.*-dotnet' | head -1)
docker rm -f pgb-proxy-js pgb-proxy-dotnet 2>/dev/null
docker run -d --name pgb-proxy-js     --network floci-docker-network -p 8080:8080 \
  alpine/socat TCP-LISTEN:8080,fork,reuseaddr TCP:$JS:8080
docker run -d --name pgb-proxy-dotnet --network floci-docker-network -p 8081:8080 \
  alpine/socat TCP-LISTEN:8080,fork,reuseaddr TCP:$DOTNET:8080

curl localhost:8080/db-info     # js
curl localhost:8081/db-info     # dotnet
```

> The proxies point at **specific task containers**. After any switch (step 6) the
> task id changes, so re-run this block to re-point them — otherwise `localhost`
> looks dead.

## 5. Watch it live (load generator)

```bash
cd client
docker compose -f docker-compose.client.yaml up --build
```

Steady state looks like:

```
before-pgb-js       OK branch=BRANCH-A addr=floci-ecs-…-js      11ms
before-pgb-dotnet   OK branch=BRANCH-A addr=floci-ecs-…-dotnet  14ms
```

(The loadgen runs *on* the floci network, so it reaches tasks by name and needs
no proxy.) Optional: `./watch-connections.sh a|b` on the host shows the DB-side
connections appear/disappear during a switch.

## 6. The switch (A ↔ B) — the downtime moment

**a. Edit the secret in the floci console** (http://localhost:4500):
open secret **`before-pgb-mrk`** and set `DB_HOST` to **`postgres-branch-b`**
(or `postgres-branch-a` to go back). Leave the other keys as they are.

**b. Force BOTH services to redeploy** so each app re-reads the secret at startup:

```bash
aws ecs update-service --cluster before-pgb-cluster --service before-pgb-js     --force-new-deployment
aws ecs update-service --cluster before-pgb-cluster --service before-pgb-dotnet --force-new-deployment
```

> ⚠️ **Redeploy both.** If you only redeploy one, you get a split brain — js on
> BRANCH-B, dotnet still on the old host — and the un-redeployed one keeps failing.

**c. Re-point the proxies** (step 4 block) and confirm both flipped:

```bash
curl localhost:8080/db-info     # branch=BRANCH-B
curl localhost:8081/db-info     # branch=BRANCH-B
```

What you'll see in the loadgen: a run of `NO-RUNNING-TASK` / `ERR` lines while the
old tasks die and the new ones start — **that gap is the downtime** — then
`OK branch=BRANCH-B`.

## 7. Teardown

```bash
docker rm -f pgb-proxy-js pgb-proxy-dotnet
cd terraform && terraform destroy -auto-approve && cd ..
docker compose -f client/docker-compose.client.yaml down
docker compose -f postgres/docker-compose.db.yaml down -v
```
