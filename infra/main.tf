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

resource "aws_vpc_security_group_ingress_rule" "api_internal_nlb" {
  for_each = {
    for port in var.api_node_ports : tostring(port) => port
  }

  security_group_id = module.eks.cluster_security_group_id
  description       = "Allow private VPC traffic to the API NodePort"
  cidr_ipv4         = var.vpc_cidr
  from_port         = each.value
  to_port           = each.value
  ip_protocol       = "tcp"

  tags = {
    Name = "${local.name_prefix}-api-internal-nlb-${each.value}"
  }
}
