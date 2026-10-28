variable "environment" {
  description = "Short environment name. Used in all resource names."
  type        = string
  default     = "poc"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.environment))
    error_message = "environment must be 2 to 8 lowercase letters or digits."
  }
}

variable "location" {
  description = "Azure region. Must have three availability zones."
  type        = string
  default     = "swedencentral"
}

variable "kubernetes_version" {
  description = "AKS minor version. Patches are applied by the auto-upgrade channel."
  type        = string
  default     = "1.36"
}

variable "node_vm_size" {
  description = "VM size for the node pool."
  type        = string
  default     = "Standard_D2s_v5"
}

variable "node_min_count" {
  description = "Minimum nodes. 3 gives one node per zone."
  type        = number
  default     = 3

  validation {
    condition     = var.node_min_count >= 3
    error_message = "Use at least 3 nodes so every zone has one."
  }
}

variable "node_max_count" {
  description = "Maximum nodes for the cluster autoscaler."
  type        = number
  default     = 6
}

variable "github_repository" {
  description = "GitHub repository that may deploy, in owner/name form."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "github_environment" {
  description = "GitHub Actions environment allowed to deploy."
  type        = string
  default     = "poc"
}

variable "app_namespace" {
  description = "Kubernetes namespace for TRDL. The CI identity can write only here."
  type        = string
  default     = "trdl"
}
