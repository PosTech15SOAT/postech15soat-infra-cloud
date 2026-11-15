variable "billing_events_pod_identity_enabled" {
  description = "Provision the EKS Pod Identity agent and dedicated Billing and OS roles for SQS."
  type        = bool
  default     = false
}

locals {
  billing_events_workloads = var.billing_events_pod_identity_enabled ? {
    numberone-billing = ["sqs:SendMessage"]
    numberone-os = [
      "sqs:GetQueueAttributes",
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
    ]
  } : {}
}

resource "aws_eks_addon" "pod_identity" {
  count = var.billing_events_pod_identity_enabled ? 1 : 0

  cluster_name = module.eks.cluster_name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_iam_role" "billing_events_workload" {
  for_each = local.billing_events_workloads

  name = "${module.eks.cluster_name}-${each.key}-sqs"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Condition = {
        StringEquals = {
          "aws:RequestTag/eks-cluster-arn"            = module.eks.cluster_arn
          "aws:RequestTag/kubernetes-namespace"       = each.key
          "aws:RequestTag/kubernetes-service-account" = each.key
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "billing_events_workload" {
  for_each = local.billing_events_workloads

  name = "billing-events"
  role = aws_iam_role.billing_events_workload[each.key].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = each.value
      Resource = aws_sqs_queue.billing_events.arn
    }]
  })
}

resource "aws_eks_pod_identity_association" "billing_events_workload" {
  for_each = local.billing_events_workloads

  cluster_name    = module.eks.cluster_name
  namespace       = each.key
  service_account = each.key
  role_arn        = aws_iam_role.billing_events_workload[each.key].arn

  depends_on = [aws_eks_addon.pod_identity, aws_iam_role_policy.billing_events_workload]
}
