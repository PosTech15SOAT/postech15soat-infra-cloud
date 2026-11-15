variable "auth_lambda_arns" {
  description = "Function and invocation ARNs from the Auth state. Set after the Auth stack is deployed."
  type = object({
    login             = string
    login_invoke      = string
    authorizer        = string
    authorizer_invoke = string
  })
  default = null
}

resource "aws_apigatewayv2_api" "numberone" {
  count         = local.http_api_enabled ? 1 : 0
  name          = "${var.project_name}-http-api"
  protocol_type = "HTTP"
}

resource "aws_cloudwatch_log_group" "http_api" {
  count             = local.http_api_enabled ? 1 : 0
  name              = "/aws/apigateway/${var.project_name}-http-api"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  count       = local.http_api_enabled ? 1 : 0
  api_id      = aws_apigatewayv2_api.numberone[0].id
  name        = "$default"
  auto_deploy = true

  dynamic "route_settings" {
    for_each = aws_apigatewayv2_route.login
    content {
      route_key              = route_settings.value.route_key
      throttling_burst_limit = 20
      throttling_rate_limit  = 5
    }
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.http_api[0].arn
    format = jsonencode({
      requestId         = "$context.requestId"
      routeKey          = "$context.routeKey"
      status            = "$context.status"
      integrationStatus = "$context.integration.status"
    })
  }
}

resource "aws_apigatewayv2_integration" "login" {
  count                  = var.auth_lambda_arns == null ? 0 : 1
  api_id                 = aws_apigatewayv2_api.numberone[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = var.auth_lambda_arns.login_invoke
  payload_format_version = "2.0"
  request_parameters     = local.remove_gateway_identity_headers
}

resource "aws_apigatewayv2_route" "login" {
  count     = var.auth_lambda_arns == null ? 0 : 1
  api_id    = aws_apigatewayv2_api.numberone[0].id
  route_key = "POST /auth/login"
  target    = "integrations/${aws_apigatewayv2_integration.login[0].id}"
}

resource "aws_apigatewayv2_authorizer" "auth" {
  count                             = var.auth_lambda_arns == null ? 0 : 1
  api_id                            = aws_apigatewayv2_api.numberone[0].id
  name                              = "numberone-auth"
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = var.auth_lambda_arns.authorizer_invoke
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true
  authorizer_result_ttl_in_seconds  = 0
  # No identity sources: Auth can return 401 for both missing and invalid credentials.
}

resource "aws_lambda_permission" "api_login" {
  count         = var.auth_lambda_arns == null ? 0 : 1
  statement_id  = "AllowCloudHttpApiLogin"
  action        = "lambda:InvokeFunction"
  function_name = var.auth_lambda_arns.login
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.numberone[0].execution_arn}/${aws_apigatewayv2_stage.default[0].name}/POST/auth/login"
}

resource "aws_lambda_permission" "api_authorizer" {
  count         = var.auth_lambda_arns == null ? 0 : 1
  statement_id  = "AllowCloudHttpApiAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = var.auth_lambda_arns.authorizer
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.numberone[0].execution_arn}/authorizers/${aws_apigatewayv2_authorizer.auth[0].id}"
}

output "http_api_url" {
  description = "Public HTTPS base URL for the API and acceptance tests."
  value       = one(aws_apigatewayv2_api.numberone[*].api_endpoint)
}

output "billing_budget_approval_base_url" {
  description = "Full HTTPS decision URL for Billing BUDGET_APPROVAL_BASE_URL."
  value       = local.private_gateway_enabled ? "${aws_apigatewayv2_api.numberone[0].api_endpoint}${split(" ", local.billing_decision_route)[1]}" : null
}
