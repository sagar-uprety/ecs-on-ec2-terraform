
################################################################################
# Defines and manages the terraform versions
################################################################################
terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.55"
    }
  }

  backend "s3" {
    bucket  = "lms-ecs-ec2"
    region  = "us-east-2"
    encrypt = true
    key     = "main/terraform.tfstate"
  }
}