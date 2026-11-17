locals {
  gateway_listener_port = 80
  gateway_proxy_port    = 18080
}

resource "aws_security_group" "gateway_vpc_link" {
  count       = local.private_gateway_enabled ? 1 : 0
  name        = "${local.name_prefix}-gateway-vpc-link"
  description = "HTTP API VPC Link ENIs"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_security_group" "gateway_nlb" {
  count       = local.private_gateway_enabled ? 1 : 0
  name        = "${local.name_prefix}-gateway-nlb"
  description = "Internal NLB for the HTTP API"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_to_nlb" {
  count                        = local.private_gateway_enabled ? 1 : 0
  security_group_id            = aws_security_group.gateway_vpc_link[0].id
  referenced_security_group_id = aws_security_group.gateway_nlb[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.gateway_listener_port
  to_port                      = local.gateway_listener_port
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_vpc_link" {
  count                        = local.private_gateway_enabled ? 1 : 0
  security_group_id            = aws_security_group.gateway_nlb[0].id
  referenced_security_group_id = aws_security_group.gateway_vpc_link[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.gateway_listener_port
  to_port                      = local.gateway_listener_port
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_eks" {
  count                        = local.private_gateway_enabled ? 1 : 0
  security_group_id            = aws_security_group.gateway_nlb[0].id
  referenced_security_group_id = module.eks.cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.gateway_proxy_port
  to_port                      = local.gateway_proxy_port
}

resource "aws_vpc_security_group_ingress_rule" "eks_from_nlb" {
  count                        = local.private_gateway_enabled ? 1 : 0
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = aws_security_group.gateway_nlb[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.gateway_proxy_port
  to_port                      = local.gateway_proxy_port
}

resource "aws_apigatewayv2_vpc_link" "gateway" {
  count              = local.private_gateway_enabled ? 1 : 0
  name               = "${local.name_prefix}-gateway"
  security_group_ids = [aws_security_group.gateway_vpc_link[0].id]
  subnet_ids         = module.vpc.private_subnet_ids

  depends_on = [aws_vpc_security_group_egress_rule.vpc_link_to_nlb]
}

resource "aws_lb" "gateway" {
  count                            = local.private_gateway_enabled ? 1 : 0
  name                             = "${local.name_prefix}-gateway"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = module.vpc.private_subnet_ids
  security_groups                  = [aws_security_group.gateway_nlb[0].id]
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "gateway" {
  count              = local.private_gateway_enabled ? 1 : 0
  name               = "${local.name_prefix}-gateway"
  target_type        = "instance"
  port               = local.gateway_proxy_port
  protocol           = "TCP"
  vpc_id             = module.vpc.vpc_id
  preserve_client_ip = true

  health_check {
    protocol = "TCP"
  }
}

resource "aws_lb_listener" "gateway" {
  count             = local.private_gateway_enabled ? 1 : 0
  load_balancer_arn = aws_lb.gateway[0].arn
  port              = local.gateway_listener_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway[0].arn
  }
}

resource "aws_autoscaling_attachment" "gateway" {
  count                  = local.private_gateway_enabled ? 1 : 0
  autoscaling_group_name = module.eks.node_group_autoscaling_group_name
  lb_target_group_arn    = aws_lb_target_group.gateway[0].arn

  depends_on = [
    aws_lb_listener.gateway,
    aws_vpc_security_group_ingress_rule.eks_from_nlb,
    aws_vpc_security_group_egress_rule.nlb_to_eks,
    helm_release.gateway_proxy,
  ]
}

resource "helm_release" "gateway_proxy" {
  count            = local.private_gateway_enabled ? 1 : 0
  name             = "numberone-gateway-proxy"
  chart            = "${path.module}/charts/gateway-proxy"
  namespace        = "numberone-gateway"
  create_namespace = true
  atomic           = true
  max_history      = 3

  depends_on = [module.eks]

  values = [yamlencode({
    port = local.gateway_proxy_port
    config = templatefile("${path.module}/gateway-proxy.conf.tftpl", {
      port             = local.gateway_proxy_port
      routes           = local.proxy_route_patterns
      vpc_link_subnets = var.private_subnet_cidrs
    })
  })]
}
