# Ephemeral PR Preview Environments on GKE

Every pull request gets its own isolated Kubernetes namespace, its own build, and its own HTTPS URL. Close the PR and the whole environment deletes itself.

This is the companion repository for a two-part tutorial:

- **Part 1** — [How to Build Ephemeral PR Preview Environments on GKE with GitHub Actions](#)
- **Part 2** — [How to Give Every Pull Request a Live URL with Ingress, Wildcard DNS, and Automatic TLS](#)

## What this does

Open a pull request and a GitHub Actions workflow builds a container image tagged for that PR, pushes it to Artifact Registry, creates a namespace called `pr-<number>` in a GKE cluster, deploys the application into it, and comments the live URL on the pull request. Push another commit and the environment updates in place. Close or merge the PR and the namespace is deleted.

Reviewers get a real, isolated environment per change instead of queueing for a shared staging server.

```
Pull request opened
        │
        ▼
GitHub Actions ──── authenticates via Workload Identity Federation (no stored key)
        │
        ├── builds image tagged pr-N-sha → Artifact Registry
        ├── creates namespace pr-N
        ├── deploys via Kustomize overlay
        └── comments https://pr-N.preview.yourdomain.com on the PR
        │
        ▼
Pull request closed → namespace deleted
```

## Key design decisions

**No service account keys.** GitHub Actions authenticates to Google Cloud using Workload Identity Federation. GitHub mints a short-lived OIDC token, Google verifies its signature and checks the repository claim against an attribute condition, then issues an access token valid for about an hour. Nothing long-lived is stored in GitHub secrets.

**One load balancer, not one per PR.** A single shared ingress-nginx controller routes every preview environment by `Host` header. A wildcard DNS record covers all hostnames, so adding an environment requires no DNS work at all.

**Namespaces as the isolation boundary.** Teardown is a single `kubectl delete namespace`, which removes every resource inside it. There is no cleanup sequence to get wrong.

**Guardrails before deploy.** Each namespace gets a `ResourceQuota` and `LimitRange` applied before anything is scheduled, including `services.loadbalancers: "0"` so a preview environment cannot provision a load balancer even if someone commits a manifest asking for one.

**Cleanup that assumes failure.** A scheduled reaper workflow deletes namespaces whose PR is closed, or that have outlived a maximum age. It only ever acts on namespaces carrying a label the deploy workflow applied, so it cannot touch anything it did not create.

## Repository layout

```
.
├── app/
│   ├── main.go                       Go HTTP server reporting its own build metadata
│   ├── go.mod
│   └── Dockerfile                    Multi-stage build, ldflags injection, non-root
├── terraform/
│   ├── main.tf                       GKE, Artifact Registry, WIF, static IP
│   ├── variables.tf
│   └── outputs.tf
├── k8s/
│   ├── base/
│   │   ├── deployment.yaml           Probes and Downward API
│   │   ├── service.yaml
│   │   ├── ingress.yaml              cert-manager annotation, placeholder host
│   │   └── kustomization.yaml
│   └── cluster/
│       ├── letsencrypt-staging.yaml
│       ├── letsencrypt-prod.yaml
│       └── namespace-guardrails.yaml ResourceQuota and LimitRange
└── .github/workflows/
    ├── preview-deploy.yml            Build, deploy, certificate, PR comment
    ├── preview-teardown.yml          Delete namespace on PR close
    └── preview-reaper.yml            Scheduled orphan cleanup
```

## Prerequisites

- A Google Cloud project with billing enabled
- `gcloud`, `terraform` (1.5+), `kubectl`, `helm` (3.x), and Docker installed locally
- `gke-gcloud-auth-plugin` — install with `gcloud components install gke-gcloud-auth-plugin`
- A domain you control, for Part 2's wildcard DNS and TLS

## Setup

### 1. Provision the infrastructure

```bash
cd terraform
terraform init
terraform apply \
  -var="project_id=YOUR_PROJECT_ID" \
  -var="github_repo=YOUR_USERNAME/YOUR_REPO"
```

Save the outputs — you need `workload_identity_provider`, `service_account_email`, and `ingress_ip`.

### 2. Add the GitHub secrets

| Secret | Value |
|---|---|
| `WIF_PROVIDER` | The `workload_identity_provider` output |
| `WIF_SERVICE_ACCOUNT` | The `service_account_email` output |

`GITHUB_TOKEN` is provided automatically by GitHub and needs no setup.

### 3. Install the shared cluster components

```bash
gcloud container clusters get-credentials pr-preview-cluster \
  --zone YOUR_ZONE --project YOUR_PROJECT_ID

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.service.loadBalancerIP="YOUR_STATIC_IP" \
  --set controller.service.externalTrafficPolicy=Local

helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

kubectl apply -f k8s/cluster/letsencrypt-staging.yaml
kubectl apply -f k8s/cluster/letsencrypt-prod.yaml
```

### 4. Point wildcard DNS at the load balancer

Create one A record: `*.preview` → your static IP.

### 5. Configure the workflows

Update the `env:` block in `.github/workflows/preview-deploy.yml` with your project ID, region, zone, and `PREVIEW_DOMAIN`. Leave `CLUSTER_ISSUER` on `letsencrypt-staging` until the flow works end to end, then switch to `letsencrypt-prod`.

Open a pull request. The environment deploys and the bot comments the URL.

## Teardown

Do **not** run a full `terraform destroy` if you plan to rebuild.

Google soft-deletes Workload Identity Pools and reserves the ID for 30 days. Recreating the stack inside that window fails with `Error 409: Requested entity already exists`, even though Terraform's state no longer knows about the pool.

Almost all of the cost is the cluster and its nodes. The identity pool, service account, IAM bindings, static IP, and Artifact Registry repository cost nothing or pennies to leave in place. Tear down only the expensive parts:

```bash
terraform destroy \
  -target=google_container_node_pool.primary_nodes \
  -target=google_container_cluster.primary
```

Uninstall the Helm releases first, since the ingress controller's Service owns a load balancer that Terraform does not manage:

```bash
helm uninstall cert-manager --namespace cert-manager
helm uninstall ingress-nginx --namespace ingress-nginx
```

Then confirm nothing was orphaned:

```bash
gcloud compute forwarding-rules list
gcloud compute addresses list
```

### Already hit the 409?

Restore the soft-deleted resources and import them back into state:

```bash
gcloud iam workload-identity-pools undelete github-pool --location=global
gcloud iam workload-identity-pools providers undelete github-provider \
  --workload-identity-pool=github-pool --location=global

terraform import google_iam_workload_identity_pool.github \
  projects/YOUR_PROJECT_ID/locations/global/workloadIdentityPools/github-pool
terraform import google_iam_workload_identity_pool_provider.github \
  projects/YOUR_PROJECT_ID/locations/global/workloadIdentityPools/github-pool/providers/github-provider
```

## Known limitations

**Forked pull requests are not supported.** PRs from forks do not receive `id-token: write`, by design, so they cannot authenticate to Google Cloud. A public repository accepting outside contributions would need a `workflow_run`-based pattern where the privileged half runs from the base repository.

**Let's Encrypt rate limits.** HTTP-01 issues one certificate per hostname, so one per pull request. Let's Encrypt allows 50 certificates per registered domain per week. Past that volume, switch to a single wildcard certificate issued over DNS-01 and replicate the secret into each namespace.

**The application is stateless.** Preview environments for an application with a database need either a per-namespace ephemeral database seeded from a sanitised snapshot, or schema-level isolation in a shared one. That is the hardest remaining problem in this pattern and is out of scope here.

## License

MIT