# Submission — Platform Engineer (DevOps) Challenge

**Candidate name:** Gideon Warui
**Date submitted:** 7 May 2026
**Time spent (approximate):** ~12 hours

---

## Environment

| Tool | Version |
|------|---------|
| Terraform | v1.15.2 |
| AWS Provider | v5.100.0 |
| TLS Provider | v4.2.1 |
| AWS CLI | v2.34.44 |
| kubectl | v1.35.2 |
| Kustomize | v5.7.1 (bundled with kubectl) |
| Helm | v3.20.0 |
| OS | Ubuntu 24 / WSL2 x86_64 |
| AWS Region | af-south-1 (Cape Town) |

---

## Tasks Completed

<!-- Check off what you completed -->

- [x] Task 1a — Fixed Terraform bugs
- [x] Task 1b — Extended EKS module (IRSA + node group)
- [x] Task 1c — Added remote state backend config
- [x] Task 2a — Fixed all 6 Kubernetes issues
- [x] Task 2b — Created Kustomize staging overlay
- [x] Task 2c — Wrote NetworkPolicy
- [x] Task 3a — Fixed pipeline bugs
- [x] Task 3b — Applied security improvements (OIDC, Trivy)
- [x] Task 3c — Added GitOps update step
- [x] Task 4  — Wrote incident triage script
- [x] Task 5  — Wrote observability design document

---

## Key Decisions and Trade-offs

### Task 1 — Terraform

#### 1a — Bug Fixes

**Restructured the Terraform layout before touching any code.** The original configuration had providers, data sources, locals, and module calls all in a single `main.tf`. Splitting these into `providers.tf`, `data.tf`, `locals.tf`, `outputs.tf`, and `main.tf` follows the standard convention used across most Terraform codebases. The motivation is practical: when multiple engineers work on the same environment, a single large `main.tf` becomes a merge conflict hotspot. Separating concerns by file type means a networking change and an IAM change rarely touch the same file. The module also lacked a `versions.tf` to declare its own provider requirements, which was added to make the module self-documenting and safe to use outside this repo.

Bugs fixed:

- **Wrong IAM policy on cluster role** (`modules/eks-cluster/main.tf`): `AmazonEKSWorkerNodePolicy` was attached to the EKS control plane role. That policy is for EC2 worker nodes. The cluster role needs `AmazonEKSClusterPolicy`, which grants the control plane permission to manage VPC resources, security groups, and ENIs. The cluster would provision but immediately be non-functional without this.

- **Public API endpoint enabled** (`modules/eks-cluster/main.tf`): `endpoint_public_access` was `true`, exposing the Kubernetes API server to the internet. Set to `false` to restrict API access to within the VPC. Engineers access kubectl via VPN or a bastion — this is the expected operational trade-off for a private cluster.

- **ELB subnet discovery tags set to integer instead of string** (`environments/staging/main.tf`): Both `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` were set to `0` (integer). The AWS Load Balancer Controller requires these values to be the string `"1"`. With the wrong type, load balancer provisioning silently fails — no ALB or NLB gets created when a Service or Ingress is applied.

- **Control plane placed in public subnets** (`environments/staging/main.tf`): `subnet_ids` was set to `module.vpc.public_subnets`, placing the EKS control plane ENIs in public subnets where they receive public IPs. Moved to `module.vpc.private_subnets`. This also gives the `endpoint_public_access = false` fix its full effect — there is no point restricting API access if the ENIs are publicly routable anyway.

#### 1b — IRSA and Managed Node Group

**IRSA role for `app-sa`** (`modules/eks-cluster/main.tf`): An IAM role with a web identity trust policy is added, scoped to a single Kubernetes service account (`system:serviceaccount:default:app-sa`) using the cluster's OIDC issuer as the federated principal. The trust policy includes both the `:sub` condition (restricts to the specific service account) and the `:aud` condition (restricts to the STS endpoint) — both are required; omitting `:aud` makes the role assumable by any workload that gets an OIDC token from this cluster. An inline S3 policy grants only `s3:GetObject` and `s3:ListBucket` on the specific bucket, following least-privilege. The role ARN is exposed as a module output so it can be placed in a Kubernetes ServiceAccount annotation by whatever CD tool manages the cluster.

**Managed node group** (`modules/eks-cluster/main.tf`): A launch template is added to attach an `Environment` tag to each EC2 instance at provision time — this is necessary because `aws_eks_node_group` tags only the node group object in the EKS API, not the underlying EC2 instances. The node group itself uses `t3.medium` instances in the private subnets, with `min=1`, `max=3`, and `desired=1`. The `depends_on` block ensures all three IAM policy attachments complete before the node group is created; without this, nodes can start bootstrapping before the CNI policy is in place and fail to join.

**Module hardening beyond the task requirements:** Several implicit defaults were made explicit to ensure the module behaves predictably across environments. `ami_type = "AL2_x86_64"` and `capacity_type = "ON_DEMAND"` are now declared on the node group — without these, the AWS provider silently picks defaults that may differ across provider versions. `update_config { max_unavailable = 1 }` controls rolling node replacement so at most one node is drained at a time during a version upgrade. All five EKS control plane log types are enabled (`api`, `audit`, `authenticator`, `controllerManager`, `scheduler`) — the original config omitted `controllerManager` and `scheduler`, which are needed to debug scheduling failures and controller reconciliation issues. A lifecycle `precondition` on the S3 policy guards against an empty `app_bucket_name` producing a malformed `arn:aws:s3:::` ARN that would silently apply but grant nothing.

**ECR repository and app S3 bucket**: The CI/CD pipeline (Task 3) pushes to ECR and the application reads from S3 via IRSA. Rather than assuming these exist outside of Terraform, both are provisioned here so a single `terraform apply` creates the complete stack with no manual pre-steps. The S3 bucket has versioning enabled, SSE-S3 default encryption, and all public access blocked. Both resource names are variable-driven — no hardcoded strings.

**ECR module** (`modules/ecr/`): The ECR repository is extracted into a reusable module (`modules/ecr/`) following the same file layout as `modules/eks-cluster` — `main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`. The module exposes `image_tag_mutability` and `scan_on_push` as inputs so other environments can override them. Tags are `IMMUTABLE` in staging — the pipeline uses `github.sha` as the image tag, which is unique per commit, so immutability prevents any overwrite of a previously deployed image. A lifecycle policy is included to expire untagged images after 14 days; without it, failed CI runs accumulate untagged layers indefinitely and inflate ECR storage costs.

#### 1c — Remote State Backend

**Partial backend configuration pattern** (`environments/staging/backend.tf` + `backend.hcl`): Terraform's `backend` block is evaluated before providers and data sources, so variable interpolation is unavailable — writing `bucket = var.state_bucket` is a syntax error. The standard workaround is a partial `backend "s3" {}` in the committed file, with the actual values in a separate `backend.hcl` passed at init time via `terraform init -backend-config=backend.hcl`. This keeps bucket names and account IDs out of static source files while still fully configuring the backend.

**State bucket region** (`backend.hcl`): The S3 state bucket and DynamoDB lock table are in `us-east-1`, not `af-south-1`. This is intentional — the infrastructure region and the state storage region are independent. Keeping state in a stable, always-available region (us-east-1) avoids a scenario where a regional outage in af-south-1 blocks Terraform operations on infrastructure that is itself not affected. A Service Control Policy (SCP) in this account also restricts S3 bucket creation to approved regions, which confirmed this approach.

**`sts_region = "us-east-1"`** (`providers.tf`): af-south-1 is an AWS opt-in region whose regional STS endpoint is not activated by default. Without this setting, the AWS provider fails credential validation with `InvalidClientTokenId` because it tries to call the af-south-1 regional STS endpoint, which is not live. Pinning `sts_region` to `us-east-1` routes credential validation through the global STS endpoint while all resources continue to be provisioned in af-south-1.

**DynamoDB lock table**: Uses `PAY_PER_REQUEST` billing — there is no predictable lock frequency, and provisioned capacity would either be wasteful or throttle unexpectedly on busy pipelines. The `LockID` attribute (string hash key) is the exact schema Terraform's S3 backend expects. Note: `dynamodb_table` is deprecated in Terraform 1.10+ in favour of `use_lockfile`, which uses native S3 conditional writes. For now `dynamodb_table` is retained as the task specification calls for DynamoDB locking explicitly. Migrating to `use_lockfile` is a one-line change once the bucket is confirmed to support S3 object locking.

**Bootstrap commands** (run once before `terraform init`):
```bash
aws s3api create-bucket --bucket acme-staging-tfstate-<account-id> --region us-east-1
aws s3api put-bucket-versioning --bucket acme-staging-tfstate-<account-id> --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket acme-staging-tfstate-<account-id> \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket acme-staging-tfstate-<account-id> \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws dynamodb create-table --table-name acme-staging-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1
```

### Task 2 — Kubernetes

#### 2a — Bug Fixes

**Issue 1 — Container running as root** (`kubernetes/base/deployment.yaml`): Added a pod-level `securityContext` with `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, and `seccompProfile: RuntimeDefault`. Added a container-level `securityContext` with `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and `capabilities.drop: ["ALL"]`. Together these eliminate the most common container escape paths: privilege escalation via setuid binaries, writes to the root filesystem for persistence, and Linux capability abuse. `readOnlyRootFilesystem: true` is paired with an `emptyDir` volume mounted at `/tmp` because Node.js needs a writable scratch space at runtime — without this the container would crash on first write.

**Issue 2 — No resource requests or limits** (`kubernetes/base/deployment.yaml`): Set `requests: cpu: 100m, memory: 128Mi` and `limits: cpu: 500m, memory: 256Mi`. Without requests, the scheduler has no basis for placement decisions and can over-commit nodes. Without limits, a single pod can consume all node memory and trigger an OOMKill cascade across unrelated workloads. The values are conservative baselines for a Node.js API — tuning them requires profiling under production load.

**Issue 3 — No liveness or readiness probes** (`kubernetes/base/deployment.yaml`): Added HTTP GET probes on `GET /health:3000`. The readiness probe (`initialDelaySeconds: 5`) gates traffic — Kubernetes will not route requests to a pod until it returns 200. The liveness probe (`initialDelaySeconds: 15`) restarts the container if the process hangs after startup. The different delays matter: too short a liveness delay restarts healthy pods that are still initialising; too short a readiness delay routes traffic to pods not yet ready to serve.

**Issue 4 — SECRET_KEY in plaintext ConfigMap** (`kubernetes/base/deployment.yaml`, `configmap.yaml`, `secret.yaml`): Moved `SECRET_KEY` to a `Secret` resource and updated the deployment env var to use `secretKeyRef`. Removed `secret_key` from the ConfigMap. In Kubernetes, Secrets are base64-encoded (not encrypted at rest by default, but separately controllable via envelope encryption on the etcd level) and are access-controlled by RBAC independently of ConfigMaps. The committed secret value is a placeholder — in production this would be populated by External Secrets Operator pulling from AWS Secrets Manager, so the real value never exists in the repository or in unencrypted cluster state.

**Issue 5 — No PodDisruptionBudget** (`kubernetes/base/pod-disruption-budget.yaml`): Created a PDB with `minAvailable: 1`. Without a PDB, `kubectl drain` during a node upgrade evicts all pods on that node simultaneously, causing downtime. The PDB instructs the eviction API to keep at least one replica running at all times. Note: the base deployment has `replicas: 1` — a PDB with `minAvailable: 1` on a single replica effectively blocks voluntary disruption. The staging overlay raises replicas to 2, at which point the PDB allows one pod to be evicted while the other continues serving.

**Issue 6 — Service type LoadBalancer** (`kubernetes/base/service.yaml`): Changed `type: LoadBalancer` to `type: ClusterIP`. A `LoadBalancer` service provisions a cloud load balancer per service, which is expensive and bypasses any ingress-level routing, TLS termination, and auth middleware. With ingress handled by a dedicated ingress controller (as is standard), services should be `ClusterIP` — reachable within the cluster only, with the ingress controller routing external traffic to them.

#### 2b — Kustomize Staging Overlay

**`kubernetes/overlays/staging/kustomization.yaml`**: Replaced the empty `bases: []` placeholder with a proper `resources: [../../base]` reference (Kustomize v5 deprecated `bases` in favour of `resources`). The `replicas` field patches the deployment count to 2. The `images` field pins the tag to `v1.2.0` without modifying the base manifest — this is the correct GitOps pattern: the base always references the image name and the overlay or CD tooling pins the tag. The `labels` field uses `includeSelectors: false` to add `environment: staging` to resource metadata only; using `commonLabels` would mutate pod selectors and `matchLabels` blocks, making it impossible to remove the label without deleting and recreating the resources.

#### 2c — NetworkPolicy

**`kubernetes/base/network-policy.yaml`**: The policy selects `app: api-service` pods and declares both `Ingress` and `Egress` policy types — declaring both is required; omitting `Egress` from `policyTypes` leaves egress fully open even if no egress rules are defined. Ingress is restricted to pods with `role: ingress-controller` on port 3000 only. Egress allows DNS on UDP/TCP 53 to `kube-dns` pods in `kube-system` — the `namespaceSelector` and `podSelector` are combined in a single `from` entry (AND logic), which restricts DNS to exactly the kube-dns pods in kube-system, not any pod in kube-system or any pod named kube-dns in any namespace. All other ingress and egress is denied by default because both policy types are declared and no other rules are present.



### Task 3 — CI/CD

#### 3a — Bug Fixes

**BUG 1 — Trigger on all push events** (`ci-cd/pipeline.yml`): `on: push` fires the workflow on every push to every branch and every pull_request event. Changed to `on: push: branches: [main]` plus `on: pull_request: branches: [main]`. This means the build and test steps run on PRs (giving feedback before merge) but the image push and GitOps update steps are gated on `github.event_name == 'push'` — they only fire on a completed merge to main. Pushing an untested image from a feature branch would be a meaningful production risk.

**BUG 2 — Hardcoded long-lived AWS credentials** (`ci-cd/pipeline.yml`): `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` were set as env vars sourced from GitHub secrets. Long-lived IAM user credentials can be leaked via CI logs, forked PRs, or secret scanning gaps. Replaced with OIDC: added `permissions: id-token: write` at the workflow level (GitHub must issue an OIDC token to the runner) and a `configure-aws-credentials` step that calls `AssumeRoleWithWebIdentity` using the role ARN stored as `AWS_ROLE_ARN`. The IAM role's trust policy must be configured to accept the OIDC token from `token.actions.githubusercontent.com` — this is done once in the AWS account, not in the pipeline. The result is that no credentials are stored anywhere; the runner gets a temporary session token scoped to the job.

**BUG 3 — Hardcoded AWS account ID** (`ci-cd/pipeline.yml`): `123456789012.dkr.ecr.$AWS_REGION.amazonaws.com` appeared in both the ECR login command and the push step. Replaced the manual `aws ecr get-login-password | docker login` command with the `amazon-ecr-login` action (`id: ecr-login`). This action resolves the registry URL automatically from the caller's identity and exposes it as `steps.ecr-login.outputs.registry`. All subsequent steps reference that output — the account ID never appears in the pipeline file.

**BUG 4 — Image pushed before tests run** (`ci-cd/pipeline.yml`): The Push step appeared before Run tests, meaning a broken build could push a faulty image to ECR before any test failure was detected. Reordered steps: Build → Run tests → Trivy scan → Push → GitOps update. A failed test or scan now aborts the run before the image reaches the registry.

**BUG 5 — Wrong package manager command** (`ci-cd/pipeline.yml`): `yarn test` was used but the project uses npm (the presence of `package-lock.json` vs `yarn.lock` is the canonical indicator). Changed to `npm test`. Running the wrong package manager silently installs nothing and the test command either fails with "command not found" or runs against stale dependencies.

#### 3b — Security Improvements

**OIDC auth**: Covered in BUG 2 above — no long-lived credentials anywhere in the pipeline.

**Trivy scan before push**: Added `aquasecurity/trivy-action@0.30.0` between the test step and the push step. `exit-code: '1'` fails the pipeline if CRITICAL vulnerabilities are found. `ignore-unfixed: true` suppresses findings where no patched version exists yet — these can't be actioned immediately and create alert fatigue that leads teams to ignore the scanner entirely. The scan runs against the locally built image (before push), so a vulnerable image never reaches the registry.

#### 3c — GitOps Update Step

After a successful push to ECR, `kustomize edit set image` rewrites the image reference in `kubernetes/overlays/staging/kustomization.yaml` to point to the newly pushed tag. The step is gated on `github.event_name == 'push'` so it never runs on PRs. The `github-actions[bot]` identity is used for the commit and push, making automated commits distinguishable from human commits in git history. `permissions: contents: write` was added at the workflow level to allow the runner to push the kustomization change back to the repo. A GitOps controller (ArgoCD or Flux) watching the repo will detect this commit and sync the staging cluster to the new image tag.

**`[skip ci]` on the GitOps commit**: Without this, the commit pushed by the GitOps step would immediately re-trigger the workflow — the runner pushes to main, the push event fires, the workflow runs, builds and tests the same SHA, pushes the same image, commits the same kustomization change, and loops indefinitely. Adding `[skip ci]` to the commit message is the standard GitHub Actions mechanism to suppress workflow triggers on automation commits.

**`IMAGE_URI` shared via `$GITHUB_ENV`**: A `Set IMAGE_URI` step runs immediately after ECR login and writes the full image reference (`registry/repo:sha`) to `$GITHUB_ENV`. Every downstream step — build, scan, push, and GitOps update — references `$IMAGE_URI` rather than reconstructing the URI independently. Without this, a tag formula change in one step silently diverges from the others; in the worst case the Trivy scan passes on one image tag while a different tag is pushed to ECR.



### Task 4 — Scripting

**`scripts/incident.sh`** accepts `-n <namespace>` and `-d <deployment>` flags via `getopts`, defaulting namespace to `default`. All output is tee'd to `/tmp/triage-<deployment>-<timestamp>.log` from the point of `exec > >(tee -a "$LOG_FILE") 2>&1` — this single redirect means every subsequent command, including those inside functions and subshells, writes to both stdout and the log file without wrapping each one individually.

**Pre-flight checks** run before any triage section. The script verifies cluster connectivity (`kubectl cluster-info`), confirms the namespace exists, and checks RBAC permissions for every operation it needs (`get deployments`, `get pods`, `get events`, `get horizontalpodautoscalers`, `get pods/log`) using `kubectl auth can-i`. Failing fast with a specific permission error is more useful to an on-call engineer than a cryptic mid-report failure. `kubectl top` requires metrics-server and is treated as non-fatal — the script warns and continues rather than exiting. The deployment existence check comes after RBAC so the error message can include a list of available deployments in the namespace.

**Label selector derivation** (Section 2) queries `deployment.spec.selector.matchLabels` via jsonpath rather than assuming a fixed `app=` label. This makes the script work for any deployment regardless of label convention.

**Previous container logs** (Section 4): if a pod has a non-zero restart count, the script fetches the terminated container's logs with `--previous`. The current container may look healthy while the root cause is only visible in the crashed container's output — this is the single most common miss in manual triage.

**HPA lookup** (Section 6) uses a jsonpath filter `?(@.spec.scaleTargetRef.name=='${DEPLOYMENT}')` to find the HPA by its target rather than by name, since HPA names don't always match deployment names.

**Safety**: every kubectl command is read-only (`get`, `describe`, `logs`, `top`). No `delete`, `patch`, `apply`, or `exec` operations anywhere in the script.

### Task 5 — Architecture

The design document (`docs/observability-design.md`) proposes a unified observability stack across the on-premise kubeadm cluster and EKS in af-south-1, built around three pillars: Prometheus + Thanos for metrics, Fluent Bit + OpenSearch for logging, and Alertmanager + PagerDuty for alerting.

**Metrics — Prometheus + Thanos over AMP:** Amazon Managed Prometheus became available in af-south-1 in June 2025, but at $0.90/10M samples ingested, ~50,000 active series across both clusters would cost ~$260/month for ingestion alone — a third of the $800 budget before logging. Thanos sidecars on existing Prometheus instances ship 2-hour TSDB blocks to S3, achieving the same cross-cluster federation at ~$50/month. Block shipping (not remote write) was chosen because it handles Direct Connect connectivity drops gracefully — Prometheus retains data locally and replays the backlog when the link recovers. Grafana Mimir and VictoriaMetrics were also evaluated and rejected (Mimir requires replacing Prometheus entirely; VM cluster is open-core with enterprise-only federation features).

**Logging — Fluent Bit + OpenSearch over self-hosted ELK:** The current Fluentd-to-ELK stack has no TLS, which is an ISO 27001 finding. Fluent Bit replaces Fluentd at 4-6x lower resource usage (AWS benchmarks), ships over TLS to managed OpenSearch in af-south-1 (satisfying data residency), and buffers to local disk during connectivity drops. OpenSearch was chosen as a managed service because self-hosting Elasticsearch requires JVM tuning and index lifecycle management that two engineers cannot sustain. ISM `cold_migration` handles the 30-day hot to archive transition, with S3 lifecycle moving objects to Glacier at 90 days.

**Alerting — SLO burn rates from the Google SRE Workbook:** Rather than threshold-based alerts that generate noise, the design uses multiwindow burn rate alerting against a 99.9% / 30-day SLO (43.8 minutes error budget). Only 4 alerts are defined in the first 30 days — API error burn rate, node not ready, PV > 85% full, and certificate expiry < 14 days. Every alert requires a runbook; alerts without runbooks are disabled. This prevents alert sprawl on a two-person team.

**Trade-offs:** The decision framework is explicit: self-host any component where the managed equivalent consumes over 40% of the budget for a single concern. Total estimated spend is ~$430/month, retaining $370 headroom for the eu-west-1 OpenSearch domain planned in 6 months.

---

## Assumptions

- The EKS cluster uses a private API endpoint in production; I temporarily enabled public access restricted to my IP for kubectl validation during the challenge, then reverted.
- The `SECRET_KEY` value in `kubernetes/base/secret.yaml` is a placeholder. In production this would be injected by External Secrets Operator pulling from AWS Secrets Manager — the real value never exists in the repository.
- The CI/CD pipeline assumes a GitHub OIDC trust relationship is already configured in the AWS account with a role whose ARN is stored as `AWS_ROLE_ARN` in GitHub Secrets.
- The on-premise cluster has outbound connectivity to AWS af-south-1 over Direct Connect for the observability stack (Thanos block shipping, Fluent Bit log delivery).
- `terraform.tfvars` is gitignored. A `terraform.tfvars.example` is committed to document the expected variables without exposing real values.

---

## What I Would Do With More Time

### Terraform — Repo Structure and Governance

The current layout (`environments/staging/` calling `modules/`) works for one environment, but adding production and eu-west-1 would mean duplicating `main.tf`, `locals.tf`, and `providers.tf` across directories with only variable differences. I would introduce **Terragrunt** to DRY this up — each environment becomes a `terragrunt.hcl` that inherits from a root config and only overrides what differs (region, instance sizes, replica counts). This eliminates copy-paste drift between staging and production.

I would also add **policy-as-code** using Open Policy Agent (OPA) with Conftest, running against `terraform plan` output in CI. Policies I would enforce from day one: no S3 buckets without encryption or public access blocks, no IAM policies with `*` resource, all resources must carry `Environment` and `ManagedBy` tags, no security groups with `0.0.0.0/0` ingress on non-443 ports. These catch the class of bugs I fixed in Task 1 before they reach `terraform apply`.

Beyond that: add `aws_eks_addon` resources for VPC CNI, CoreDNS, and kube-proxy so add-on lifecycle is Terraform-managed. Add a VPN or bastion module so the EKS private endpoint is accessible without temporarily enabling public access. Pin module versions using git tags so environments can upgrade independently. Add **tfsec** or **Checkov** as a pre-commit hook and CI step for static security scanning of HCL.

### Kubernetes — Admission Control and Secret Management

Deploy **External Secrets Operator** with a SecretStore pointing to AWS Secrets Manager, replacing the placeholder Secret. The real value never exists in git or in unencrypted etcd — ESO pulls it at pod start via IRSA.

Add **Kyverno** or **OPA Gatekeeper** as an admission controller with policies that mirror the fixes from Task 2: deny pods without `securityContext.runAsNonRoot`, deny containers without resource limits, deny images with `latest` tag, require the `app` label on all workloads. This prevents the same class of issues from being reintroduced by other teams as they onboard.

Add a HorizontalPodAutoscaler for `api-service` with CPU-based scaling (target 70%), and a cert-manager `ClusterIssuer` backed by Let's Encrypt for automated TLS certificate lifecycle on ingress.

### CI/CD — Supply Chain Security and Multi-Environment

Add **image signing with Cosign** (Sigstore) after the Trivy scan passes, and **SBOM generation with Syft** attached to the image as an OCI artifact. This gives a verifiable chain: build → test → scan → sign → push. Kubernetes admission policy (Kyverno) can then reject unsigned images at deploy time.

Split the pipeline into a reusable workflow template (`.github/workflows/build-test-push.yml`) called from per-environment workflows. Add a matrix strategy for staging/production with environment-specific variables and approval gates (`environment: production` with required reviewers).

Add `node_modules` caching (`actions/cache`) to avoid re-downloading dependencies on every run. Add Slack notification on failure using `slackapi/slack-github-action`. Add branch protection rules requiring the pipeline to pass before merge.

### Scripting — Machine Output and Remediation Hints

Add a `--format json` flag to `incident.sh` for machine-readable output that could feed into a Slack webhook, PagerDuty custom event, or incident management system. Add a `--since` flag (e.g. `--since 30m`) to scope log and event collection to a time window — during active incidents, full history is noise.

Add a summary section that maps observed symptoms to likely causes: `ErrImagePull` → check ECR permissions and image tag; `CrashLoopBackOff` with OOMKilled → check memory limits; `Pending` pods → check node capacity and taints. Not auto-remediation, but guided next-steps for an on-call engineer at 3 AM.

### Observability — Infrastructure as Code for the Stack

Write Terraform for the OpenSearch domain, S3 buckets, and IAM roles referenced in the design document — the observability stack should be as reproducible as the application infrastructure. Commit Helm values for kube-prometheus-stack and Thanos as version-controlled files in the repo, deployed via ArgoCD ApplicationSets so adding a new cluster is a one-line addition.

Prototype OpenTelemetry Collector as a DaemonSet alongside Fluent Bit, ready for application teams to start sending traces once the `trace_id` convention matures. Add a cost monitoring dashboard in Grafana that tracks OpenSearch index sizes, S3 storage growth, and Prometheus cardinality — preventing cost surprises before they hit the $800 ceiling.

---

## How to Test My Solution

### Task 1
```bash
# Validate all Terraform configs
cd terraform/environments/staging
terraform validate

# Initialise with remote backend
terraform init -backend-config=backend.hcl

# Generate and review plan (requires af-south-1 to be enabled in the AWS account)
terraform plan -var="app_bucket_suffix=app-data" -out=tfplan
terraform show -no-color tfplan > ../../plan-output.txt

# Apply
terraform apply tfplan

# Destroy when done
terraform destroy -var="app_bucket_suffix=app-data"
```

### Task 2
```bash
# Validate base manifests
kubectl apply --dry-run=client -f kubernetes/base/

# Build and validate staging overlay
kubectl kustomize kubernetes/overlays/staging/ | kubectl apply --dry-run=client -f -

# Apply to a live cluster (requires kubeconfig)
kubectl apply -k kubernetes/overlays/staging/

# Verify NetworkPolicy
kubectl get networkpolicy -n default
kubectl describe networkpolicy api-service-netpol -n default

# Verify PDB
kubectl get pdb -n default

# Verify security context (should show runAsNonRoot, no root containers)
kubectl get deployment api-service -o jsonpath='{.spec.template.spec.securityContext}'
```

### Task 3

**What was validated locally (23 automated checks, all passed):**

```bash
python3 ci-cd/validate-pipeline.py
```

The script checks YAML structure, step ordering, OIDC permissions, conditional
gates, security hygiene (no hardcoded credentials or account IDs), Trivy
configuration, action version pinning, and all 5 labeled bug fixes. See the
script for the full check list.

**What cannot be validated without a live GitHub Actions run:**

- OIDC token exchange with AWS (requires IAM trust relationship configured in the account)
- `docker build` success (requires a Dockerfile at the repo root)
- `npm test` pass (requires the Node.js project with a working test suite)
- Trivy scan results on the built image
- GitOps commit push permissions on the actual repository

**To trigger a live run:**
```bash
# Build + test on any branch (push to ECR is skipped — not main):
git push origin solution/gideon-warui

# Full pipeline (build + test + scan + push + GitOps) on merge to main:
git checkout main && git merge solution/gideon-warui && git push origin main

# PR triggers build + test only:
gh pr create --base main --head solution/gideon-warui

# Prerequisites:
# - AWS_ROLE_ARN secret configured in GitHub repo settings
# - OIDC trust relationship configured in AWS IAM for GitHub Actions
# - ECR repository acme/api-service exists in af-south-1
# - Dockerfile present at repo root
```

### Task 4
```bash
# Run against any deployment
./scripts/incident.sh -n <namespace> -d <deployment>

# Example (default namespace)
./scripts/incident.sh -n default -d api-service

# Help
./scripts/incident.sh -h
```

Example output from a live run against `nginx-demo` on `acme-staging-eks` is committed to `scripts/logs/nginx-demo-triage-example.log`.
