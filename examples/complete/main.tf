provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Example    = "tf-eks/complete"
      Repository = "tf-eks"
    }
  }
}

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

################################################################################
# Network: no internet gateway, no NAT. Nodes reach AWS only through VPC endpoints.
################################################################################

module "vpc" {
  source = "../../modules/vpc"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # Node subnets (/20 each). Routes stay inside the VPC.
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  # Dedicated /28 subnets for the EKS control-plane ENIs, as the EKS best practices recommend.
  control_plane_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 12, 4080 + i)]

  # Flow logs (on by default) go to a KMS-encrypted log group kept for a year.
}

# Upgrade path from the first published version of this example, which used the registry VPC module.
# No-ops for fresh deployments. The control-plane subnets keep their identity (recreating them with the
# same CIDRs would conflict while EKS still uses them), and the old flow-log group and its key are
# kept, not destroyed, so earlier flow-log history stays readable.
moved {
  from = module.vpc.aws_subnet.intra
  to   = module.vpc.aws_subnet.control_plane
}

moved {
  from = module.vpc.aws_route_table.intra
  to   = module.vpc.aws_route_table.control_plane
}

moved {
  from = module.vpc.aws_route_table_association.intra
  to   = module.vpc.aws_route_table_association.control_plane
}

removed {
  from = module.vpc.aws_cloudwatch_log_group.flow_log

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_kms_key.flow_logs

  lifecycle {
    destroy = false
  }
}

module "vpc_endpoints" {
  source = "../../modules/vpc-endpoints"

  name                = var.name
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnet_ids
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
  node_subnet_ids          = module.vpc.private_subnet_ids
  control_plane_subnet_ids = module.vpc.control_plane_subnet_ids

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
