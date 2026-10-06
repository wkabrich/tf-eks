################################################################################
# Cluster
################################################################################

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Private Kubernetes API server endpoint. Reachable only from the VPC and networks allowed by the cluster security group."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded certificate authority data for the cluster."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = aws_eks_cluster.this.version
}

output "cluster_platform_version" {
  description = "EKS platform version of the control plane."
  value       = aws_eks_cluster.this.platform_version
}

output "cluster_service_cidr" {
  description = "CIDR block Kubernetes service IPs are allocated from."
  value       = var.ip_family == "ipv6" ? aws_eks_cluster.this.kubernetes_network_config[0].service_ipv6_cidr : aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster (used by IRSA)."
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA, or null when enable_irsa is false."
  value       = try(aws_iam_openid_connect_provider.this[0].arn, null)
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for this cluster. It must run from a network that can reach the private endpoint."
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${aws_eks_cluster.this.name}"
}

################################################################################
# Networking
################################################################################

output "cluster_primary_security_group_id" {
  description = "ID of the security group EKS created and attached to the control-plane ENIs. Not attached to nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_security_group_id" {
  description = "ID of the module-managed security group on the control-plane ENIs that controls access to the private API endpoint."
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "ID of the security group attached to every managed node (and to pods on secondary ENIs). Reference it from load balancer, database and VPC endpoint security groups."
  value       = aws_security_group.node.id
}

################################################################################
# IAM
################################################################################

output "cluster_iam_role_arn" {
  description = "ARN of the EKS cluster IAM role."
  value       = aws_iam_role.cluster.arn
}

output "node_iam_role_arn" {
  description = "ARN of the IAM role shared by the managed node groups."
  value       = aws_iam_role.node.arn
}

output "node_iam_role_name" {
  description = "Name of the IAM role shared by the managed node groups."
  value       = aws_iam_role.node.name
}

output "pod_identity_role_arns" {
  description = "Pod Identity role ARNs the module created for its add-ons, keyed by add-on name."
  value       = { for name, role in aws_iam_role.pod_identity : name => role.arn }
}

################################################################################
# Encryption and logging
################################################################################

output "kms_key_arn" {
  description = "ARN of the KMS key used for Kubernetes API envelope encryption."
  value       = local.cluster_kms_key_arn
}

output "cloudwatch_log_group_kms_key_arn" {
  description = "ARN of the KMS key encrypting the control-plane log group."
  value       = local.logs_kms_key_arn
}

output "ebs_kms_key_arn" {
  description = "ARN of the KMS key encrypting node volumes. Use it as kmsKeyId in EBS CSI StorageClasses."
  value       = local.ebs_kms_key_arn
}

output "cloudwatch_log_group_name" {
  description = "Name of the CloudWatch log group receiving control-plane logs."
  value       = aws_cloudwatch_log_group.this.name
}

output "cloudwatch_log_group_arn" {
  description = "ARN of the CloudWatch log group receiving control-plane logs."
  value       = aws_cloudwatch_log_group.this.arn
}

################################################################################
# Compute, add-ons and access
################################################################################

output "node_groups" {
  description = "Managed node groups, keyed by the node_groups map key."
  value = {
    for k, ng in aws_eks_node_group.this : k => {
      arn                     = ng.arn
      node_group_name         = ng.node_group_name
      status                  = ng.status
      release_version         = ng.release_version
      autoscaling_groups      = try(ng.resources[0].autoscaling_groups[*].name, [])
      launch_template_id      = aws_launch_template.node[k].id
      launch_template_version = aws_launch_template.node[k].latest_version
    }
  }
}

output "addons" {
  description = "Installed EKS add-ons and their versions, keyed by add-on name."
  value = {
    for name, addon in merge(aws_eks_addon.before_compute, aws_eks_addon.this) : name => {
      arn     = addon.arn
      version = addon.addon_version
    }
  }
}

output "access_entries" {
  description = "Access entry ARNs, keyed by the access_entries map key."
  value       = { for k, e in aws_eks_access_entry.this : k => e.access_entry_arn }
}
