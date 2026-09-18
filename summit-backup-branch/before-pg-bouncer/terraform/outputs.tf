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

output "ecr_repos" {
  value = {
    js     = aws_ecr_repository.js.repository_url
    dotnet = aws_ecr_repository.dotnet.repository_url
  }
}

output "switch_hint" {
  value = "To switch branch: update DB_HOST in secret '${aws_secretsmanager_secret.app.name}', then force-new-deployment on both services. See commands-to-deploy-in-floci.md §Switch."
}
