# Plan-only unit tests with a mocked AWS provider.
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_data "aws_vpc_endpoint_service" {
    defaults = { service_name = "com.amazonaws.us-east-1.mock", vpc_endpoint_policy_supported = true }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_security_group" {
    defaults = { id = "sg-0123456789abcdef0" }
  }
}

variables {
  name            = "test"
  vpc_id          = "vpc-0123456789abcdef0"
  subnet_ids      = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0aaaaaaaaaaaaaaa2"]
  route_table_ids = ["rtb-0aaaaaaaaaaaaaaa1"]
}

run "defaults" {
  command = plan

  assert {
    condition     = toset(keys(aws_vpc_endpoint.interface)) == toset(["ec2", "ecr.api", "ecr.dkr", "eks", "eks-auth", "logs", "sts"])
    error_message = "The baseline interface endpoints must be created."
  }

  assert {
    condition     = alltrue([for ep in aws_vpc_endpoint.interface : ep.private_dns_enabled && ep.vpc_endpoint_type == "Interface"])
    error_message = "Interface endpoints must use private DNS."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.cidr["0"].cidr_ipv4 == "10.0.0.0/16" && aws_vpc_security_group_ingress_rule.cidr["0"].from_port == 443
    error_message = "The endpoint security group must allow HTTPS from the VPC CIDR."
  }

  assert {
    condition     = aws_vpc_endpoint.s3[0].vpc_endpoint_type == "Gateway" && length(data.aws_iam_policy_document.s3_perimeter) == 0
    error_message = "The S3 gateway endpoint must exist and keep the default policy unless the perimeter is enabled."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.interface_perimeter) == 0
    error_message = "No perimeter policies by default."
  }

  assert {
    condition     = jsondecode(aws_vpc_endpoint.interface["ecr.api"].policy).Statement[0].Action == "*" && jsondecode(aws_vpc_endpoint.s3[0].policy).Statement[0].Principal == "*"
    error_message = "Without the perimeter, endpoints must carry AWS's full-access policy explicitly, so turning the perimeter off resets it."
  }

  assert {
    condition     = length(output.dependency_ids) == 7 + 1 + 1 + 1
    error_message = "dependency_ids must cover every endpoint, the security group and its rules."
  }
}

run "account_perimeter" {
  command = plan

  variables {
    interface_endpoints = ["ecr.api", "sts", "oidc-eks"]
    data_perimeter      = { enabled = true }
  }

  assert {
    condition = (
      one(data.aws_iam_policy_document.interface_perimeter["ecr.api"].statement[0].condition).variable == "aws:PrincipalAccount" &&
      one(one(data.aws_iam_policy_document.interface_perimeter["ecr.api"].statement[0].condition).values) == "123456789012"
    )
    error_message = "Interface endpoints must only admit this account's principals."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.interface_perimeter["sts"].statement) == 2 && length(data.aws_iam_policy_document.interface_perimeter["ecr.api"].statement) == 1
    error_message = "Only the STS endpoint may additionally allow unauthenticated web-identity federation (IRSA)."
  }

  assert {
    condition     = aws_vpc_endpoint.interface["ecr.api"].policy == data.aws_iam_policy_document.interface_perimeter["ecr.api"].json
    error_message = "Interface endpoints must carry the perimeter policy."
  }

  assert {
    condition = (
      one(data.aws_iam_policy_document.s3_perimeter[0].statement[0].resources) == "arn:aws:s3:::prod-us-east-1-starport-layer-bucket/*" &&
      one(data.aws_iam_policy_document.s3_perimeter[0].statement[1].condition).variable == "aws:ResourceAccount"
    )
    error_message = "The S3 perimeter must allow ECR layers and this account's buckets only."
  }
}

run "organization_perimeter" {
  command = plan

  variables {
    data_perimeter = { enabled = true, organization_id = "o-abcdefghij" }
  }

  assert {
    condition     = one(data.aws_iam_policy_document.interface_perimeter["ec2"].statement[0].condition).variable == "aws:PrincipalOrgID"
    error_message = "An organization perimeter must key on aws:PrincipalOrgID."
  }
}

run "reject_missing_route_tables" {
  command = plan

  variables {
    route_table_ids = []
  }

  expect_failures = [aws_vpc_endpoint.s3]
}
