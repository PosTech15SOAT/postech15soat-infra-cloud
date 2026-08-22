module "vpc" {
  source = "./modules/vpc"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
}

module "eks" {
  source = "./modules/eks"

  cluster_name                 = "${local.name_prefix}-eks"
  kubernetes_version           = var.kubernetes_version
  cluster_role_arn             = data.aws_iam_role.eks_cluster.arn
  node_role_arn                = data.aws_iam_role.eks_node.arn
  subnet_ids                   = module.vpc.public_subnet_ids
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  node_instance_types          = var.node_instance_types
  node_desired_size            = var.node_desired_size
  node_min_size                = var.node_min_size
  node_max_size                = var.node_max_size
}

module "ecr" {
  source = "./modules/ecr"

  repository_name = "${var.project_name}-auto-service-api"
}
