data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_session_context" "current" {
  count = var.enable_cluster_creator_admin_permissions ? 1 : 0

  # Resolves an assumed-role session ARN to the underlying IAM role ARN, which is what access entries need.
  arn = data.aws_caller_identity.current.arn
}

data "aws_vpc" "this" {
  id = var.vpc_id
}

# One filtered query rather than a lookup per subnet, so it still works (as a read deferred to apply)
# when the subnet list itself is only known after apply.
data "aws_subnets" "control_plane_unsupported_az" {
  filter {
    name   = "subnet-id"
    values = local.control_plane_subnet_ids
  }

  filter {
    name   = "availability-zone-id"
    values = local.eks_unsupported_az_ids
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 0
      error_message = "EKS does not accept control-plane subnets in AZ IDs ${join(", ", local.eks_unsupported_az_ids)}; move these subnets: ${join(", ", self.ids)}."
    }
  }
}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region
  dns_suffix = data.aws_partition.current.dns_suffix

  # Built from the name, not aws_eks_cluster.this.arn, so IAM trust policies and the log-group
  # KMS policy can be created before the cluster without a dependency cycle.
  cluster_arn              = "arn:${local.partition}:eks:${local.region}:${local.account_id}:cluster/${var.name}"
  log_group_name           = "/aws/eks/${var.name}/cluster"
  log_group_arn            = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.log_group_name}"
  control_plane_subnet_ids = length(var.control_plane_subnet_ids) > 0 ? var.control_plane_subnet_ids : var.node_subnet_ids

  # The keys asked for by the inputs ...
  requested_kms_key_arns = {
    cluster = var.create_kms_key ? aws_kms_key.cluster[0].arn : var.kms_key_arn
    logs    = var.create_cloudwatch_log_group_kms_key ? aws_kms_key.logs[0].arn : var.cloudwatch_log_group_kms_key_arn
    ebs     = var.create_ebs_kms_key ? aws_kms_key.ebs[0].arn : var.ebs_kms_key_arn
  }

  # ... and the keys actually used, frozen at creation by the per-key guards in kms.tf. Every consumer reads
  # these, so an input change can never re-key the cluster, log group, launch templates or CSI policy
  # until the matching guard is deliberately re-baselined.
  cluster_kms_key_arn = terraform_data.kms_key_guard["cluster"].output
  logs_kms_key_arn    = terraform_data.kms_key_guard["logs"].output
  ebs_kms_key_arn     = terraform_data.kms_key_guard["ebs"].output

  # AZ IDs that EKS does not accept for control-plane subnets.
  eks_unsupported_az_ids = ["use1-az3", "usw1-az2", "cac1-az3"]

  vpc_ipv4_cidr_blocks = distinct(concat([data.aws_vpc.this.cidr_block], [for a in data.aws_vpc.this.cidr_block_associations : a.cidr_block]))
  service_cidr_prefix  = var.service_ipv4_cidr == null ? null : tonumber(split("/", var.service_ipv4_cidr)[1])
}

################################################################################
# Control-plane logging
################################################################################

# Pre-created so retention and encryption apply from the first log line. Otherwise EKS would
# create the group itself, unencrypted and with infinite retention.
resource "aws_cloudwatch_log_group" "this" {
  name                        = local.log_group_name
  retention_in_days           = var.cloudwatch_log_group_retention_in_days
  kms_key_id                  = local.logs_kms_key_arn
  log_group_class             = var.cloudwatch_log_group_class
  deletion_protection_enabled = var.cloudwatch_log_group_deletion_protection

  tags = var.tags
}

################################################################################
# Cluster
################################################################################

resource "aws_eks_cluster" "this" {
  #checkov:skip=CKV_AWS_339:Checkov's allow-list stops at 1.35 (Oct 2026) while EKS standard support covers 1.34-1.37; the version is validated by var.kubernetes_version and the version_support check block.
  name     = var.name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = var.cluster_enabled_log_types

  # Core networking add-ons are installed as EKS managed add-ons (addons.tf) instead of the
  # unmanaged copies EKS would otherwise bootstrap.
  bootstrap_self_managed_addons = false

  deletion_protection = var.deletion_protection

  access_config {
    # Access entries only: no aws-auth ConfigMap. The transition is one-way, so API is final.
    authentication_mode = "API"
    # Nobody gets implicit cluster-admin; admins are granted through access_entries.
    bootstrap_cluster_creator_admin_permissions = false
  }

  encryption_config {
    # "secrets" is deprecated upstream but still required by provider 6.x and scanners. With a
    # customer managed key, EKS uses it as the KEK for all Kubernetes API data.
    resources = ["secrets"]

    provider {
      key_arn = local.cluster_kms_key_arn
    }
  }

  vpc_config {
    subnet_ids                = local.control_plane_subnet_ids
    security_group_ids        = [aws_security_group.cluster.id]
    endpoint_private_access   = true
    endpoint_public_access    = false
    control_plane_egress_mode = var.control_plane_egress_mode
  }

  kubernetes_network_config {
    ip_family         = var.ip_family
    service_ipv4_cidr = var.service_ipv4_cidr
  }

  upgrade_policy {
    support_type = var.upgrade_support_type
  }

  dynamic "control_plane_scaling_config" {
    for_each = var.control_plane_scaling_tier != null ? [var.control_plane_scaling_tier] : []

    content {
      tier = control_plane_scaling_config.value
    }
  }

  dynamic "zonal_shift_config" {
    for_each = var.zonal_shift_enabled != null ? [var.zonal_shift_enabled] : []

    content {
      enabled = zonal_shift_config.value
    }
  }

  tags = merge(var.tags, var.cluster_tags)

  timeouts {
    create = var.cluster_timeouts.create
    update = var.cluster_timeouts.update
    delete = var.cluster_timeouts.delete
  }

  lifecycle {
    # The API never returns these two create-time flags. Ignoring them keeps imported or adopted
    # clusters from being planned for replacement.
    ignore_changes = [
      access_config[0].bootstrap_cluster_creator_admin_permissions,
      bootstrap_self_managed_addons,
    ]

    precondition {
      condition     = data.aws_vpc.this.enable_dns_support && data.aws_vpc.this.enable_dns_hostnames
      error_message = "VPC ${var.vpc_id} must have enableDnsSupport and enableDnsHostnames turned on: the private API endpoint and interface VPC endpoints rely on Route 53 private hosted zones."
    }

    precondition {
      condition     = var.ip_family == "ipv4" || var.service_ipv4_cidr == null
      error_message = "service_ipv4_cidr cannot be set when ip_family is ipv6."
    }

    precondition {
      # Two CIDRs overlap exactly when their network addresses agree under the shorter prefix.
      condition = var.service_ipv4_cidr == null ? true : alltrue([
        for c in local.vpc_ipv4_cidr_blocks :
        cidrhost("${cidrhost(var.service_ipv4_cidr, 0)}/${min(local.service_cidr_prefix, tonumber(split("/", c)[1]))}", 0) !=
        cidrhost("${cidrhost(c, 0)}/${min(local.service_cidr_prefix, tonumber(split("/", c)[1]))}", 0)
      ])
      error_message = "service_ipv4_cidr ${coalesce(var.service_ipv4_cidr, "-")} overlaps a CIDR block of VPC ${var.vpc_id}."
    }

    precondition {
      condition = contains(keys(local.enabled_addons), "eks-pod-identity-agent") || (
        !local.create_vpc_cni_role && !local.create_ebs_csi_role &&
        alltrue([for addon in values(local.enabled_addons) : addon.pod_identity_service_account == null])
      )
      error_message = "eks-pod-identity-agent must stay enabled while any add-on uses Pod Identity (vpc-cni and the EBS CSI driver do by default)."
    }
  }

  depends_on = [
    data.aws_subnets.control_plane_unsupported_az,
    aws_cloudwatch_log_group.this,
    aws_iam_role_policy_attachments_exclusive.cluster,
    aws_iam_role_policy.cluster_kms,
    aws_vpc_security_group_ingress_rule.cluster,
  ]
}

################################################################################
# Destroy guard
#
# EKS deletion protection only fails DeleteCluster. On its own, terraform destroy would first tear
# down everything that depends on the cluster (nodes, add-ons, access entries) and every independent
# branch (EBS key, IAM roles) before reaching that error. This guard depends on every leaf resource
# in the module, so it is destroyed first and stops the destroy while deletion_protection is true.
################################################################################

resource "terraform_data" "deletion_guard" {
  # Values in dependencies are only there to order the caller's resources behind the guard.
  input = {
    protect      = var.deletion_protection
    dependencies = var.deletion_guard_dependencies
  }

  provisioner "local-exec" {
    when = destroy
    # try() also accepts the plain bool this guard stored in earlier drafts.
    command = try(self.input.protect, self.input) ? "echo deletion_protection is true for this EKS cluster: apply with deletion_protection = false before destroying && exit 1" : "exit 0"
  }

  depends_on = [
    aws_eks_node_group.this,
    aws_eks_addon.this,
    aws_eks_access_policy_association.this,
    aws_iam_openid_connect_provider.this,
    aws_iam_role_policy.node_ssm,
    aws_kms_alias.cluster,
    aws_kms_alias.logs,
    aws_kms_alias.ebs,
    aws_cloudwatch_log_metric_filter.audit,
    aws_cloudwatch_metric_alarm.audit,
    aws_vpc_security_group_egress_rule.node_all_ipv4,
    aws_vpc_security_group_egress_rule.node_all_ipv6,
    terraform_data.kms_key_guard,
    terraform_data.kms_key_ownership,
  ]
}

# Warns (without failing) when the chosen version has left standard support and is billed at the
# extended-support rate, or will be force-upgraded.
check "version_support" {
  data "aws_eks_cluster_versions" "standard" {
    cluster_type   = "eks"
    version_status = "STANDARD_SUPPORT"
  }

  assert {
    condition     = contains([for v in data.aws_eks_cluster_versions.standard.cluster_versions : v.cluster_version], var.kubernetes_version)
    error_message = "Kubernetes ${var.kubernetes_version} is not in EKS standard support. Upgrade, or set upgrade_support_type = \"EXTENDED\" and accept extended-support pricing."
  }
}
