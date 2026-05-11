variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "kubeconfig context name for the on-prem cluster"
  type        = string
  default     = "default"
}

variable "environment" {
  description = "Environment label applied to all resources"
  type        = string
  default     = "onprem"
}

variable "cluster_name" {
  description = "Name used to label this cluster in ArgoCD"
  type        = string
  default     = "omen-onprem"
}
