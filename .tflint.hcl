tflint {
  required_version = ">= 0.60"
}

config {
  format           = "compact"
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

plugin "aws" {
  enabled = true
  version = "0.49.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

rule "aws_security_group_rule_deprecated" {
  enabled = true
}

rule "aws_security_group_inline_rules" {
  enabled = true
}

rule "aws_iam_role_deprecated_policy_attributes" {
  enabled = true
}

rule "aws_iam_policy_document_gov_friendly_arns" {
  enabled = true
}

rule "aws_iam_role_policy_gov_friendly_arns" {
  enabled = true
}

rule "aws_iam_policy_gov_friendly_arns" {
  enabled = true
}
