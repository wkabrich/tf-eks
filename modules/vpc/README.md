# Private VPC for EKS

A VPC with no path to the internet, shaped for the parent EKS module:

- no internet gateway, no NAT gateway, and only local routes; workloads reach AWS through VPC endpoints (`../vpc-endpoints`)
- DNS support and DNS hostnames on, which the EKS private endpoint and interface endpoint private DNS require
- private node subnets (one route table per AZ, ready for the S3 gateway endpoint), tagged for internal load balancers
- optional dedicated control-plane subnets for the EKS ENIs (a `/28` per AZ is enough)
- the default security group stripped of all rules, and kept that way
- VPC flow logs in a CloudWatch log group encrypted with a dedicated, rotating KMS key, written by a role scoped to that log group

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name = "payments-prod"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b", "us-east-1c"]

  private_subnets       = ["10.0.0.0/20", "10.0.16.0/20", "10.0.32.0/20"]
  control_plane_subnets = ["10.0.255.0/28", "10.0.255.16/28", "10.0.255.32/28"]
}
```

EKS does not accept control-plane subnets in the AZ IDs `use1-az3`, `usw1-az2` and `cac1-az3`. AZ names map to different AZ IDs per account, so choose `azs` with `data "aws_availability_zones"` and `exclude_zone_ids`, as `examples/complete` does.

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
| [aws_cloudwatch_log_group.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_flow_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_route_table.control_plane](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.control_plane](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_subnet.control_plane](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.flow_logs_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.flow_logs_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_azs"></a> [azs](#input\_azs) | Availability Zone names, one per subnet in each tier. Use at least two; for EKS control-plane subnets avoid the AZ IDs use1-az3, usw1-az2 and cac1-az3. | `list(string)` | n/a | yes |
| <a name="input_cidr"></a> [cidr](#input\_cidr) | IPv4 CIDR block of the VPC. | `string` | n/a | yes |
| <a name="input_name"></a> [name](#input\_name) | Name used for the VPC and as a prefix for its resources (usually the cluster name). | `string` | n/a | yes |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | CIDR blocks of the private node subnets, one per entry in azs. These have no route outside the VPC. | `list(string)` | n/a | yes |
| <a name="input_control_plane_subnet_tags"></a> [control\_plane\_subnet\_tags](#input\_control\_plane\_subnet\_tags) | Extra tags for the control-plane subnets. | `map(string)` | `{}` | no |
| <a name="input_control_plane_subnets"></a> [control\_plane\_subnets](#input\_control\_plane\_subnets) | CIDR blocks of dedicated subnets for the EKS control-plane ENIs (/28 is enough), one per entry in azs. Empty creates none. | `list(string)` | `[]` | no |
| <a name="input_create_flow_log_kms_key"></a> [create\_flow\_log\_kms\_key](#input\_create\_flow\_log\_kms\_key) | Create a dedicated KMS key for the flow-log log group. Set false and pass flow\_log\_kms\_key\_arn to use your own. | `bool` | `true` | no |
| <a name="input_enable_flow_logs"></a> [enable\_flow\_logs](#input\_enable\_flow\_logs) | Send VPC flow logs to an encrypted CloudWatch log group. | `bool` | `true` | no |
| <a name="input_flow_log_kms_key_arn"></a> [flow\_log\_kms\_key\_arn](#input\_flow\_log\_kms\_key\_arn) | ARN of an existing KMS key for the flow-log log group, when create\_flow\_log\_kms\_key is false. Its policy must let logs.<region>.amazonaws.com use it for this log group. | `string` | `null` | no |
| <a name="input_flow_log_max_aggregation_interval"></a> [flow\_log\_max\_aggregation\_interval](#input\_flow\_log\_max\_aggregation\_interval) | Maximum seconds over which a flow-log record is aggregated: 60 or 600. | `number` | `600` | no |
| <a name="input_flow_log_retention_in_days"></a> [flow\_log\_retention\_in\_days](#input\_flow\_log\_retention\_in\_days) | Retention of the flow-log log group. 0 keeps logs forever. | `number` | `365` | no |
| <a name="input_flow_log_traffic_type"></a> [flow\_log\_traffic\_type](#input\_flow\_log\_traffic\_type) | Traffic captured by the flow log: ACCEPT, REJECT or ALL. | `string` | `"ALL"` | no |
| <a name="input_private_subnet_tags"></a> [private\_subnet\_tags](#input\_private\_subnet\_tags) | Extra tags for the private node subnets. The default marks them for internal load balancers created by the AWS Load Balancer Controller. | `map(string)` | <pre>{<br/>  "kubernetes.io/role/internal-elb": "1"<br/>}</pre> | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every resource the module creates. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_control_plane_route_table_id"></a> [control\_plane\_route\_table\_id](#output\_control\_plane\_route\_table\_id) | ID of the control-plane route table, or null when there are no control-plane subnets. |
| <a name="output_control_plane_subnet_ids"></a> [control\_plane\_subnet\_ids](#output\_control\_plane\_subnet\_ids) | IDs of the control-plane subnets, in the order of azs (empty when none were requested). |
| <a name="output_default_security_group_id"></a> [default\_security\_group\_id](#output\_default\_security\_group\_id) | ID of the VPC's default security group (all rules removed). |
| <a name="output_flow_log_group_name"></a> [flow\_log\_group\_name](#output\_flow\_log\_group\_name) | Name of the CloudWatch log group receiving VPC flow logs, or null when flow logs are off. |
| <a name="output_flow_log_kms_key_arn"></a> [flow\_log\_kms\_key\_arn](#output\_flow\_log\_kms\_key\_arn) | ARN of the KMS key encrypting the flow-log log group, or null when flow logs are off. |
| <a name="output_private_route_table_ids"></a> [private\_route\_table\_ids](#output\_private\_route\_table\_ids) | IDs of the private route tables, one per AZ (for gateway endpoints such as S3). |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | IDs of the private node subnets, in the order of azs. |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | IPv4 CIDR block of the VPC. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | ID of the VPC. |
<!-- END_TF_DOCS -->
