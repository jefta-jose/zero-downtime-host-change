locals {
  # DB settings injected one-per-env-var into the tasks via the ECS `secrets`
  # block. Unlike the "before" demo, DB_HOST here is the pooler and never moves.
  db_secret = {
    DB_HOST     = var.db_host
    DB_PORT     = var.db_port
    DB_NAME     = var.db_name
    DB_USER     = var.db_user
    DB_PASSWORD = var.db_password
  }
}

# ---------------------------------------------------------------------------
# ECR repositories (parity with a real AWS setup; images are pushed to floci's
# registry directly).
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
# IAM role reused as both execution and task role.
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

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ---------------------------------------------------------------------------
# Shared secret holding the DB connection settings. Here it points at the POOLER
# and is written ONCE. A branch switch does NOT touch this secret (it edits the
# pgbouncer config instead), so there is no force-new-deployment on a switch.
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
# UPSTREAM secret — the source of truth for WHICH BRANCH pgbouncer points at.
# This is the ONE thing a switch changes: switch.sh writes a new branch here,
# and pgbouncer re-reads it (render-from-sm.sh) + RELOADs. It is deliberately
# SEPARATE from the app secret above (which stays pinned to pgbouncer:6432 and is
# never touched by a switch). Initial value = branch-a; switch.sh owns it at
# runtime, hence ignore_changes on the version.
#
# Locally pgbouncer reads this with floci admin (test/test) creds, so no IAM is
# required. In real AWS the pgbouncer TASK role would need GetSecretValue on this
# secret's ARN (same shape as ecs_read_secret above).
# ---------------------------------------------------------------------------
resource "aws_secretsmanager_secret" "upstream" {
  name = "${var.prefix}-upstream"
}

resource "aws_secretsmanager_secret_version" "upstream" {
  secret_id = aws_secretsmanager_secret.upstream.id
  secret_string = jsonencode({
    host     = "postgres-branch-a"
    port     = "5432"
    dbname   = var.db_name
    user     = var.db_user
    password = var.db_password
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
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
