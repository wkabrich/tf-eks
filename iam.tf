locals {
  iam_role_name_prefix = substr(var.name, 0, 28)
  iam_policy_arn       = "arn:${local.partition}:iam::aws:policy"
  cni_policy_arn       = var.ip_family == "ipv6" ? aws_iam_policy.cni_ipv6[0].arn : "${local.iam_policy_arn}/AmazonEKS_CNI_Policy"
}

################################################################################
# Cluster role
################################################################################

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    sid     = "EKSClusterAssumeRole"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.${local.dns_suffix}"]
    }

    # Confused-deputy protection: only this cluster, in this account, may assume the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = [local.cluster_arn]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name_prefix           = "${local.iam_role_name_prefix}-cluster-"
  description           = "EKS cluster role for ${var.name}"
  assume_role_policy    = data.aws_iam_policy_document.cluster_assume_role.json
  force_detach_policies = true

  tags = var.tags
}

locals {
  cluster_managed_policy_arns = merge(
    { AmazonEKSClusterPolicy = "${local.iam_policy_arn}/AmazonEKSClusterPolicy" },
    # Security groups for pods needs EKS to manage trunk and branch ENIs.
    var.vpc_cni.enable_pod_security_groups ? { AmazonEKSVPCResourceController = "${local.iam_policy_arn}/AmazonEKSVPCResourceController" } : {},
  )
}

# Managed policies are attached with the *_exclusive resource rather than one attachment per policy.
# A change to the set is an in-place update, so it can never be planned as create-before-destroy
# replacements, which would end with the policy detached. It also removes policies attached outside
# Terraform.
# Earlier drafts attached policies one aws_iam_role_policy_attachment at a time. Forget those without
# detaching anything; the exclusive resources adopt the existing attachments.
removed {
  from = aws_iam_role_policy_attachment.cluster

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.node

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.pod_identity

  lifecycle {
    destroy = false
  }
}

resource "aws_iam_role_policy_attachments_exclusive" "cluster" {
  role_name   = aws_iam_role.cluster.name
  policy_arns = values(local.cluster_managed_policy_arns)
}

data "aws_iam_policy_document" "cluster_kms" {
  statement {
    sid       = "EnvelopeEncryptionKeyUse"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:ListGrants"]
    resources = [local.cluster_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "cluster_kms" {
  name   = "envelope-encryption"
  role   = aws_iam_role.cluster.id
  policy = data.aws_iam_policy_document.cluster_kms.json
}

################################################################################
# Node role (shared by all managed node groups)
################################################################################

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    sid     = "EC2AssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.${local.dns_suffix}"]
    }
  }
}

# The exclusive attachment resource does nothing on destroy, so customer-managed policies attached to a
# module role must outlive the role (whose deletion force-detaches them). Otherwise DeletePolicy can run
# while the policy is still attached and fail.
resource "terraform_data" "node_policy_arns" {
  input = values(local.node_managed_policy_arns)
}

resource "aws_iam_role" "node" {
  name_prefix           = "${local.iam_role_name_prefix}-node-"
  description           = "EKS managed node group role for ${var.name}"
  assume_role_policy    = data.aws_iam_policy_document.node_assume_role.json
  force_detach_policies = true

  tags = var.tags

  depends_on = [terraform_data.node_policy_arns]
}

locals {
  node_managed_policy_arns = merge(
    {
      # Includes eks-auth:AssumeRoleForPodIdentity for the Pod Identity agent.
      AmazonEKSWorkerNodePolicy = "${local.iam_policy_arn}/AmazonEKSWorkerNodePolicy"
      # Pull only: no repository enumeration (CIS EKS 5.1.3).
      AmazonEC2ContainerRegistryPullOnly = "${local.iam_policy_arn}/AmazonEC2ContainerRegistryPullOnly"
    },
    var.attach_cni_policy_to_node_role ? { AmazonEKS_CNI_Policy = local.cni_policy_arn } : {},
    var.node_iam_role_additional_policy_arns,
  )
}

resource "aws_iam_role_policy_attachments_exclusive" "node" {
  role_name   = aws_iam_role.node.name
  policy_arns = values(local.node_managed_policy_arns)
}

# EKS best-practice minimal Session Manager policy. Unlike AmazonSSMManagedInstanceCore it does
# not grant ssm:GetParameter(s) on every parameter in the account.
data "aws_iam_policy_document" "node_ssm" {
  count = var.enable_node_ssm_access ? 1 : 0

  #checkov:skip=CKV_AWS_111:These Session Manager channel and Run Command actions do not support resource-level permissions.
  #checkov:skip=CKV_AWS_356:These Session Manager channel and Run Command actions do not support resource-level permissions.

  statement {
    sid = "SessionManager"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid = "RunCommand"
    actions = [
      "ec2messages:AcknowledgeMessage",
      "ec2messages:DeleteMessage",
      "ec2messages:FailMessage",
      "ec2messages:GetEndpoint",
      "ec2messages:GetMessages",
      "ec2messages:SendReply",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "node_ssm" {
  count = var.enable_node_ssm_access ? 1 : 0

  name   = "ssm-session-manager"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node_ssm[0].json
}

################################################################################
# VPC CNI IPv6 policy (no AWS managed equivalent)
################################################################################

data "aws_iam_policy_document" "cni_ipv6" {
  count = var.ip_family == "ipv6" ? 1 : 0

  #checkov:skip=CKV_AWS_111:EC2 Describe* and AssignIpv6Addresses do not support resource-level permissions.
  #checkov:skip=CKV_AWS_356:EC2 Describe* and AssignIpv6Addresses do not support resource-level permissions.

  statement {
    sid = "AssignDescribe"
    actions = [
      "ec2:AssignIpv6Addresses",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "CreateTags"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:${local.partition}:ec2:*:*:network-interface/*"]
  }
}

resource "aws_iam_policy" "cni_ipv6" {
  count = var.ip_family == "ipv6" ? 1 : 0

  name_prefix = "${local.iam_role_name_prefix}-cni-ipv6-"
  description = "Amazon VPC CNI permissions for IPv6 EKS cluster ${var.name}"
  policy      = data.aws_iam_policy_document.cni_ipv6[0].json

  tags = var.tags
}

################################################################################
# Pod Identity roles for module-managed add-ons
################################################################################

data "aws_iam_policy" "ebs_csi" {
  count = local.create_ebs_csi_role ? 1 : 0

  # Looked up by name because AWS documents these policies' ARNs both with and without the service-role/ path.
  name = var.ebs_csi_driver_policy == "cluster_scoped" ? "AmazonEBSCSIDriverEKSClusterScopedPolicy" : "AmazonEBSCSIDriverPolicyV2"
}

locals {
  pod_identity_roles = merge(
    local.create_vpc_cni_role ? {
      vpc-cni = {
        namespace       = "kube-system"
        service_account = "aws-node"
        policy_arns     = { cni = local.cni_policy_arn }
      }
    } : {},
    local.create_ebs_csi_role ? {
      aws-ebs-csi-driver = {
        namespace       = "kube-system"
        service_account = "ebs-csi-controller-sa"
        policy_arns     = { ebs = data.aws_iam_policy.ebs_csi[0].arn }
      }
    } : {},
  )

}

data "aws_iam_policy_document" "pod_identity_assume_role" {
  for_each = local.pod_identity_roles

  statement {
    sid     = "EKSPodIdentity"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Pod Identity session tags: only this service account, in this namespace, on this cluster.
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/eks-cluster-arn"
      values   = [local.cluster_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-namespace"
      values   = [each.value.namespace]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes-service-account"
      values   = [each.value.service_account]
    }
  }
}

resource "aws_iam_role" "pod_identity" {
  for_each = local.pod_identity_roles

  name_prefix           = "${local.iam_role_name_prefix}-${substr(each.key, 0, 7)}-"
  description           = "EKS Pod Identity role for ${each.value.namespace}/${each.value.service_account} on ${var.name}"
  assume_role_policy    = data.aws_iam_policy_document.pod_identity_assume_role[each.key].json
  force_detach_policies = true

  tags = var.tags

  # Destroyed (force-detaching its policies) before the custom IPv6 CNI policy is deleted.
  depends_on = [aws_iam_policy.cni_ipv6]
}

resource "aws_iam_role_policy_attachments_exclusive" "pod_identity" {
  for_each = local.pod_identity_roles

  role_name   = aws_iam_role.pod_identity[each.key].name
  policy_arns = values(each.value.policy_arns)
}

# Lets the EBS CSI driver create and attach volumes encrypted with the EBS key, so StorageClasses can
# set kmsKeyId to the ebs_kms_key_arn output.
data "aws_iam_policy_document" "ebs_csi_kms" {
  count = local.create_ebs_csi_role ? 1 : 0

  statement {
    sid       = "EBSKeyUse"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"]
    resources = concat([local.ebs_kms_key_arn], var.ebs_csi_additional_kms_key_arns)
  }

  statement {
    sid       = "EBSKeyGrants"
    actions   = ["kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant"]
    resources = concat([local.ebs_kms_key_arn], var.ebs_csi_additional_kms_key_arns)

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_iam_role_policy" "ebs_csi_kms" {
  count = local.create_ebs_csi_role ? 1 : 0

  name   = "ebs-kms"
  role   = aws_iam_role.pod_identity["aws-ebs-csi-driver"].id
  policy = data.aws_iam_policy_document.ebs_csi_kms[0].json
}

################################################################################
# IRSA (optional)
################################################################################

resource "aws_iam_openid_connect_provider" "this" {
  count = var.enable_irsa ? 1 : 0

  url            = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list = ["sts.${local.dns_suffix}"]
  # thumbprint_list is omitted: IAM fetches and trusts the issuer's CA itself, so the Terraform
  # runner never needs to reach the OIDC endpoint (useful in no-egress networks).

  tags = merge(var.tags, { Name = "${var.name}-irsa" })
}
