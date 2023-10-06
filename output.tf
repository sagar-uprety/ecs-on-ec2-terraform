################################################################################
# Defines the list of output for the created infrastructure
################################################################################

output "ecs_cluster_arn" {
  value       = module.ecs_cluster.arn
  description = "ARN of the ECS cluster"
}

output "target_group_arn" {
  value       = module.alb.target_group_arns
  description = "ARN of the target group of the ALB"
}

output "security_group_id" {
  value       = module.alb.security_group_id
  description = "Value of the security group id"
}

output "private_subnets" {
  value       = module.vpc.private_subnets
  description = "Value of the private subnets"
}

output "alb_dns_name" {
  value       = module.alb.lb_dns_name
  description = "DNS name of the ALB"
}