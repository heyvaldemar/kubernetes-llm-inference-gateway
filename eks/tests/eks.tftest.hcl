# What the GPU run's Terraform promises (ADR 5), checked on a plan against a
# mocked AWS provider: no account, no credentials, no cost. CI runs it on
# every push (e2e.yml, job "Lint"); the run itself is .github/workflows/gpu.yml.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:sts::123456789012:assumed-role/platform-validation-create/run" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/platform-validation-create" }
  }
  # us-east-1c is use1-az3 here, the zone that takes no EKS control plane.
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az3", "use1-az4"]
    }
  }
}

override_data {
  target = data.aws_ec2_instance_type_offerings.node["m7i.large"]
  values = { locations = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"] }
}

override_data {
  target = data.aws_ec2_instance_type_offerings.node["g6.xlarge"]
  values = { locations = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"] }
}

variables {
  run_id                   = "12345678901"
  cluster_name             = "reference-platform-inference-12345678901"
  operator_cidrs           = ["203.0.113.7/32"]
  iam_permissions_boundary = "arn:aws:iam::123456789012:policy/platform-validation-boundary"
  gpu_zone                 = "us-east-1d"
  gpu_reservation_ends     = "2026-10-30T18:00:00Z"
}

run "every_zone_that_offers_the_gpu" {
  command = plan

  assert {
    condition     = local.azs == tolist(["us-east-1a", "us-east-1b", "us-east-1d"])
    error_message = "every zone that offers both instance types, and never use1-az3"
  }
  assert {
    condition     = length(aws_subnet.public) == 3 && alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch])
    error_message = "a public subnet in each, whose nodes get an address for their own traffic out"
  }
}

run "only_zones_that_offer_the_gpu" {
  command = plan

  override_data {
    target = data.aws_ec2_instance_type_offerings.node["g6.xlarge"]
    values = { locations = ["us-east-1a", "us-east-1c", "us-east-1d"] }
  }

  assert {
    condition     = local.azs == tolist(["us-east-1a", "us-east-1d"])
    error_message = "a zone without the GPU instance type is left out"
  }
}

run "the_api_answers_the_runner_alone" {
  command = plan

  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].public_access_cidrs == toset(["203.0.113.7/32"])
    error_message = "the public endpoint answers the operator's /32 and nothing else"
  }
  assert {
    condition     = aws_eks_cluster.this.vpc_config[0].endpoint_private_access
    error_message = "the nodes reach the API through the private endpoint"
  }
  assert {
    condition     = aws_eks_cluster.this.access_config[0].authentication_mode == "API" && !aws_eks_cluster.this.access_config[0].bootstrap_cluster_creator_admin_permissions
    error_message = "access entries only, and the creator is an administrator only by its explicit entry"
  }
}

run "one_l4_for_the_model_servers_alone" {
  command = plan

  assert {
    condition     = aws_eks_node_group.gpu[0].instance_types == tolist(["g6.xlarge"]) && aws_eks_node_group.gpu[0].ami_type == "AL2023_x86_64_NVIDIA"
    error_message = "one g6.xlarge on EKS's AL2023 NVIDIA image"
  }
  assert {
    condition     = [for t in aws_eks_node_group.gpu[0].taint : "${t.key}=${t.value}:${t.effect}"] == ["nvidia.com/gpu=present:NO_SCHEDULE"]
    error_message = "the GPU node is tainted, so only what asks for a GPU lands on it"
  }
  assert {
    condition     = aws_eks_node_group.gpu[0].labels["inference.heyvaldemar.com/accelerator"] == "nvidia"
    error_message = "the model servers find the GPU node by its label"
  }
  assert {
    condition     = alltrue([for g in [aws_eks_node_group.gpu[0], aws_eks_node_group.cpu] : g.scaling_config[0].min_size == 1 && g.scaling_config[0].max_size == 1 && g.capacity_type == "ON_DEMAND"])
    error_message = "exactly one node of each, on demand, the price the cost per token is computed from"
  }
  assert {
    condition     = aws_eks_node_group.cpu.instance_types == tolist(["m7i.large"]) && length(aws_eks_node_group.cpu.taint) == 0
    error_message = "everything else on one untainted CPU node"
  }
}

run "the_l4_is_reserved_before_its_node_exists" {
  command = plan

  assert {
    condition     = aws_ec2_capacity_reservation.gpu[0].instance_type == "g6.xlarge" && aws_ec2_capacity_reservation.gpu[0].availability_zone == "us-east-1d" && aws_ec2_capacity_reservation.gpu[0].instance_count == 1
    error_message = "one g6.xlarge reserved, in the zone the run found one in"
  }
  assert {
    condition     = aws_ec2_capacity_reservation.gpu[0].instance_match_criteria == "targeted"
    error_message = "targeted: only a launch that names the reservation takes it"
  }
  assert {
    condition     = aws_ec2_capacity_reservation.gpu[0].end_date_type == "limited" && aws_ec2_capacity_reservation.gpu[0].end_date == "2026-10-30T18:00:00Z"
    error_message = "AWS ends the reservation by itself, whatever happens to the teardown"
  }
  assert {
    condition     = length(aws_launch_template.node["gpu"].capacity_reservation_specification) == 1 && length(aws_launch_template.node["cpu"].capacity_reservation_specification) == 0
    error_message = "the GPU node launches into the reservation, and the CPU node does not"
  }
}

run "the_fallback_is_one_a10g_in_a_zone_that_offers_it" {
  command = plan
  variables {
    gpu_instance_type = "g5.xlarge"
    gpu_zone          = "us-east-1b"
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.node["g5.xlarge"]
    values = { locations = ["us-east-1b", "us-east-1d"] }
  }

  assert {
    condition     = local.azs == tolist(["us-east-1b", "us-east-1d"])
    error_message = "the zones are those that offer the A10G"
  }
  assert {
    condition     = aws_ec2_capacity_reservation.gpu[0].instance_type == "g5.xlarge" && aws_eks_node_group.gpu[0].instance_types == tolist(["g5.xlarge"]) && aws_eks_node_group.gpu[0].ami_type == "AL2023_x86_64_NVIDIA"
    error_message = "one g5.xlarge reserved and made, on the same NVIDIA image"
  }
}

run "a_gpu_the_run_cannot_name_is_refused" {
  command = plan
  variables {
    gpu_instance_type = "g4dn.xlarge"
  }
  expect_failures = [var.gpu_instance_type]
}

run "the_first_apply_makes_no_gpu" {
  command = plan
  variables {
    gpu_zone = ""
  }

  assert {
    condition     = length(aws_ec2_capacity_reservation.gpu) == 0 && length(aws_eks_node_group.gpu) == 0
    error_message = "no reservation and no GPU node until a zone has given one"
  }
}

run "a_zone_outside_the_run_is_refused" {
  command = plan
  variables {
    gpu_zone = "us-east-1c"
  }
  expect_failures = [aws_ec2_capacity_reservation.gpu]
}

run "nodes_keep_pods_off_the_instance_credentials" {
  command = plan

  assert {
    condition     = alltrue([for t in aws_launch_template.node : t.metadata_options[0].http_tokens == "required" && t.metadata_options[0].http_put_response_hop_limit == 1])
    error_message = "IMDSv2 only, one hop: a pod cannot reach the node's role"
  }
  assert {
    condition     = aws_launch_template.node["gpu"].block_device_mappings[0].ebs[0].volume_size == 80 && aws_launch_template.node["gpu"].block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "the GPU node's encrypted root volume holds vLLM's image unpacked and the model"
  }
}

run "every_role_carries_the_boundary" {
  command = plan

  assert {
    condition     = alltrue([for r in [aws_iam_role.cluster, aws_iam_role.node] : r.permissions_boundary == var.iam_permissions_boundary && startswith(r.name, var.cluster_name)])
    error_message = "every role the run makes carries the account's boundary, under the cluster's name"
  }
}

run "a_name_outside_the_guardrails_is_refused" {
  command = plan
  variables {
    cluster_name = "inference-12345678901"
  }
  expect_failures = [var.cluster_name]
}

run "an_api_open_to_a_range_is_refused" {
  command = plan
  variables {
    operator_cidrs = ["203.0.113.0/24"]
  }
  expect_failures = [var.operator_cidrs]
}

run "fewer_than_two_zones_with_the_gpu_stop_the_plan" {
  command = plan
  variables {
    gpu_zone = ""
  }

  override_data {
    target = data.aws_ec2_instance_type_offerings.node["g6.xlarge"]
    values = { locations = ["us-east-1a", "us-east-1c"] }
  }

  expect_failures = [aws_vpc.this]
}
