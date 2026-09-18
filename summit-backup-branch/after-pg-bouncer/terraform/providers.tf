# All AWS API calls go to floci at :4566. Credentials are dummy ("test") and all
# the client-side validation that would try to reach real AWS is skipped.
provider "aws" {
  region                      = var.region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  s3_use_path_style           = true

  endpoints {
    ecs            = var.floci_endpoint
    ecr            = var.floci_endpoint
    ec2            = var.floci_endpoint
    iam            = var.floci_endpoint
    sts            = var.floci_endpoint
    logs           = var.floci_endpoint
    secretsmanager = var.floci_endpoint
  }
}
