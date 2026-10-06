variable "region" {
  description = "AWS Region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Cluster name; also used to name the VPC."
  type        = string
  default     = "private-eks"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the cluster."
  type        = string
  default     = "1.37"
}

variable "vpc_cidr" {
  description = "CIDR block for the example VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "admin_role_arn" {
  description = "IAM role granted cluster-admin through an EKS access entry (for example your SSO administrator role)."
  type        = string
}

variable "admin_cidr_blocks" {
  description = "Networks (VPN, Direct Connect, bastion VPC) allowed to reach the private API endpoint."
  type        = list(string)
  default     = []
}
