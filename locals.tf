locals {
  name    = "lms-ecs-ec2"
  project = "ecs-module-lms"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  containers = [
    {
      name = "user",
      port = 3000,
    },
    {
      name = "product",
      port = 3001,
    },
    {
      name = "order",
      port = 3002
    },
  ]

  container_name = "user"
  container_port = 3000
  tags = {
    Name    = local.name,
    Project = local.project
  }
 user_data = <<-EOT
        #!/bin/bash
        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER=${local.name}
        ECS_LOGLEVEL=debug
        ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(local.tags)}
        ECS_ENABLE_TASK_IAM_ROLE=true
        EOF
      EOT
}

data "aws_availability_zones" "available" {}