variable "name" {
  description = "Name used for the VPC and as a prefix for its resources (usually the cluster name)."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Za-z][A-Za-z0-9_-]{0,63}$", var.name))
    error_message = "name must start with an alphanumeric character and contain only alphanumerics, hyphens and underscores (max 64)."
  }
}

variable "cidr" {
  description = "IPv4 CIDR block of the VPC."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.cidr))
    error_message = "cidr must be a valid IPv4 CIDR block."
  }
}

variable "azs" {
  description = "Availability Zone names, one per subnet in each tier. Use at least two; for EKS control-plane subnets avoid the AZ IDs use1-az3, usw1-az2 and cac1-az3."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2 && length(distinct(var.azs)) == length(var.azs)
    error_message = "azs must list at least two distinct Availability Zones."
  }
}

variable "private_subnets" {
  description = "CIDR blocks of the private node subnets, one per entry in azs. These have no route outside the VPC."
  type        = list(string)

  validation {
    condition     = length(var.private_subnets) == length(var.azs) && alltrue([for c in var.private_subnets : can(cidrnetmask(c))])
    error_message = "private_subnets must contain one valid IPv4 CIDR block per entry in azs."
  }
}

variable "control_plane_subnets" {
  description = "CIDR blocks of dedicated subnets for the EKS control-plane ENIs (/28 is enough), one per entry in azs. Empty creates none."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = length(var.control_plane_subnets) == 0 || (length(var.control_plane_subnets) == length(var.azs) && alltrue([for c in var.control_plane_subnets : can(cidrnetmask(c))]))
    error_message = "control_plane_subnets must be empty or contain one valid IPv4 CIDR block per entry in azs."
  }
}

variable "private_subnet_tags" {
  description = "Extra tags for the private node subnets. The default marks them for internal load balancers created by the AWS Load Balancer Controller."
  type        = map(string)
  default     = { "kubernetes.io/role/internal-elb" = "1" }
  nullable    = false
}

variable "control_plane_subnet_tags" {
  description = "Extra tags for the control-plane subnets."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to an encrypted CloudWatch log group."
  type        = bool
  default     = true
  nullable    = false
}

variable "flow_log_traffic_type" {
  description = "Traffic captured by the flow log: ACCEPT, REJECT or ALL."
  type        = string
  default     = "ALL"
  nullable    = false

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be ACCEPT, REJECT or ALL."
  }
}

variable "flow_log_max_aggregation_interval" {
  description = "Maximum seconds over which a flow-log record is aggregated: 60 or 600."
  type        = number
  default     = 600
  nullable    = false

  validation {
    condition     = contains([60, 600], var.flow_log_max_aggregation_interval)
    error_message = "flow_log_max_aggregation_interval must be 60 or 600."
  }
}

variable "flow_log_retention_in_days" {
  description = "Retention of the flow-log log group. 0 keeps logs forever."
  type        = number
  default     = 365
  nullable    = false

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_in_days)
    error_message = "flow_log_retention_in_days must be a value CloudWatch Logs accepts."
  }
}

variable "create_flow_log_kms_key" {
  description = "Create a dedicated KMS key for the flow-log log group. Set false and pass flow_log_kms_key_arn to use your own."
  type        = bool
  default     = true
  nullable    = false
}

variable "flow_log_kms_key_arn" {
  description = "ARN of an existing KMS key for the flow-log log group, when create_flow_log_kms_key is false. Its policy must let logs.<region>.amazonaws.com use it for this log group."
  type        = string
  default     = null

  validation {
    condition     = var.flow_log_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-zA-Z-]+$", var.flow_log_kms_key_arn))
    error_message = "flow_log_kms_key_arn must be a KMS key ARN."
  }

  validation {
    condition     = var.create_flow_log_kms_key ? var.flow_log_kms_key_arn == null : var.flow_log_kms_key_arn != null || !var.enable_flow_logs
    error_message = "Set flow_log_kms_key_arn when create_flow_log_kms_key is false (and flow logs are enabled), and leave it unset otherwise."
  }
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
  nullable    = false
}
