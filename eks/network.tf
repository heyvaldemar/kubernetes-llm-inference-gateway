# Public subnets and an internet gateway, and no NAT gateway: the nodes
# pull vLLM's image from Docker Hub and the model from Hugging Face, about
# 10 GB a run, which a NAT gateway would bill by the gigabyte. Each node has
# a public address for its own traffic out, and nothing reaches it from
# outside: the nodes sit in EKS's cluster security group, which admits only
# its own members. The cluster's API answers the runner's address alone.

data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_ec2_instance_type_offerings" "node" {
  for_each      = toset([var.node_instance_type, var.gpu_instance_type])
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [each.value]
  }
}

locals {
  # Every zone that offers both instance types, up to four, so the run can
  # reserve an L4 in whichever has one free: g6 capacity in a zone comes and
  # goes. use1-az3 takes no EKS control plane.
  zone_ids = zipmap(data.aws_availability_zones.available.names, data.aws_availability_zones.available.zone_ids)
  offered = setintersection(
    [for name, id in local.zone_ids : name if id != "use1-az3"],
    data.aws_ec2_instance_type_offerings.node[var.node_instance_type].locations,
    data.aws_ec2_instance_type_offerings.node[var.gpu_instance_type].locations,
  )
  azs     = slice(sort(tolist(local.offered)), 0, min(4, length(local.offered)))
  subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = var.cluster_name }

  lifecycle {
    precondition {
      condition     = length(local.azs) >= 2
      error_message = "EKS needs two zones, and fewer than two in the region offer both ${var.node_instance_type} and ${var.gpu_instance_type}."
    }
  }
}

# The default security group allows all traffic between its members. Nothing
# uses it; with no rules, nothing can by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.cluster_name}-default-unused" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.cluster_name }
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.cluster_name}-public-${local.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.cluster_name}-public" }
}

resource "aws_route" "out" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
