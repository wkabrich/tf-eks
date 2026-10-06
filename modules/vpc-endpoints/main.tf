data "aws_vpc" "this" {
  count = length(var.allowed_cidr_blocks) == 0 ? 1 : 0

  id = var.vpc_id
}

# Resolved through the API rather than formatted, so service names are correct in every partition.
data "aws_vpc_endpoint_service" "interface" {
  for_each = var.interface_endpoints

  service      = each.key
  service_type = "Interface"
}

data "aws_vpc_endpoint_service" "s3" {
  count = var.create_s3_gateway_endpoint ? 1 : 0

  service      = "s3"
  service_type = "Gateway"
}

data "aws_partition" "current" {}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  allowed_cidr_blocks = length(var.allowed_cidr_blocks) > 0 ? var.allowed_cidr_blocks : [data.aws_vpc.this[0].cidr_block]

  perimeter              = var.data_perimeter.enabled
  perimeter_by_org       = var.data_perimeter.organization_id != null
  perimeter_principal    = local.perimeter_by_org ? "aws:PrincipalOrgID" : "aws:PrincipalAccount"
  perimeter_resource     = local.perimeter_by_org ? "aws:ResourceOrgID" : "aws:ResourceAccount"
  perimeter_values       = local.perimeter_by_org ? [var.data_perimeter.organization_id] : [data.aws_caller_identity.current.account_id]
  ecr_layer_bucket_arn   = "arn:${data.aws_partition.current.partition}:s3:::prod-${data.aws_region.current.region}-starport-layer-bucket"
  perimeter_policy_skips = ["oidc-eks"] # endpoint services that only accept the default policy

  # AWS's default endpoint policy, set explicitly: the provider treats a null policy as "leave as is", so
  # without this, turning the perimeter off would leave its policies in place.
  full_access_policy = jsonencode({
    Version   = "2008-10-17"
    Statement = [{ Effect = "Allow", Principal = "*", Action = "*", Resource = "*" }]
  })
}

data "aws_iam_policy_document" "interface_perimeter" {
  #checkov:skip=CKV_AWS_1:VPC endpoint (resource) policy: "*" is limited by the principal-account/org condition (AWS data-perimeter pattern).
  #checkov:skip=CKV_AWS_49:VPC endpoint (resource) policy: "*" is limited by the principal-account/org condition (AWS data-perimeter pattern).
  for_each = local.perimeter ? var.interface_endpoints : toset([])

  statement {
    sid       = "AllowPerimeterPrincipals"
    actions   = ["*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = local.perimeter_principal
      values   = local.perimeter_values
    }
  }

  # IRSA exchanges a web-identity token without AWS credentials, so there is no principal account to check.
  dynamic "statement" {
    for_each = startswith(each.key, "sts") ? [1] : []

    content {
      sid       = "AllowWebIdentityFederation"
      actions   = ["sts:AssumeRoleWithWebIdentity"]
      resources = ["*"]

      principals {
        type        = "*"
        identifiers = ["*"]
      }
    }
  }
}

data "aws_iam_policy_document" "s3_perimeter" {
  count = local.perimeter && var.create_s3_gateway_endpoint ? 1 : 0

  statement {
    sid       = "AllowECRImageLayers"
    actions   = ["s3:GetObject"]
    resources = ["${local.ecr_layer_bucket_arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "AllowPerimeterBuckets"
    actions   = ["s3:*"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "StringEquals"
      variable = local.perimeter_resource
      values   = local.perimeter_values
    }
  }

  dynamic "statement" {
    for_each = length(var.data_perimeter.additional_s3_bucket_arns) > 0 ? [1] : []

    content {
      sid       = "AllowAdditionalBuckets"
      actions   = ["s3:*"]
      resources = concat(var.data_perimeter.additional_s3_bucket_arns, [for b in var.data_perimeter.additional_s3_bucket_arns : "${b}/*"])

      principals {
        type        = "*"
        identifiers = ["*"]
      }
    }
  }
}

resource "aws_security_group" "this" {
  name_prefix = "${var.name}-vpce-"
  description = "Interface VPC endpoints for ${var.name}: HTTPS from the VPC"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cidr" {
  for_each = { for i, cidr in local.allowed_cidr_blocks : tostring(i) => cidr }

  security_group_id = aws_security_group.this.id
  description       = "HTTPS to interface endpoints"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = strcontains(each.value, ":") ? null : each.value
  cidr_ipv6         = strcontains(each.value, ":") ? each.value : null

  tags = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "security_group" {
  for_each = { for i, sg in var.allowed_security_group_ids : tostring(i) => sg }

  security_group_id            = aws_security_group.this.id
  description                  = "HTTPS to interface endpoints"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  referenced_security_group_id = each.value

  tags = var.tags
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.interface_endpoints

  vpc_id              = var.vpc_id
  service_name        = data.aws_vpc_endpoint_service.interface[each.key].service_name
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.this.id]
  ip_address_type     = var.ip_address_type
  policy = lookup(var.interface_endpoint_policies, each.key, (
    contains(local.perimeter_policy_skips, each.key) || !data.aws_vpc_endpoint_service.interface[each.key].vpc_endpoint_policy_supported ? null :
    local.perimeter ? try(data.aws_iam_policy_document.interface_perimeter[each.key].json, null) : local.full_access_policy
  ))

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_vpc_endpoint" "s3" {
  count = var.create_s3_gateway_endpoint ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = data.aws_vpc_endpoint_service.s3[0].service_name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
  policy = (
    var.s3_gateway_endpoint_policy != null ? var.s3_gateway_endpoint_policy :
    local.perimeter ? try(data.aws_iam_policy_document.s3_perimeter[0].json, null) : local.full_access_policy
  )

  tags = merge(var.tags, { Name = "${var.name}-s3" })

  lifecycle {
    precondition {
      condition     = length(var.route_table_ids) > 0
      error_message = "route_table_ids must list the node subnets' route tables when create_s3_gateway_endpoint is true."
    }
  }
}
