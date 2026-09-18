# Floci problems log

Known Floci quirks we hit and how to bypass them, so future work doesn't re-debug.

## 1. Terraform AWS provider crashes reading CloudFront back from Floci

Floci's CloudFront responses omit structs real AWS always returns (`TrustedKeyGroups`,
`OriginGroups`, `ForwardedValues`, ...), so the provider nil-derefs on read-back.

- **Fixed by bumping the provider `~> 5.0` → `~> 6.30`:** cleared the first crash
  (`TrustedKeyGroups` nil-deref) — v6 added that nil-guard. Also required adding
  `127.0.0.1 000000000000.localhost` to `/etc/hosts`, since v6 reads S3 bucket tags via
  the S3 Control API whose URL puts the account id in a vhost WSL couldn't resolve.
- **Fixed the rest by creating CloudFront via the AWS CLI instead of Terraform:** even
  v6 (and `main`) still nil-deref on `OriginGroups`, so no released provider can
  round-trip Floci's CloudFront — `aws cloudfront create-distribution` works fine
  (see `terraform/summit-backup-branch/app/commands-to-deploy-in-floci.md` step 4).

> Safety: always `aws sts get-caller-identity` first — Floci is account `000000000000`.

## 2. Floci doesn't actually serve traffic through a CloudFront distribution

The docs claim viewer GET/HEAD to a distribution's domain/alias are proxied to the
origin, but on this build they aren't. Requests to `:4566` with `Host` set to the
generated `<id>.cloudfront.net` **or** a configured alias are parsed by the S3
virtual-host router as a bucket name (`summit-backup.local` → bucket `summit-backup`
→ `NoSuchBucket`), so the S3 handler shadows CloudFront.

- **Bypass:** treat Floci's CloudFront as management-API-only. Create/get/delete and
  the id/domain handoff work; to view the frontend locally, serve it straight from S3
  (`GET $AWS_ENDPOINT_URL/<bucket>/index.html`). Mapping a hostname in `/etc/hosts`
  does not route through CloudFront.
- **Note:** delete-distribution enforces disable-first (real-AWS behavior) — flip
  `Enabled:false` via update-distribution, then delete.

## 3. Route 53 is management-plane only — no DNS resolution (Phase 2)

Docs, verbatim: "Actual DNS resolution is not provided — this is a management-plane-only
implementation," and "Actual DNS resolution" is listed under **Not Supported (Phase 2)**.
You can create private hosted zones + record sets, but nothing resolves them.

- **Impact:** the "stable CNAME alias, flip the target on cutover" pattern (options.md
  Option A) **cannot be exercised on Floci** — a container can't resolve the alias.
- **Bypass for a local demo:** simulate the resolver yourself (dnsmasq, or an `/etc/hosts`
  entry you rewrite at "cutover"); Floci's Route 53 won't do it. Real validation needs
  real AWS + Lakebase anyway (the Neon SNI/`sslmode` unknown).

## 4. AppConfig works fully — including the runtime data plane (verified)

Both planes work: management (application/environment/profile/hosted-version/deployment)
and `appconfigdata` (`StartConfigurationSession` + `GetLatestConfiguration`). Verified an
end-to-end cutover: a live session picked up a newly deployed version via its
`NextPollConfigurationToken` with no new session — options.md Option D is achievable here.

- **Gotcha:** `aws appconfig list-deployment-strategies` gets misrouted to S3 and returns
  `NoSuchBucket` (same Host-shadow bug as #2). **Bypass:** capture the strategy `Id` from
  `create-deployment-strategy` output instead of listing it.
- Use a 0-minute / 100%-growth / `replicate-to NONE` deployment strategy for instant cutover.

## 5. ECS per-key secret injection needs Floci ≥ 1.6.0

The ECS task-def `secrets` block with a JSON-key selector — `valueFrom = "<arn>:KEY::"`,
the form CDK/Terraform emit to inject one field of a Secrets Manager secret — is a
first-class, tested feature, but only from **1.6.0** (2026-08-06, PR #2133, the
`SecretsManagerSelector` parser). Older builds (we hit this on **1.5.33**) treat the
whole suffixed string as the secret id and fail the task launch with
`ResourceInitializationError: ... Secrets Manager can't find the specified secret`, even
though the base secret exists and resolves fine through the API. ECS↔Secrets Manager sync
is *not* broken — the build was just too old.

- **Bypass:** run Floci ≥ 1.6.0 (check `docker inspect floci/floci:<tag>`'s version
  label; bump the image in `docker-compose.yaml` and `docker compose pull && up -d`).
  If stuck on an old build, inject the whole secret with a plain-ARN `valueFrom` (no
  `:KEY::` suffix) and parse the JSON in-app.
- **Unrelated but easy to confuse:** secret resolution happens *before* the image pull,
  so a missing ECR image produces a *different* error — this one is purely the selector.
