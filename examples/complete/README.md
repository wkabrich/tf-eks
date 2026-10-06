# Complete example: private EKS with no internet egress

This example builds:

- a VPC with **no internet gateway and no NAT gateway**, three `/20` node subnets, three dedicated `/28` control-plane subnets, a locked-down default security group, and VPC flow logs
- the interface and S3 gateway endpoints nodes need to bootstrap and pull images, plus Session Manager endpoints
- the cluster: private endpoint only, three CMKs, all control-plane logs, audit-log metric filters, a Bottlerocket ARM system node group and an AL2023 x86 general node group

```bash
terraform init
```

```bash
terraform apply -var admin_role_arn=arn:aws:iam::111122223333:role/Admin -var 'admin_cidr_blocks=["10.100.0.0/16"]'
```

`admin_cidr_blocks` should be a network that can actually route to this VPC (VPN, Direct Connect, TGW). Without one, use SSM port forwarding through one of the cluster's nodes (`enable_node_ssm_access` is on in this example). See the root README.

The example sets `deletion_protection = false` so `terraform destroy` works. Leave the module default (`true`) for real clusters.

Cost note: the interface endpoints (9 endpoints × 3 AZs), three KMS keys, the control plane and the four nodes are billed while the example runs.
