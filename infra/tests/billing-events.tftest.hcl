mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-eks"
    }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      certificate_authority = [{ data = "bW9jay1jYQ==" }]
      identity              = [{ oidc = [{ issuer = "https://issuer.example.test" }] }]
    }
  }

  mock_resource "aws_eks_node_group" {
    defaults = {
      resources = [{ autoscaling_groups = [{ name = "mock-nodes" }] }]
    }
  }
}

mock_provider "helm" {}
mock_provider "archive" {}

variables {
  cluster_role_name = "eks-cluster"
  node_role_name    = "eks-node"
  datadog_api_key   = "mock"
}

override_resource {
  target = aws_sqs_queue.billing_events
  values = {
    arn = "arn:aws:sqs:us-east-1:123456789012:numberone-billing-events"
    url = "https://sqs.us-east-1.amazonaws.com/123456789012/numberone-billing-events"
  }
}

override_resource {
  target = aws_sqs_queue.billing_events_dlq
  values = {
    arn = "arn:aws:sqs:us-east-1:123456789012:numberone-billing-events-dlq"
    url = "https://sqs.us-east-1.amazonaws.com/123456789012/numberone-billing-events-dlq"
  }
}

run "queues_are_available_without_workload_identity_permissions" {
  command = apply

  assert {
    condition = (
      length(aws_eks_addon.pod_identity) == 0 &&
      length(aws_eks_pod_identity_association.billing_events_workload) == 0 &&
      length(data.aws_iam_role.billing_events_workload) == 0
    )
    error_message = "The queue rollout must be independent of IAM and Pod Identity provisioning."
  }

  assert {
    condition = alltrue([
      for queue in [aws_sqs_queue.billing_events, aws_sqs_queue.billing_events_dlq] :
      !queue.fifo_queue && queue.sqs_managed_sse_enabled &&
      queue.receive_wait_time_seconds == 20 && queue.visibility_timeout_seconds == 60
    ])
    error_message = "Both queues must be Standard, use SSE-SQS and poll for 20 s with a 60 s visibility timeout."
  }

  assert {
    condition = (
      aws_sqs_queue.billing_events.message_retention_seconds == 345600 &&
      aws_sqs_queue.billing_events_dlq.message_retention_seconds == 1209600 &&
      jsondecode(aws_sqs_queue_redrive_policy.billing_events.redrive_policy).maxReceiveCount == 5 &&
      jsondecode(aws_sqs_queue_redrive_policy.billing_events.redrive_policy).deadLetterTargetArn == output.billing_events_dlq_arn &&
      jsondecode(aws_sqs_queue_redrive_allow_policy.billing_events_dlq.redrive_allow_policy).redrivePermission == "byQueue" &&
      toset(jsondecode(aws_sqs_queue_redrive_allow_policy.billing_events_dlq.redrive_allow_policy).sourceQueueArns) == toset([output.billing_events_queue_arn])
    )
    error_message = "The DLQ must receive only from the main queue after five deliveries and retain messages for 14 days."
  }
}

run "pod_identity_associates_two_existing_roles" {
  command = apply

  variables {
    billing_events_workload_role_names = {
      billing = "existing-billing"
      os      = "existing-os"
    }
  }

  override_data {
    target = data.aws_iam_role.billing_events_workload["numberone-billing"]
    values = {
      arn = "arn:aws:iam::123456789012:role/workloads/existing-billing"
    }
  }

  override_data {
    target = data.aws_iam_role.billing_events_workload["numberone-os"]
    values = {
      arn = "arn:aws:iam::123456789012:role/workloads/existing-os"
    }
  }

  assert {
    condition = (
      length(aws_eks_addon.pod_identity) == 1 &&
      data.aws_iam_role.billing_events_workload["numberone-billing"].name == "existing-billing" &&
      data.aws_iam_role.billing_events_workload["numberone-os"].name == "existing-os" &&
      length(toset([for association in aws_eks_pod_identity_association.billing_events_workload : association.role_arn])) == 2 &&
      alltrue([
        for workload, association in aws_eks_pod_identity_association.billing_events_workload :
        association.namespace == workload && association.service_account == workload &&
        association.role_arn == data.aws_iam_role.billing_events_workload[workload].arn
      ])
    )
    error_message = "Billing and OS must use distinct roles associated with their existing ServiceAccounts."
  }
}

run "pod_identity_rejects_a_shared_role" {
  command = plan

  variables {
    billing_events_workload_role_names = {
      billing = "shared-role"
      os      = "Shared-Role"
    }
  }

  expect_failures = [var.billing_events_workload_role_names]
}

run "bridge_exposes_only_explicit_jwt_routes_with_an_existing_role" {
  command = plan

  variables {
    billing_events_bridge_role_name = "existing-lambda-role"
  }

  assert {
    condition = (
      aws_lambda_function.billing_events_bridge[0].handler == "bridge.handler" &&
      data.aws_iam_role.billing_events_bridge[0].name == "existing-lambda-role" &&
      length(aws_apigatewayv2_authorizer.billing_events_bridge) == 1 &&
      one(aws_apigatewayv2_authorizer.billing_events_bridge[0].jwt_configuration).audience == toset(["numberone-billing-sqs-bridge"]) &&
      toset(keys(aws_apigatewayv2_route.billing_events_bridge)) == toset([
        "POST /eventos", "GET /fila", "POST /recebimentos", "POST /confirmacoes", "POST /visibilidade"
      ]) &&
      alltrue([for route in aws_apigatewayv2_route.billing_events_bridge : route.authorization_type == "JWT"])
    )
    error_message = "Use an existing role and require JWT on every supported bridge operation."
  }
}
