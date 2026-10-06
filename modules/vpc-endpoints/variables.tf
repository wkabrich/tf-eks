variable "name" {
  description = "Name prefix for the endpoint security group and tags (usually the cluster name)."
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC to create the endpoints in. It must have enableDnsSupport and enableDnsHostnames turned on for private DNS."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the interface endpoint ENIs, at most one per Availability Zone (usually the node subnets)."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "subnet_ids must contain at least one subnet."
  }
}

variable "interface_endpoints" {
  description = <<-EOT
    AWS service short names to create interface endpoints for (com.amazonaws.<region>.<name>). The default is what a no-NAT EKS cluster needs:
      ec2, ecr.api, ecr.dkr: node bootstrap and image pulls (required)
      eks-auth: EKS Pod Identity, including the vpc-cni add-on's credentials (required with the parent module)
      sts: IRSA and SDKs using regional STS
      logs: Fluent Bit / CloudWatch agent
      eks: EKS API calls from inside the VPC (CI runners, aws eks update-kubeconfig)
    Common additions: ssm and ssmmessages (Session Manager), elasticloadbalancing (AWS Load Balancer Controller), autoscaling (Cluster Autoscaler),
    guardduty-data (GuardDuty runtime monitoring), monitoring, xray, kms, secretsmanager, oidc-eks (in-VPC OIDC discovery).
  EOT
  type        = set(string)
  default     = ["ec2", "ecr.api", "ecr.dkr", "eks", "eks-auth", "logs", "sts"]
  nullable    = false
}

variable "create_s3_gateway_endpoint" {
  description = "Create an S3 gateway endpoint. ECR stores image layers in S3, so nodes in subnets without NAT need it to pull any image."
  type        = bool
  default     = true
  nullable    = false
}

variable "route_table_ids" {
  description = "Route tables of the node subnets, associated with the S3 gateway endpoint."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "s3_gateway_endpoint_policy" {
  description = "JSON policy for the S3 gateway endpoint; overrides data_perimeter. null sets AWS's full-access policy, or the perimeter policy when data_perimeter is enabled. A restrictive policy must at least allow s3:GetObject on arn:aws:s3:::prod-<region>-starport-layer-bucket/* for ECR image pulls."
  type        = string
  default     = null
}

variable "data_perimeter" {
  description = <<-EOT
    Attach endpoint policies that form a data perimeter. Interface endpoints then accept only principals from this account (or organization_id), plus
    unauthenticated sts:AssumeRoleWithWebIdentity for IRSA. The S3 gateway endpoint reaches only buckets owned by this account (or organization),
    the AWS-owned bucket that holds ECR image layers, and additional_s3_bucket_arns. This stops a compromised pod from sending data to another
    AWS account through the endpoints using foreign credentials. It also blocks legitimate cross-account access through these endpoints, so
    review before enabling. It does not restrict which ECR repositories images come from (the check is on the caller, not the resource),
    and DNS-based exfiltration is out of scope (use Route 53 Resolver DNS Firewall).
  EOT
  type = object({
    enabled                   = optional(bool, false)
    organization_id           = optional(string)
    additional_s3_bucket_arns = optional(list(string), [])
  })
  default  = {}
  nullable = false

  validation {
    condition     = var.data_perimeter.organization_id == null ? true : can(regex("^o-[a-z0-9]{10,32}$", var.data_perimeter.organization_id))
    error_message = "data_perimeter.organization_id must look like o-xxxxxxxxxx."
  }
}

variable "interface_endpoint_policies" {
  description = "Custom endpoint policy JSON per interface endpoint service, keyed by service short name. Overrides data_perimeter for that service."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the interface endpoints on TCP 443. Empty uses the VPC's primary IPv4 CIDR. Include every CIDR pods may use (secondary CIDRs, custom networking), because pod traffic to endpoints keeps the pod IP."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach the interface endpoints on TCP 443, in addition to allowed_cidr_blocks."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "ip_address_type" {
  description = "IP address type of the interface endpoints: ipv4, dualstack or ipv6. null uses the AWS default (ipv4)."
  type        = string
  default     = null

  validation {
    condition     = var.ip_address_type == null || contains(["ipv4", "dualstack", "ipv6"], coalesce(var.ip_address_type, "ipv4"))
    error_message = "ip_address_type must be null, ipv4, dualstack or ipv6."
  }
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
  nullable    = false
}
