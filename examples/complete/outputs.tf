output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Private API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Run from a network that can reach the private endpoint."
  value       = module.eks.kubeconfig_command
}

output "node_security_group_id" {
  description = "Security group attached to the nodes."
  value       = module.eks.node_security_group_id
}

output "ebs_kms_key_arn" {
  description = "KMS key to reference from EBS CSI StorageClasses."
  value       = module.eks.ebs_kms_key_arn
}
