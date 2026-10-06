provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Example    = "tf-eks/complete"
      Repository = "tf-eks"
    }
  }
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  #checkov:skip=CKV_AWS_394:Zones are picked dynamically; zone IDs EKS rejects for control-plane subnets are excluded below.
  state = "available"
  # AZ IDs that EKS does not accept for control-plane subnets.
  exclude_zone_ids = ["use1-az3", "usw1-az2", "cac1-az3"]

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, min(3, length(data.aws_availability_zones.available.names)))
}

# VPC flow logs get their own customer managed key, like every other log group in this example.
data "aws_iam_policy_document" "flow_logs_kms" {
  #checkov:skip=CKV_AWS_109:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_111:KMS key policy - Resource "*" refers to the key the policy is attached to.
  #checkov:skip=CKV_AWS_356:KMS key policy - Resource "*" refers to the key the policy is attached to.
  statement {
    sid       = "EnableIAMPolicies"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "CloudWatchLogsUseForFlowLogs"
    actions   = ["kms:Decrypt", "kms:Describe*", "kms:Encrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"]
    }

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc-flow-log/*"]
    }
  }
}

resource "aws_kms_key" "flow_logs" {
  description             = "${var.name}: VPC flow logs"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.flow_logs_kms.json
}

################################################################################
# Network: no internet gateway, no NAT. Nodes reach AWS only through VPC endpoints.
################################################################################

module "vpc" {
  #checkov:skip=CKV_TF_1:Registry module pinned to an exact version.
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # Node subnets (/20 each). Routes stay inside the VPC.
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  # Dedicated /28 subnets for the EKS control-plane ENIs, as the EKS best practices recommend.
  intra_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 12, 4080 + i)]

  enable_nat_gateway   = false
  enable_dns_hostnames = true
  enable_dns_support   = true

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  # Lock down the default security group and record traffic for forensics.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 365
  flow_log_cloudwatch_log_group_kms_key_id        = aws_kms_key.flow_logs.arn
}

module "vpc_endpoints" {
  source = "../../modules/vpc-endpoints"

  name                = var.name
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnets
  route_table_ids     = module.vpc.private_route_table_ids
  allowed_cidr_blocks = [module.vpc.vpc_cidr_block]

  # Baseline plus Session Manager, so nodes can be inspected without SSH.
  interface_endpoints = ["ec2", "ecr.api", "ecr.dkr", "eks", "eks-auth", "logs", "sts", "ssm", "ssmmessages"]

  # Only this account's principals and buckets are reachable through the endpoints.
  data_perimeter = { enabled = true }
}

################################################################################
# Cluster
################################################################################

module "eks" {
  source = "../.."

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = module.vpc.vpc_id
  node_subnet_ids          = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  cluster_endpoint_allowed_cidr_blocks = var.admin_cidr_blocks
  service_ipv4_cidr                    = "172.20.0.0/16"

  # Normally left at the default (true). Disabled so the example can be torn down with terraform destroy.
  deletion_protection = false

  access_entries = {
    admin = {
      principal_arn = var.admin_role_arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  node_groups = {
    system = {
      ami_type       = "BOTTLEROCKET_ARM_64"
      instance_types = ["m7g.large"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      labels         = { "node-role" = "system" }
    }
    general = {
      ami_type     = "AL2023_x86_64_STANDARD"
      min_size     = 1
      max_size     = 6
      desired_size = 2
    }
  }

  enable_node_ssm_access          = true
  enable_audit_log_metric_filters = true

  tags = {
    Environment = "example"
  }

  # Nodes in a no-NAT VPC can only bootstrap once the endpoints exist. Pass that ordering as data;
  # never put depends_on on this module (it defers every data source inside it).
  node_group_dependencies = module.vpc_endpoints.dependency_ids

  # With deletion_protection on, terraform destroy would stop before touching the endpoints too.
  deletion_guard_dependencies = module.vpc_endpoints.dependency_ids
}
