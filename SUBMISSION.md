# Submission — Platform Engineer (DevOps) Challenge

**Candidate name:** Gideon Warui
**Date submitted:**
**Time spent (approximate):**

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
- [ ] Task 4  — Wrote incident triage script
- [ ] Task 5  — Wrote observability design document

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



### Task 4 — Scripting



### Task 5 — Architecture



---

## Assumptions

-
-
-

---

## What I Would Do With More Time

-
-
-

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
# Commands to validate Kubernetes manifests
```

### Task 3
```
# How to test the pipeline (e.g., which branch to push to)
```

### Task 4
```bash
# How to run the triage script
```
