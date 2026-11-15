variable "billing_events_workload_role_names" {
  description = "Existing IAM role names for the Billing producer and OS consumer. Null leaves Pod Identity disabled."
  type = object({
    billing = string
    os      = string
  })
  default = null

  validation {
    condition = var.billing_events_workload_role_names == null ? true : alltrue([
      can(regex("^[A-Za-z0-9_+=,.@-]{1,64}$", var.billing_events_workload_role_names.billing)),
      can(regex("^[A-Za-z0-9_+=,.@-]{1,64}$", var.billing_events_workload_role_names.os)),
      try(lower(var.billing_events_workload_role_names.billing) != lower(var.billing_events_workload_role_names.os), false),
    ])
    error_message = "Provide two different existing IAM role names, one for Billing and one for OS."
  }
}

locals {
  billing_events_workloads = var.billing_events_workload_role_names == null ? {} : {
    numberone-billing = var.billing_events_workload_role_names.billing
    numberone-os      = var.billing_events_workload_role_names.os
  }
}

data "aws_iam_role" "billing_events_workload" {
  for_each = local.billing_events_workloads

  name = each.value
}

resource "aws_eks_addon" "pod_identity" {
  count = var.billing_events_workload_role_names == null ? 0 : 1

  cluster_name = module.eks.cluster_name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_eks_pod_identity_association" "billing_events_workload" {
  for_each = data.aws_iam_role.billing_events_workload

  cluster_name    = module.eks.cluster_name
  namespace       = each.key
  service_account = each.key
  role_arn        = each.value.arn

  depends_on = [aws_eks_addon.pod_identity]
}
