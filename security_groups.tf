################################################################################
# Security groups
#
# EKS also creates its own "cluster security group" and attaches it to the control-plane ENIs.
# The module leaves it untouched and adds two groups it fully manages:
#   cluster: attached to the control-plane ENIs. Decides who may reach the private API endpoint.
#   node:    attached to every node (and so to pods on secondary ENIs) through the launch templates.
#            Setting it in the launch template stops EKS from also attaching its cluster security
#            group to nodes. Only this group carries the kubernetes.io/cluster/<name> tag, which
#            the AWS Load Balancer Controller requires to be unique per ENI.
################################################################################

# Resolving the S3 gateway service first keeps the prefix-list name correct in every partition.
data "aws_vpc_endpoint_service" "s3" {
  service      = "s3"
  service_type = "Gateway"
}

data "aws_ec2_managed_prefix_list" "s3" {
  name = data.aws_vpc_endpoint_service.s3.service_name
}

locals {
  https_egress_cidr_blocks = coalesce(var.node_security_group_https_egress_cidr_blocks, [data.aws_vpc.this.cidr_block])

  sg_rule_defaults = {
    from_port                    = null
    to_port                      = null
    cidr_ipv4                    = null
    cidr_ipv6                    = null
    prefix_list_id               = null
    referenced_security_group_id = null
  }

  cluster_ingress_rules = merge(
    {
      nodes_https = {
        description                  = "Nodes to the Kubernetes API server"
        ip_protocol                  = "tcp"
        from_port                    = 443
        to_port                      = 443
        referenced_security_group_id = aws_security_group.node.id
      }
    },
    {
      for i, cidr in var.cluster_endpoint_allowed_cidr_blocks : "allowed_cidr_${i}" => {
        description = "Administrative network to the Kubernetes API server"
        ip_protocol = "tcp"
        from_port   = 443
        to_port     = 443
        cidr_ipv4   = strcontains(cidr, ":") ? null : cidr
        cidr_ipv6   = strcontains(cidr, ":") ? cidr : null
      }
    },
    {
      for i, sg in var.cluster_endpoint_allowed_security_group_ids : "allowed_sg_${i}" => {
        description                  = "Administrative security group to the Kubernetes API server"
        ip_protocol                  = "tcp"
        from_port                    = 443
        to_port                      = 443
        referenced_security_group_id = sg
      }
    },
  )

  # Explicit control plane -> node rules, so the cluster keeps working even if someone narrows the
  # all-traffic egress rule on the EKS-managed cluster security group.
  cluster_egress_rules = merge(
    {
      nodes_kubelet = {
        description = "API server to kubelet (logs, exec, port-forward)"
        from_port   = 10250
        to_port     = 10250
      }
      nodes_https = {
        description = "API server to pods and nodes on 443"
        from_port   = 443
        to_port     = 443
      }
    },
    {
      for port in var.node_security_group_webhook_ports : "nodes_webhook_${port}" => {
        description = "API server to admission webhook / aggregated API on ${port}"
        from_port   = port
        to_port     = port
      }
    },
  )

  node_ingress_rules = merge(
    {
      self_all = {
        description                  = "Node-to-node and pod-to-pod traffic (scope further with NetworkPolicies)"
        ip_protocol                  = "-1"
        referenced_security_group_id = aws_security_group.node.id
      }
      cluster_kubelet = {
        description                  = "API server to kubelet"
        ip_protocol                  = "tcp"
        from_port                    = 10250
        to_port                      = 10250
        referenced_security_group_id = aws_security_group.cluster.id
      }
      cluster_https = {
        description                  = "API server to pods and nodes on 443"
        ip_protocol                  = "tcp"
        from_port                    = 443
        to_port                      = 443
        referenced_security_group_id = aws_security_group.cluster.id
      }
    },
    {
      for port in var.node_security_group_webhook_ports : "cluster_webhook_${port}" => {
        description                  = "API server to admission webhook / aggregated API on ${port}"
        ip_protocol                  = "tcp"
        from_port                    = port
        to_port                      = port
        referenced_security_group_id = aws_security_group.cluster.id
      }
    },
    {
      for k, r in var.node_security_group_additional_rules : k => merge(r, {
        referenced_security_group_id = r.self ? aws_security_group.node.id : r.referenced_security_group_id
      }) if r.direction == "ingress"
    },
  )

  # Default-deny egress for a private, no-NAT cluster. Amazon DNS, IMDS and Time Sync are not filtered
  # by security groups, so they need no rules here.
  node_egress_rules = merge(
    {
      self_all = {
        description                  = "Node-to-node and pod-to-pod traffic"
        ip_protocol                  = "-1"
        referenced_security_group_id = aws_security_group.node.id
      }
      cluster_https = {
        description                  = "Kubelet and pods to the Kubernetes API server"
        ip_protocol                  = "tcp"
        from_port                    = 443
        to_port                      = 443
        referenced_security_group_id = aws_security_group.cluster.id
      }
      s3_gateway = {
        description    = "S3 gateway endpoint (ECR image layers, AMI and agent packages)"
        ip_protocol    = "tcp"
        from_port      = 443
        to_port        = 443
        prefix_list_id = data.aws_ec2_managed_prefix_list.s3.id
      }
    },
    {
      for i, cidr in local.https_egress_cidr_blocks : "https_cidr_${i}" => {
        description = "HTTPS to interface VPC endpoints and in-VPC services"
        ip_protocol = "tcp"
        from_port   = 443
        to_port     = 443
        cidr_ipv4   = strcontains(cidr, ":") ? null : cidr
        cidr_ipv6   = strcontains(cidr, ":") ? cidr : null
      }
    },
    {
      for k, r in var.node_security_group_additional_rules : k => merge(r, {
        referenced_security_group_id = r.self ? aws_security_group.node.id : r.referenced_security_group_id
      }) if r.direction == "egress"
    },
  )
}

#-------------------------------------------------------------------------------
# Cluster (control-plane ENIs)
#-------------------------------------------------------------------------------

resource "aws_security_group" "cluster" {
  name_prefix = "${var.name}-cluster-"
  description = "EKS ${var.name} control plane: private API endpoint access"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-cluster" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "cluster" {
  for_each = { for k, v in local.cluster_ingress_rules : k => merge(local.sg_rule_defaults, v) }

  security_group_id            = aws_security_group.cluster.id
  description                  = each.value.description
  ip_protocol                  = each.value.ip_protocol
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  cidr_ipv4                    = each.value.cidr_ipv4
  cidr_ipv6                    = each.value.cidr_ipv6
  referenced_security_group_id = each.value.referenced_security_group_id

  tags = merge(var.tags, { Name = "${var.name}-cluster-${each.key}" })
}

resource "aws_vpc_security_group_egress_rule" "cluster" {
  for_each = local.cluster_egress_rules

  security_group_id            = aws_security_group.cluster.id
  description                  = each.value.description
  ip_protocol                  = "tcp"
  from_port                    = each.value.from_port
  to_port                      = each.value.to_port
  referenced_security_group_id = aws_security_group.node.id

  tags = merge(var.tags, { Name = "${var.name}-cluster-${each.key}" })
}

#-------------------------------------------------------------------------------
# Nodes
#-------------------------------------------------------------------------------

resource "aws_security_group" "node" {
  name_prefix = "${var.name}-node-"
  description = "EKS ${var.name} managed node groups and pods"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, {
    Name                                = "${var.name}-node"
    "kubernetes.io/cluster/${var.name}" = "owned"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "node" {
  for_each = { for k, v in local.node_ingress_rules : k => merge(local.sg_rule_defaults, v) }

  security_group_id            = aws_security_group.node.id
  description                  = each.value.description
  ip_protocol                  = each.value.ip_protocol
  from_port                    = each.value.ip_protocol == "-1" ? null : each.value.from_port
  to_port                      = each.value.ip_protocol == "-1" ? null : each.value.to_port
  cidr_ipv4                    = each.value.cidr_ipv4
  cidr_ipv6                    = each.value.cidr_ipv6
  prefix_list_id               = each.value.prefix_list_id
  referenced_security_group_id = each.value.referenced_security_group_id

  tags = merge(var.tags, { Name = "${var.name}-node-${each.key}" })
}

resource "aws_vpc_security_group_egress_rule" "node" {
  for_each = { for k, v in local.node_egress_rules : k => merge(local.sg_rule_defaults, v) }

  security_group_id            = aws_security_group.node.id
  description                  = each.value.description
  ip_protocol                  = each.value.ip_protocol
  from_port                    = each.value.ip_protocol == "-1" ? null : each.value.from_port
  to_port                      = each.value.ip_protocol == "-1" ? null : each.value.to_port
  cidr_ipv4                    = each.value.cidr_ipv4
  cidr_ipv6                    = each.value.cidr_ipv6
  prefix_list_id               = each.value.prefix_list_id
  referenced_security_group_id = each.value.referenced_security_group_id

  tags = merge(var.tags, { Name = "${var.name}-node-${each.key}" })
}

# Opt-in escape hatch for clusters that do have a NAT or egress firewall path.
resource "aws_vpc_security_group_egress_rule" "node_all_ipv4" {
  count = var.node_security_group_allow_all_egress ? 1 : 0

  #checkov:skip=CKV_AWS_382:Opt-in via node_security_group_allow_all_egress; the default is restricted egress.
  security_group_id = aws_security_group.node.id
  description       = "Unrestricted IPv4 egress (node_security_group_allow_all_egress)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0" #trivy:ignore:AWS-0104

  tags = merge(var.tags, { Name = "${var.name}-node-all-ipv4" })
}

resource "aws_vpc_security_group_egress_rule" "node_all_ipv6" {
  count = var.node_security_group_allow_all_egress && var.ip_family == "ipv6" ? 1 : 0

  #checkov:skip=CKV_AWS_382:Opt-in via node_security_group_allow_all_egress; the default is restricted egress.
  security_group_id = aws_security_group.node.id
  description       = "Unrestricted IPv6 egress (node_security_group_allow_all_egress)"
  ip_protocol       = "-1"
  cidr_ipv6         = "::/0" #trivy:ignore:AWS-0104

  tags = merge(var.tags, { Name = "${var.name}-node-all-ipv6" })
}
