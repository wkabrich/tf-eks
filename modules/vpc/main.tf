################################################################################
# A VPC with no path to the internet: no internet gateway, no NAT gateway, and only local routes.
# Workloads reach AWS services through VPC endpoints (see ../vpc-endpoints).
################################################################################

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  create_flow_log_kms_key = var.enable_flow_logs && var.create_flow_log_kms_key
  flow_log_group_name     = "/aws/vpc-flow-log/${var.name}"
  # Built from the name so the KMS key policy does not depend on the log group it encrypts.
  flow_log_group_arn   = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${local.flow_log_group_name}"
  flow_log_kms_key_arn = local.create_flow_log_kms_key ? aws_kms_key.flow_logs[0].arn : var.flow_log_kms_key_arn
}

resource "aws_vpc" "this" {
  cidr_block = var.cidr

  # Required by the EKS private endpoint (Route 53 private hosted zone) and interface endpoint private DNS.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# Adopting the default security group removes all of its rules, so nothing can fall back to it. The
# explicit empty lists make Terraform remove any rule added later, rather than ignoring it.
resource "aws_default_security_group" "this" {
  vpc_id  = aws_vpc.this.id
  ingress = []
  egress  = []

  tags = merge(var.tags, { Name = "${var.name}-default" })
}

################################################################################
# Subnets
################################################################################

resource "aws_subnet" "private" {
  count = length(var.private_subnets)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnets[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.name}-private-${var.azs[count.index]}" }, var.private_subnet_tags)
}

# One route table per AZ: only the local route, plus whatever gateway endpoints (S3) attach to it.
resource "aws_route_table" "private" {
  count = length(var.private_subnets)

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-private-${var.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count = length(var.private_subnets)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_subnet" "control_plane" {
  count = length(var.control_plane_subnets)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.control_plane_subnets[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.name}-control-plane-${var.azs[count.index]}" }, var.control_plane_subnet_tags)
}

resource "aws_route_table" "control_plane" {
  count = length(var.control_plane_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-control-plane" })
}

resource "aws_route_table_association" "control_plane" {
  count = length(var.control_plane_subnets)

  subnet_id      = aws_subnet.control_plane[count.index].id
  route_table_id = aws_route_table.control_plane[0].id
}

################################################################################
# Flow logs
################################################################################

data "aws_iam_policy_document" "flow_logs_kms" {
  count = local.create_flow_log_kms_key ? 1 : 0

  #checkov:skip=CKV_AWS_109:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_111:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_356:KMS key policy - Resource "*" refers to the key the policy is attached to.

  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchLogsUseForFlowLogGroup"
    actions   = ["kms:Decrypt", "kms:Describe*", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.${data.aws_partition.current.dns_suffix}"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.flow_log_group_arn]
    }
  }
}

resource "aws_kms_key" "flow_logs" {
  count = local.create_flow_log_kms_key ? 1 : 0

  description             = "${var.name}: VPC flow logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.flow_logs_kms[0].json

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })
}

resource "aws_kms_alias" "flow_logs" {
  count = local.create_flow_log_kms_key ? 1 : 0

  name          = "alias/vpc/${var.name}/flow-logs"
  target_key_id = aws_kms_key.flow_logs[0].key_id
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = local.flow_log_group_name
  retention_in_days = var.flow_log_retention_in_days
  kms_key_id        = local.flow_log_kms_key_arn

  tags = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume_role" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    sid     = "VPCFlowLogsAssumeRole"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    # Confused-deputy protection: only flow logs in this account and Region.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:ec2:${local.region}:${local.account_id}:vpc-flow-log/*"]
    }
  }
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name_prefix        = "${substr(var.name, 0, 26)}-flow-logs-"
  description        = "VPC flow logs delivery for ${var.name}"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume_role[0].json

  tags = var.tags
}

data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    sid       = "WriteFlowLogGroup"
    actions   = ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"]
    resources = ["${local.flow_log_group_arn}:*"]
  }

  statement {
    sid       = "DescribeLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "flow-logs-delivery"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = var.flow_log_traffic_type
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = var.flow_log_max_aggregation_interval

  tags = merge(var.tags, { Name = var.name })

  depends_on = [aws_iam_role_policy.flow_logs]
}
