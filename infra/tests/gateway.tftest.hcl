mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-eks"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/mock/1234567890123456"
    }
  }
  mock_resource "aws_lb_listener" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:listener/net/mock/1234567890123456/1234567890123456"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock"
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
      !contains(keys(aws_apigatewayv2_route.public), "GET /css/budget.css") &&
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
      alltrue([for route in aws_apigatewayv2_route.public : route.authorization_type == "NONE"]) &&
      toset(keys(aws_apigatewayv2_route.public)) == toset([
        "GET /api/public/orcamentos-ordem-servico/decisao",
        "POST /api/public/orcamentos-ordem-servico/aprovar",
        "POST /api/public/orcamentos-ordem-servico/rejeitar",
        "GET /css/budget.css",
        "POST /api/public/pagamentos/notificacoes/mercado-pago",
      ]) &&
      length(aws_apigatewayv2_route.public) == 5 &&
      length(aws_apigatewayv2_route.protected) == 0 &&
      length(aws_apigatewayv2_route.login) == 0 &&
      length(aws_apigatewayv2_authorizer.auth) == 0 &&
      contains(keys(aws_apigatewayv2_route.public), "POST /api/public/pagamentos/notificacoes/mercado-pago") &&
      contains(keys(aws_apigatewayv2_route.public), "GET /css/budget.css") &&
      aws_apigatewayv2_route.public["GET /css/budget.css"].authorization_type == "NONE" &&
      local.proxy_routes["GET /css/budget.css"] == "billing" &&
      local.proxy_route_patterns["GET:/css/budget\\.css"] == "billing"
    )
    error_message = "Public mode must publish Billing endpoints and budget CSS without JWT, keeping protected routes closed."
  }
}

run "full_matrix_requires_auth" {
  command = plan
  variables {
    private_gateway_routes = "full"
  }
  expect_failures = [aws_apigatewayv2_integration.private["protected"]]
}

run "private_identity_does_not_publish_a_gateway_route" {
  command = plan
  variables {
    private_gateway_routes      = "public"
    os_identity_ingress_enabled = true
  }

  assert {
    condition = (
      aws_lb_listener.os_identity[0].port == 8081 &&
      aws_lb_listener.os_identity[0].protocol == "TCP" &&
      aws_lb_target_group.os_identity[0].port == 18443 &&
      length(helm_release.os_identity_proxy) == 1 &&
      length(aws_apigatewayv2_route.login) == 0 &&
      length(aws_apigatewayv2_authorizer.auth) == 0 &&
      aws_lb.gateway[0].internal &&
      aws_lb_target_group.os_identity[0].protocol == "TCP" &&
      aws_lb_listener.os_identity[0].certificate_arn == null &&
      alltrue([for route in aws_apigatewayv2_route.public : route.authorization_type == "NONE"]) &&
      toset(keys(aws_apigatewayv2_route.public)) == local.billing_public_routes &&
      length(aws_apigatewayv2_route.public) == 5 &&
      aws_apigatewayv2_route.public["GET /css/budget.css"].authorization_type == "NONE" &&
      local.proxy_routes["GET /css/budget.css"] == "billing" &&
      local.proxy_route_patterns["GET:/css/budget\\.css"] == "billing" &&
      length(aws_apigatewayv2_route.protected) == 0 &&
      alltrue([for route in keys(local.proxy_routes) : !strcontains(route, "/internal/")])
    )
    error_message = "The private identity path must use its own private HTTP listener without adding a public route."
  }
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
      length(aws_apigatewayv2_route.login) == 1 &&
      length(aws_apigatewayv2_authorizer.auth) == 1 &&
      length(aws_lambda_permission.api_login) == 1 &&
      length(aws_lambda_permission.api_authorizer) == 1 &&
      length(aws_apigatewayv2_route.protected) == 25 &&
      alltrue([for route in aws_apigatewayv2_route.public : route.authorization_type == "NONE"]) &&
      toset(keys(aws_apigatewayv2_route.public)) == local.billing_public_routes &&
      length(aws_apigatewayv2_route.public) == 5 &&
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

run "identity_http_configuration_and_network_restrictions" {
  # Computed IDs and URLs need the simulated state; all infrastructure providers are mocked.
  command = apply

  override_resource {
    target = aws_security_group.os_identity_client[0]
    values = { id = "sg-auth-client" }
  }
  override_resource {
    target = aws_security_group.gateway_nlb[0]
    values = { id = "sg-private-nlb" }
  }
  override_resource {
    target = aws_lb.gateway[0]
    values = {
      dns_name = "internal-numberone.elb.amazonaws.com"
      arn      = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/net/mock/1234567890123456"
    }
  }
  override_module {
    target = module.eks
    outputs = {
      cluster_name                       = "mock-eks"
      cluster_endpoint                   = "https://eks.example.test"
      cluster_certificate_authority_data = "bW9jay1jYQ=="
      cluster_security_group_id          = "sg-eks-nodes"
      node_group_autoscaling_group_name  = "mock-nodes"
      cluster_oidc_issuer                = "https://issuer.example.test"
    }
  }
  variables {
    private_gateway_routes      = "probe"
    os_identity_ingress_enabled = true
  }

  assert {
    condition = (
      aws_vpc_security_group_egress_rule.auth_identity_to_nlb[0].security_group_id == "sg-auth-client" &&
      aws_vpc_security_group_egress_rule.auth_identity_to_nlb[0].referenced_security_group_id == "sg-private-nlb" &&
      aws_vpc_security_group_ingress_rule.nlb_from_auth_identity[0].security_group_id == "sg-private-nlb" &&
      aws_vpc_security_group_ingress_rule.nlb_from_auth_identity[0].referenced_security_group_id == "sg-auth-client" &&
      aws_vpc_security_group_egress_rule.nlb_to_os_identity_proxy[0].security_group_id == "sg-private-nlb" &&
      aws_vpc_security_group_egress_rule.nlb_to_os_identity_proxy[0].referenced_security_group_id == "sg-eks-nodes" &&
      aws_vpc_security_group_ingress_rule.os_identity_proxy_from_nlb[0].security_group_id == "sg-eks-nodes" &&
      aws_vpc_security_group_ingress_rule.os_identity_proxy_from_nlb[0].referenced_security_group_id == "sg-private-nlb" &&
      aws_vpc_security_group_egress_rule.auth_identity_to_nlb[0].from_port == 8081 &&
      aws_vpc_security_group_egress_rule.auth_identity_to_nlb[0].to_port == 8081 &&
      aws_vpc_security_group_ingress_rule.nlb_from_auth_identity[0].from_port == 8081 &&
      aws_vpc_security_group_ingress_rule.nlb_from_auth_identity[0].to_port == 8081 &&
      aws_vpc_security_group_ingress_rule.os_identity_proxy_from_nlb[0].from_port == 18443 &&
      aws_vpc_security_group_ingress_rule.os_identity_proxy_from_nlb[0].to_port == 18443 &&
      aws_vpc_security_group_egress_rule.nlb_to_os_identity_proxy[0].from_port == 18443 &&
      aws_vpc_security_group_egress_rule.nlb_to_os_identity_proxy[0].to_port == 18443 &&
      aws_vpc_security_group_ingress_rule.nlb_from_auth_identity[0].cidr_ipv4 == null &&
      aws_vpc_security_group_ingress_rule.os_identity_proxy_from_nlb[0].cidr_ipv4 == null
    )
    error_message = "Identity ingress must restrict traffic to the client and NLB SGs on dedicated ports."
  }

  assert {
    condition = (
      !can(yamldecode(helm_release.os_identity_proxy[0].values[0]).tlsSecretName) &&
      !strcontains(yamldecode(helm_release.os_identity_proxy[0].values[0]).config, "ssl") &&
      !strcontains(yamldecode(helm_release.os_identity_proxy[0].values[0]).config, "Authorization") &&
      strcontains(yamldecode(helm_release.os_identity_proxy[0].values[0]).config, "if ($request_method != POST) { return 405; }") &&
      strcontains(yamldecode(helm_release.os_identity_proxy[0].values[0]).config, "location = /internal/auth/customer-identity") &&
      strcontains(yamldecode(helm_release.os_identity_proxy[0].values[0]).config, "return 404;") &&
      strcontains(yamldecode(helm_release.os_identity_proxy[0].values[0]).config, ":8080 resolve;") &&
      strcontains(yamldecode(helm_release.gateway_proxy[0].values[0]).config, "zone inventory 64k;") &&
      length(regexall(":8080 resolve;", yamldecode(helm_release.gateway_proxy[0].values[0]).config)) == 3
    )
    error_message = "Proxies must start without Services; identity must use HTTP without TLS or Bearer forwarding."
  }

  assert {
    condition = (
      output.os_identity_ingress.base_url == "http://internal-numberone.elb.amazonaws.com:8081" &&
      output.os_identity_ingress.endpoint_url == "http://internal-numberone.elb.amazonaws.com:8081/internal/auth/customer-identity" &&
      output.os_identity_ingress.client_security_group_id == "sg-auth-client"
    )
    error_message = "Auth must receive the exact private HTTP origin, endpoint URL and client SG."
  }
}
