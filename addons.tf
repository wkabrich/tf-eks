locals {
  addon_defaults = {
    enabled                      = true
    version                      = null
    most_recent                  = false
    configuration_values         = null
    before_compute               = false
    pod_identity_role_arn        = null
    pod_identity_service_account = null
    resolve_conflicts_on_create  = "OVERWRITE"
    resolve_conflicts_on_update  = "OVERWRITE"
    preserve                     = false
  }

  vpc_cni_env = merge(
    var.vpc_cni.enable_prefix_delegation ? { ENABLE_PREFIX_DELEGATION = "true", WARM_PREFIX_TARGET = "1" } : {},
    var.vpc_cni.enable_pod_security_groups ? { ENABLE_POD_ENI = "true", POD_SECURITY_GROUP_ENFORCING_MODE = "standard" } : {},
    var.vpc_cni.network_policy_enforcing_mode == "strict" ? { NETWORK_POLICY_ENFORCING_MODE = "strict" } : {},
  )

  # Add-on configuration values are strings even when they look like booleans.
  vpc_cni_configuration_values = jsonencode(merge(
    { enableNetworkPolicy = tostring(var.vpc_cni.enable_network_policy) },
    length(local.vpc_cni_env) > 0 ? { env = local.vpc_cni_env } : {},
  ))

  # DaemonSets that reach ACTIVE with zero nodes are created before the node groups, so nodes join with
  # networking, kube-proxy and Pod Identity already in place. Deployments (coredns, the EBS CSI
  # controller) stay DEGRADED without schedulable nodes, so they are created after the node groups.
  # Networking and DNS add-ons are preserved on delete: removing the add-on resource never takes the
  # running aws-node, kube-proxy, pod identity agent or CoreDNS workloads down with it.
  core_addons = {
    eks-pod-identity-agent = {
      before_compute = true
      preserve       = true
    }
    vpc-cni = {
      before_compute       = true
      preserve             = true
      configuration_values = local.vpc_cni_configuration_values
    }
    kube-proxy = {
      before_compute = true
      preserve       = true
    }
    eks-node-monitoring-agent = {
      before_compute = true
      enabled        = var.enable_node_monitoring_agent
    }
    coredns = {
      preserve = true
    }
    aws-ebs-csi-driver = {
      enabled = var.enable_ebs_csi_driver
    }
  }

  # Every add-on object has the same fixed set of fields, and a caller value replaces only its own
  # field. A value that is unknown until apply (say a role ARN created in the same run) therefore
  # cannot make the for_each keys below unknown.
  addons = {
    for name in setunion(keys(local.core_addons), keys(var.addons)) : name => {
      for field, default in merge(local.addon_defaults, try(local.core_addons[name], {})) :
      field => try(var.addons[name][field], null) == null ? default : try(var.addons[name][field], null)
    }
  }

  enabled_addons = { for name, addon in local.addons : name => addon if addon.enabled }

  addon_versions = {
    for name, addon in local.enabled_addons : name => (
      addon.version != null ? addon.version : try(data.aws_eks_addon_version.this[name].version, null)
    )
  }

  # The module creates Pod Identity roles for these add-ons unless the caller supplies their own.
  module_pod_identity_service_accounts = {
    vpc-cni            = "aws-node"
    aws-ebs-csi-driver = "ebs-csi-controller-sa"
  }

  # Decided from pod_identity_service_account (a literal in practice), not from the role ARN, which
  # may only be known after apply.
  create_vpc_cni_role = contains(keys(local.enabled_addons), "vpc-cni") && try(var.addons["vpc-cni"].pod_identity_service_account, null) == null
  create_ebs_csi_role = contains(keys(local.enabled_addons), "aws-ebs-csi-driver") && try(var.addons["aws-ebs-csi-driver"].pod_identity_service_account, null) == null

  addon_pod_identity = {
    for name, addon in local.enabled_addons : name => (
      addon.pod_identity_service_account != null ? {
        role_arn        = addon.pod_identity_role_arn
        service_account = addon.pod_identity_service_account
      } :
      contains(keys(local.pod_identity_roles), name) ? {
        role_arn        = aws_iam_role.pod_identity[name].arn
        service_account = local.module_pod_identity_service_accounts[name]
      } : null
    )
  }
}

data "aws_eks_addon_version" "this" {
  for_each = { for name, addon in local.enabled_addons : name => addon if addon.version == null }

  addon_name         = each.key
  kubernetes_version = coalesce(var.data_plane_kubernetes_version, var.kubernetes_version)
  most_recent        = each.value.most_recent
}

resource "aws_eks_addon" "before_compute" {
  for_each = { for name, addon in local.enabled_addons : name => addon if addon.before_compute }

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = local.addon_versions[each.key]
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = each.value.resolve_conflicts_on_create
  resolve_conflicts_on_update = each.value.resolve_conflicts_on_update
  preserve                    = each.value.preserve

  dynamic "pod_identity_association" {
    for_each = local.addon_pod_identity[each.key] != null ? [local.addon_pod_identity[each.key]] : []

    content {
      role_arn        = pod_identity_association.value.role_arn
      service_account = pod_identity_association.value.service_account
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachments_exclusive.pod_identity]
}

resource "aws_eks_addon" "this" {
  for_each = { for name, addon in local.enabled_addons : name => addon if !addon.before_compute }

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.key
  addon_version               = local.addon_versions[each.key]
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = each.value.resolve_conflicts_on_create
  resolve_conflicts_on_update = each.value.resolve_conflicts_on_update
  preserve                    = each.value.preserve

  dynamic "pod_identity_association" {
    for_each = local.addon_pod_identity[each.key] != null ? [local.addon_pod_identity[each.key]] : []

    content {
      role_arn        = pod_identity_association.value.role_arn
      service_account = pod_identity_association.value.service_account
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      # AmazonEBSCSIDriverEKSClusterScopedPolicy relies on the cluster-name volume tags that driver v1.58.0+ sets.
      condition = (
        each.key != "aws-ebs-csi-driver" || var.ebs_csi_driver_policy != "cluster_scoped" || !local.create_ebs_csi_role ? true :
        try(
          tonumber(regex("^v([0-9]+)\\.([0-9]+)", local.addon_versions[each.key])[0]) > 1 ||
          tonumber(regex("^v([0-9]+)\\.([0-9]+)", local.addon_versions[each.key])[1]) >= 58,
          false
        )
      )
      error_message = "ebs_csi_driver_policy = \"cluster_scoped\" needs aws-ebs-csi-driver v1.58.0 or later (this plan resolves ${coalesce(local.addon_versions[each.key], "an unknown version")}). Pin a newer version or use ebs_csi_driver_policy = \"v2\"."
    }
  }

  depends_on = [
    aws_eks_node_group.this,
    aws_iam_role_policy_attachments_exclusive.pod_identity,
    aws_iam_role_policy.ebs_csi_kms,
  ]
}

# Deployment add-ons stay DEGRADED, then time out after 20 minutes, without a schedulable node.
check "addon_compute" {
  assert {
    condition = (
      length([for addon in values(local.enabled_addons) : addon if !addon.before_compute]) == 0 ||
      anytrue([for ng in values(var.node_groups) : ng.desired_size > 0])
    )
    error_message = "coredns and the EBS CSI controller need at least one node group with desired_size >= 1 (or compute from another stack); otherwise their creation times out."
  }
}
