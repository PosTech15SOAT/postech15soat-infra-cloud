variable "aws_region" {
  description = "AWS region used by the Learner Lab."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to resource names."
  type        = string
  default     = "numberone"
}

variable "environment" {
  description = "Shared infrastructure environment name."
  type        = string
  default     = "lab"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR."
  }
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]

  validation {
    condition     = length(var.availability_zones) >= 2
    error_message = "At least two availability zones are required."
  }
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version supported by the active Learner Lab."
  type        = string
}

variable "cluster_role_name" {
  description = "Existing IAM role name used by the EKS control plane."
  type        = string
}

variable "node_role_name" {
  description = "Existing IAM role name used by the managed node group."
  type        = string
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.small"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 2

  validation {
    condition     = var.node_max_size >= var.node_min_size
    error_message = "node_max_size must be greater than or equal to node_min_size."
  }
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API. Restrict when possible."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
