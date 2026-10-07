terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Look up the project so we can reference its numeric project number,
# which Workload Identity Federation requires (it doesn't accept the human-readable project ID).
data "google_project" "current" {}

# -----------------------------------------------------------
# Enable required APIs
# -----------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "compute.googleapis.com",
  ])

  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------
# Artifact Registry — where preview images live
# -----------------------------------------------------------
resource "google_artifact_registry_repository" "preview" {
  location      = var.region
  repository_id = "pr-preview"
  description   = "Container images for PR preview environments"
  format        = "DOCKER"

  depends_on = [google_project_service.apis]
}

# -----------------------------------------------------------
# GKE cluster
# -----------------------------------------------------------
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.zone

  # Create the cluster with a throwaway default pool, then remove it
  # and manage nodes through a separate node pool resource. This is the
  # standard pattern — it lets you resize or upgrade the node pool
  # without recreating the cluster control plane.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {}

  # Set to true before you use this for anything real.
  deletion_protection = false

  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-pool"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = var.node_count

  node_config {
    machine_type = var.machine_type
    disk_size_gb = 50

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    labels = {
      purpose = "pr-preview-envs"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# -----------------------------------------------------------
# Service account that GitHub Actions will impersonate
# -----------------------------------------------------------
resource "google_service_account" "github_actions" {
  account_id   = "github-actions-preview"
  display_name = "GitHub Actions — PR Preview Environments"
}

# Permission to push images to Artifact Registry
resource "google_project_iam_member" "artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# Permission to create namespaces and deploy workloads in GKE.
# container.developer grants full access to Kubernetes API objects,
# but NOT permission to modify the cluster itself.
resource "google_project_iam_member" "gke_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

# -----------------------------------------------------------
# Workload Identity Federation
# -----------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Identity pool for GitHub Actions OIDC"

  depends_on = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub OIDC Provider"

  # Map claims from the GitHub OIDC token to Google attributes
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  # CRITICAL: without this condition, ANY GitHub repository on the
  # internet could authenticate against your pool.
  attribute_condition = "assertion.repository == '${var.github_repo}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# Allow tokens from your specific repo to impersonate the service account
resource "google_service_account_iam_member" "github_impersonation" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/attribute.repository/${var.github_repo}"
}


# -----------------------------------------------------------
# Static external IP for the Ingress controller
# -----------------------------------------------------------
resource "google_compute_address" "ingress" {
  name         = "pr-preview-ingress-ip"
  region       = var.region
  address_type = "EXTERNAL"

  depends_on = [google_project_service.apis]
}
