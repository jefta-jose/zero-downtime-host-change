locals {
  # Keys injected one-per-env-var into the tasks via the ECS `secrets` block
  # (floci >= 1.6.0 supports the ":KEY::" selector -- see floci-problems-log #5).
  db_secret = {
    DB_HOST     = var.db_host
    DB_PORT     = var.db_port
    DB_NAME     = var.db_name
    DB_USER     = var.db_user
    DB_PASSWORD = var.db_password
  }
}

# ---------------------------------------------------------------------------
# ECR repositories (one per backend). Optional for floci -- images are pushed to
# the registry directly -- but created for parity with a real AWS setup.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "js" {
  name                 = "${var.prefix}-js"
  image_tag_mutability = "MUTABLE"
}

resource "aws_ecr_repository" "dotnet" {
  name                 = "${var.prefix}-dotnet"
  image_tag_mutability = "MUTABLE"
}

# ---------------------------------------------------------------------------
# IAM role reused as both execution and task role (mirrors the existing project).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs" {
  name               = "${var.prefix}-ecs-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# Execution-role permissions: pull task images from ECR and ship container logs
# to CloudWatch (the awslogs driver). Required on real AWS for any Fargate task;
# harmless under floci. Secrets Manager access is granted separately below --
# this managed policy deliberately does NOT cover it.
resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------------------------------------------------------------------------
# Shared secret holding the DB connection settings. The switch edits DB_HOST in
# this secret. lifecycle.ignore_changes lets you flip it with the AWS CLI without
# terraform trying to revert it on the next apply.
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "app" {
  name = "${var.prefix}-mrk"
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode(local.db_secret)

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# The execution role must be allowed to read this secret so ECS can resolve the
# DB_* keys in each task def's `secrets` block at launch. AmazonECSTaskExecution-
# RolePolicy does not include Secrets Manager, so grant it explicitly, scoped to
# just this secret. Without it, task launch fails with an access-denied resolving
# the secret (distinct from the selector/version issues in floci-problems-log #5).
resource "aws_iam_role_policy" "ecs_read_secret" {
  name = "${var.prefix}-ecs-read-secret"
  role = aws_iam_role.ecs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadAppSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.app.arn
    }]
  })
}

# ---------------------------------------------------------------------------
# Security group for the tasks (default VPC). Open 8080 for the local demo.
# ---------------------------------------------------------------------------
resource "aws_security_group" "tasks" {
  name   = "${var.prefix}-tasks"
  vpc_id = var.vpc_id

  ingress {
    description = "app http"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.prefix}-tasks" }
}

# ---------------------------------------------------------------------------
# ECS cluster + log groups.
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = "${var.prefix}-cluster"
}

resource "aws_cloudwatch_log_group" "js" {
  name              = "/ecs/${var.prefix}-js"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "dotnet" {
  name              = "/ecs/${var.prefix}-dotnet"
  retention_in_days = 7
}