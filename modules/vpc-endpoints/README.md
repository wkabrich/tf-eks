# VPC endpoints for a private EKS cluster

Creates the interface endpoints and the S3 gateway endpoint that EKS nodes need in subnets with no NAT or internet gateway, plus a security group that allows HTTPS from the VPC.

Every interface endpoint gets private DNS, so SDKs, nodeadm and the kubelet use the normal regional hostnames with no extra configuration. Service names are resolved through the EC2 API, so the module works in every partition.

```hcl
module "vpc_endpoints" {
  source = "../../modules/vpc-endpoints"

  name            = "payments-prod"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnet_ids      # one per AZ (module.vpc is ../vpc)
  route_table_ids = module.vpc.private_route_table_ids # for the S3 gateway endpoint

  interface_endpoints = ["ec2", "ecr.api", "ecr.dkr", "eks", "eks-auth", "logs", "sts", "ssm", "ssmmessages"]

  # Only this account's principals (or organization_id) through the interface endpoints,
  # only this account's buckets (plus the ECR layer bucket) through the S3 gateway.
  data_perimeter = { enabled = true }
}
```

Notes:

- Pod traffic to the endpoints keeps the pod's IP address. `allowed_cidr_blocks` must therefore cover every CIDR that pods use, including secondary CIDRs used for custom networking. It defaults to the VPC's primary CIDR.
- An endpoint service that is not offered in every AZ fails on subnets in the unsupported AZs. Pass only subnets in supported AZs.
- `data_perimeter` blocks a compromised pod from sending data to another AWS account through the endpoints with foreign credentials. It also blocks legitimate cross-account access: callers from other accounts on the interface endpoints, and other accounts' buckets through the S3 gateway (unless listed in `additional_s3_bucket_arns`). It does **not** restrict where images come from. The interface check is on the caller, so this account's nodes can still pull from other accounts' ECR repositories. Use admission policies or registry controls for image provenance, and Route 53 Resolver DNS Firewall for DNS tunnelling.
- Turning `data_perimeter` off resets the endpoints to AWS's default full-access policy.
- Pass `dependency_ids` to the EKS module's `node_group_dependencies` and `deletion_guard_dependencies`. Nodes then wait for every endpoint, and the endpoints sit behind the cluster's destroy guard.
- If your organisation runs centralized endpoints in a shared-services VPC (Route 53 profiles or shared private hosted zones), skip this module and make sure those endpoints serve the cluster VPC.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.67, < 7.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 6.67, < 7.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_vpc_endpoint.interface](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_security_group_ingress_rule.cidr](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.security_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.interface_perimeter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.s3_perimeter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
| [aws_vpc_endpoint_service.interface](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc_endpoint_service) | data source |
| [aws_vpc_endpoint_service.s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc_endpoint_service) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for the endpoint security group and tags (usually the cluster name). | `string` | n/a | yes |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | Subnets for the interface endpoint ENIs, at most one per Availability Zone (usually the node subnets). | `list(string)` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC to create the endpoints in. It must have enableDnsSupport and enableDnsHostnames turned on for private DNS. | `string` | n/a | yes |
| <a name="input_allowed_cidr_blocks"></a> [allowed\_cidr\_blocks](#input\_allowed\_cidr\_blocks) | CIDR blocks allowed to reach the interface endpoints on TCP 443. Empty uses the VPC's primary IPv4 CIDR. Include every CIDR pods may use (secondary CIDRs, custom networking), because pod traffic to endpoints keeps the pod IP. | `list(string)` | `[]` | no |
| <a name="input_allowed_security_group_ids"></a> [allowed\_security\_group\_ids](#input\_allowed\_security\_group\_ids) | Security groups allowed to reach the interface endpoints on TCP 443, in addition to allowed\_cidr\_blocks. | `list(string)` | `[]` | no |
| <a name="input_create_s3_gateway_endpoint"></a> [create\_s3\_gateway\_endpoint](#input\_create\_s3\_gateway\_endpoint) | Create an S3 gateway endpoint. ECR stores image layers in S3, so nodes in subnets without NAT need it to pull any image. | `bool` | `true` | no |
| <a name="input_data_perimeter"></a> [data\_perimeter](#input\_data\_perimeter) | Attach endpoint policies that form a data perimeter. Interface endpoints then accept only principals from this account (or organization\_id), plus<br/>unauthenticated sts:AssumeRoleWithWebIdentity for IRSA. The S3 gateway endpoint reaches only buckets owned by this account (or organization),<br/>the AWS-owned bucket that holds ECR image layers, and additional\_s3\_bucket\_arns. This stops a compromised pod from sending data to another<br/>AWS account through the endpoints using foreign credentials. It also blocks legitimate cross-account access through these endpoints, so<br/>review before enabling. It does not restrict which ECR repositories images come from (the check is on the caller, not the resource),<br/>and DNS-based exfiltration is out of scope (use Route 53 Resolver DNS Firewall). | <pre>object({<br/>    enabled                   = optional(bool, false)<br/>    organization_id           = optional(string)<br/>    additional_s3_bucket_arns = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| <a name="input_interface_endpoint_policies"></a> [interface\_endpoint\_policies](#input\_interface\_endpoint\_policies) | Custom endpoint policy JSON per interface endpoint service, keyed by service short name. Overrides data\_perimeter for that service. | `map(string)` | `{}` | no |
| <a name="input_interface_endpoints"></a> [interface\_endpoints](#input\_interface\_endpoints) | AWS service short names to create interface endpoints for (com.amazonaws.<region>.<name>). The default is what a no-NAT EKS cluster needs:<br/>  ec2, ecr.api, ecr.dkr: node bootstrap and image pulls (required)<br/>  eks-auth: EKS Pod Identity, including the vpc-cni add-on's credentials (required with the parent module)<br/>  sts: IRSA and SDKs using regional STS<br/>  logs: Fluent Bit / CloudWatch agent<br/>  eks: EKS API calls from inside the VPC (CI runners, aws eks update-kubeconfig)<br/>Common additions: ssm and ssmmessages (Session Manager), elasticloadbalancing (AWS Load Balancer Controller), autoscaling (Cluster Autoscaler),<br/>guardduty-data (GuardDuty runtime monitoring), monitoring, xray, kms, secretsmanager, oidc-eks (in-VPC OIDC discovery). | `set(string)` | <pre>[<br/>  "ec2",<br/>  "ecr.api",<br/>  "ecr.dkr",<br/>  "eks",<br/>  "eks-auth",<br/>  "logs",<br/>  "sts"<br/>]</pre> | no |
| <a name="input_ip_address_type"></a> [ip\_address\_type](#input\_ip\_address\_type) | IP address type of the interface endpoints: ipv4, dualstack or ipv6. null uses the AWS default (ipv4). | `string` | `null` | no |
| <a name="input_route_table_ids"></a> [route\_table\_ids](#input\_route\_table\_ids) | Route tables of the node subnets, associated with the S3 gateway endpoint. | `list(string)` | `[]` | no |
| <a name="input_s3_gateway_endpoint_policy"></a> [s3\_gateway\_endpoint\_policy](#input\_s3\_gateway\_endpoint\_policy) | JSON policy for the S3 gateway endpoint; overrides data\_perimeter. null sets AWS's full-access policy, or the perimeter policy when data\_perimeter is enabled. A restrictive policy must at least allow s3:GetObject on arn:aws:s3:::prod-<region>-starport-layer-bucket/* for ECR image pulls. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_dependency_ids"></a> [dependency\_ids](#output\_dependency\_ids) | IDs of every resource this module creates. Pass to the EKS module's node\_group\_dependencies (nodes wait for the endpoints) and deletion\_guard\_dependencies (the endpoints are protected by its destroy guard). |
| <a name="output_interface_endpoint_ids"></a> [interface\_endpoint\_ids](#output\_interface\_endpoint\_ids) | Interface endpoint IDs, keyed by service short name. |
| <a name="output_s3_gateway_endpoint_id"></a> [s3\_gateway\_endpoint\_id](#output\_s3\_gateway\_endpoint\_id) | ID of the S3 gateway endpoint, or null when it is not created. |
| <a name="output_s3_prefix_list_id"></a> [s3\_prefix\_list\_id](#output\_s3\_prefix\_list\_id) | Prefix list ID of the S3 gateway endpoint, for security group egress rules. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | ID of the security group attached to the interface endpoints. |
<!-- END_TF_DOCS -->
