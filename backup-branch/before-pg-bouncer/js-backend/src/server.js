import express from 'express';
import { pool, DB_CONFIG, POOL_CONSTRUCTED_AT } from './db.js';

const app = express();
const PORT = Number(process.env.API_PORT || 8080);
const ORIGIN = process.env.LOG_ORIGIN || 'js-backend';

// Number of /slow requests currently holding a server connection open.
let inFlightSlow = 0;

// Liveness + DB reachability. Reports the frozen host so you can confirm which
// branch this process was launched against.
app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1 AS ok');
    res.json({ status: 'ok', origin: ORIGIN, dbHost: DB_CONFIG.host, poolConstructedAt: POOL_CONSTRUCTED_AT });
  } catch (e) {
    res.status(503).json({ status: 'unhealthy', origin: ORIGIN, dbHost: DB_CONFIG.host, error: e.message });
  }
});

// Which branch am I actually talking to right now? BRANCH-A vs BRANCH-B.
app.get('/db-info', async (_req, res) => {
  try {
    const r = await pool.query(
      `SELECT b.branch_name, b.color,
              current_database()      AS db,
              inet_server_addr()::text AS server_ip,
              pg_backend_pid()        AS backend_pid,
              now()                   AS now
         FROM branch_info b
        WHERE b.id = 1`
    );
    const row = r.rows[0] || {};
    res.json({
      origin: ORIGIN,
      dbHost: DB_CONFIG.host,
      branch: row.branch_name,
      color: row.color,
      db: row.db,
      serverIp: row.server_ip,
      backendPid: row.backend_pid,
      now: row.now,
    });
  } catch (e) {
    res.status(503).json({ origin: ORIGIN, dbHost: DB_CONFIG.host, error: e.message });
  }
});

// Holds a server connection open for `seconds` via pg_sleep. Use it to create
// an in-flight query you can watch in pg_stat_activity -- and to see it get cut
// when the task is redeployed during a host switch.
app.get('/slow', async (req, res) => {
  const seconds = Math.min(Number(req.query.seconds || 15), 300);
  const started = Date.now();
  inFlightSlow++;
  try {
    const r = await pool.query('SELECT pg_sleep($1), pg_backend_pid() AS pid', [seconds]);
    res.json({
      origin: ORIGIN,
      dbHost: DB_CONFIG.host,
      sleptSeconds: seconds,
      backendPid: r.rows[0].pid,
      elapsedMs: Date.now() - started,
    });
  } catch (e) {
    res.status(503).json({ origin: ORIGIN, dbHost: DB_CONFIG.host, error: e.message, elapsedMs: Date.now() - started });
  } finally {
    inFlightSlow--;
  }
});

// Live pool counters -- watch total/idle/waiting move as load arrives, and note
// the frozen host + construction time.
app.get('/pool-stats', (_req, res) => {
  res.json({
    origin: ORIGIN,
    dbHost: DB_CONFIG.host,
    poolConstructedAt: POOL_CONSTRUCTED_AT,
    total: pool.totalCount,
    idle: pool.idleCount,
    waiting: pool.waitingCount,
    inFlightSlow,
  });
});

app.get('/', (_req, res) =>
  res.json({ origin: ORIGIN, endpoints: ['/health', '/db-info', '/slow?seconds=N', '/pool-stats'] })
);

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[${ORIGIN}] listening on :${PORT} -> db host ${DB_CONFIG.host}:${DB_CONFIG.port}`);
});
