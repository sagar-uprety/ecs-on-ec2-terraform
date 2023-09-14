################################################################################
# Defines the resources to be created
################################################################################

provider "aws" {
  region = var.region
  # Default tags (Global tags) applies to all resources created by this provider
  default_tags {
    tags = {
      Owner       = var.owner
      Environment = var.environment
      Application = var.application
    }
  }
}
