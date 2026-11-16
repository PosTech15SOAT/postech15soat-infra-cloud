variable "billing_events_bridge_role_name" {
  description = "Existing Lambda execution role for the HTTP SQS bridge. Empty disables the bridge."
  type        = string
  default     = ""
}

locals {
  billing_events_bridge_enabled = var.billing_events_bridge_role_name != ""
  billing_events_bridge_name    = "${local.name_prefix}-billing-sqs-bridge"
  billing_events_bridge_routes = local.billing_events_bridge_enabled ? toset([
    "POST /eventos",
    "GET /fila",
    "POST /recebimentos",
    "POST /confirmacoes",
    "POST /visibilidade",
    "POST /historico",
    "GET /historico",
  ]) : toset([])
}

data "aws_iam_role" "billing_events_bridge" {
  count = local.billing_events_bridge_enabled ? 1 : 0
  name  = var.billing_events_bridge_role_name
}

data "archive_file" "billing_events_bridge" {
  count       = local.billing_events_bridge_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/functions/billing-events-bridge/bridge.py"
  output_path = "${path.module}/.terraform/billing-events-bridge.zip"
}

resource "aws_cloudwatch_log_group" "billing_events_bridge" {
  count             = local.billing_events_bridge_enabled ? 1 : 0
  name              = "/aws/lambda/${local.billing_events_bridge_name}"
  retention_in_days = 14
}

resource "aws_lambda_function" "billing_events_bridge" {
  count            = local.billing_events_bridge_enabled ? 1 : 0
  function_name    = local.billing_events_bridge_name
  role             = data.aws_iam_role.billing_events_bridge[0].arn
  filename         = data.archive_file.billing_events_bridge[0].output_path
  source_code_hash = data.archive_file.billing_events_bridge[0].output_base64sha256
  handler          = "bridge.handler"
  runtime          = "python3.13"
  timeout          = 27

  environment {
    variables = {
      QUEUE_URL          = aws_sqs_queue.billing_events.url
      HISTORY_TABLE_NAME = "${var.project_name}-${var.environment}-vehicle-maintenance-history"
    }
  }

  depends_on = [aws_cloudwatch_log_group.billing_events_bridge]
}

resource "aws_apigatewayv2_api" "billing_events_bridge" {
  count         = local.billing_events_bridge_enabled ? 1 : 0
  name          = local.billing_events_bridge_name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "billing_events_bridge" {
  count       = local.billing_events_bridge_enabled ? 1 : 0
  api_id      = aws_apigatewayv2_api.billing_events_bridge[0].id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 20
    throttling_rate_limit  = 10
  }
}

resource "aws_apigatewayv2_authorizer" "billing_events_bridge" {
  count            = local.billing_events_bridge_enabled ? 1 : 0
  name             = "numberone-service-accounts"
  api_id           = aws_apigatewayv2_api.billing_events_bridge[0].id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = ["numberone-billing-sqs-bridge"]
    issuer   = module.eks.cluster_oidc_issuer
  }
}

resource "aws_apigatewayv2_integration" "billing_events_bridge" {
  count                  = local.billing_events_bridge_enabled ? 1 : 0
  api_id                 = aws_apigatewayv2_api.billing_events_bridge[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.billing_events_bridge[0].invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

resource "aws_apigatewayv2_route" "billing_events_bridge" {
  for_each           = local.billing_events_bridge_routes
  api_id             = aws_apigatewayv2_api.billing_events_bridge[0].id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.billing_events_bridge[0].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.billing_events_bridge[0].id
}

resource "aws_lambda_permission" "billing_events_bridge" {
  for_each      = local.billing_events_bridge_routes
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.billing_events_bridge[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.billing_events_bridge[0].execution_arn}/$default/${replace(each.key, " ", "")}"
}

output "billing_events_bridge_url" {
  description = "Base HTTPS URL for the Billing and OS HTTP SQS adapters."
  value       = one(aws_apigatewayv2_api.billing_events_bridge[*].api_endpoint)
}
