################################################################################
# Audit-log detections (opt-in)
#
# Metric filters on the control-plane audit stream. Each filter becomes a custom metric in the
# EKS/<cluster>/Audit namespace and, when SNS topics are given, an alarm that fires once the count
# reaches its threshold within the period.
################################################################################

locals {
  # Default detections. Patterns use CloudWatch Logs JSON filter syntax against the audit event:
  # https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/#audit-k8s-io-v1-Event
  #
  # TODO(you): choose the detections that fit your threat model. One example is provided.
  # Things to weigh:
  #   - Signal vs noise. Controllers read Secrets constantly, so scope by user or verb.
  #   - Coverage. Typical candidates are 401/403 spikes (credential probing), pods/exec and
  #     pods/attach (interactive access), changes to RBAC objects (clusterroles, clusterrolebindings),
  #     changes to admission webhooks (mutating/validatingwebhookconfigurations), and requests from
  #     system:anonymous.
  #   - Threshold and period. A burst of 403s is interesting; a single one usually is not.
  default_audit_log_metric_filters = {
    secret_reads_by_humans = {
      description = "Secrets read or listed by a non-system identity"
      pattern     = "{ ($.objectRef.resource = \"secrets\") && (($.verb = \"get\") || ($.verb = \"list\")) && ($.user.username != \"system:*\") }"
      threshold   = 1
      period      = 300
    }
  }

  audit_log_metric_filters = var.enable_audit_log_metric_filters ? merge(local.default_audit_log_metric_filters, var.audit_log_additional_metric_filters) : {}
}

resource "aws_cloudwatch_log_metric_filter" "audit" {
  for_each = local.audit_log_metric_filters

  name           = "${var.name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.this.name
  pattern        = each.value.pattern

  metric_transformation {
    name          = each.key
    namespace     = "EKS/${var.name}/Audit"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }

  lifecycle {
    precondition {
      condition     = var.cloudwatch_log_group_class == "STANDARD"
      error_message = "Audit-log metric filters require cloudwatch_log_group_class = \"STANDARD\"."
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "audit" {
  for_each = length(var.audit_log_alarm_sns_topic_arns) > 0 ? local.audit_log_metric_filters : {}

  alarm_name          = "${var.name}-${each.key}"
  alarm_description   = "EKS ${var.name}: ${each.value.description}"
  namespace           = "EKS/${var.name}/Audit"
  metric_name         = aws_cloudwatch_log_metric_filter.audit[each.key].metric_transformation[0].name
  statistic           = "Sum"
  period              = each.value.period
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.audit_log_alarm_sns_topic_arns
  ok_actions          = var.audit_log_alarm_sns_topic_arns

  tags = var.tags
}
