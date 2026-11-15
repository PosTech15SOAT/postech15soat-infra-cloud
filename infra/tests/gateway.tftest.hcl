mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-eks"
    }
  }
}
mock_provider "helm" {}

variables {
  cluster_role_name = "eks-cluster"
  node_role_name    = "eks-node"
  datadog_api_key   = "mock"
}

run "base_does_not_publish_an_api" {
  command = plan

  assert {
    condition     = length(aws_apigatewayv2_api.numberone) == 0 && length(aws_lb.gateway) == 0
    error_message = "The base stack must not require ingress or Auth."
  }
}

run "billing_probe_uses_one_private_integration" {
  command = plan
  variables {
    private_gateway_routes = "probe"
  }

  assert {
    condition = (
      length(aws_apigatewayv2_route.public) == 1 &&
      contains(keys(aws_apigatewayv2_route.public), "GET /api/public/orcamentos-ordem-servico/decisao") &&
      length(aws_apigatewayv2_route.protected) == 0 &&
      length(aws_apigatewayv2_route.login) == 0 &&
      aws_apigatewayv2_stage.default[0].name == "$default" &&
      aws_apigatewayv2_integration.private["public"].connection_type == "VPC_LINK" &&
      aws_lb.gateway[0].internal
    )
    error_message = "Probe mode must publish only the Billing decision GET through the private NLB."
  }

  assert {
    condition = alltrue([
      for header in keys(local.gateway_identity_fields) :
      aws_apigatewayv2_integration.private["public"].request_parameters["remove:header.${header}"] == "''"
    ])
    error_message = "Public Billing requests must have all contracted identity headers removed."
  }
}

run "public_billing_mode" {
  command = plan
  variables {
    private_gateway_routes = "public"
  }

  assert {
    condition = (
      length(aws_apigatewayv2_route.public) == 4 &&
      length(aws_apigatewayv2_route.protected) == 0 &&
      contains(keys(aws_apigatewayv2_route.public), "POST /api/public/pagamentos/notificacoes/mercado-pago")
    )
    error_message = "Public mode must publish the Billing validation endpoints and keep JWT routes closed."
  }
}

run "full_matrix_requires_auth" {
  command = plan
  variables {
    private_gateway_routes = "full"
  }
  expect_failures = [aws_apigatewayv2_integration.private["protected"]]
}

run "full_matrix_is_explicit_and_protected" {
  command = plan
  variables {
    private_gateway_routes = "full"
    auth_lambda_arns = {
      login             = "arn:aws:lambda:us-east-1:123456789012:function:login"
      login_invoke      = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:login/invocations"
      authorizer        = "arn:aws:lambda:us-east-1:123456789012:function:authorizer"
      authorizer_invoke = "arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/arn:aws:lambda:us-east-1:123456789012:function:authorizer/invocations"
    }
  }

  assert {
    condition = (
      length(aws_apigatewayv2_route.protected) == 25 &&
      length(aws_apigatewayv2_route.public) == 4 &&
      alltrue([for route in aws_apigatewayv2_route.protected : route.authorization_type == "CUSTOM"]) &&
      alltrue([
        for route in keys(local.proxy_routes) : length(regexall("(^ANY |[+*]|/internal/|/actuator)", route)) == 0
      ]) &&
      local.proxy_routes["GET /api/admin/ordens-servico/{id}"] == "os" &&
      local.proxy_route_patterns["GET:/api/admin/ordens-servico/${local.path_id_pattern}"] == "os" &&
      local.proxy_routes["POST /api/admin/ordens-servico/{serviceOrderId}/orcamentos"] == "billing" &&
      local.proxy_routes["GET /api/admin/itens/{itemId}"] == "inventory"
    )
    error_message = "Only explicitly mapped methods and paths may reach the three services."
  }

  assert {
    condition = alltrue([
      for header, field in local.gateway_identity_fields :
      aws_apigatewayv2_integration.private["protected"].request_parameters["overwrite:header.${header}"] == "$context.authorizer.${field}"
    ])
    error_message = "All identity headers must be replaced with the current Authorizer context."
  }
}
