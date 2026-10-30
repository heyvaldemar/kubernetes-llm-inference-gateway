output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "zones" {
  value = local.azs
}

output "vpc_id" {
  value = aws_vpc.this.id
}
