# The GPU run (ADR 5), one at a time: everything here is made by a run of
# .github/workflows/gpu.yml and destroyed by it, in the validation account's
# region.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.68"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

locals {
  tags = {
    "inference.heyvaldemar.com/project" = "kubernetes-llm-inference-gateway"
    "inference.heyvaldemar.com/cluster" = var.cluster_name
    "run-id"                            = var.run_id
    "managed-by"                        = "terraform"
  }
}
