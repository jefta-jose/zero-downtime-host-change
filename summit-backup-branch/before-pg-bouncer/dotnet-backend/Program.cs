using Npgsql;

var builder = WebApplication.CreateBuilder(args);

// --- Same "before pgbouncer" idea as the JS backend, in the .NET worker's style. ---
//
// The connection string (and therefore the HOST) is read ONCE at startup and the
// NpgsqlDataSource is built from it a single time. This mirrors Summit's .NET
// worker, whose host comes from a connection string resolved at container start.
// Changing the host means restarting the process -- a redeploy.
string dbHost   = Environment.GetEnvironmentVariable("DB_HOST")     ?? "localhost";
string dbPort   = Environment.GetEnvironmentVariable("DB_PORT")     ?? "5432";
string dbName   = Environment.GetEnvironmentVariable("DB_NAME")     ?? "summit";
string dbUser   = Environment.GetEnvironmentVariable("DB_USER")     ?? "summit";
string dbPass   = Environment.GetEnvironmentVariable("DB_PASSWORD") ?? "summit";
string origin   = Environment.GetEnvironmentVariable("LOG_ORIGIN")  ?? "dotnet-backend";
int    apiPort  = int.Parse(Environment.GetEnvironmentVariable("API_PORT") ?? "8080");
string poolConstructedAt = DateTime.UtcNow.ToString("o");

var connString = new NpgsqlConnectionStringBuilder
{
    Host        = dbHost,
    Port        = int.Parse(dbPort),
    Database    = dbName,
    Username    = dbUser,
    Password    = dbPass,
    KeepAlive   = 30,
    MaxPoolSize = 10,
    // No ConnectionLifetime set on purpose: connections are not proactively
    // recycled (mirrors Summit's "before" state).
}.ConnectionString;

// Built once. The host is captured here for the process lifetime.
var dataSource = NpgsqlDataSource.Create(connString);
Console.WriteLine($"[db] datasource built for host={dbHost}:{dbPort} db={dbName} at {poolConstructedAt}");

builder.WebHost.UseUrls($"http://0.0.0.0:{apiPort}");
var app = builder.Build();

// Count of /slow requests currently holding a server connection open.
int inFlightSlow = 0;

app.MapGet("/", () => Results.Json(new
{
    origin,
    endpoints = new[] { "/health", "/db-info", "/slow?seconds=N", "/pool-stats" }
}));

app.MapGet("/health", async () =>
{
    try
    {
        await using var cmd = dataSource.CreateCommand("SELECT 1");
        await cmd.ExecuteScalarAsync();
        return Results.Json(new { status = "ok", origin, dbHost, poolConstructedAt });
    }
    catch (Exception e)
    {
        return Results.Json(new { status = "unhealthy", origin, dbHost, error = e.Message }, statusCode: 503);
    }
});

app.MapGet("/db-info", async () =>
{
    try
    {
        await using var cmd = dataSource.CreateCommand(
            "SELECT branch_name, color, current_database(), inet_server_addr()::text, pg_backend_pid(), now() " +
            "FROM branch_info WHERE id = 1");
        await using var r = await cmd.ExecuteReaderAsync();
        if (await r.ReadAsync())
        {
            return Results.Json(new
            {
                origin,
                dbHost,
                branch     = r.GetString(0),
                color      = r.GetString(1),
                db         = r.GetString(2),
                serverIp   = r.IsDBNull(3) ? null : r.GetString(3),
                backendPid = r.GetInt32(4),
                now        = r.GetDateTime(5),
            });
        }
        return Results.Json(new { origin, dbHost, error = "no branch_info row" }, statusCode: 500);
    }
    catch (Exception e)
    {
        return Results.Json(new { origin, dbHost, error = e.Message }, statusCode: 503);
    }
});

app.MapGet("/slow", async (int? seconds) =>
{
    int s = Math.Min(seconds ?? 15, 300);
    Interlocked.Increment(ref inFlightSlow);
    var sw = System.Diagnostics.Stopwatch.StartNew();
    try
    {
        await using var cmd = dataSource.CreateCommand("SELECT pg_sleep(@s), pg_backend_pid()");
        cmd.Parameters.AddWithValue("s", s);
        cmd.CommandTimeout = 320;
        await using var r = await cmd.ExecuteReaderAsync();
        int pid = 0;
        if (await r.ReadAsync()) pid = r.GetInt32(1);
        return Results.Json(new { origin, dbHost, sleptSeconds = s, backendPid = pid, elapsedMs = sw.ElapsedMilliseconds });
    }
    catch (Exception e)
    {
        return Results.Json(new { origin, dbHost, error = e.Message, elapsedMs = sw.ElapsedMilliseconds }, statusCode: 503);
    }
    finally
    {
        Interlocked.Decrement(ref inFlightSlow);
    }
});

app.MapGet("/pool-stats", () => Results.Json(new
{
    origin,
    dbHost,
    poolConstructedAt,
    inFlightSlow,
    note = "Npgsql does not expose live pool counts; watch pg_stat_activity for server-side connections."
}));

app.Run();