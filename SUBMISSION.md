# Submission — Platform Engineer (DevOps) Challenge

**Candidate name:** Gideon Warui
**Date submitted:** 7 May 2026
**Time spent (approximate):** ~4 hours

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

#### File Layout

```
terraform/
├── environments/staging/
│   ├── backend.tf              # partial S3 backend block (values in backend.hcl)
│   ├── backend.hcl             # actual bucket/table/region values, passed at init
│   ├── data.tf                 # data sources (caller identity, region)
│   ├── locals.tf               # common tags, naming conventions
│   ├── main.tf                 # module calls (VPC, EKS, ECR) + S3 app bucket
│   ├── outputs.tf              # root outputs surfaced from modules
│   ├── providers.tf            # AWS provider config (sts_region workaround)
│   ├── variables.tf            # all input variables with descriptions and defaults
│   └── terraform.tfvars.example # example values (tfvars is gitignored)
├── modules/eks-cluster/
│   ├── main.tf                 # cluster, IAM roles, OIDC, IRSA, node group
│   ├── outputs.tf              # cluster_endpoint, oidc_provider_arn, app_sa_role_arn, etc.
│   ├── variables.tf            # module inputs
│   └── versions.tf             # required providers
├── modules/ecr/
│   ├── main.tf                 # ECR repo + lifecycle policy
│   ├── outputs.tf              # repository_url, repository_arn
│   ├── variables.tf            # name, tag mutability, scan_on_push
│   └── versions.tf             # required providers
└── plan-output.txt             # saved terraform plan (43 resources)
```

#### Terraform Outputs

Outputs defined in `environments/staging/outputs.tf`:

| Output | Source | Purpose |
|---|---|---|
| `cluster_name` | `module.eks` | EKS cluster identifier |
| `cluster_endpoint` | `module.eks` | API server URL for kubeconfig |
| `oidc_provider_arn` | `module.eks` | Used in IRSA trust policies |
| `node_group_role_arn` | `module.eks` | IAM role attached to worker nodes |
| `app_sa_role_arn` | `module.eks` | IRSA role ARN for the `app-sa` ServiceAccount |
| `ecr_repository_url` | `module.ecr` | Used by CI/CD to tag and push images |
| `app_bucket_name` | `aws_s3_bucket` | S3 bucket referenced in the IRSA policy |

43 resources total: VPC (15), EKS cluster + IAM + OIDC + node group (13), S3 bucket + hardening (4), ECR (2), networking (9). Full plan in `terraform/plan-output.txt`.

#### Gitignored Files

Sensitive and generated files excluded via `.gitignore`:

`*.tfvars`, `*.tfstate`, `*.tfstate.backup`, `*.tfplan`, `tfplan`, `**/.terraform/`, `.terraform.lock.hcl`, `crash.log`, `override.tf`, `*_override.tf`, `.terraformrc`, `terraform.rc`, `*.pem`, `*.key`, `.env`, `.env.*`

`terraform.tfvars.example` is committed with placeholder values. `backend.hcl` is committed for reviewer visibility but would be gitignored in production with a `backend.hcl.example` instead.

#### 1a — Bug Fixes

Before fixing anything, I split the original single `main.tf` into `providers.tf`, `data.tf`, `locals.tf`, `outputs.tf`, and `main.tf`. Multiple engineers hitting the same file is a merge conflict magnet. I also added `versions.tf` to the module so it declares its own provider requirements.

Bugs found and fixed:

- **Wrong IAM policy on cluster role** (`modules/eks-cluster/main.tf`): `AmazonEKSWorkerNodePolicy` was on the cluster role. That's a node policy, not a control plane policy. Swapped it for `AmazonEKSClusterPolicy`. The cluster would provision fine but the control plane couldn't manage VPC resources, so nothing would actually work.

- **Public API endpoint** (`modules/eks-cluster/main.tf`): `endpoint_public_access` was `true`, which exposes the K8s API to the internet. Set it to `false`. Engineers access via VPN or bastion.

- **ELB subnet tags were integers** (`environments/staging/main.tf`): `kubernetes.io/role/elb` and `kubernetes.io/role/internal-elb` were set to `0` (integer). The AWS Load Balancer Controller needs these as the string `"1"`. Wrong type = silent failure, no ALB/NLB gets created.

- **Control plane in public subnets** (`environments/staging/main.tf`): `subnet_ids` pointed at `module.vpc.public_subnets`, so control plane ENIs got public IPs. Moved to `private_subnets`. Setting `endpoint_public_access = false` doesn't help much if the ENIs are publicly routable anyway.

#### 1b — IRSA and Managed Node Group

For IRSA, I added an IAM role with a web identity trust policy scoped to `system:serviceaccount:default:app-sa` using the cluster's OIDC issuer. The trust policy has both `:sub` and `:aud` conditions. Skipping `:aud` would let any workload with an OIDC token from this cluster assume the role. The S3 policy grants only `s3:GetObject` and `s3:ListBucket` on the specific bucket.

The managed node group uses `t3.medium` in private subnets, min 1 / max 3 / desired 1. I added a launch template to tag EC2 instances with `Environment` at provision time because `aws_eks_node_group` only tags the node group API object, not the actual instances. The `depends_on` block waits for all three IAM policy attachments before creating the node group, otherwise nodes try to bootstrap before the CNI policy is attached and fail to join.

I also pinned `ami_type = "AL2_x86_64"` and `capacity_type = "ON_DEMAND"` explicitly since the provider defaults can shift between versions. Enabled all five control plane log types (the original was missing `controllerManager` and `scheduler`). Added a lifecycle `precondition` on the S3 policy so an empty `app_bucket_name` gets caught instead of producing a malformed ARN.

The CI/CD pipeline (Task 3) pushes to ECR and the app reads from S3 via IRSA, so I provisioned both in Terraform rather than assuming they exist elsewhere. One `terraform apply` creates the whole stack. The S3 bucket has versioning, SSE-S3, and public access blocked. ECR tags are `IMMUTABLE` since the pipeline uses `github.sha` (unique per commit). I also added a lifecycle policy to expire untagged images after 14 days so failed CI runs don't pile up.

The ECR repo is in its own module (`modules/ecr/`) with the same layout as `eks-cluster`. It exposes `image_tag_mutability` and `scan_on_push` as inputs for other environments to override.

#### 1c — Remote State Backend

Terraform's `backend` block runs before providers and data sources, so you can't interpolate variables. I used a partial `backend "s3" {}` in `backend.tf` and a separate `backend.hcl` with the actual values, passed at init via `terraform init -backend-config=backend.hcl`.

The state bucket is in `us-east-1`, not `af-south-1`. I did this on purpose: state storage and infrastructure region don't need to match, and a regional outage in af-south-1 shouldn't block Terraform operations. An SCP in this account also restricts bucket creation to approved regions, which confirmed the approach.

I had to set `sts_region = "us-east-1"` in the provider config because af-south-1 is an opt-in region and its regional STS endpoint isn't active by default. Without that, the provider throws `InvalidClientTokenId` trying to call the af-south-1 STS endpoint. Resources still provision in af-south-1; it's just credential validation that goes through the global endpoint.

DynamoDB lock table uses `PAY_PER_REQUEST` since there's no predictable lock frequency. `dynamodb_table` is technically deprecated in Terraform 1.10+ in favour of `use_lockfile` (native S3 conditional writes), but the task spec calls for DynamoDB specifically. It's a one-line migration later.

Bootstrap commands (run once before `terraform init`):
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

**Issue 1 — Running as root.** Added pod-level `securityContext` with `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, and `seccompProfile: RuntimeDefault`. At container level: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, and `capabilities.drop: ["ALL"]`. This closes the common container escape paths (setuid binaries, filesystem persistence, capability abuse). Paired `readOnlyRootFilesystem` with an `emptyDir` at `/tmp` since Node.js needs a writable scratch dir.

**Issue 2 — No resource limits.** Set requests to `cpu: 100m, memory: 128Mi` and limits to `cpu: 500m, memory: 256Mi`. Without requests the scheduler can't make placement decisions and will over-commit nodes. Without limits a single pod can eat all node memory and OOMKill everything else. These are conservative baselines; real tuning needs production load profiling.

**Issue 3 — No probes.** Added HTTP GET probes on `/health:3000`. Readiness has `initialDelaySeconds: 5` so traffic doesn't route to pods that aren't ready yet. Liveness has `initialDelaySeconds: 15` so it doesn't kill pods that are still starting up. Getting these delays wrong causes either premature restarts or traffic to unhealthy pods.

**Issue 4 — SECRET_KEY in a ConfigMap.** Moved it to a `Secret` resource, updated the deployment to use `secretKeyRef`. Secrets get their own RBAC controls and are base64-encoded (not encrypted at rest by default, but envelope encryption can be configured on etcd). The committed value is a placeholder. In production I'd use External Secrets Operator pulling from AWS Secrets Manager so the real value never touches git or unencrypted cluster state.

**Issue 5 — No PDB.** Created a PodDisruptionBudget with `minAvailable: 1`. Without it, `kubectl drain` during a node upgrade evicts all pods at once. Worth noting: with the base `replicas: 1`, this PDB effectively blocks voluntary disruption entirely. The staging overlay bumps replicas to 2, so then one pod can be evicted while the other serves.

**Issue 6 — LoadBalancer service.** Changed to `ClusterIP`. A `LoadBalancer` type provisions a cloud LB per service, which is expensive and bypasses any ingress-level routing, TLS, or auth. Services should be `ClusterIP` with an ingress controller handling external traffic.

#### 2b — Kustomize Staging Overlay

Replaced the empty `bases: []` with `resources: [../../base]` (Kustomize v5 deprecated `bases`). The overlay sets replicas to 2, pins the image tag to `v1.2.0` via the `images` field (so the base manifest stays generic), and adds `environment: staging` to resource metadata. I used `includeSelectors: false` on the label rather than `commonLabels` because `commonLabels` mutates pod selectors and `matchLabels`, which makes the label impossible to remove later without deleting and recreating resources.

#### 2c — NetworkPolicy

The policy selects `app: api-service` pods and declares both `Ingress` and `Egress` in `policyTypes`. You have to list both explicitly; if you leave `Egress` out of `policyTypes`, egress stays wide open even with no egress rules defined.

Ingress: only from pods with `role: ingress-controller`, on port 3000.

Egress: DNS only (UDP/TCP 53) to `kube-dns` pods in `kube-system`. The `namespaceSelector` and `podSelector` are in the same `from` entry so they AND together. If they were separate entries, you'd get OR logic and accidentally allow any pod in `kube-system` or any pod labelled `kube-dns` in any namespace.

Everything else denied by default.

### Task 3 — CI/CD

#### 3a — Bug Fixes

**BUG 1 — Trigger scope.** `on: push` fires on every branch push. Changed to `on: push: branches: [main]` plus `on: pull_request: branches: [main]`. Build and test run on PRs for feedback; the ECR push and GitOps steps are gated on `github.event_name == 'push'` so they only fire after a merge to main.

**BUG 2 — Hardcoded AWS credentials.** `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` were sourced from GitHub secrets. Long-lived keys can leak via CI logs, forked PRs, or secret scanning gaps. Replaced with OIDC: added `permissions: id-token: write` and a `configure-aws-credentials` step that calls `AssumeRoleWithWebIdentity`. No credentials stored anywhere; the runner gets a short-lived session token.

**BUG 3 — Hardcoded account ID.** `123456789012.dkr.ecr...` was in both the login command and push step. I derive the account ID from `aws sts get-caller-identity` instead, and set the full ECR registry URL once via `$GITHUB_ENV` so every downstream step uses the same value.

**BUG 4 — Push before tests.** The push step ran before tests. Reordered to: build → test → Trivy scan → push → GitOps update. A failing test or scan now stops the pipeline before anything reaches the registry.

**BUG 5 — Wrong package manager.** `yarn test` was used but the project has `package-lock.json`, not `yarn.lock`. Changed to `npm test`.

#### 3b — Security Improvements

OIDC auth covered in BUG 2 above.

Added `aquasecurity/trivy-action@0.30.0` between test and push. `exit-code: '1'` fails the pipeline on CRITICAL vulnerabilities. `ignore-unfixed: true` suppresses findings with no available patch, which otherwise just trains the team to ignore the scanner. The scan runs against the local image before push, so a vulnerable image never reaches ECR.

#### 3c — GitOps Update Step

After pushing to ECR, `kustomize edit set image` rewrites the image tag in `kubernetes/overlays/staging/kustomization.yaml`. The step uses `github-actions[bot]` for the commit so automated commits are distinguishable from human ones. Added `permissions: contents: write` so the runner can push back to the repo. A GitOps controller (ArgoCD / Flux) picks up the commit and syncs the cluster.

The commit message includes `[skip ci]` to prevent an infinite loop (runner pushes to main → triggers workflow → builds same SHA → pushes same image → commits same kustomization change → repeat).

`IMAGE_URI` is set once via `$GITHUB_ENV` right after ECR login, and every downstream step references it. If each step built the URI independently, a tag formula change in one step could silently diverge from another. Worst case: Trivy scans one tag while a different tag gets pushed.

### Task 4 — Scripting

`scripts/incident.sh` takes `-n <namespace>` and `-d <deployment>` flags via `getopts`, namespace defaults to `default`. Output goes to both stdout and `/tmp/triage-<deployment>-<timestamp>.log` via `exec > >(tee -a "$LOG_FILE") 2>&1` so every command after that point is captured automatically.

Pre-flight checks run first: cluster connectivity, namespace existence, RBAC permissions for each operation (`get deployments`, `get pods`, `get events`, `get horizontalpodautoscalers`, `get pods/log`) via `kubectl auth can-i`. Better to fail fast with a clear permission error than crash mid-report. `kubectl top` needs metrics-server and is treated as non-fatal.

The label selector for pod lookups comes from `deployment.spec.selector.matchLabels` via jsonpath rather than assuming `app=<name>`. Works for any deployment regardless of label conventions.

If a pod has restarts, the script grabs the previous container's logs with `--previous`. The current container might look fine while the actual root cause is only in the crashed container's output. This is the most common miss in manual triage.

HPA lookup uses a jsonpath filter on `spec.scaleTargetRef.name` to find the HPA by target rather than by name, since HPA names don't always match deployment names.

Every kubectl command is read-only. No `delete`, `patch`, `apply`, or `exec` anywhere.

### Task 5 — Architecture

The design doc (`docs/observability-design.md`) covers a unified observability stack across the on-prem kubeadm cluster and EKS in af-south-1.

**Metrics:** I went with Prometheus + Thanos over AMP. AMP is available in af-south-1 since June 2025, but at $0.90/10M samples ingested, ~50k active series across both clusters runs ~$260/month just for ingestion. That's a third of the $800 budget before we even get to logging. Thanos sidecars on existing Prometheus instances ship 2-hour TSDB blocks to S3 for ~$50/month. I chose block shipping over remote write because it handles Direct Connect drops better: Prometheus keeps data locally and replays when the link comes back. Also evaluated Mimir (requires replacing Prometheus entirely) and VictoriaMetrics (cluster edition is open-core with enterprise-only federation).

**Logging:** Fluent Bit replaces the existing Fluentd+ELK stack (which has no TLS, an ISO 27001 finding). Fluent Bit uses 4-6x less resources than Fluentd per AWS benchmarks, ships over TLS to managed OpenSearch in af-south-1, and buffers to disk during connectivity drops. I picked managed OpenSearch because self-hosting Elasticsearch means JVM tuning and index lifecycle management that two engineers can't realistically keep up with. ISM handles the 30-day hot-to-archive transition; S3 lifecycle moves objects to Glacier at 90 days.

**Alerting:** Multiwindow burn rate alerts per the Google SRE Workbook against a 99.9% / 30-day SLO (43.8 minutes error budget). Only 4 alerts in the first 30 days: API error burn rate, node not ready, PV > 85% full, cert expiry < 14 days. Every alert requires a runbook; no runbook means the alert gets disabled. Two-person team can't afford alert sprawl.

**Budget:** Self-host anything where the managed alternative eats >40% of budget for one concern. Total estimated spend is ~$430/month, leaving $370 for the eu-west-1 OpenSearch domain planned in 6 months.

---

## Observations on the Current Architecture

Working through the tasks, I noticed a few things in `docs/architecture-brief.md` that would be risks in production. Not criticisms — the brief is intentionally scoped — but things I'd raise in my first week.

**Direct Connect is a SPOF.** One link between Nairobi and af-south-1. If it drops, the on-prem cluster loses all cloud connectivity — not just observability but potentially application traffic too. I'd push for a site-to-site VPN as failover, even at reduced bandwidth.

**Spot instances serving customer APIs.** Spot can be reclaimed with 2 minutes notice. Without PDBs, graceful shutdown, and on-demand fallback, you get intermittent availability drops that are hard to trace. The PDB from Task 2 helps but `terminationGracePeriodSeconds` needs tuning and latency-sensitive workloads shouldn't live exclusively on spot.

**kubeadm v1.29 with 2 engineers.** Control plane upgrades are manual, node-by-node, strict minor-version sequence. 3 CP nodes + 12 workers = a full day per upgrade. v1.29 EOL'd in early 2026, so this is already overdue. I'd look at k3s or RKE2 for simpler lifecycle, or commit to quarterly upgrade windows.

**No ingress controller documented.** I changed the Service to ClusterIP in Task 2 assuming an ingress controller exists. If there isn't one, deploying ingress-nginx or the AWS LB Controller is a prereq for that change to work.

**No DR strategy.** The on-prem cluster has etcd on the control plane nodes with no mention of snapshot schedule, off-site backup, or tested restore. ISO 27001 auditors will ask about RPO/RTO. EKS manages its own control plane, but PVs and on-prem databases still need backup.

**Multi-tenancy without admission control.** The 6-month roadmap has multi-tenancy via namespaces and NetworkPolicy. That gives logical and network isolation, but nothing stops a team from deploying a privileged container, mounting hostPath, or skipping resource limits. Kyverno or OPA Gatekeeper is needed to actually enforce those boundaries.

**ISO 27001 gaps beyond ELK.** kubeadm doesn't enable API server audit logging by default (`--audit-policy-file` must be configured), etcd isn't encrypted at rest unless you set it up, and there's no RBAC review or least-privilege enforcement mentioned for on-prem. All of these will come up in a cert audit.

---

## Assumptions

- EKS uses a private API endpoint in production. I temporarily enabled public access restricted to my IP for kubectl validation, then reverted.
- The `SECRET_KEY` in `kubernetes/base/secret.yaml` is a placeholder. In production it'd come from External Secrets Operator pulling from AWS Secrets Manager.
- The pipeline assumes a GitHub OIDC trust relationship is already configured in the AWS account with the role ARN in `AWS_ROLE_ARN`.
- On-prem has outbound connectivity to af-south-1 over Direct Connect for the observability stack.
- `terraform.tfvars` is gitignored. A `.example` file is committed to show expected inputs.

---

## What I Would Do With More Time

### Terraform

The current `environments/staging/` calling `modules/` layout works for one environment but adding production and eu-west-1 means duplicating `main.tf`, `locals.tf`, and `providers.tf` with only variable differences. I'd bring in Terragrunt so each environment is a `terragrunt.hcl` inheriting from a root config, overriding just what differs.

I'd also add OPA with Conftest against `terraform plan` output in CI. Policies from day one: no S3 buckets without encryption, no IAM policies with `*` resource, mandatory `Environment` and `ManagedBy` tags, no `0.0.0.0/0` ingress on non-443 ports. This catches the same class of bugs I found in Task 1 before they hit `terraform apply`.

Beyond that: `aws_eks_addon` resources for VPC CNI, CoreDNS, and kube-proxy. A VPN or bastion module for private endpoint access. Module version pinning via git tags. tfsec or Checkov as a pre-commit hook and CI step.

### Kubernetes

Deploy External Secrets Operator with a SecretStore pointing to AWS Secrets Manager, replacing the placeholder Secret. Real values never touch git or unencrypted etcd.

Add Kyverno or OPA Gatekeeper with policies mirroring the Task 2 fixes: deny pods without `runAsNonRoot`, deny containers without resource limits, deny `latest` tag, require `app` label. This prevents the same issues from coming back when other teams onboard.

Add an HPA for `api-service` (CPU target 70%) and cert-manager with a Let's Encrypt ClusterIssuer for automated TLS on ingress.

### CI/CD

Image signing with Cosign after Trivy passes, SBOM generation with Syft as an OCI artifact. Then Kyverno can reject unsigned images at deploy time. Full chain: build → test → scan → sign → push.

Split the pipeline into a reusable workflow template called from per-environment workflows. Matrix strategy for staging/production with approval gates. Add `node_modules` caching, Slack notifications on failure, and branch protection requiring green CI before merge.

### Scripting

Add `--format json` for machine-readable output (Slack webhooks, PagerDuty events). Add `--since 30m` to scope logs/events to a time window since full history is noise during an active incident.

Add a symptom-to-cause summary: `ErrImagePull` → check ECR permissions; `CrashLoopBackOff` + OOMKilled → check memory limits; `Pending` → check node capacity and taints. Not auto-remediation, just guided next-steps for 3 AM.

### Observability

Write Terraform for the OpenSearch domain, S3 buckets, and IAM roles from the design doc so the observability stack is as reproducible as the app infra. Commit Helm values for kube-prometheus-stack and Thanos, deploy via ArgoCD ApplicationSets so adding a cluster is a one-line change.

Prototype an OpenTelemetry Collector DaemonSet alongside Fluent Bit for when application teams start sending traces. Add a cost dashboard in Grafana tracking OpenSearch index sizes, S3 growth, and Prometheus cardinality to catch cost surprises before they blow through the $800 ceiling.

---

## How to Test My Solution

### Task 1
```bash
cd terraform/environments/staging
terraform validate
terraform init -backend-config=backend.hcl
terraform plan -var="app_bucket_suffix=app-data" -out=tfplan
terraform show -no-color tfplan > ../../plan-output.txt
terraform apply tfplan
terraform destroy -var="app_bucket_suffix=app-data"
```

### Task 2
```bash
# Validate base manifests
kubectl apply --dry-run=client -f kubernetes/base/

# Build and validate staging overlay
kubectl kustomize kubernetes/overlays/staging/ | kubectl apply --dry-run=client -f -

# Apply to a live cluster
kubectl apply -k kubernetes/overlays/staging/

# Verify key resources
kubectl get networkpolicy,pdb -n default
kubectl describe networkpolicy api-service-netpol -n default
kubectl get deployment api-service -o jsonpath='{.spec.template.spec.securityContext}'
```

### Task 3

Validated locally with 23 automated checks (all passed):

```bash
python3 ci-cd/validate-pipeline.py
```

Checks cover YAML structure, step ordering, OIDC permissions, conditional gates, security hygiene (no hardcoded credentials or account IDs), Trivy config, action pinning, and all 5 labeled bug fixes.

What needs a live GitHub Actions run:
- OIDC token exchange with AWS (needs the IAM trust relationship)
- `docker build` (needs a Dockerfile)
- `npm test` (needs the Node.js project)
- Trivy scan on the actual image
- GitOps commit push permissions

To trigger:
```bash
# PR (build + test only):
gh pr create --base main --head solution/gideon-warui

# Full pipeline (merge to main):
git checkout main && git merge solution/gideon-warui && git push origin main
```

### Task 4
```bash
./scripts/incident.sh -n <namespace> -d <deployment>
./scripts/incident.sh -n default -d api-service
./scripts/incident.sh -h
```

Example output from a live run on `acme-staging-eks`: `scripts/logs/nginx-demo-triage-example.log`
