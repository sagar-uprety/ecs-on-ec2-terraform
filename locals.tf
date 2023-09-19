locals {
  name     = "lms-ecs-ec2"
  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  container_name = "shop"
  container_port = 3000

  tags = {
    Owner       = var.owner
    Environment = var.environment
    Application = var.application
  }
}
