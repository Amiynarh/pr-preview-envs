output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_zone" {
  value = var.zone
}

output "artifact_registry_url" {
  description = "Base URL for pushing images"
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.preview.repository_id}"
}

output "workload_identity_provider" {
  description = "Paste this into the GitHub Actions workflow"
  value       = "projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${google_iam_workload_identity_pool.github.workload_identity_pool_id}/providers/${google_iam_workload_identity_pool_provider.github.workload_identity_pool_provider_id}"
}

output "service_account_email" {
  description = "Paste this into the GitHub Actions workflow"
  value       = google_service_account.github_actions.email
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.zone} --project ${var.project_id}"
}
