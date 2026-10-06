################################################################################
# Cluster
################################################################################

variable "name" {
  description = "Name of the EKS cluster. Also used to name and prefix every resource the module creates."
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Za-z][A-Za-z0-9_-]{0,99}$", var.name))
    error_message = "name must start with an alphanumeric character, contain only alphanumerics, hyphens and underscores, and be at most 100 characters."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes <major>.<minor> version for the control plane and node groups, e.g. \"1.37\". Required on purpose: a module default that changed between releases would silently upgrade clusters."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must be a <major>.<minor> string such as \"1.37\"."
  }
}

variable "data_plane_kubernetes_version" {
  description = "Kubernetes version for the node groups and add-on version lookups when they must differ from the control plane. null follows kubernetes_version. Use it for staged upgrades (control plane first, nodes in a later apply), or for an EKS rollback, which requires node groups and add-ons to go back before the control plane."
  type        = string
  default     = null

  validation {
    condition     = var.data_plane_kubernetes_version == null ? true : can(regex("^1\\.[0-9]{2}$", var.data_plane_kubernetes_version))
    error_message = "data_plane_kubernetes_version must be null or a <major>.<minor> string such as \"1.36\"."
  }
}

variable "upgrade_support_type" {
  description = "EKS upgrade policy. STANDARD auto-upgrades the control plane at the end of standard support; EXTENDED keeps the version for 12 more months at roughly 6x the hourly control-plane price. The EKS API default is EXTENDED, so the module always sets this explicitly."
  type        = string
  default     = "STANDARD"
  nullable    = false

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.upgrade_support_type)
    error_message = "upgrade_support_type must be STANDARD or EXTENDED."
  }
}

variable "deletion_protection" {
  description = "Block deletion of the cluster through the EKS API, and make terraform destroy fail before it touches anything this module manages (node groups, add-ons, access entries, IAM, KMS keys) or anything passed in deletion_guard_dependencies / node_group_dependencies. Other caller resources that merely reference module outputs are not protected. To destroy, first apply with this set to false. Removing the module block from configuration bypasses the Terraform-side guard (the EKS API protection still applies)."
  type        = bool
  default     = true
  nullable    = false
}

variable "control_plane_egress_mode" {
  description = "How the API server reaches webhooks, OIDC issuers and aggregated APIs. null (AWS_MANAGED) needs no egress path in your VPC. CUSTOMER_ROUTED sends that traffic through the control-plane subnets, so it needs a route to the destinations. Switching to CUSTOMER_ROUTED is one-way: reverting forces cluster replacement."
  type        = string
  default     = null

  validation {
    condition     = var.control_plane_egress_mode == null || contains(["AWS_MANAGED", "CUSTOMER_ROUTED"], coalesce(var.control_plane_egress_mode, "AWS_MANAGED"))
    error_message = "control_plane_egress_mode must be null, AWS_MANAGED or CUSTOMER_ROUTED."
  }
}

variable "control_plane_scaling_tier" {
  description = "Provisioned control-plane tier (standard, tier-xl, tier-2xl, tier-4xl, tier-8xl). Non-standard tiers carry a significant hourly charge. null leaves the EKS default. Removing the value does not revert the tier: set \"standard\" explicitly."
  type        = string
  default     = null

  validation {
    condition     = var.control_plane_scaling_tier == null || contains(["standard", "tier-xl", "tier-2xl", "tier-4xl", "tier-8xl"], coalesce(var.control_plane_scaling_tier, "standard"))
    error_message = "control_plane_scaling_tier must be null or one of standard, tier-xl, tier-2xl, tier-4xl, tier-8xl."
  }
}

variable "zonal_shift_enabled" {
  description = "Enable ARC zonal autoshift for the cluster. null leaves the setting unmanaged."
  type        = bool
  default     = null
}

variable "cluster_timeouts" {
  description = "Create, update and delete timeouts for the aws_eks_cluster resource. null uses the provider defaults (30m/60m/15m)."
  type = object({
    create = optional(string)
    update = optional(string)
    delete = optional(string)
  })
  default  = {}
  nullable = false
}

variable "tags" {
  description = "Tags applied to every resource the module creates. They are also stamped on node instances, volumes and ENIs through the launch templates, so changing them rolls every node (and moves unpinned node groups to the latest AMI)."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "cluster_tags" {
  description = "Extra tags applied only to the EKS cluster. Useful for tags such as GuardDutyManaged."
  type        = map(string)
  default     = {}
  nullable    = false
}

################################################################################
# Networking
################################################################################

variable "vpc_id" {
  description = "ID of the VPC. It must have enableDnsSupport and enableDnsHostnames turned on, and its DHCP options must include AmazonProvidedDNS, so the EKS-managed private hosted zone and interface-endpoint private DNS resolve."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must be a VPC ID (vpc-...)."
  }
}

variable "node_subnet_ids" {
  description = "Private subnet IDs for worker nodes. Also used for the control-plane ENIs when control_plane_subnet_ids is empty. Do not use subnets that route to an internet gateway."
  type        = list(string)

  validation {
    condition     = length(var.node_subnet_ids) >= 2 && alltrue([for s in var.node_subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))])
    error_message = "node_subnet_ids must contain at least two subnet IDs (subnet-...) in different Availability Zones."
  }
}

variable "control_plane_subnet_ids" {
  description = "Dedicated subnets for the EKS-managed control-plane ENIs (small /28 subnets in at least two AZs are recommended). Empty uses node_subnet_ids. Replacement subnets must cover the same AZs as the originals."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = length(var.control_plane_subnet_ids) == 0 || (length(var.control_plane_subnet_ids) >= 2 && alltrue([for s in var.control_plane_subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))]))
    error_message = "control_plane_subnet_ids must be empty or contain at least two subnet IDs (subnet-...)."
  }
}

variable "cluster_endpoint_allowed_cidr_blocks" {
  description = "CIDR blocks (VPN, Direct Connect, peered VPCs, CI runners) allowed to reach the private API endpoint on TCP 443. Nodes are always allowed."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for c in var.cluster_endpoint_allowed_cidr_blocks : can(cidrhost(c, 0)) && !endswith(c, "/0")])
    error_message = "cluster_endpoint_allowed_cidr_blocks must be valid CIDRs and must not be 0.0.0.0/0 or ::/0."
  }
}

variable "cluster_endpoint_allowed_security_group_ids" {
  description = "Security group IDs (bastions, CI runners in the same VPC) allowed to reach the private API endpoint on TCP 443."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "ip_family" {
  description = "IP family for pod and service addresses: ipv4 or ipv6. ipv6 requires dual-stack subnets. Create-time only: EKS cannot change it, and the module cannot replace a cluster under the same name, so changing it means building a new cluster."
  type        = string
  default     = "ipv4"
  nullable    = false

  validation {
    condition     = contains(["ipv4", "ipv6"], var.ip_family)
    error_message = "ip_family must be ipv4 or ipv6."
  }
}

variable "service_ipv4_cidr" {
  description = "CIDR for Kubernetes service IPs. Pick an RFC 1918 block (/12 to /24) that does not overlap the VPC or any connected network. null lets EKS choose 10.100.0.0/16 or 172.20.0.0/16. Create-time only: changing it means building a new cluster."
  type        = string
  default     = null

  validation {
    # A CIDR is inside an RFC 1918 range when its prefix is at least as long as the range's and
    # masking its network address to the range's prefix gives the range's base address.
    condition = var.service_ipv4_cidr == null ? true : try(
      tonumber(split("/", var.service_ipv4_cidr)[1]) >= 12 &&
      tonumber(split("/", var.service_ipv4_cidr)[1]) <= 24 &&
      anytrue([
        for r in ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"] :
        tonumber(split("/", var.service_ipv4_cidr)[1]) >= tonumber(split("/", r)[1]) &&
        cidrhost("${cidrhost(var.service_ipv4_cidr, 0)}/${split("/", r)[1]}", 0) == cidrhost(r, 0)
      ]),
      false
    )
    error_message = "service_ipv4_cidr must be a /12 to /24 block inside 10.0.0.0/8, 172.16.0.0/12 or 192.168.0.0/16."
  }
}

################################################################################
# Logging
################################################################################

variable "cluster_enabled_log_types" {
  description = "Control-plane log types sent to CloudWatch Logs. All five are enabled by default (CIS EKS 2.1.1, trivy AWS-0038, checkov CKV_AWS_37). audit and authenticator are mandatory."
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  nullable    = false

  validation {
    condition = (
      alltrue([for t in var.cluster_enabled_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)]) &&
      contains(var.cluster_enabled_log_types, "audit") &&
      contains(var.cluster_enabled_log_types, "authenticator")
    )
    error_message = "cluster_enabled_log_types may only contain api, audit, authenticator, controllerManager and scheduler, and must include audit and authenticator."
  }
}

variable "cloudwatch_log_group_retention_in_days" {
  description = "Retention for the /aws/eks/<name>/cluster log group. 0 keeps logs forever. The default of 365 days meets checkov CKV_AWS_338."
  type        = number
  default     = 365
  nullable    = false

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.cloudwatch_log_group_retention_in_days)
    error_message = "cloudwatch_log_group_retention_in_days must be a value CloudWatch Logs accepts (0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653)."
  }
}

variable "cloudwatch_log_group_class" {
  description = "Log class for the control-plane log group. STANDARD supports metric filters and subscriptions; INFREQUENT_ACCESS is cheaper but does not. Create-time only: CloudWatch cannot change it, and the fixed log group name prevents replacement."
  type        = string
  default     = "STANDARD"
  nullable    = false

  validation {
    condition     = contains(["STANDARD", "INFREQUENT_ACCESS"], var.cloudwatch_log_group_class)
    error_message = "cloudwatch_log_group_class must be STANDARD or INFREQUENT_ACCESS."
  }
}

variable "cloudwatch_log_group_deletion_protection" {
  description = "Prevent deletion of the control-plane log group. Leave false if you need terraform destroy to work without manual steps."
  type        = bool
  default     = false
  nullable    = false
}

variable "audit_log_alarm_sns_topic_arns" {
  description = "SNS topic ARNs notified when an audit-log metric filter fires. Empty creates the metric filters without alarms."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "enable_audit_log_metric_filters" {
  description = "Create CloudWatch metric filters (and alarms, if audit_log_alarm_sns_topic_arns is set) on security-relevant Kubernetes audit events. Requires cloudwatch_log_group_class = STANDARD."
  type        = bool
  default     = false
  nullable    = false
}

variable "audit_log_additional_metric_filters" {
  description = "Extra audit-log metric filters merged with the module defaults. pattern uses CloudWatch Logs filter syntax against the JSON audit event."
  type = map(object({
    pattern     = string
    description = string
    threshold   = optional(number, 1)
    period      = optional(number, 300)
  }))
  default  = {}
  nullable = false
}

################################################################################
# Encryption
################################################################################

variable "create_kms_key" {
  description = "Create a dedicated KMS key as the KEK for Kubernetes API envelope encryption. Set false and pass kms_key_arn to use your own. Create-time only: EKS cannot switch keys, so the module refuses a change of this flag or of kms_key_arn on an existing cluster."
  type        = bool
  default     = true
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of an existing symmetric KMS key used as the KEK for Kubernetes API envelope encryption, when create_kms_key is false. It cannot be changed after the cluster exists (the module refuses). Deleting or disabling this key makes the cluster unrecoverable."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-zA-Z-]+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (not an alias): an alias causes a permanent diff on aws_eks_cluster."
  }

  validation {
    condition     = var.create_kms_key ? var.kms_key_arn == null : var.kms_key_arn != null
    error_message = "Set kms_key_arn when create_kms_key is false, and leave it unset when create_kms_key is true."
  }
}

variable "create_cloudwatch_log_group_kms_key" {
  description = "Create a dedicated KMS key for the control-plane log group. Set false and pass cloudwatch_log_group_kms_key_arn to use your own."
  type        = bool
  default     = true
  nullable    = false
}

variable "cloudwatch_log_group_kms_key_arn" {
  description = "ARN of an existing KMS key for the control-plane log group, when create_cloudwatch_log_group_kms_key is false. The key policy must already let logs.<region>.amazonaws.com use it for this log group."
  type        = string
  default     = null

  validation {
    condition     = var.cloudwatch_log_group_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-zA-Z-]+$", var.cloudwatch_log_group_kms_key_arn))
    error_message = "cloudwatch_log_group_kms_key_arn must be a KMS key ARN."
  }

  validation {
    condition     = var.create_cloudwatch_log_group_kms_key ? var.cloudwatch_log_group_kms_key_arn == null : var.cloudwatch_log_group_kms_key_arn != null
    error_message = "Set cloudwatch_log_group_kms_key_arn when create_cloudwatch_log_group_kms_key is false, and leave it unset when create_cloudwatch_log_group_kms_key is true."
  }
}

variable "create_ebs_kms_key" {
  description = "Create a dedicated KMS key for node EBS volumes and EBS CSI volumes. Set false and pass ebs_kms_key_arn to use your own."
  type        = bool
  default     = true
  nullable    = false
}

variable "ebs_kms_key_arn" {
  description = "ARN of an existing KMS key for node EBS volumes, when create_ebs_kms_key is false. The key policy must already let the AWSServiceRoleForAutoScaling service-linked role use it and create grants for AWS resources."
  type        = string
  default     = null

  validation {
    condition     = var.ebs_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-zA-Z-]+$", var.ebs_kms_key_arn))
    error_message = "ebs_kms_key_arn must be a KMS key ARN."
  }

  validation {
    condition     = var.create_ebs_kms_key ? var.ebs_kms_key_arn == null : var.ebs_kms_key_arn != null
    error_message = "Set ebs_kms_key_arn when create_ebs_kms_key is false, and leave it unset when create_ebs_kms_key is true."
  }
}

variable "kms_key_administrator_arns" {
  description = "Additional IAM principals allowed to manage the module-created KMS keys (the AWS default key-administrator actions). They get no direct cryptographic permissions, but they can change key policies, create grants and schedule deletion, so treat them as able to obtain use of the keys. The account root statement is always present, so IAM policies in the account still govern access."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "kms_key_deletion_window_in_days" {
  description = "Waiting period before a module-created KMS key is deleted after destroy (7-30 days)."
  type        = number
  default     = 30
  nullable    = false

  validation {
    condition     = var.kms_key_deletion_window_in_days >= 7 && var.kms_key_deletion_window_in_days <= 30
    error_message = "kms_key_deletion_window_in_days must be between 7 and 30."
  }
}

variable "create_autoscaling_service_linked_role" {
  description = "Create the account-wide AWSServiceRoleForAutoScaling service-linked role. The EBS key policy names it as a principal, so it must exist first. Only enable this in accounts that have never used EC2 Auto Scaling: creation fails if the role already exists."
  type        = bool
  default     = false
  nullable    = false
}

################################################################################
# Access
################################################################################

variable "access_entries" {
  description = "EKS access entries to create, keyed by a short name. Do not add entries for node group roles: EKS creates those. Each policy association grants an AWS-managed access policy (arn:<partition>:eks::aws:cluster-access-policy/...) at cluster or namespace scope."
  type = map(object({
    principal_arn     = string
    type              = optional(string, "STANDARD")
    kubernetes_groups = optional(list(string))
    user_name         = optional(string)
    tags              = optional(map(string), {})
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        type       = string
        namespaces = optional(list(string))
      })
    })), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for e in values(var.access_entries) : contains(["STANDARD", "EC2_LINUX", "EC2_WINDOWS", "FARGATE_LINUX", "HYBRID_LINUX"], e.type)])
    error_message = "access_entries[*].type must be STANDARD, EC2_LINUX, EC2_WINDOWS, FARGATE_LINUX or HYBRID_LINUX."
  }

  validation {
    condition = alltrue(flatten([
      for e in values(var.access_entries) : [
        for p in values(e.policy_associations) :
        contains(["cluster", "namespace"], p.access_scope.type) &&
        (p.access_scope.type == "cluster" ? length(coalesce(p.access_scope.namespaces, [])) == 0 : length(coalesce(p.access_scope.namespaces, [])) > 0)
      ]
    ]))
    error_message = "access_scope.type must be cluster (no namespaces) or namespace (with at least one namespace)."
  }

  validation {
    condition     = alltrue([for e in values(var.access_entries) : e.type == "STANDARD" || (length(e.policy_associations) == 0 && e.kubernetes_groups == null)])
    error_message = "Only STANDARD access entries may have policy_associations or kubernetes_groups."
  }

  validation {
    condition     = alltrue([for e in values(var.access_entries) : !can(regex("^arn:[^:]+:sts::", e.principal_arn))])
    error_message = "access_entries[*].principal_arn must be an IAM role or user ARN, not an STS assumed-role session ARN."
  }

  validation {
    condition     = length(distinct([for e in values(var.access_entries) : e.principal_arn])) == length(var.access_entries)
    error_message = "Each principal_arn may appear in only one access entry (EKS allows one entry per principal)."
  }
}

variable "enable_cluster_creator_admin_permissions" {
  description = "Add the identity running Terraform as a cluster-admin access entry. Off by default so admin access is always granted explicitly through access_entries."
  type        = bool
  default     = false
  nullable    = false
}

variable "enable_irsa" {
  description = "Create an IAM OIDC provider for IRSA. Off by default: EKS Pod Identity is preferred and is what the module uses. Enable only for workloads that still need IRSA (Fargate, Windows, IRSA-only add-ons). No-egress VPCs then also need the sts and oidc-eks endpoints."
  type        = bool
  default     = false
  nullable    = false
}

################################################################################
# Node groups
################################################################################

variable "node_groups" {
  description = <<-EOT
    EKS managed node groups, keyed by a short name. Each one gets a hardened launch template (IMDSv2 only with hop limit 1, encrypted gp3 volumes, no SSH, no public IPs).
    ami_type must be an AL2023 or Bottlerocket type; AL2 is end-of-life. instance_types defaults to m7g.large for ARM AMIs and m7i.large otherwise.
    bootstrap_extra_config is merged into the EKS-generated bootstrap: an AL2023 NodeConfig YAML document, or Bottlerocket TOML settings
    (the module owns settings.host-containers.admin and, except on NVIDIA variants, settings.kernel.lockdown).
    disk_size, disk_iops and disk_throughput describe the root volume on AL2023 and the data volume on Bottlerocket.
    release_version pins the AMI; for AL2023 it must start with the node Kubernetes version, so move it in the same change as an upgrade.
    Changing ami_type, instance_types, capacity_type or subnet_ids replaces the node group at its configured desired_size: raise
    desired_size to the current capacity first, or roll the change by adding a new map key and removing the old one.
  EOT
  type = map(object({
    ami_type                      = optional(string, "AL2023_x86_64_STANDARD")
    instance_types                = optional(list(string))
    capacity_type                 = optional(string, "ON_DEMAND")
    min_size                      = optional(number, 2)
    max_size                      = optional(number, 4)
    desired_size                  = optional(number, 2)
    subnet_ids                    = optional(list(string))
    disk_size                     = optional(number, 50)
    disk_iops                     = optional(number)
    disk_throughput               = optional(number)
    labels                        = optional(map(string), {})
    taints                        = optional(list(object({ key = string, value = optional(string), effect = string })), [])
    max_unavailable_percentage    = optional(number, 33)
    update_strategy               = optional(string)
    release_version               = optional(string)
    enable_node_repair            = optional(bool, true)
    enable_detailed_monitoring    = optional(bool, false)
    additional_security_group_ids = optional(list(string), [])
    bootstrap_extra_config        = optional(string)
    force_update_version          = optional(bool, false)
    tags                          = optional(map(string), {})
  }))
  default  = { default = {} }
  nullable = false

  validation {
    condition = alltrue([for ng in values(var.node_groups) : contains([
      "AL2023_x86_64_STANDARD", "AL2023_ARM_64_STANDARD", "AL2023_x86_64_NVIDIA", "AL2023_ARM_64_NVIDIA", "AL2023_x86_64_NEURON",
      "BOTTLEROCKET_x86_64", "BOTTLEROCKET_ARM_64", "BOTTLEROCKET_x86_64_FIPS", "BOTTLEROCKET_ARM_64_FIPS",
      "BOTTLEROCKET_x86_64_NVIDIA", "BOTTLEROCKET_ARM_64_NVIDIA", "BOTTLEROCKET_x86_64_NVIDIA_FIPS", "BOTTLEROCKET_ARM_64_NVIDIA_FIPS",
    ], ng.ami_type)])
    error_message = "node_groups[*].ami_type must be an AL2023_* or BOTTLEROCKET_* AMI type. AL2 AMIs are not published for Kubernetes 1.33+, and CUSTOM/Windows types are out of scope."
  }

  validation {
    # CAPACITY_BLOCK is not offered: it needs launch-template market options and a reservation target.
    condition     = alltrue([for ng in values(var.node_groups) : contains(["ON_DEMAND", "SPOT"], ng.capacity_type)])
    error_message = "node_groups[*].capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition     = alltrue([for ng in values(var.node_groups) : ng.min_size >= 0 && ng.min_size <= ng.desired_size && ng.desired_size <= ng.max_size && ng.max_size >= 1])
    error_message = "node_groups[*] sizes must satisfy 0 <= min_size <= desired_size <= max_size and max_size >= 1."
  }

  validation {
    condition     = alltrue([for ng in values(var.node_groups) : ng.update_strategy == null || contains(["DEFAULT", "MINIMAL"], coalesce(ng.update_strategy, "DEFAULT"))])
    error_message = "node_groups[*].update_strategy must be null, DEFAULT or MINIMAL."
  }

  validation {
    condition     = alltrue([for ng in values(var.node_groups) : alltrue([for t in ng.taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)])])
    error_message = "node_groups[*].taints[*].effect must be NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE."
  }

  validation {
    condition     = alltrue([for k, ng in var.node_groups : can(regex("^[0-9A-Za-z][A-Za-z0-9_-]{0,19}$", k)) && ng.disk_size >= 20])
    error_message = "node_groups keys must be 1-20 alphanumerics, hyphens or underscores, and disk_size must be at least 20 GiB."
  }

  validation {
    # gp3: 3,000-80,000 IOPS at no more than 500 IOPS/GiB; throughput 125-2,000 MiB/s at no more than 0.25 MiB/s per IOPS.
    condition = alltrue([for ng in values(var.node_groups) :
      (ng.disk_iops == null ? true : ng.disk_iops >= 3000 && ng.disk_iops <= min(80000, max(3000, 500 * ng.disk_size))) &&
      (ng.disk_throughput == null ? true : ng.disk_throughput >= 125 && ng.disk_throughput <= min(2000, coalesce(ng.disk_iops, 3000) / 4))
    ])
    error_message = "node_groups[*].disk_iops must be 3000-80000 and at most 500 per GiB of disk_size; disk_throughput must be 125-2000 MiB/s and at most disk_iops / 4."
  }

  validation {
    # TOML forbids redefining a table, so the caller may not define the tables the module emits
    # ([settings.host-containers.admin], and [settings.kernel] except on NVIDIA variants), whether by
    # header, dotted key or inline table, nor use a bare [settings] / [settings.host-containers] header.
    condition = alltrue([for ng in values(var.node_groups) :
      !startswith(ng.ami_type, "BOTTLEROCKET") || ng.bootstrap_extra_config == null ? true : (
        !can(regex("(?m)^\\s*(\\[\\s*settings\\s*\\]|\\[\\s*settings\\.host-containers(\\.admin)?\\s*\\]|settings\\s*=|settings\\.host-containers\\s*=|settings\\.host-containers\\.admin\\s*[.=])", ng.bootstrap_extra_config)) &&
        (strcontains(ng.ami_type, "NVIDIA") || !can(regex("(?m)^\\s*(\\[\\s*settings\\.kernel\\s*\\]|settings\\.kernel\\s*[.=])", ng.bootstrap_extra_config)))
      )
    ])
    error_message = "Bottlerocket bootstrap_extra_config must not define settings.host-containers.admin or (except on NVIDIA variants) settings.kernel, which the module owns, and must not use bare [settings] or [settings.host-containers] headers. Use specific table headers such as [settings.kernel.sysctl], [settings.kubernetes] or [settings.host-containers.control]."
  }

  validation {
    condition = alltrue([for ng in values(var.node_groups) :
      ng.release_version == null || startswith(ng.ami_type, "BOTTLEROCKET") ? true :
      startswith(ng.release_version, "${coalesce(var.data_plane_kubernetes_version, var.kubernetes_version)}.")
    ])
    error_message = "AL2023 node_groups[*].release_version must start with the node Kubernetes version (e.g. 1.37.x-YYYYMMDD). Move the pin in the same change as kubernetes_version: EKS cannot roll AMIs back."
  }
}

variable "node_iam_role_additional_policy_arns" {
  description = "Extra IAM policy ARNs to attach to the shared node role, keyed by a static name. The module manages the node role's managed policies exclusively, so policies attached any other way are removed on the next apply. Prefer Pod Identity for workload permissions: anything attached here is available to every host-network pod."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "enable_node_ssm_access" {
  description = "Let nodes register with Systems Manager so engineers can open Session Manager shells (audited, no SSH). Attaches the minimal EKS best-practice policy instead of AmazonSSMManagedInstanceCore. No-egress VPCs also need the ssm and ssmmessages endpoints."
  type        = bool
  default     = false
  nullable    = false
}

variable "attach_cni_policy_to_node_role" {
  description = "Also attach the VPC CNI policy to the node role. Off by default: the vpc-cni add-on gets its own Pod Identity role, so no other pod inherits ENI management permissions. Turn on only for migrations, or when the eks-auth endpoint is unavailable."
  type        = bool
  default     = false
  nullable    = false
}

variable "node_security_group_webhook_ports" {
  description = "TCP ports the control plane may open to pods for admission webhooks and aggregated APIs (metrics-server 10251, AWS Load Balancer Controller 9443, Karpenter 8443, prometheus-adapter 6443, legacy metrics-server 4443)."
  type        = list(number)
  default     = [4443, 6443, 8443, 9443, 10251]
  nullable    = false
}

variable "node_security_group_allow_all_egress" {
  description = "Let nodes and pods open connections to any IPv4/IPv6 address. Off by default: egress is limited to other nodes, the API server, HTTPS inside the VPC (interface endpoints) and the S3 gateway prefix list. Add narrower rules with node_security_group_additional_rules first."
  type        = bool
  default     = false
  nullable    = false
}

variable "node_security_group_https_egress_cidr_blocks" {
  description = "CIDR blocks nodes may reach on TCP 443 (interface VPC endpoints, internal HTTPS services). null uses the VPC's primary IPv4 CIDR."
  type        = list(string)
  default     = null

  validation {
    condition     = var.node_security_group_https_egress_cidr_blocks == null || alltrue([for c in coalesce(var.node_security_group_https_egress_cidr_blocks, []) : can(cidrhost(c, 0))])
    error_message = "node_security_group_https_egress_cidr_blocks must contain valid CIDR blocks."
  }
}

variable "node_security_group_additional_rules" {
  description = "Extra node security group rules, keyed by a static name. Set exactly one target: cidr_ipv4, cidr_ipv6, prefix_list_id, referenced_security_group_id or self = true."
  type = map(object({
    direction                    = string
    description                  = string
    ip_protocol                  = string
    from_port                    = optional(number)
    to_port                      = optional(number)
    cidr_ipv4                    = optional(string)
    cidr_ipv6                    = optional(string)
    prefix_list_id               = optional(string)
    referenced_security_group_id = optional(string)
    self                         = optional(bool, false)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for r in values(var.node_security_group_additional_rules) : contains(["ingress", "egress"], r.direction)])
    error_message = "node_security_group_additional_rules[*].direction must be ingress or egress."
  }

  validation {
    condition = alltrue([for r in values(var.node_security_group_additional_rules) :
      length(compact([r.cidr_ipv4, r.cidr_ipv6, r.prefix_list_id, r.referenced_security_group_id, r.self ? "self" : null])) == 1
    ])
    error_message = "Each node_security_group_additional_rules entry needs exactly one of cidr_ipv4, cidr_ipv6, prefix_list_id, referenced_security_group_id or self = true."
  }

  validation {
    condition     = alltrue([for r in values(var.node_security_group_additional_rules) : r.ip_protocol == "-1" || (r.from_port != null && r.to_port != null)])
    error_message = "node_security_group_additional_rules entries need from_port and to_port unless ip_protocol is \"-1\"."
  }
}

################################################################################
# Add-ons
################################################################################

variable "addons" {
  description = <<-EOT
    Overrides and additions for EKS managed add-ons, merged over the module's core set (eks-pod-identity-agent, vpc-cni, kube-proxy, coredns, eks-node-monitoring-agent, aws-ebs-csi-driver).
    Unset fields keep the module default. Set enabled = false to drop a core add-on (the core networking add-ons are preserved: their workloads keep running until you delete them).
    before_compute = true creates an extra add-on before node groups; use it only for DaemonSets that must run before workloads. It is create-time only
    (changing it moves the add-on between two resources; use a moved block) and cannot be overridden for core add-ons.
    version null pins the EKS default version for kubernetes_version (most_recent = true picks the newest instead, which drifts as AWS publishes builds).
  EOT
  type = map(object({
    enabled                      = optional(bool)
    version                      = optional(string)
    most_recent                  = optional(bool)
    configuration_values         = optional(string)
    before_compute               = optional(bool)
    pod_identity_role_arn        = optional(string)
    pod_identity_service_account = optional(string)
    resolve_conflicts_on_create  = optional(string)
    resolve_conflicts_on_update  = optional(string)
    preserve                     = optional(bool)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for a in values(var.addons) : (a.pod_identity_role_arn == null) == (a.pod_identity_service_account == null)])
    error_message = "Set pod_identity_role_arn and pod_identity_service_account together."
  }

  validation {
    condition = alltrue([for name, a in var.addons :
      a.before_compute == null || !contains(["eks-pod-identity-agent", "vpc-cni", "kube-proxy", "eks-node-monitoring-agent", "coredns", "aws-ebs-csi-driver"], name)
    ])
    error_message = "before_compute cannot be overridden for the module's core add-ons; their ordering is fixed."
  }
}

variable "vpc_cni" {
  description = "Settings rendered into the vpc-cni add-on configuration (ignored if addons[\"vpc-cni\"].configuration_values is set). network_policy_enforcing_mode = strict makes every pod default-deny, so allow CoreDNS and other dependencies with NetworkPolicies before enabling it. enable_pod_security_groups also attaches AmazonEKSVPCResourceController to the cluster role."
  type = object({
    enable_network_policy         = optional(bool, true)
    network_policy_enforcing_mode = optional(string, "standard")
    enable_prefix_delegation      = optional(bool, false)
    enable_pod_security_groups    = optional(bool, false)
  })
  default  = {}
  nullable = false

  validation {
    condition     = contains(["standard", "strict"], var.vpc_cni.network_policy_enforcing_mode)
    error_message = "vpc_cni.network_policy_enforcing_mode must be standard or strict."
  }
}

variable "enable_ebs_csi_driver" {
  description = "Install the aws-ebs-csi-driver add-on with a Pod Identity role using the managed policy chosen by ebs_csi_driver_policy (cluster-scoped by default) and permission to use the EBS KMS key."
  type        = bool
  default     = true
  nullable    = false
}

variable "enable_node_monitoring_agent" {
  description = "Install the eks-node-monitoring-agent add-on, which lets node auto repair react to kernel, runtime, network and storage faults."
  type        = bool
  default     = true
  nullable    = false
}

variable "ebs_csi_driver_policy" {
  description = "Managed policy for the EBS CSI driver's Pod Identity role. cluster_scoped (AmazonEBSCSIDriverEKSClusterScopedPolicy) limits the driver to volumes, snapshots and instances tagged for this cluster, and needs driver v1.58.0+. v2 (AmazonEBSCSIDriverPolicyV2) covers every CSI-managed volume in the account. Statically provisioned volumes need the ebs.csi.aws.com/cluster-name tag under cluster_scoped."
  type        = string
  default     = "cluster_scoped"
  nullable    = false

  validation {
    condition     = contains(["cluster_scoped", "v2"], var.ebs_csi_driver_policy)
    error_message = "ebs_csi_driver_policy must be cluster_scoped or v2."
  }
}

################################################################################
# Ordering
################################################################################

variable "node_group_dependencies" {
  description = "Values (for example VPC endpoint IDs) that must exist before node groups are created. Nodes in a no-NAT VPC cannot bootstrap until the endpoints exist. Use this instead of a module-level depends_on, which defers every data source in the module and makes Terraform replace (and detach) IAM resources."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "ebs_csi_additional_kms_key_arns" {
  description = "Extra KMS keys the EBS CSI driver may use, for example the previous EBS key after a key switch. Keep it listed until every volume and snapshot encrypted with it has been migrated or deleted."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "deletion_guard_dependencies" {
  description = "IDs of caller resources that should only be destroyed after the deletion guard passes, for example Helm releases or VPC endpoints the cluster depends on. With deletion_protection on, terraform destroy then fails before touching them too. Listed resources must order themselves on specific module outputs (e.g. node_groups, addons), not with depends_on = [module.<name>], which would be a dependency cycle."
  type        = list(string)
  default     = []
  nullable    = false
}
