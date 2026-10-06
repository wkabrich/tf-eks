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
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-log/test" }
  }
}

variables {
  name                  = "test"
  cidr                  = "10.0.0.0/16"
  azs                   = ["us-east-1a", "us-east-1b", "us-east-1c"]
  private_subnets       = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  control_plane_subnets = ["10.0.255.0/28", "10.0.255.16/28", "10.0.255.32/28"]
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_support && aws_vpc.this.enable_dns_hostnames
    error_message = "EKS private endpoints need VPC DNS support and hostnames."
  }

  assert {
    condition     = length(aws_subnet.private) == 3 && length(aws_subnet.control_plane) == 3 && alltrue([for s in concat(aws_subnet.private, aws_subnet.control_plane) : s.map_public_ip_on_launch == false])
    error_message = "Every subnet must be private."
  }

  assert {
    condition     = aws_subnet.private[0].tags["kubernetes.io/role/internal-elb"] == "1" && aws_subnet.private[1].availability_zone == "us-east-1b"
    error_message = "Node subnets must be spread over the AZs and tagged for internal load balancers."
  }

  assert {
    condition     = length(aws_route_table.private) == 3 && length(aws_route_table.control_plane) == 1 && length(aws_route_table_association.control_plane) == 3
    error_message = "Each AZ needs its own private route table; control-plane subnets share one."
  }

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0 && length(aws_default_security_group.this.egress) == 0
    error_message = "The default security group must have no rules."
  }

  assert {
    condition = (
      aws_flow_log.this[0].traffic_type == "ALL" &&
      aws_cloudwatch_log_group.flow_logs[0].name == "/aws/vpc-flow-log/test" &&
      aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 365 &&
      aws_kms_key.flow_logs[0].enable_key_rotation
    )
    error_message = "Flow logs must capture all traffic into an encrypted, retained log group."
  }

  assert {
    condition     = one(one(data.aws_iam_policy_document.flow_logs_kms[0].statement[1].condition).values) == "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-log/test"
    error_message = "The flow-log key must only be usable by CloudWatch Logs for this log group."
  }

  assert {
    condition     = one(data.aws_iam_policy_document.flow_logs[0].statement[0].resources) == "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-log/test:*"
    error_message = "The flow-log role may only write to its own log group."
  }
}

run "no_control_plane_subnets_and_no_flow_logs" {
  command = plan

  variables {
    control_plane_subnets = []
    enable_flow_logs      = false
  }

  assert {
    condition     = length(aws_subnet.control_plane) == 0 && length(aws_route_table.control_plane) == 0 && length(aws_flow_log.this) == 0 && length(aws_kms_key.flow_logs) == 0
    error_message = "Optional pieces must be skipped."
  }
}

run "bring_your_own_flow_log_key" {
  command = plan

  variables {
    create_flow_log_kms_key = false
    flow_log_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
  }

  assert {
    condition     = length(aws_kms_key.flow_logs) == 0 && aws_cloudwatch_log_group.flow_logs[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
    error_message = "A supplied flow-log key must be used instead of creating one."
  }
}

run "reject_subnet_count_mismatch" {
  command = plan

  variables {
    private_subnets = ["10.0.0.0/20"]
  }

  expect_failures = [var.private_subnets]
}

run "reject_missing_flow_log_key" {
  command = plan

  variables {
    create_flow_log_kms_key = false
  }

  expect_failures = [var.flow_log_kms_key_arn]
}
