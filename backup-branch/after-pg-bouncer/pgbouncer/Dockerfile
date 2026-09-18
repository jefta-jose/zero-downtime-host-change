# PgBouncer that reads its upstream branch from Secrets Manager.
#
# The stock edoburu/pgbouncer image can't talk to SM, so we add aws-cli + jq and
# an entrypoint that renders the [databases] line FROM the secret on boot. A
# branch switch updates the secret and re-runs the render (see switch.sh), so the
# secret — not any file in this repo — is the source of truth.
FROM edoburu/pgbouncer:latest
USER root

# aws-cli (to read floci's Secrets Manager) + jq (parse the secret) + bash +
# su-exec (drop from root to the pgbouncer user; pgbouncer refuses to run as root).
RUN apk add --no-cache aws-cli jq bash su-exec

# Static config baked in; only the [databases] line is rendered from SM at runtime.
COPY conf/pgbouncer.ini  /etc/pgbouncer/pgbouncer.ini
COPY conf/userlist.txt   /etc/pgbouncer/userlist.txt
COPY scripts/render-from-sm.sh /usr/local/bin/render-from-sm.sh
COPY scripts/entrypoint.sh     /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/render-from-sm.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
