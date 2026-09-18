terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 6.30 per floci-problems-log.md #1 (older providers nil-deref on
      # floci's responses). We don't touch CloudFront here, but keep the pin
      # consistent with the rest of the project.
      version = "~> 6.30"
    }
  }
}
