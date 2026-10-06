# Shared AWS provider mocks for the module's tests.

mock_data "aws_partition" {
  defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
}
mock_data "aws_caller_identity" {
  defaults = { account_id = "123456789012", arn = "arn:aws:sts::123456789012:assumed-role/admin/session" }
}
mock_data "aws_region" {
  defaults = { region = "us-east-1", name = "us-east-1" }
}
mock_data "aws_iam_session_context" {
  defaults = { issuer_arn = "arn:aws:iam::123456789012:role/admin" }
}
mock_data "aws_iam_policy_document" {
  defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
}
mock_data "aws_iam_policy" {
  defaults = { arn = "arn:aws:iam::aws:policy/AmazonEBSCSIDriverEKSClusterScopedPolicy" }
}
mock_data "aws_vpc" {
  defaults = {
    cidr_block              = "10.0.0.0/16"
    cidr_block_associations = [{ association_id = "vpc-cidr-assoc-0", cidr_block = "10.0.0.0/16", state = "associated" }]
    enable_dns_support      = true
    enable_dns_hostnames    = true
  }
}
# No subnet is public or in an EKS-unsupported AZ unless a test overrides these.
mock_data "aws_subnets" {
  defaults = { ids = [] }
}
mock_data "aws_vpc_endpoint_service" {
  defaults = { service_name = "com.amazonaws.us-east-1.s3" }
}
mock_data "aws_ec2_managed_prefix_list" {
  defaults = { id = "pl-63a5400a" }
}
mock_data "aws_eks_addon_version" {
  defaults = { version = "v1.60.0-eksbuild.1" }
}
mock_data "aws_eks_cluster_versions" {
  defaults = {
    cluster_versions = [
      for v in ["1.34", "1.35", "1.36", "1.37"] : {
        cluster_type                   = "eks"
        cluster_version                = v
        control_plane_component_config = []
        default_platform_version       = "eks.1"
        default_version                = v == "1.36"
        end_of_extended_support_date   = "2028-12-01T00:00:00Z"
        end_of_standard_support_date   = "2027-12-01T00:00:00Z"
        kubernetes_patch_version       = "${v}.0"
        release_date                   = "2026-10-01T00:00:00Z"
        version_status                 = "STANDARD_SUPPORT"
      }
    ]
  }
}

mock_resource "aws_iam_role" {
  defaults = { arn = "arn:aws:iam::123456789012:role/mock", name = "mock" }
}
mock_resource "aws_iam_policy" {
  defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
}
mock_resource "aws_kms_key" {
  defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
}
mock_resource "aws_eks_cluster" {
  defaults = {
    arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/test"
    certificate_authority = [{ data = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t" }]
    identity              = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE" }] }]
  }
}
mock_resource "aws_security_group" {
  defaults = { id = "sg-0123456789abcdef0" }
}
mock_resource "aws_launch_template" {
  defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
}
mock_resource "aws_cloudwatch_log_group" {
  defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/eks/test/cluster" }
}
