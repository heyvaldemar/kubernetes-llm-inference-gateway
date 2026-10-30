# Two nodes: a CPU node for the router, its Endpoint Picker, the load
# generator and CoreDNS, and the GPU node for the four model servers alone.
# IMDSv2 only, with a hop limit that keeps pods off the instance's
# credentials.

resource "aws_iam_role" "node" {
  name                 = "${var.cluster_name}-node"
  permissions_boundary = var.iam_permissions_boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryPullOnly",
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

locals {
  # Instances and volumes a node group launches carry no provider default
  # tags; these let scripts/eks.sh find and price them, and find what a
  # destroy left.
  node_groups = {
    cpu = { instance_type = var.node_instance_type, ami_type = "AL2023_x86_64_STANDARD", disk_gib = null }
    gpu = { instance_type = var.gpu_instance_type, ami_type = "AL2023_x86_64_NVIDIA", disk_gib = var.gpu_disk_gib }
  }
}

resource "aws_launch_template" "node" {
  for_each    = local.node_groups
  name_prefix = "${var.cluster_name}-${each.key}-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  dynamic "block_device_mappings" {
    for_each = each.value.disk_gib == null ? [] : [each.value.disk_gib]
    content {
      device_name = "/dev/xvda"
      ebs {
        volume_size           = block_device_mappings.value
        volume_type           = "gp3"
        delete_on_termination = true
        encrypted             = true
      }
    }
  }

  dynamic "tag_specifications" {
    for_each = ["instance", "volume"]
    content {
      resource_type = tag_specifications.value
      tags          = merge(local.tags, { Name = "${var.cluster_name}-${each.key}" })
    }
  }
}

resource "aws_eks_node_group" "cpu" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-cpu"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  ami_type        = local.node_groups.cpu.ami_type
  instance_types  = [local.node_groups.cpu.instance_type]
  capacity_type   = "ON_DEMAND"

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  launch_template {
    id      = aws_launch_template.node["cpu"].id
    version = aws_launch_template.node["cpu"].latest_version
  }

  depends_on = [aws_eks_addon.before_nodes, aws_iam_role_policy_attachment.node]
}

# EKS's AL2023 image with NVIDIA's driver (580) and container toolkit, one
# L4, tainted so only what asks for a GPU lands on it. NVIDIA's device plugin
# (deploy/gpu/device-plugin.yaml) offers the GPU to the scheduler as four.
# A launch that finds no capacity fails the apply within the timeout instead
# of keeping the control plane billing for Terraform's default hour.
resource "aws_eks_node_group" "gpu" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-gpu"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = aws_subnet.public[*].id
  ami_type        = local.node_groups.gpu.ami_type
  instance_types  = [local.node_groups.gpu.instance_type]
  capacity_type   = "ON_DEMAND"

  labels = {
    "inference.heyvaldemar.com/accelerator" = "nvidia"
  }

  taint {
    key    = "nvidia.com/gpu"
    value  = "present"
    effect = "NO_SCHEDULE"
  }

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 1
  }

  launch_template {
    id      = aws_launch_template.node["gpu"].id
    version = aws_launch_template.node["gpu"].latest_version
  }

  timeouts {
    create = "20m"
  }

  depends_on = [aws_eks_addon.before_nodes, aws_iam_role_policy_attachment.node]
}
