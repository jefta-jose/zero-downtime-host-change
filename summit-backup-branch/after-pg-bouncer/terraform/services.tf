locals {
  # DB settings arrive via the ECS `secrets` block, one JSON key per env var.
  db_secrets = [
    for k in ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"] : {
      name      = k
      valueFrom = "${aws_secretsmanager_secret.app.arn}:${k}::"
    }
  ]
}

# ===========================================================================
# JS backend (Summit "main pool" analogue). IDENTICAL image to the "before"
# demo — the app is unchanged; it just connects to pgbouncer:6432 now.
# ===========================================================================
resource "aws_ecs_task_definition" "js" {
  family                   = "${var.prefix}-js"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs.arn
  task_role_arn            = aws_iam_role.ecs.arn

  container_definitions = jsonencode([{
    name         = "js"
    image        = var.js_image
    essential    = true
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "LOG_ORIGIN", value = "after-pgb-js" },
      { name = "API_PORT", value = "8080" },
    ]
    secrets = local.db_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.js.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "js"
      }
    }
  }])
}

resource "aws_ecs_service" "js" {
  name            = "${var.prefix}-js"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.js.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  # A branch switch does NOT redeploy these services, but keep the ignore so an
  # out-of-band restart (if you ever do one) doesn't fight terraform.
  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}

# ===========================================================================
# .NET backend (Summit "worker" analogue). Same story: unchanged image.
# ===========================================================================
resource "aws_ecs_task_definition" "dotnet" {
  family                   = "${var.prefix}-dotnet"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs.arn
  task_role_arn            = aws_iam_role.ecs.arn

  container_definitions = jsonencode([{
    name         = "dotnet"
    image        = var.dotnet_image
    essential    = true
    portMappings = [{ containerPort = 8080, hostPort = 8080, protocol = "tcp" }]
    environment = [
      { name = "LOG_ORIGIN", value = "after-pgb-dotnet" },
      { name = "API_PORT", value = "8080" },
    ]
    secrets = local.db_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.dotnet.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "dotnet"
      }
    }
  }])
}

resource "aws_ecs_service" "dotnet" {
  name            = "${var.prefix}-dotnet"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.dotnet.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  lifecycle {
    ignore_changes = [task_definition, desired_count]
  }
}
