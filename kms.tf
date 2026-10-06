################################################################################
# KMS
#
# Three keys by default, because each has a different blast radius and a disjoint set of principals:
#   cluster: KEK for Kubernetes API data. Deleting it, or revoking EKS's grant, makes the cluster
#            unrecoverable.
#   logs:    control-plane log group. Only CloudWatch Logs may use it, and only for this group.
#   ebs:     node root/data volumes. The EC2 Auto Scaling service-linked role launches the instances.
################################################################################

locals {
  kms_admin_actions = [
    "kms:CancelKeyDeletion",
    "kms:Create*",
    "kms:Delete*",
    "kms:Describe*",
    "kms:Disable*",
    "kms:Enable*",
    "kms:Get*",
    "kms:List*",
    "kms:Put*",
    "kms:Revoke*",
    "kms:RotateKeyOnDemand",
    "kms:ScheduleKeyDeletion",
    "kms:TagResource",
    "kms:UntagResource",
    "kms:Update*",
  ]

  autoscaling_service_linked_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"
}

data "aws_iam_policy_document" "kms_base" {
  #checkov:skip=CKV_AWS_109:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_111:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_356:KMS key policy - Resource "*" refers to the key the policy is attached to.

  # Standard default statement. It delegates access control to IAM and keeps the key from ever
  # becoming unmanageable.
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  dynamic "statement" {
    for_each = length(var.kms_key_administrator_arns) > 0 ? [1] : []

    content {
      sid       = "KeyAdministration"
      actions   = local.kms_admin_actions
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = var.kms_key_administrator_arns
      }
    }
  }
}

#-------------------------------------------------------------------------------
# Kubernetes API envelope encryption
#-------------------------------------------------------------------------------

resource "aws_kms_key" "cluster" {
  count = var.create_kms_key ? 1 : 0

  description              = "EKS ${var.name}: Kubernetes API envelope encryption"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = var.kms_key_deletion_window_in_days
  policy                   = data.aws_iam_policy_document.kms_base.json

  tags = merge(var.tags, { Name = "${var.name}-eks" })
}

resource "aws_kms_alias" "cluster" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/eks/${var.name}"
  target_key_id = aws_kms_key.cluster[0].key_id
}

#-------------------------------------------------------------------------------
# Control-plane log group
#-------------------------------------------------------------------------------

data "aws_iam_policy_document" "logs_kms" {
  count = var.create_cloudwatch_log_group_kms_key ? 1 : 0

  #checkov:skip=CKV_AWS_109:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_111:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_356:KMS key policy - Resource "*" refers to the key the policy is attached to.

  source_policy_documents = [data.aws_iam_policy_document.kms_base.json]

  statement {
    sid = "CloudWatchLogsUseForClusterLogGroup"
    actions = [
      "kms:Decrypt",
      "kms:Describe*",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.${local.dns_suffix}"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.log_group_arn]
    }
  }
}

resource "aws_kms_key" "logs" {
  count = var.create_cloudwatch_log_group_kms_key ? 1 : 0

  description              = "EKS ${var.name}: control-plane CloudWatch log group"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = var.kms_key_deletion_window_in_days
  policy                   = data.aws_iam_policy_document.logs_kms[0].json

  tags = merge(var.tags, { Name = "${var.name}-logs" })
}

resource "aws_kms_alias" "logs" {
  count = var.create_cloudwatch_log_group_kms_key ? 1 : 0

  name          = "alias/eks/${var.name}/logs"
  target_key_id = aws_kms_key.logs[0].key_id
}

#-------------------------------------------------------------------------------
# Node and persistent-volume EBS encryption
#-------------------------------------------------------------------------------

resource "aws_iam_service_linked_role" "autoscaling" {
  count = var.create_autoscaling_service_linked_role ? 1 : 0

  aws_service_name = "autoscaling.amazonaws.com"
  tags             = var.tags
}

data "aws_iam_policy_document" "ebs_kms" {
  count = var.create_ebs_kms_key ? 1 : 0

  #checkov:skip=CKV_AWS_109:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_111:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_356:KMS key policy - Resource "*" refers to the key the policy is attached to.

  source_policy_documents = [data.aws_iam_policy_document.kms_base.json]

  # Managed node groups launch through an Auto Scaling group, so the Auto Scaling service-linked
  # role (not the node role) creates and attaches the encrypted volumes.
  statement {
    sid = "AutoScalingServiceLinkedRoleUse"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.autoscaling_service_linked_role_arn]
    }
  }

  statement {
    sid       = "AutoScalingServiceLinkedRoleGrants"
    actions   = ["kms:CreateGrant"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.autoscaling_service_linked_role_arn]
    }

    condition {
      test     = "Bool"
      variable = "kms:GrantIsForAWSResource"
      values   = ["true"]
    }
  }
}

resource "aws_kms_key" "ebs" {
  count = var.create_ebs_kms_key ? 1 : 0

  description              = "EKS ${var.name}: node and persistent-volume EBS encryption"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = var.kms_key_deletion_window_in_days
  policy                   = data.aws_iam_policy_document.ebs_kms[0].json

  tags = merge(var.tags, { Name = "${var.name}-ebs" })

  # KMS rejects policies that name principals which do not exist yet.
  depends_on = [aws_iam_service_linked_role.autoscaling]
}

resource "aws_kms_alias" "ebs" {
  count = var.create_ebs_kms_key ? 1 : 0

  name          = "alias/eks/${var.name}/ebs"
  target_key_id = aws_kms_key.ebs[0].key_id
}

#-------------------------------------------------------------------------------
# Key-switch guards
#
# Changing a key input on an existing cluster would leave the cluster on its old KEK (EKS cannot
# re-key, and the provider silently skips the change) and schedule the module-created key for
# deletion. That degrades the cluster permanently, and makes existing logs and volumes unreadable.
#   kms_key_ownership: which keys the module owns. The create_* flags are always known at plan time,
#                      so moving away from a module key fails before any key is touched.
#   kms_key_guard:     one per key, holding the ARN in use since creation (ignore_changes freezes it).
#                      Every consumer reads the frozen ARN, so a changed input never reaches the cluster,
#                      log group, launch templates or CSI policy. The postcondition fails at plan when the
#                      new ARN is known at plan time, otherwise at apply, before anything is re-keyed.
# Intentional switches of the logs or EBS key re-baseline the matching guard with -replace (README:
# key-switch procedure).
#-------------------------------------------------------------------------------

resource "terraform_data" "kms_key_ownership" {
  input = {
    cluster = var.create_kms_key
    logs    = var.create_cloudwatch_log_group_kms_key
    ebs     = var.create_ebs_kms_key
  }

  lifecycle {
    ignore_changes = [input]

    postcondition {
      condition     = self.output.cluster == var.create_kms_key
      error_message = "create_kms_key cannot change after the cluster exists: EKS cannot re-key, and the module-created key would be scheduled for deletion while the cluster still uses it."
    }

    postcondition {
      condition     = self.output.logs == var.create_cloudwatch_log_group_kms_key && self.output.ebs == var.create_ebs_kms_key
      error_message = "create_cloudwatch_log_group_kms_key / create_ebs_kms_key changed, which would schedule deletion of a key that still encrypts existing logs or volumes. Revert, or follow the key-switch procedure in the README."
    }
  }
}

resource "terraform_data" "kms_key_guard" {
  for_each = local.requested_kms_key_arns

  input = each.value

  lifecycle {
    ignore_changes = [input]

    postcondition {
      condition     = self.output == each.value
      error_message = "The ${each.key} KMS key input changed after creation. ${each.key == "cluster" ? "EKS cannot re-key a cluster; revert kms_key_arn." : "Existing data is still encrypted with the old key; revert, or follow the key-switch procedure in the README."}"
    }
  }
}
