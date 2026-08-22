data "aws_iam_role" "eks_cluster" {
  name = var.cluster_role_name
}

data "aws_iam_role" "eks_node" {
  name = var.node_role_name
}
