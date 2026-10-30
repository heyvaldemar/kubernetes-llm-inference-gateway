variable "region" {
  description = "The validation account's one region."
  type        = string
  default     = "us-east-1"
}

variable "run_id" {
  description = "The GitHub run that owns everything here, for the tags and the name."
  type        = string
}

variable "cluster_name" {
  description = <<-EOT
    The cluster's name, and the prefix of every IAM role it makes. The
    validation account lets a run create and change roles only under
    reference-platform (its guardrails), so this starts with that.
  EOT
  type        = string

  validation {
    condition     = can(regex("^reference-platform-inference-[a-z0-9-]{1,30}$", var.cluster_name))
    error_message = "cluster_name is reference-platform-inference-<run>, the prefix the account's guardrails allow roles under."
  }
}

variable "kubernetes_version" {
  description = "EKS's Kubernetes version."
  type        = string
  default     = "1.37"
}

variable "vpc_cidr" {
  description = "The VPC's range."
  type        = string
  default     = "10.43.0.0/16"
}

variable "operator_cidrs" {
  description = "Where the operator reaches the cluster's API from: the runner's own address, /32, for the length of a run."
  type        = list(string)

  validation {
    condition     = length(var.operator_cidrs) > 0 && alltrue([for c in var.operator_cidrs : endswith(c, "/32")])
    error_message = "operator_cidrs holds single addresses (/32): the API is never open to a range."
  }
}

variable "iam_permissions_boundary" {
  description = "The account's permissions boundary, which every role a run makes must carry."
  type        = string
}

variable "node_instance_type" {
  description = <<-EOT
    The CPU node, where the router, its Endpoint Picker, the load generator
    and CoreDNS run, so that nothing but the model servers takes the GPU
    node's four vCPUs.
  EOT
  type        = string
  default     = "m7i.large"

  validation {
    condition     = contains(["m7i.large"], var.node_instance_type)
    error_message = "node_instance_type is m7i.large, the CPU node scripts/eks.sh prices."
  }
}

variable "gpu_instance_type" {
  description = <<-EOT
    The GPU node: one NVIDIA L4, four vCPUs, inside the account's quota for
    G and VT instances (8 vCPUs in us-east-1 since 2026-10-22, which the
    flagship's weekly GPU run also uses, on another day).
  EOT
  type        = string
  default     = "g6.xlarge"

  validation {
    condition     = contains(["g6.xlarge"], var.gpu_instance_type)
    error_message = "gpu_instance_type is g6.xlarge: one L4, the node scripts/eks.sh prices and the budget allows."
  }
}

variable "gpu_disk_gib" {
  description = <<-EOT
    The GPU node's root volume. vLLM's image is 7.3 GB compressed and about
    three times that unpacked, containerd keeps both, and the model's 3.1 GB
    goes beside them.
  EOT
  type        = number
  default     = 80
}
