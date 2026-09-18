variable "region" {
  type    = string
  default = "us-east-1"
}

variable "floci_endpoint" {
  type    = string
  default = "http://localhost:4566"
}

variable "prefix" {
  type    = string
  default = "before-pgb"
}

# Default VPC / subnets that floci ships with (see data/ec2-*.json).
variable "vpc_id" {
  type    = string
  default = "vpc-default-us-east-1"
}

variable "subnet_ids" {
  type    = list(string)
  default = ["subnet-default-a", "subnet-default-b", "subnet-default-c"]
}

# Image references. floci's ECR registry container is published on the host at
# localhost:5100; floci pulls task images via the host Docker daemon, so this
# plain registry path resolves. Build+push instructions are in
# commands-to-deploy-in-floci.md.
variable "js_image" {
  type    = string
  default = "localhost:5100/before-pgb-js:latest"
}

variable "dotnet_image" {
  type    = string
  default = "localhost:5100/before-pgb-dotnet:latest"
}

# --- Initial DB target: BRANCH-A. The switch flips DB_HOST (and DB_PORT if you
# choose to reach the DBs by published host port instead of container name). ---
# From the spawned task containers, the branch DBs are reachable by their
# container names over floci's Docker network.
variable "db_host" {
  type    = string
  default = "postgres-branch-a"
}

variable "db_port" {
  type    = string
  default = "5432"
}

variable "db_name" {
  type    = string
  default = "summit"
}

variable "db_user" {
  type    = string
  default = "summit"
}

variable "db_password" {
  type    = string
  default = "summit"
}
