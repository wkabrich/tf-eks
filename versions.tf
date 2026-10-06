terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # 6.52 added vpc_config.control_plane_egress_mode; 6.67 is the version this module is tested against.
      version = ">= 6.67, < 7.0"
    }
  }
}
