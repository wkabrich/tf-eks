output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of the private node subnets, in the order of azs."
  value       = aws_subnet.private[*].id
}

output "private_route_table_ids" {
  description = "IDs of the private route tables, one per AZ (for gateway endpoints such as S3)."
  value       = aws_route_table.private[*].id
}

output "control_plane_subnet_ids" {
  description = "IDs of the control-plane subnets, in the order of azs (empty when none were requested)."
  value       = aws_subnet.control_plane[*].id
}

output "control_plane_route_table_id" {
  description = "ID of the control-plane route table, or null when there are no control-plane subnets."
  value       = try(aws_route_table.control_plane[0].id, null)
}

output "default_security_group_id" {
  description = "ID of the VPC's default security group (all rules removed)."
  value       = aws_default_security_group.this.id
}

output "flow_log_group_name" {
  description = "Name of the CloudWatch log group receiving VPC flow logs, or null when flow logs are off."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].name, null)
}

output "flow_log_kms_key_arn" {
  description = "ARN of the KMS key encrypting the flow-log log group, or null when flow logs are off."
  value       = var.enable_flow_logs ? local.flow_log_kms_key_arn : null
}
