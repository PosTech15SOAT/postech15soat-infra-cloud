variable "private_gateway_routes" {
  description = "Private routes to publish: disabled, probe (Billing decision GET), public (Billing public routes), or full (including protected routes)."
  type        = string
  default     = "disabled"

  validation {
    condition     = contains(["disabled", "probe", "public", "full"], var.private_gateway_routes)
    error_message = "Choose disabled, probe, public, or full."
  }
}

locals {
  private_gateway_enabled = var.private_gateway_routes != "disabled"
  http_api_enabled        = local.private_gateway_enabled || var.auth_lambda_arns != null

  billing_decision_route = "GET /api/public/orcamentos-ordem-servico/decisao"
  billing_public_routes = toset([
    local.billing_decision_route,
    "POST /api/public/orcamentos-ordem-servico/aprovar",
    "POST /api/public/orcamentos-ordem-servico/rejeitar",
    "POST /api/public/pagamentos/notificacoes/mercado-pago",
    "GET /css/budget.css",
  ])

  protected_gateway_routes = {
    "POST /api/admin/clientes"                                            = "os"
    "POST /api/admin/veiculos"                                            = "os"
    "POST /api/admin/servicos"                                            = "os"
    "POST /api/admin/ordens-servico"                                      = "os"
    "GET /api/admin/ordens-servico/{id}"                                  = "os"
    "PATCH /api/admin/ordens-servico/{id}/iniciar-diagnostico"            = "os"
    "POST /api/admin/itens-ordem-servico"                                 = "os"
    "POST /api/admin/itens-ordem-servico/{itemId}/insumos"                = "os"
    "POST /api/admin/itens"                                               = "inventory"
    "GET /api/admin/itens/{itemId}"                                       = "inventory"
    "POST /api/admin/estoque/entrada"                                     = "inventory"
    "GET /api/admin/estoque/itens/{itemId}/movimentacoes"                 = "inventory"
    "POST /api/admin/ordens-servico/{serviceOrderId}/orcamentos"          = "billing"
    "GET /api/admin/orcamentos-ordem-servico/{id}"                        = "billing"
    "PATCH /api/admin/orcamentos-ordem-servico/{id}/solicitar-aprovacao"  = "billing"
    "PATCH /api/admin/itens-ordem-servico/{id}/iniciar"                   = "os"
    "PATCH /api/admin/itens-ordem-servico/{id}/concluir"                  = "os"
    "PATCH /api/admin/ordens-servico/{id}/concluir"                       = "os"
    "POST /api/admin/ordens-servico/{serviceOrderId}/pagamentos/checkout" = "billing"
    "GET /api/admin/ordens-servico/{serviceOrderId}/pagamentos/checkout"  = "billing"
    "PATCH /api/admin/ordens-servico/{id}/entregar"                       = "os"
    "PATCH /api/admin/ordens-servico/{id}/cancelar"                       = "os"
    "GET /api/admin/ordens-servico/{id}/compensacao"                      = "os"
    "GET /api/public/ordens-servico/{id}/acompanhamento"                  = "os"
    "GET /api/public/veiculos/{vehicleId}/historico-manutencoes"          = "os"
  }

  active_public_routes = var.private_gateway_routes == "probe" ? toset([local.billing_decision_route]) : (
    local.private_gateway_enabled ? local.billing_public_routes : toset([])
  )
  active_protected_routes = var.private_gateway_routes == "full" ? local.protected_gateway_routes : {}

  proxy_routes = merge(
    { for route in local.active_public_routes : route => "billing" },
    local.active_protected_routes,
  )
  path_id_pattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
  # Compare the original URI with the allowlist before forwarding it unchanged.
  proxy_route_patterns = {
    for route, service in local.proxy_routes :
    "${split(" ", route)[0]}:${replace(replace(split(" ", route)[1], ".", "\\."), "/\\{[^}]+\\}/", local.path_id_pattern)}" => service
  }

  gateway_identity_fields = {
    "X-Authenticated-Subject"     = "principalId"
    "X-Authenticated-Customer-Id" = "customerId"
    "X-Authenticated-Status"      = "userStatus"
    "X-Authenticated-Roles"       = "roles"
    "X-Authenticated-Permissions" = "permissions"
  }
  remove_gateway_identity_headers = {
    for header in keys(local.gateway_identity_fields) : "remove:header.${header}" => "''"
  }
  overwrite_gateway_identity_headers = {
    for header, field in local.gateway_identity_fields :
    "overwrite:header.${header}" => "$context.authorizer.${field}"
  }
  private_request_parameters = {
    "overwrite:path"                        = "$request.path"
    "overwrite:header.X-Gateway-Request-Id" = "$context.requestId"
  }
}

resource "aws_apigatewayv2_integration" "private" {
  for_each = toset(concat(
    local.private_gateway_enabled ? ["public"] : [],
    var.private_gateway_routes == "full" ? ["protected"] : [],
  ))

  api_id                 = aws_apigatewayv2_api.numberone[0].id
  integration_type       = "HTTP_PROXY"
  integration_method     = "ANY"
  integration_uri        = aws_lb_listener.gateway[0].arn
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.gateway[0].id
  payload_format_version = "1.0"
  timeout_milliseconds   = 30000

  request_parameters = merge(
    local.private_request_parameters,
    each.key == "public" ? local.remove_gateway_identity_headers : local.overwrite_gateway_identity_headers,
  )

  depends_on = [aws_autoscaling_attachment.gateway, aws_vpc_security_group_ingress_rule.nlb_from_vpc_link]

  lifecycle {
    precondition {
      condition     = each.key != "protected" || var.auth_lambda_arns != null
      error_message = "Deploy Auth and provide its Lambda ARNs before publishing protected routes."
    }
  }
}

resource "aws_apigatewayv2_route" "public" {
  for_each = local.active_public_routes

  api_id             = aws_apigatewayv2_api.numberone[0].id
  route_key          = each.key
  authorization_type = "NONE"
  target             = "integrations/${aws_apigatewayv2_integration.private["public"].id}"
}

resource "aws_apigatewayv2_route" "protected" {
  for_each = local.active_protected_routes

  api_id             = aws_apigatewayv2_api.numberone[0].id
  route_key          = each.key
  authorization_type = "CUSTOM"
  authorizer_id      = one(aws_apigatewayv2_authorizer.auth[*].id)
  target             = "integrations/${aws_apigatewayv2_integration.private["protected"].id}"

  depends_on = [aws_lambda_permission.api_authorizer]
}
