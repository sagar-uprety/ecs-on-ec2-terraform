data "aws_availability_zones" "available" {}

################################################################################
# Cluster
################################################################################

module "ecs_cluster" {
  source       = "terraform-aws-modules/ecs/aws//modules/cluster"
  version      = "5.2.2"
  cluster_name = "${local.name}-cluster"

  cluster_settings = {
    "name" : "containerInsights",
    "value" : "enabled"
  }

  # Capacity provider - autoscaling groups
  default_capacity_provider_use_fargate = false

  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = 90
  # create_task_exec_iam_role              = true # Create IAM role for task execution (Uses Managed AmazonECSTaskExecutionRolePolicy)
  create_task_exec_policy = true # Create IAM policy for task execution (Uses Managed AmazonECSTaskExecutionRolePolicy)


  autoscaling_capacity_providers = {
    # On-demand instances
    ex-1 = {
      auto_scaling_group_arn         = module.autoscaling["ex-1"].autoscaling_group_arn
      managed_termination_protection = "ENABLED"

      managed_scaling = {
        maximum_scaling_step_size = 2
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
        target_capacity           = 60
      }

      default_capacity_provider_strategy = {
        weight = 70
        base   = 20
      }
    }
    # Spot instances
    ex-2 = {
      auto_scaling_group_arn         = module.autoscaling["ex-2"].autoscaling_group_arn
      managed_termination_protection = "ENABLED"

      managed_scaling = {
        maximum_scaling_step_size = 2
        minimum_scaling_step_size = 1
        status                    = "DISABLED"
        target_capacity           = 90
      }

      default_capacity_provider_strategy = {
        weight = 30
      }
    }
  }

}

################################################################################
# Service
################################################################################

module "ecs_service" {
  source  = "terraform-aws-modules/ecs/aws//modules/service"
  version = "5.2.2"

  # Service
  name                   = "${local.name}-service"
  cluster_arn            = module.ecs_cluster.arn
  family                 = local.name #unique name for task defination
  enable_execute_command = true

  cpu                               = 1536
  memory                            = 3072
  health_check_grace_period_seconds = 15

  # Task Definition
  requires_compatibilities = ["EC2"]
  capacity_provider_strategy = {
    # On-demand instances
    ex-1 = {
      capacity_provider = module.ecs_cluster.autoscaling_capacity_providers["ex-1"].name
      weight            = 1
      base              = 1
    }
  }


  create_iam_role        = true # ECS Service IAM Role: Allows Amazon ECS to make calls to your load balancer on your behalf.
  create_task_definition = true
  create_tasks_iam_role  = true #ECS Task Role

  #   volume = {
  #     my-vol = {}
  #   }
  volume = {
    my-vol = {
      docker_volume_configuration = {
        scope         = "shared"
        autoprovision = true
        driver        = "local"
        labels = {
          "app" = "lms-ecs-docker-volume"
        }
      }
    }
  }

  # Container definition(s)
  container_definitions = {
    (local.container_name) = {
      cpu       = 1024
      memory    = 2560
      essential = true
      image     = var.image_url
      port_mappings = [
        {
          name          = local.container_name
          containerPort = local.container_port
          hostPort      = local.container_port
          protocol      = "tcp"
        }
      ]

      mount_points = [
        {
          sourceVolume  = "my-vol",
          containerPath = "/var/app"
        }
      ]

      enable_cloudwatch_logging              = true
      create_cloudwatch_log_group            = true
      readonly_root_filesystem               = false
      cloudwatch_log_group_retention_in_days = 30
    }
  }

  wait_for_steady_state = false
  subnet_ids            = module.vpc.private_subnets

  load_balancer = {
    service = {
      target_group_arn = element(module.alb.target_group_arns, 0)
      container_name   = local.container_name
      container_port   = local.container_port
    }
  }

  security_group_rules = {
    alb_ingress_3000 = {
      type                     = "ingress"
      from_port                = local.container_port
      to_port                  = local.container_port
      protocol                 = "tcp"
      description              = "Shop Service port"
      source_security_group_id = module.alb_sg.security_group_id
    }
    egress_all = {
      type        = "egress"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

}

################################################################################
# Supporting Resources
################################################################################

# https://docs.aws.amazon.com/AmazonECS/latest/developerguide/ecs-optimized_AMI.html#ecs-optimized-ami-linux
data "aws_ssm_parameter" "ecs_optimized_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended"
}

module "alb_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${local.name}-alb-sg"
  description = "Service security group"
  vpc_id      = module.vpc.vpc_id

  ingress_rules       = ["http-80-tcp"]
  ingress_cidr_blocks = ["0.0.0.0/0"]

  egress_rules       = ["all-all"]
  egress_cidr_blocks = module.vpc.private_subnets_cidr_blocks

}

module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 8.0"

  name = "${local.name}-alb"

  load_balancer_type = "application"

  vpc_id          = module.vpc.vpc_id
  subnets         = module.vpc.public_subnets
  security_groups = [module.alb_sg.security_group_id]

  http_tcp_listeners = [
    {
      port               = 80
      protocol           = "HTTP"
      target_group_index = 0
    },
  ]

  target_groups = [
    {
      name             = "${local.name}-${local.container_name}"
      backend_protocol = "HTTP"
      backend_port     = local.container_port
      target_type      = "ip",
      health_check = {
        enabled             = true
        interval            = 30
        path                = "/users"
        port                = local.container_port
        healthy_threshold   = 3
        unhealthy_threshold = 3
        timeout             = 6
        protocol            = "HTTP"
      }
    },
  ]

}

module "autoscaling" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 6.5"

  for_each = {
    # On-demand instances
    ex-1 = {
      instance_type              = "t2.medium"
      use_mixed_instances_policy = false
      mixed_instances_policy     = {}
      user_data                  = <<-EOT
        #!/bin/bash
        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER=${local.name}-cluster
        ECS_LOGLEVEL=debug
        ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(local.tags)}
        ECS_ENABLE_TASK_IAM_ROLE=true
        ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
        EOF
      EOT
    }
    # Spot instances
    ex-2 = {
      instance_type              = "t2.medium"
      use_mixed_instances_policy = false
      user_data                  = <<-EOT
        #!/bin/bash
        cat <<'EOF' >> /etc/ecs/ecs.config
        ECS_CLUSTER=${local.name}-cluster
        ECS_LOGLEVEL=debug
        ECS_CONTAINER_INSTANCE_TAGS=${jsonencode(local.tags)}
        ECS_ENABLE_TASK_IAM_ROLE=true
        ECS_ENABLE_SPOT_INSTANCE_DRAINING=true
        ECS_IMAGE_PULL_BEHAVIOR=prefer-cached
        EOF
      EOT
    }
  }

  name = "${local.name}-${each.key}"

  image_id      = jsondecode(data.aws_ssm_parameter.ecs_optimized_ami.value)["image_id"]
  instance_type = each.value.instance_type

  security_groups                 = [module.autoscaling_sg.security_group_id]
  user_data                       = base64encode(each.value.user_data)
  ignore_desired_capacity_changes = true

  create_iam_instance_profile = true
  iam_role_name               = local.name
  iam_role_description        = "ECS role for ${local.name}"
  iam_role_policies = {
    AmazonEC2ContainerServiceforEC2Role = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
    AmazonSSMManagedInstanceCore        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  vpc_zone_identifier = module.vpc.private_subnets
  health_check_type   = "EC2"
  min_size            = 1
  max_size            = 2
  desired_capacity    = 1

  # https://github.com/hashicorp/terraform-provider-aws/issues/12582
  autoscaling_group_tags = {
    AmazonECSManaged = true
  }

  # Required for  managed_termination_protection = "ENABLED"
  protect_from_scale_in = true

}

module "autoscaling_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "${local.name}-autoscaling-sg"
  description = "Autoscaling group security group"
  vpc_id      = module.vpc.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "http-80-tcp"
      source_security_group_id = module.alb_sg.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1

  egress_rules = ["all-all"]

}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

}

# DynamoDB

module "order_dynamodb_table" {
  source   = "terraform-aws-modules/dynamodb-table/aws"
  version  = "3.3.0"
  name     = "ecs-orders-ms"
  hash_key = "id"

  attributes = [
    {
      name = "id"
      type = "S"
    }
  ]

  tags = local.tags
}

module "user_dynamodb_table" {
  source   = "terraform-aws-modules/dynamodb-table/aws"
  version  = "3.3.0"
  name     = "ecs-users-ms"
  hash_key = "id"

  attributes = [
    {
      name = "id"
      type = "S"
    }
  ]

  tags = local.tags
}

module "product_dynamodb_table" {
  source   = "terraform-aws-modules/dynamodb-table/aws"
  version  = "3.3.0"
  name     = "ecs-products-ms"
  hash_key = "id"

  attributes = [
    {
      name = "id"
      type = "S"
    }
  ]

  tags = local.tags
}




resource "aws_iam_role_policy" "task_definition_role-policy" {
  name = "${local.name}-task-definition-role-policy"
  role = module.ecs_service.tasks_iam_role_name
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Effect" : "Allow",
        "Action" : [
          "dynamodb:*"
        ],
        "Resource" : "*"
      },
      {
        "Effect" : "Allow",
        "Action" : [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ],
        "Resource" : "*"
      }
    ]
  })
}
