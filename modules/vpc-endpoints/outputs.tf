output "security_group_id" {
  description = "ID of the security group attached to the interface endpoints."
  value       = aws_security_group.this.id
}

output "interface_endpoint_ids" {
  description = "Interface endpoint IDs, keyed by service short name."
  value       = { for k, ep in aws_vpc_endpoint.interface : k => ep.id }
}

output "s3_gateway_endpoint_id" {
  description = "ID of the S3 gateway endpoint, or null when it is not created."
  value       = try(aws_vpc_endpoint.s3[0].id, null)
}

output "s3_prefix_list_id" {
  description = "Prefix list ID of the S3 gateway endpoint, for security group egress rules."
  value       = try(aws_vpc_endpoint.s3[0].prefix_list_id, null)
}

output "dependency_ids" {
  description = "IDs of every resource this module creates. Pass to the EKS module's node_group_dependencies (nodes wait for the endpoints) and deletion_guard_dependencies (the endpoints are protected by its destroy guard)."
  value = concat(
    [for ep in aws_vpc_endpoint.interface : ep.id],
    aws_vpc_endpoint.s3[*].id,
    [aws_security_group.this.id],
    [for r in aws_vpc_security_group_ingress_rule.cidr : r.id],
    [for r in aws_vpc_security_group_ingress_rule.security_group : r.id],
  )
}
