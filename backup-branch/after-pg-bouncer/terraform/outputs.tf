output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_names" {
  value = [aws_ecs_service.js.name, aws_ecs_service.dotnet.name]
}

output "secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.app.name
}

output "upstream_secret_name" {
  value = aws_secretsmanager_secret.upstream.name
}

output "ecr_repos" {
  value = {
    js     = aws_ecr_repository.js.repository_url
    dotnet = aws_ecr_repository.dotnet.repository_url
  }
}

output "switch_hint" {
  value = "To switch branch: (1) update the '${var.prefix}-upstream' secret in Secrets Manager to the branch you want, then (2) run pgbouncer/switch.sh to gracefully apply it (pgbouncer re-reads SM + RELOAD/RECONNECT/WAIT_CLOSE). switch.sh does NOT modify the secret. The apps are NOT redeployed and DB_HOST stays 'pgbouncer'. See commands-to-deploy-in-floci.md."
}
