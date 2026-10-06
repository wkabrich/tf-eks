locals {
  data_plane_kubernetes_version = coalesce(var.data_plane_kubernetes_version, var.kubernetes_version)

  node_groups = {
    for name, ng in var.node_groups : name => merge(ng, {
      os             = startswith(ng.ami_type, "BOTTLEROCKET") ? "bottlerocket" : "al2023"
      instance_types = ng.instance_types != null ? ng.instance_types : (strcontains(ng.ami_type, "ARM_64") ? ["m7g.large"] : ["m7i.large"])
      subnet_ids     = ng.subnet_ids != null ? ng.subnet_ids : var.node_subnet_ids
    })
  }

  # Bottlerocket keeps the OS on a small read-only /dev/xvda and container data on /dev/xvdb. Both are
  # encrypted, and the requested size and performance go to the data volume only (the few-GiB OS
  # volume cannot take more than baseline gp3 IOPS). AL2023 has one root volume.
  node_block_devices = {
    for name, ng in local.node_groups : name => ng.os == "bottlerocket" ? [
      { device_name = "/dev/xvda", volume_size = null, iops = null, throughput = null },
      { device_name = "/dev/xvdb", volume_size = ng.disk_size, iops = ng.disk_iops, throughput = ng.disk_throughput },
      ] : [
      { device_name = "/dev/xvda", volume_size = ng.disk_size, iops = ng.disk_iops, throughput = ng.disk_throughput },
    ]
  }

  all_node_subnet_ids = distinct(flatten([for ng in local.node_groups : ng.subnet_ids]))

  # EKS merges this with the bootstrap user data it generates (cluster endpoint, CA, kubelet flags), so
  # the module only adds settings. AL2023 takes extra NodeConfig documents as a MIME part.
  al2023_user_data = {
    for name, ng in local.node_groups : name => base64encode(<<-EOT
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="//"

      --//
      Content-Type: application/node.eks.aws

      ${ng.bootstrap_extra_config}
      --//--
    EOT
    ) if ng.os == "al2023" && ng.bootstrap_extra_config != null
  }

  # Bottlerocket takes TOML, and values here override the EKS-generated settings. The caller's TOML
  # comes first so its top-level dotted keys stay at the root rather than landing under the module's
  # tables. The admin (SSH/superpowered) container stays off. Kernel lockdown blocks unsigned kernel
  # code and raw kernel memory writes; NVIDIA variants are left at their default because they load
  # out-of-tree drivers.
  bottlerocket_user_data = {
    for name, ng in local.node_groups : name => base64encode(join("\n", compact([
      ng.bootstrap_extra_config,
      <<-EOT
      [settings.host-containers.admin]
      enabled = false
      EOT
      ,
      strcontains(ng.ami_type, "NVIDIA") ? null : <<-EOT
      [settings.kernel]
      lockdown = "integrity"
      EOT
    ]))) if ng.os == "bottlerocket"
  }
}

# Refuses node subnets that hand out public IPv4 addresses (CIS EKS 5.4.3). One filtered query, so it
# still works (as a read deferred to apply) when the subnet list is only known after apply.
data "aws_subnets" "node_public_ip" {
  # Skipped without managed node groups: an empty subnet-id filter is sent to EC2 with no values.
  count = length(var.node_groups) > 0 ? 1 : 0

  filter {
    name   = "subnet-id"
    values = local.all_node_subnet_ids
  }

  filter {
    name   = "map-public-ip-on-launch"
    values = ["true"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) == 0
      error_message = "Node subnets must not auto-assign public IPv4 addresses (CIS EKS 5.4.3): ${join(", ", self.ids)}."
    }
  }
}

# Lets callers order node creation after resources the nodes need at boot (VPC endpoints in a no-NAT
# VPC) without a module-level depends_on.
resource "terraform_data" "node_group_dependencies" {
  input = var.node_group_dependencies
}

resource "aws_launch_template" "node" {
  for_each = local.node_groups

  name_prefix            = "${substr("${var.name}-${each.key}", 0, 97)}-"
  description            = "EKS ${var.name} managed node group ${each.key}"
  update_default_version = true

  # Setting security groups here stops EKS from attaching its cluster security group to the nodes.
  vpc_security_group_ids = concat([aws_security_group.node.id], each.value.additional_security_group_ids)
  user_data              = each.value.os == "bottlerocket" ? local.bottlerocket_user_data[each.key] : try(local.al2023_user_data[each.key], null)

  # IMDSv2 only, and hop limit 1 so pods (which sit one network hop away) cannot read node-role
  # credentials. Pod Identity and the host-network add-ons are unaffected. Pods that read
  # region or VPC ID from IMDS must get them from configuration instead.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_protocol_ipv6          = var.ip_family == "ipv6" ? "enabled" : "disabled"
    instance_metadata_tags      = "disabled"
  }

  dynamic "block_device_mappings" {
    for_each = local.node_block_devices[each.key]

    content {
      device_name = block_device_mappings.value.device_name

      ebs {
        volume_type           = "gp3"
        volume_size           = block_device_mappings.value.volume_size
        iops                  = block_device_mappings.value.iops
        throughput            = block_device_mappings.value.throughput
        encrypted             = true
        kms_key_id            = local.ebs_kms_key_arn
        delete_on_termination = true
      }
    }
  }

  monitoring {
    enabled = each.value.enable_detailed_monitoring
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])

    content {
      resource_type = tag_specifications.value
      tags          = merge(var.tags, each.value.tags, { Name = "${var.name}-${each.key}" })
    }
  }

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_eks_node_group" "this" {
  for_each = local.node_groups

  cluster_name           = aws_eks_cluster.this.name
  node_group_name_prefix = "${substr(var.name, 0, 15)}-${each.key}-"
  node_role_arn          = aws_iam_role.node.arn
  subnet_ids             = each.value.subnet_ids

  # Follows the control plane unless data_plane_kubernetes_version says otherwise. The cluster_name
  # reference above still orders node updates after control-plane updates.
  version              = local.data_plane_kubernetes_version
  release_version      = each.value.release_version
  force_update_version = each.value.force_update_version
  ami_type             = each.value.ami_type
  capacity_type        = each.value.capacity_type
  instance_types       = each.value.instance_types
  labels               = each.value.labels

  dynamic "taint" {
    for_each = each.value.taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  update_config {
    max_unavailable_percentage = each.value.max_unavailable_percentage
    update_strategy            = each.value.update_strategy
  }

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = aws_launch_template.node[each.key].latest_version
  }

  node_repair_config {
    enabled = each.value.enable_node_repair
  }

  tags = merge(var.tags, each.value.tags)

  lifecycle {
    create_before_destroy = true
    # Leave desired_size to the cluster autoscaler or Karpenter after creation.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    data.aws_subnets.node_public_ip,
    aws_iam_role_policy_attachments_exclusive.node,
    aws_iam_role_policy.node_ssm,
    terraform_data.node_group_dependencies,
    aws_eks_addon.before_compute,
    aws_vpc_security_group_ingress_rule.node,
    aws_vpc_security_group_egress_rule.node,
    aws_vpc_security_group_ingress_rule.cluster,
    aws_vpc_security_group_egress_rule.cluster,
  ]
}
