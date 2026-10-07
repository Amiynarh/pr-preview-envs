variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-west2"
}

variable "zone" {
  description = "GCP zone. A zonal cluster is cheaper than a regional one."
  type        = string
  default     = "europe-west2-a"
}

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "pr-preview-cluster"
}

variable "github_repo" {
  description = "GitHub repository in owner/repo format, e.g. amiynarh/pr-preview-envs"
  type        = string
}

variable "machine_type" {
  description = "Node machine type"
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "Number of nodes in the pool"
  type        = number
  default     = 2
}
