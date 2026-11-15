mock_provider "aws" {
  mock_data "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-eks"
    }
  }

  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:us-east-1:123456789012:cluster/numberone-eks"
      certificate_authority = [{ data = "bW9jay1jYQ==" }]
    }
  }

  mock_resource "aws_eks_node_group" {
    defaults = {
      resources = [{ autoscaling_groups = [{ name = "mock-nodes" }] }]
    }
  }
}

mock_provider "helm" {}

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
      length(aws_iam_role.billing_events_workload) == 0
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

run "pod_identity_uses_distinct_service_accounts_and_only_the_main_queue" {
  command = apply

  variables {
    billing_events_pod_identity_enabled = true
  }

  override_resource {
    target = aws_iam_role.billing_events_workload["numberone-billing"]
    values = {
      arn = "arn:aws:iam::123456789012:role/numberone-eks-numberone-billing-sqs"
    }
  }

  override_resource {
    target = aws_iam_role.billing_events_workload["numberone-os"]
    values = {
      arn = "arn:aws:iam::123456789012:role/numberone-eks-numberone-os-sqs"
    }
  }

  assert {
    condition = (
      length(aws_eks_addon.pod_identity) == 1 &&
      length(toset([for role in aws_iam_role.billing_events_workload : role.name])) == 2 &&
      alltrue([
        for workload, association in aws_eks_pod_identity_association.billing_events_workload :
        association.namespace == workload && association.service_account == workload &&
        association.role_arn == aws_iam_role.billing_events_workload[workload].arn
      ])
    )
    error_message = "Billing and OS must use distinct roles associated with their existing ServiceAccounts."
  }

  assert {
    condition = (
      toset(jsondecode(aws_iam_role_policy.billing_events_workload["numberone-billing"].policy).Statement[0].Action) == toset(["sqs:SendMessage"]) &&
      toset(jsondecode(aws_iam_role_policy.billing_events_workload["numberone-os"].policy).Statement[0].Action) == toset([
        "sqs:GetQueueAttributes", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility"
      ]) &&
      alltrue([
        for policy in aws_iam_role_policy.billing_events_workload :
        jsondecode(policy.policy).Statement[0].Resource == output.billing_events_queue_arn
      ])
    )
    error_message = "Workload roles must have only the contracted SQS actions on the main queue."
  }

  assert {
    condition = alltrue([
      for workload, role in aws_iam_role.billing_events_workload :
      jsondecode(role.assume_role_policy).Statement[0].Principal.Service == "pods.eks.amazonaws.com" &&
      jsondecode(role.assume_role_policy).Statement[0].Condition.StringEquals == {
        "aws:RequestTag/eks-cluster-arn"            = module.eks.cluster_arn
        "aws:RequestTag/kubernetes-namespace"       = workload
        "aws:RequestTag/kubernetes-service-account" = workload
      }
    ])
    error_message = "Each trust policy must restrict the EKS cluster, namespace and ServiceAccount."
  }
}
