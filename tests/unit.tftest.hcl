# Unit tests. They run without AWS credentials: every provider call is mocked.
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  override_during = plan
  source          = "./tests/mocks"
}

variables {
  name               = "test"
  kubernetes_version = "1.37"
  vpc_id             = "vpc-0123456789abcdef0"
  node_subnet_ids    = ["subnet-0aaaaaaaaaaaaaaa1", "subnet-0aaaaaaaaaaaaaaa2"]
}

################################################################################
# Secure defaults
################################################################################

run "secure_defaults" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_public_access == false && aws_eks_cluster.this.vpc_config[0].endpoint_private_access == true
    error_message = "The API endpoint must be private-only."
  }

  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions == false
    error_message = "Access must use access entries only, with no implicit creator admin."
  }

  assert {
    condition     = tolist(aws_eks_cluster.this.encryption_config[0].resources) == tolist(["secrets"])
    error_message = "Envelope encryption with a customer managed key must be configured."
  }

  assert {
    condition     = length(aws_eks_cluster.this.enabled_cluster_log_types) == 5
    error_message = "All five control-plane log types must be enabled by default."
  }

  assert {
    condition     = aws_eks_cluster.this.bootstrap_self_managed_addons == false && aws_eks_cluster.this.deletion_protection == true
    error_message = "Self-managed add-on bootstrap must be off and deletion protection on."
  }

  assert {
    condition     = terraform_data.deletion_guard.input.protect == true
    error_message = "The destroy guard must follow deletion_protection."
  }

  assert {
    condition     = aws_eks_cluster.this.upgrade_policy[0].support_type == "STANDARD"
    error_message = "Upgrade policy must default to STANDARD support."
  }

  assert {
    condition     = length(aws_kms_key.cluster) == 1 && length(aws_kms_key.logs) == 1 && length(aws_kms_key.ebs) == 1
    error_message = "Three dedicated KMS keys must be created by default."
  }

  assert {
    condition     = alltrue([for k in [aws_kms_key.cluster[0], aws_kms_key.logs[0], aws_kms_key.ebs[0]] : k.enable_key_rotation])
    error_message = "KMS key rotation must be enabled."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this.name == "/aws/eks/test/cluster" && aws_cloudwatch_log_group.this.retention_in_days == 365
    error_message = "The control-plane log group must be pre-created with one year of retention."
  }

  assert {
    condition = (
      aws_launch_template.node["default"].metadata_options[0].http_tokens == "required" &&
      aws_launch_template.node["default"].metadata_options[0].http_put_response_hop_limit == 1 &&
      aws_launch_template.node["default"].metadata_options[0].http_endpoint == "enabled"
    )
    error_message = "Launch templates must enforce IMDSv2 with a hop limit of 1."
  }

  assert {
    condition     = alltrue([for bd in aws_launch_template.node["default"].block_device_mappings : bd.ebs[0].encrypted == "true" && bd.ebs[0].volume_type == "gp3"])
    error_message = "Node volumes must be encrypted gp3."
  }

  assert {
    condition     = aws_launch_template.node["default"].key_name == null
    error_message = "Launch templates must not configure SSH keys."
  }

  assert {
    condition     = tolist(aws_eks_node_group.this["default"].instance_types) == tolist(["m7i.large"]) && aws_eks_node_group.this["default"].ami_type == "AL2023_x86_64_STANDARD"
    error_message = "Default node group must be AL2023 x86_64 on m7i.large."
  }

  assert {
    condition     = aws_eks_node_group.this["default"].node_repair_config[0].enabled == true && aws_eks_node_group.this["default"].version == "1.37"
    error_message = "Node auto repair must be on and nodes must follow the control-plane version."
  }

  assert {
    condition     = toset(keys(aws_eks_addon.before_compute)) == toset(["eks-node-monitoring-agent", "eks-pod-identity-agent", "kube-proxy", "vpc-cni"])
    error_message = "DaemonSet add-ons must be created before compute."
  }

  assert {
    condition     = toset(keys(aws_eks_addon.this)) == toset(["aws-ebs-csi-driver", "coredns"])
    error_message = "Deployment add-ons must be created after compute."
  }

  assert {
    condition     = aws_eks_addon.before_compute["vpc-cni"].preserve && aws_eks_addon.this["coredns"].preserve && !aws_eks_addon.this["aws-ebs-csi-driver"].preserve
    error_message = "Networking and DNS add-ons must be preserved on delete."
  }

  assert {
    condition     = jsondecode(aws_eks_addon.before_compute["vpc-cni"].configuration_values).enableNetworkPolicy == "true"
    error_message = "VPC CNI network policy enforcement must be enabled."
  }

  assert {
    condition     = one(aws_eks_addon.before_compute["vpc-cni"].pod_identity_association).service_account == "aws-node"
    error_message = "vpc-cni must use a Pod Identity association."
  }

  assert {
    condition     = toset(keys(aws_iam_role.pod_identity)) == toset(["aws-ebs-csi-driver", "vpc-cni"])
    error_message = "Pod Identity roles must be created for vpc-cni and the EBS CSI driver."
  }

  assert {
    condition = (
      contains(aws_iam_role_policy_attachments_exclusive.node.policy_arns, "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy") &&
      contains(aws_iam_role_policy_attachments_exclusive.node.policy_arns, "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly") &&
      length(aws_iam_role_policy_attachments_exclusive.node.policy_arns) == 2
    )
    error_message = "The node role must get exactly the worker-node and pull-only policies (no CNI policy)."
  }

  assert {
    condition     = toset(aws_iam_role_policy_attachments_exclusive.cluster.policy_arns) == toset(["arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"])
    error_message = "The cluster role must get only AmazonEKSClusterPolicy by default."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.node_all_ipv4) == 0
    error_message = "Unrestricted node egress must be opt-in."
  }

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_egress_rule.node : r.cidr_ipv4 != "0.0.0.0/0"])
    error_message = "No default node egress rule may target 0.0.0.0/0."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.node["https_cidr_0"].cidr_ipv4 == "10.0.0.0/16"
    error_message = "HTTPS egress must default to the VPC CIDR."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.this) == 0 && length(aws_eks_access_entry.this) == 0
    error_message = "IRSA and access entries must be opt-in."
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.cluster)) == toset(["nodes_https"]) && aws_vpc_security_group_ingress_rule.cluster["nodes_https"].from_port == 443
    error_message = "By default only nodes may reach the API endpoint, on 443."
  }

  assert {
    condition     = terraform_data.kms_key_ownership.input == { cluster = true, logs = true, ebs = true }
    error_message = "The ownership guard must record which keys the module created."
  }
}

run "policy_documents" {
  command = plan

  assert {
    condition = (
      one(one([for c in data.aws_iam_policy_document.cluster_assume_role.statement[0].condition : c.values if c.variable == "aws:SourceArn"])) == "arn:aws:eks:us-east-1:123456789012:cluster/test" &&
      one(one([for c in data.aws_iam_policy_document.cluster_assume_role.statement[0].condition : c.values if c.variable == "aws:SourceAccount"])) == "123456789012"
    )
    error_message = "The cluster role trust policy must pin aws:SourceArn and aws:SourceAccount."
  }

  assert {
    condition = (
      toset([for c in data.aws_iam_policy_document.pod_identity_assume_role["vpc-cni"].statement[0].condition : c.variable]) ==
      toset(["aws:RequestTag/eks-cluster-arn", "aws:RequestTag/kubernetes-namespace", "aws:RequestTag/kubernetes-service-account"]) &&
      one(one([for c in data.aws_iam_policy_document.pod_identity_assume_role["vpc-cni"].statement[0].condition : c.values if c.variable == "aws:RequestTag/kubernetes-service-account"])) == "aws-node"
    )
    error_message = "Pod Identity trust policies must be scoped to the cluster, namespace and service account."
  }

  assert {
    condition = (
      one(data.aws_iam_policy_document.logs_kms[0].statement[0].condition).variable == "kms:EncryptionContext:aws:logs:arn" &&
      one(one(data.aws_iam_policy_document.logs_kms[0].statement[0].condition).values) == "arn:aws:logs:us-east-1:123456789012:log-group:/aws/eks/test/cluster"
    )
    error_message = "The logs key must be usable by CloudWatch Logs for the cluster log group only."
  }

  assert {
    condition = (
      one(one(data.aws_iam_policy_document.ebs_kms[0].statement[0].principals).identifiers) == "arn:aws:iam::123456789012:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" &&
      one(data.aws_iam_policy_document.ebs_kms[0].statement[1].condition).variable == "kms:GrantIsForAWSResource"
    )
    error_message = "The EBS key must grant the Auto Scaling service-linked role, with grants limited to AWS resources."
  }

  assert {
    condition     = data.aws_iam_policy.ebs_csi[0].name == "AmazonEBSCSIDriverEKSClusterScopedPolicy"
    error_message = "The EBS CSI driver must default to the cluster-scoped managed policy."
  }
}

################################################################################
# Feature toggles
################################################################################

run "bring_your_own_keys" {
  command = plan

  variables {
    create_kms_key                      = false
    kms_key_arn                         = "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
    create_cloudwatch_log_group_kms_key = false
    cloudwatch_log_group_kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222"
    create_ebs_kms_key                  = false
    ebs_kms_key_arn                     = "arn:aws:kms:us-east-1:123456789012:key/33333333-3333-3333-3333-333333333333"
  }

  assert {
    condition     = length(aws_kms_key.cluster) + length(aws_kms_key.logs) + length(aws_kms_key.ebs) == 0
    error_message = "No keys may be created when all key ARNs are supplied."
  }

  # Consumers read the guard's frozen output, which is only known after apply; the guards' inputs show
  # which keys will be used.
  assert {
    condition = (
      terraform_data.kms_key_guard["cluster"].input == "arn:aws:kms:us-east-1:123456789012:key/11111111-1111-1111-1111-111111111111" &&
      terraform_data.kms_key_guard["logs"].input == "arn:aws:kms:us-east-1:123456789012:key/22222222-2222-2222-2222-222222222222" &&
      terraform_data.kms_key_guard["ebs"].input == "arn:aws:kms:us-east-1:123456789012:key/33333333-3333-3333-3333-333333333333"
    )
    error_message = "The supplied keys must be used."
  }
}

run "reject_inconsistent_key_inputs" {
  command = plan

  variables {
    create_kms_key = false
  }

  expect_failures = [var.kms_key_arn]
}

run "bottlerocket_arm_node_group" {
  command = plan

  variables {
    node_groups = {
      system = {
        ami_type               = "BOTTLEROCKET_ARM_64"
        disk_size              = 100
        disk_iops              = 6000
        bootstrap_extra_config = "settings.kubernetes.max-pods = 58"
      }
    }
  }

  assert {
    condition     = tolist(aws_eks_node_group.this["system"].instance_types) == tolist(["m7g.large"])
    error_message = "ARM node groups must default to a Graviton instance type."
  }

  assert {
    condition = (
      length(aws_launch_template.node["system"].block_device_mappings) == 2 &&
      one([for bd in aws_launch_template.node["system"].block_device_mappings : bd.ebs[0].iops if bd.device_name == "/dev/xvdb"]) == 6000 &&
      one([for bd in aws_launch_template.node["system"].block_device_mappings : bd.ebs[0].iops if bd.device_name == "/dev/xvda"]) != 6000
    )
    error_message = "Bottlerocket must encrypt both volumes and give the requested IOPS to the data volume only."
  }

  assert {
    condition = (
      startswith(base64decode(aws_launch_template.node["system"].user_data), "settings.kubernetes.max-pods = 58") &&
      strcontains(base64decode(aws_launch_template.node["system"].user_data), "lockdown = \"integrity\"") &&
      strcontains(base64decode(aws_launch_template.node["system"].user_data), "[settings.host-containers.admin]\nenabled = false")
    )
    error_message = "Caller TOML must come first (so dotted keys stay at the root), followed by the module's admin-container and lockdown settings."
  }
}

run "al2023_extra_node_config" {
  command = plan

  variables {
    node_groups = {
      default = {
        bootstrap_extra_config = "apiVersion: node.eks.aws/v1alpha1\nkind: NodeConfig\nspec:\n  kubelet:\n    config:\n      shutdownGracePeriod: 30s"
      }
    }
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.node["default"].user_data), "Content-Type: application/node.eks.aws")
    error_message = "AL2023 extra configuration must be wrapped as a NodeConfig MIME part."
  }
}

run "staged_data_plane_version" {
  command = plan

  variables {
    data_plane_kubernetes_version = "1.36"
  }

  assert {
    condition     = aws_eks_cluster.this.version == "1.37" && aws_eks_node_group.this["default"].version == "1.36"
    error_message = "Node groups must follow data_plane_kubernetes_version when it is set."
  }

  assert {
    condition     = data.aws_eks_addon_version.this["coredns"].kubernetes_version == "1.36"
    error_message = "Add-on versions must be resolved for the data-plane version."
  }
}

run "access_entries_and_creator_admin" {
  command = plan

  variables {
    enable_cluster_creator_admin_permissions = true
    access_entries = {
      viewers = {
        principal_arn = "arn:aws:iam::123456789012:role/viewers"
        policy_associations = {
          view = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
            access_scope = { type = "namespace", namespaces = ["apps"] }
          }
        }
      }
    }
  }

  assert {
    condition     = toset(keys(aws_eks_access_policy_association.this)) == toset(["cluster_creator/cluster_admin", "viewers/view"])
    error_message = "Policy associations must be keyed <entry>/<policy>."
  }

  assert {
    condition     = aws_eks_access_entry.this["cluster_creator"].principal_arn == "arn:aws:iam::123456789012:role/admin"
    error_message = "The cluster creator entry must use the session issuer (role) ARN."
  }
}

run "addon_overrides" {
  command = plan

  variables {
    enable_ebs_csi_driver = false
    addons = {
      snapshot-controller = {}
      coredns             = { version = "v1.14.7-eksbuild.10" }
    }
  }

  assert {
    condition     = toset(keys(aws_eks_addon.this)) == toset(["coredns", "snapshot-controller"])
    error_message = "User add-ons must merge with the core set and honour disabled core add-ons."
  }

  assert {
    condition     = aws_eks_addon.this["coredns"].addon_version == "v1.14.7-eksbuild.10" && aws_eks_addon.this["coredns"].preserve
    error_message = "A pinned add-on version must win over the EKS default without losing other core defaults."
  }

  assert {
    condition     = !contains(keys(aws_iam_role.pod_identity), "aws-ebs-csi-driver")
    error_message = "No EBS CSI role may be created when the driver is disabled."
  }
}

run "bring_your_own_addon_role" {
  command = plan

  variables {
    addons = {
      vpc-cni = {
        pod_identity_role_arn        = "arn:aws:iam::123456789012:role/custom-cni"
        pod_identity_service_account = "aws-node"
      }
    }
  }

  assert {
    condition     = !contains(keys(aws_iam_role.pod_identity), "vpc-cni") && one(aws_eks_addon.before_compute["vpc-cni"].pod_identity_association).role_arn == "arn:aws:iam::123456789012:role/custom-cni"
    error_message = "A caller-supplied Pod Identity role must replace the module role."
  }
}

run "irsa" {
  command = plan

  variables {
    enable_irsa = true
  }

  assert {
    condition     = toset(aws_iam_openid_connect_provider.this[0].client_id_list) == toset(["sts.amazonaws.com"])
    error_message = "IRSA must create an OIDC provider for STS."
  }
}

run "allow_all_egress_opt_in" {
  command = plan

  variables {
    node_security_group_allow_all_egress = true
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.node_all_ipv4[0].cidr_ipv4 == "0.0.0.0/0" && length(aws_vpc_security_group_egress_rule.node_all_ipv6) == 0
    error_message = "Opting in must add the unrestricted IPv4 egress rule only."
  }
}

run "pod_security_groups_and_strict_network_policy" {
  command = plan

  variables {
    vpc_cni = { enable_pod_security_groups = true, network_policy_enforcing_mode = "strict" }
  }

  assert {
    condition     = contains(aws_iam_role_policy_attachments_exclusive.cluster.policy_arns, "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController")
    error_message = "Security groups for pods needs AmazonEKSVPCResourceController on the cluster role."
  }

  assert {
    condition = (
      jsondecode(aws_eks_addon.before_compute["vpc-cni"].configuration_values).env.ENABLE_POD_ENI == "true" &&
      jsondecode(aws_eks_addon.before_compute["vpc-cni"].configuration_values).env.NETWORK_POLICY_ENFORCING_MODE == "strict"
    )
    error_message = "ENABLE_POD_ENI and strict network policy must be rendered into the vpc-cni configuration."
  }
}

run "ipv6" {
  command = plan

  variables {
    ip_family                            = "ipv6"
    node_security_group_allow_all_egress = true
  }

  assert {
    condition     = length(aws_iam_policy.cni_ipv6) == 1 && aws_launch_template.node["default"].metadata_options[0].http_protocol_ipv6 == "enabled"
    error_message = "IPv6 clusters need the custom CNI policy and the IMDS IPv6 endpoint."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.node_all_ipv6[0].cidr_ipv6 == "::/0"
    error_message = "IPv6 clusters that opt into unrestricted egress need the ::/0 rule."
  }
}

run "audit_metric_filters" {
  command = plan

  variables {
    enable_audit_log_metric_filters = true
    audit_log_alarm_sns_topic_arns  = ["arn:aws:sns:us-east-1:123456789012:security"]
  }

  assert {
    condition     = contains(keys(aws_cloudwatch_metric_alarm.audit), "secret_reads_by_humans") && aws_cloudwatch_log_metric_filter.audit["secret_reads_by_humans"].log_group_name == "/aws/eks/test/cluster"
    error_message = "Audit metric filters and alarms must be created on the control-plane log group."
  }
}

run "ordering_dependencies" {
  command = plan

  variables {
    node_group_dependencies     = ["vpce-0123456789abcdef0"]
    deletion_guard_dependencies = ["vpce-0123456789abcdef0"]
  }

  assert {
    condition     = one(terraform_data.node_group_dependencies.input) == "vpce-0123456789abcdef0" && one(terraform_data.deletion_guard.input.dependencies) == "vpce-0123456789abcdef0"
    error_message = "Node group and destroy-guard dependencies must be recorded."
  }
}

run "ebs_csi_keeps_previous_key" {
  command = plan

  variables {
    ebs_csi_additional_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/44444444-4444-4444-4444-444444444444"]
  }

  assert {
    condition = alltrue([
      for st in data.aws_iam_policy_document.ebs_csi_kms[0].statement :
      contains(st.resources, "arn:aws:kms:us-east-1:123456789012:key/44444444-4444-4444-4444-444444444444")
    ])
    error_message = "The EBS CSI role must keep access to previous EBS keys."
  }
}

run "longest_names" {
  command = plan

  variables {
    name        = "a123456789b123456789c123456789d123456789e123456789f123456789g123456789h123456789i123456789j123456789"
    node_groups = { abcdefghij0123456789 = {} }
  }

  assert {
    condition     = length(aws_launch_template.node["abcdefghij0123456789"].name_prefix) <= 99
    error_message = "Launch template name prefixes must fit the provider's 99-character limit."
  }
}

################################################################################
# Guard rails
################################################################################

run "reject_patch_version" {
  command = plan

  variables {
    kubernetes_version = "1.37.1"
  }

  expect_failures = [var.kubernetes_version]
}

run "reject_open_endpoint_cidr" {
  command = plan

  variables {
    cluster_endpoint_allowed_cidr_blocks = ["0.0.0.0/0"]
  }

  expect_failures = [var.cluster_endpoint_allowed_cidr_blocks]
}

run "reject_al2" {
  command = plan

  variables {
    node_groups = { legacy = { ami_type = "AL2_x86_64" } }
  }

  expect_failures = [var.node_groups]
}

run "reject_capacity_block" {
  command = plan

  variables {
    node_groups = { gpu = { ami_type = "AL2023_x86_64_NVIDIA", capacity_type = "CAPACITY_BLOCK" } }
  }

  expect_failures = [var.node_groups]
}

run "reject_iops_above_volume_ratio" {
  command = plan

  variables {
    node_groups = { default = { disk_size = 20, disk_iops = 16000 } }
  }

  expect_failures = [var.node_groups]
}

run "reject_bottlerocket_owned_settings" {
  command = plan

  variables {
    node_groups = { br = { ami_type = "BOTTLEROCKET_x86_64", bootstrap_extra_config = "[settings.kernel]\nlockdown = \"none\"" } }
  }

  expect_failures = [var.node_groups]
}

run "reject_stale_release_pin" {
  command = plan

  variables {
    node_groups = { default = { release_version = "1.36.4-20260915" } }
  }

  expect_failures = [var.node_groups]
}

run "reject_public_node_subnet" {
  command = plan

  override_data {
    target = data.aws_subnets.node_public_ip[0]
    values = { ids = ["subnet-0aaaaaaaaaaaaaaa1"] }
  }

  expect_failures = [data.aws_subnets.node_public_ip[0]]
}

run "reject_non_rfc1918_service_cidr" {
  command = plan

  variables {
    service_ipv4_cidr = "100.64.0.0/16"
  }

  expect_failures = [var.service_ipv4_cidr]
}

run "accept_rfc1918_service_cidr" {
  command = plan

  variables {
    service_ipv4_cidr = "172.20.0.0/16"
  }

  assert {
    condition     = aws_eks_cluster.this.kubernetes_network_config[0].service_ipv4_cidr == "172.20.0.0/16"
    error_message = "A valid service CIDR must be passed through."
  }
}

run "reject_service_cidr_overlapping_vpc" {
  command = plan

  variables {
    service_ipv4_cidr = "10.0.128.0/20"
  }

  expect_failures = [aws_eks_cluster.this]
}

run "reject_missing_audit_logs" {
  command = plan

  variables {
    cluster_enabled_log_types = ["api", "authenticator"]
  }

  expect_failures = [var.cluster_enabled_log_types]
}

run "reject_undocumented_egress_mode" {
  command = plan

  variables {
    control_plane_egress_mode = "CUSTOMER_ISOLATED"
  }

  expect_failures = [var.control_plane_egress_mode]
}

run "reject_namespace_scope_without_namespaces" {
  command = plan

  variables {
    access_entries = {
      bad = {
        principal_arn = "arn:aws:iam::123456789012:role/bad"
        policy_associations = {
          edit = {
            policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
            access_scope = { type = "namespace" }
          }
        }
      }
    }
  }

  expect_failures = [var.access_entries]
}

run "reject_duplicate_principals" {
  command = plan

  variables {
    access_entries = {
      a = { principal_arn = "arn:aws:iam::123456789012:role/admin" }
      b = { principal_arn = "arn:aws:iam::123456789012:role/admin" }
    }
  }

  expect_failures = [var.access_entries]
}

run "reject_sts_session_principal" {
  command = plan

  variables {
    access_entries = {
      a = { principal_arn = "arn:aws:sts::123456789012:assumed-role/admin/session" }
    }
  }

  expect_failures = [var.access_entries]
}

run "reject_kms_alias" {
  command = plan

  variables {
    create_kms_key = false
    kms_key_arn    = "arn:aws:kms:us-east-1:123456789012:alias/eks"
  }

  expect_failures = [var.kms_key_arn]
}

run "reject_core_addon_reordering" {
  command = plan

  variables {
    addons = { coredns = { before_compute = true } }
  }

  expect_failures = [var.addons]
}

run "reject_disabled_pod_identity_agent" {
  command = plan

  variables {
    addons = { eks-pod-identity-agent = { enabled = false } }
  }

  expect_failures = [aws_eks_cluster.this]
}

run "reject_old_ebs_csi_with_cluster_scoped_policy" {
  command = plan

  variables {
    addons = { aws-ebs-csi-driver = { version = "v1.50.0-eksbuild.1" } }
  }

  expect_failures = [aws_eks_addon.this]
}

run "reject_audit_filters_on_infrequent_access" {
  command = plan

  variables {
    enable_audit_log_metric_filters = true
    cloudwatch_log_group_class      = "INFREQUENT_ACCESS"
  }

  expect_failures = [aws_cloudwatch_log_metric_filter.audit]
}

run "reject_ipv6_with_service_cidr" {
  command = plan

  variables {
    ip_family         = "ipv6"
    service_ipv4_cidr = "172.20.0.0/16"
  }

  expect_failures = [aws_eks_cluster.this]
}

run "reject_vpc_without_dns" {
  command = plan

  override_data {
    target = data.aws_vpc.this
    values = {
      cidr_block              = "10.0.0.0/16"
      cidr_block_associations = []
      enable_dns_support      = true
      enable_dns_hostnames    = false
    }
  }

  expect_failures = [aws_eks_cluster.this]
}

run "no_managed_node_groups" {
  command = plan

  # Compute comes from elsewhere (Karpenter, another stack): no public-IP subnet query with an empty filter.
  variables {
    node_groups = {}
  }

  expect_failures = [check.addon_compute]

  assert {
    condition     = length(data.aws_subnets.node_public_ip) == 0 && length(aws_eks_node_group.this) == 0
    error_message = "Without node groups the module must not query node subnets."
  }
}

run "reject_unsupported_control_plane_az" {
  command = plan

  override_data {
    target = data.aws_subnets.control_plane_unsupported_az
    values = { ids = ["subnet-0aaaaaaaaaaaaaaa2"] }
  }

  expect_failures = [data.aws_subnets.control_plane_unsupported_az]
}

run "reject_creator_also_in_access_entries" {
  command = plan

  variables {
    enable_cluster_creator_admin_permissions = true
    access_entries = {
      ci = { principal_arn = "arn:aws:iam::123456789012:role/admin" }
    }
  }

  expect_failures = [aws_eks_access_entry.this]
}

run "reject_dotted_bottlerocket_kernel_settings" {
  command = plan

  variables {
    node_groups = { br = { ami_type = "BOTTLEROCKET_x86_64", bootstrap_extra_config = "settings.kernel.sysctl.\"vm.max_map_count\" = \"262144\"" } }
  }

  expect_failures = [var.node_groups]
}

run "reject_bare_settings_header" {
  command = plan

  variables {
    node_groups = { br = { ami_type = "BOTTLEROCKET_x86_64", bootstrap_extra_config = "[settings]\nhost-containers.admin.enabled = true" } }
  }

  expect_failures = [var.node_groups]
}

run "reject_ebs_key_arn_with_module_key" {
  command = plan

  variables {
    ebs_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/33333333-3333-3333-3333-333333333333"
  }

  expect_failures = [var.ebs_kms_key_arn]
}

run "reject_missing_log_key_arn" {
  command = plan

  variables {
    create_cloudwatch_log_group_kms_key = false
  }

  expect_failures = [var.cloudwatch_log_group_kms_key_arn]
}

run "reject_invalid_name" {
  command = plan

  variables {
    name = "-bad"
  }

  expect_failures = [var.name]
}

run "reject_single_node_subnet" {
  command = plan

  variables {
    node_subnet_ids = ["subnet-0aaaaaaaaaaaaaaa1"]
  }

  expect_failures = [var.node_subnet_ids]
}

run "reject_rule_with_two_targets" {
  command = plan

  variables {
    node_security_group_additional_rules = {
      db = { direction = "egress", description = "db", ip_protocol = "tcp", from_port = 5432, to_port = 5432, cidr_ipv4 = "10.0.0.0/16", self = true }
    }
  }

  expect_failures = [var.node_security_group_additional_rules]
}
