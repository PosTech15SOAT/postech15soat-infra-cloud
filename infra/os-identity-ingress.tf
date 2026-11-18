variable "os_identity_ingress_enabled" {
  description = "Enable the private HTTP listener used by the Auth Lambdas to verify OS customer identity."
  type        = bool
  default     = false
}

locals {
  os_identity_enabled       = var.os_identity_ingress_enabled && local.private_gateway_enabled
  os_identity_listener_port = 8081
  os_identity_proxy_port    = 18443
}

# Keep the existing description: changing it would replace the client SG used by Auth.
resource "aws_security_group" "os_identity_client" {
  count       = local.os_identity_enabled ? 1 : 0
  name        = "${local.name_prefix}-os-identity-client"
  description = "Private OS identity HTTPS access for Auth Lambdas"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "auth_identity_to_nlb" {
  count                        = local.os_identity_enabled ? 1 : 0
  security_group_id            = aws_security_group.os_identity_client[0].id
  referenced_security_group_id = aws_security_group.gateway_nlb[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.os_identity_listener_port
  to_port                      = local.os_identity_listener_port
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_auth_identity" {
  count                        = local.os_identity_enabled ? 1 : 0
  security_group_id            = aws_security_group.gateway_nlb[0].id
  referenced_security_group_id = aws_security_group.os_identity_client[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.os_identity_listener_port
  to_port                      = local.os_identity_listener_port
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_os_identity_proxy" {
  count                        = local.os_identity_enabled ? 1 : 0
  security_group_id            = aws_security_group.gateway_nlb[0].id
  referenced_security_group_id = module.eks.cluster_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = local.os_identity_proxy_port
  to_port                      = local.os_identity_proxy_port
}

resource "aws_vpc_security_group_ingress_rule" "os_identity_proxy_from_nlb" {
  count                        = local.os_identity_enabled ? 1 : 0
  security_group_id            = module.eks.cluster_security_group_id
  referenced_security_group_id = aws_security_group.gateway_nlb[0].id
  ip_protocol                  = "tcp"
  from_port                    = local.os_identity_proxy_port
  to_port                      = local.os_identity_proxy_port
}

resource "aws_lb_target_group" "os_identity" {
  count       = local.os_identity_enabled ? 1 : 0
  name        = "${local.name_prefix}-os-identity"
  target_type = "instance"
  port        = local.os_identity_proxy_port
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id

  health_check {
    protocol = "TCP"
  }
}

resource "aws_lb_listener" "os_identity" {
  count             = local.os_identity_enabled ? 1 : 0
  load_balancer_arn = aws_lb.gateway[0].arn
  port              = local.os_identity_listener_port
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.os_identity[0].arn
  }
}

resource "aws_autoscaling_attachment" "os_identity" {
  count                  = local.os_identity_enabled ? 1 : 0
  autoscaling_group_name = module.eks.node_group_autoscaling_group_name
  lb_target_group_arn    = aws_lb_target_group.os_identity[0].arn

  depends_on = [
    aws_lb_listener.os_identity,
    aws_vpc_security_group_ingress_rule.os_identity_proxy_from_nlb,
    aws_vpc_security_group_egress_rule.nlb_to_os_identity_proxy,
    helm_release.os_identity_proxy,
  ]
}

resource "helm_release" "os_identity_proxy" {
  count       = local.os_identity_enabled ? 1 : 0
  name        = "numberone-os-identity-proxy"
  chart       = "${path.module}/charts/gateway-proxy"
  namespace   = "numberone-gateway"
  atomic      = true
  max_history = 3

  depends_on = [helm_release.gateway_proxy]

  values = [yamlencode({
    port = local.os_identity_proxy_port
    config = templatefile("${path.module}/os-identity-proxy.conf.tftpl", {
      port = local.os_identity_proxy_port
    })
  })]
}

output "os_identity_ingress" {
  description = "Private HTTP origin for Auth (base_url), exact endpoint URL and Lambda client SG."
  value = local.os_identity_enabled ? {
    base_url                 = "http://${aws_lb.gateway[0].dns_name}:${local.os_identity_listener_port}"
    endpoint_url             = "http://${aws_lb.gateway[0].dns_name}:${local.os_identity_listener_port}/internal/auth/customer-identity"
    client_security_group_id = aws_security_group.os_identity_client[0].id
  } : null
}
