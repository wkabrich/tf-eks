# Lifecycle tests: apply against mocked AWS, then plan changes against that state.
#   terraform init -backend=false && terraform test

# Mocked values are generated at apply time here (the default), so plan and apply agree.
mock_provider "aws" {
  source = "./tests/mocks"
}

variables {
  name               = "test"
  kubernetes_version = "1.37"
  vpc_id             = "vpc-0123456789abcdef0"
  node_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0aaaaaaaaaaaaaaa2"]
  # The destroy guard would (correctly) fail the test teardown otherwise.
  deletion_protection = false
}

run "create" {
  command = apply

  assert {
    condition = (
      terraform_data.kms_key_guard["cluster"].output == aws_kms_key.cluster[0].arn &&
      aws_eks_cluster.this.encryption_config[0].provider[0].key_arn == aws_kms_key.cluster[0].arn &&
      one(aws_launch_template.node["default"].block_device_mappings).ebs[0].kms_key_id == aws_kms_key.ebs[0].arn
    )
    error_message = "The guards must record the keys in use at creation, and consumers must use them."
  }
}

run "replan_is_clean" {
  command = plan

  assert {
    condition     = terraform_data.kms_key_guard["cluster"].output == aws_kms_key.cluster[0].arn
    error_message = "An unchanged configuration must keep passing the key guard."
  }
}

run "refuse_cluster_key_switch" {
  command = plan

  variables {
    create_kms_key = false
    kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
  }

  expect_failures = [terraform_data.kms_key_guard, terraform_data.kms_key_ownership]
}

run "refuse_ebs_key_switch" {
  command = plan

  variables {
    create_ebs_kms_key = false
    ebs_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/33333333-3333-3333-3333-333333333333"
  }

  expect_failures = [terraform_data.kms_key_guard, terraform_data.kms_key_ownership]
}

run "refuse_handover_of_module_key" {
  command = plan

  # Same ARN, so the ARN guard passes; the ownership guard must still refuse, because the module would
  # otherwise schedule its own key (still used by the cluster) for deletion.
  variables {
    create_kms_key = false
    kms_key_arn    = run.create.kms_key_arn
  }

  expect_failures = [terraform_data.kms_key_ownership]
}

run "rebaseline_logs_key_only" {
  command = plan

  # The documented key-switch procedure for the logs key: both guards re-baselined, nothing else re-keyed.
  variables {
    create_cloudwatch_log_group_kms_key = false
    cloudwatch_log_group_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
  }

  plan_options {
    replace = [terraform_data.kms_key_guard["logs"], terraform_data.kms_key_ownership]
  }

  assert {
    condition = (
      one(aws_launch_template.node["default"].block_device_mappings).ebs[0].kms_key_id == aws_kms_key.ebs[0].arn &&
      aws_eks_cluster.this.encryption_config[0].provider[0].key_arn == aws_kms_key.cluster[0].arn
    )
    error_message = "Re-baselining the logs key must not touch the EBS or cluster key consumers."
  }
}

run "byo_create" {
  command = apply

  # A separate cluster that started with caller-supplied keys.
  state_key = "byo"

  variables {
    create_kms_key = false
    kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
  }
}

run "refuse_switch_between_caller_keys" {
  command   = plan
  state_key = "byo"

  variables {
    create_kms_key = false
    kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/55555555-5555-5555-5555-555555555555"
  }

  expect_failures = [terraform_data.kms_key_guard]
}
