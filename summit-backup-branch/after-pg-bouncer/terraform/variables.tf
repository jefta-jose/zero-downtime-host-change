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
  default = "after-pgb"
}

# Default VPC / subnets that floci ships with.
variable "vpc_id" {
  type    = string
  default = "vpc-default-us-east-1"
}

variable "subnet_ids" {
  type    = list(string)
  default = ["subnet-default-a", "subnet-default-b", "subnet-default-c"]
}

# The app code is IDENTICAL to the "before" demo — that is the whole point: the
# app does not change when you add a pooler. So we reuse the very same images.
variable "js_image" {
  type    = string
  default = "localhost:5100/before-pgb-js:latest"
}

variable "dotnet_image" {
  type    = string
  default = "localhost:5100/before-pgb-dotnet:latest"
}

# --- The stable endpoint. Unlike the "before" demo (where DB_HOST is a branch
# and the switch flips it), here DB_HOST is the POOLER and is set ONCE, never
# changed by a switch. A branch switch happens inside pgbouncer (switch.sh). ---
variable "db_host" {
  type    = string
  default = "pgbouncer"
}

variable "db_port" {
  type    = string
  default = "6432"
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
