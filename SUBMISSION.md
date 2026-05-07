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
- [ ] Task 1c — Added remote state backend config
- [ ] Task 2a — Fixed all 6 Kubernetes issues
- [ ] Task 2b — Created Kustomize staging overlay
- [ ] Task 2c — Wrote NetworkPolicy
- [ ] Task 3a — Fixed pipeline bugs
- [ ] Task 3b — Applied security improvements (OIDC, Trivy)
- [ ] Task 3c — Added GitOps update step
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

**ECR repository and app S3 bucket** (`environments/staging/main.tf`): The CI/CD pipeline (Task 3) pushes to ECR and the application reads from S3 via IRSA. Rather than assuming these exist outside of Terraform, both are provisioned here so a single `terraform apply` creates the complete stack with no manual pre-steps. The ECR repository uses `IMMUTABLE` tags — the pipeline tags images with `github.sha`, which is unique per commit, so immutability prevents accidental overwrites of previously deployed images. `scan_on_push = true` enables AWS basic vulnerability scanning at no cost. The S3 bucket has versioning enabled, SSE-S3 default encryption, and all public access blocked. Both resource names are variable-driven (`var.ecr_repository_name`, `var.project`, `var.environment`, `var.app_bucket_suffix`) — no hardcoded strings.

#### 1c — Remote State Backend



### Task 2 — Kubernetes



### Task 3 — CI/CD



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
# Commands to validate Terraform
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
