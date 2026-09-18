import pg from 'pg';

const { Pool } = pg;

// --- The whole point of the "before pgbouncer" demo lives here. ---
//
// The connection settings (crucially the HOST) are read ONCE, at process start,
// and frozen for the life of the container. This mirrors Summit's main pool:
// the value is captured when the Pool is constructed and never re-read. The only
// way to point this process at a different Lakebase branch (a different host) is
// to restart the process -- i.e. redeploy the ECS task.
export const DB_CONFIG = Object.freeze({
  host: process.env.DB_HOST || 'localhost',
  port: Number(process.env.DB_PORT || 5432),
  database: process.env.DB_NAME || 'summit',
  user: process.env.DB_USER || 'summit',
  password: process.env.DB_PASSWORD || 'summit',
});

export const POOL_CONSTRUCTED_AT = new Date().toISOString();

// Pool options deliberately mirror Summit today (see option-b §6): keepAlive on,
// a long idle timeout, and NO maxLifetime -- so busy connections are not recycled
// on their own. That is exactly what makes the "before" pain visible: nothing
// short of a process restart moves this pool to a new host.
export const pool = new Pool({
  host: DB_CONFIG.host,
  port: DB_CONFIG.port,
  database: DB_CONFIG.database,
  user: DB_CONFIG.user,
  password: DB_CONFIG.password,
  keepAlive: true,
  idleTimeoutMillis: 600000, // 10 min
  max: 10,
});

pool.on('error', (err) => {
  // Fires when an idle backend connection dies (e.g. the DB behind the frozen
  // host went away). We log it rather than crash.
  console.error(`[db] idle client error: ${err.message}`);
});

console.log(
  `[db] pool constructed for host=${DB_CONFIG.host}:${DB_CONFIG.port} ` +
  `db=${DB_CONFIG.database} at ${POOL_CONSTRUCTED_AT}`
);
