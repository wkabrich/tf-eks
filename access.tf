locals {
  cluster_admin_policy_arn = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_entries = merge(
    var.enable_cluster_creator_admin_permissions ? {
      cluster_creator = {
        principal_arn     = data.aws_iam_session_context.current[0].issuer_arn
        type              = "STANDARD"
        kubernetes_groups = null
        user_name         = null
        tags              = {}
        policy_associations = {
          cluster_admin = {
            policy_arn   = local.cluster_admin_policy_arn
            access_scope = { type = "cluster", namespaces = null }
          }
        }
      }
    } : {},
    var.access_entries,
  )

  access_policy_associations = merge([
    for entry_key, entry in local.access_entries : {
      for policy_key, policy in entry.policy_associations : "${entry_key}/${policy_key}" => {
        entry_key     = entry_key
        principal_arn = entry.principal_arn
        policy_arn    = policy.policy_arn
        access_scope  = policy.access_scope
      }
    }
  ]...)
}

resource "aws_eks_access_entry" "this" {
  for_each = local.access_entries

  cluster_name      = aws_eks_cluster.this.name
  principal_arn     = each.value.principal_arn
  type              = each.value.type
  kubernetes_groups = each.value.kubernetes_groups
  user_name         = each.value.user_name

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    precondition {
      condition     = length(distinct([for e in values(local.access_entries) : e.principal_arn])) == length(local.access_entries)
      error_message = "The Terraform caller (enable_cluster_creator_admin_permissions) is also listed in access_entries, and EKS allows one access entry per principal. Remove it from access_entries or turn off enable_cluster_creator_admin_permissions."
    }
  }
}

resource "aws_eks_access_policy_association" "this" {
  for_each = local.access_policy_associations

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_eks_access_entry.this[each.value.entry_key].principal_arn
  policy_arn    = each.value.policy_arn

  access_scope {
    type       = each.value.access_scope.type
    namespaces = each.value.access_scope.type == "namespace" ? each.value.access_scope.namespaces : null
  }
}
