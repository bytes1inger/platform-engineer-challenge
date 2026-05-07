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

- [ ] Task 1a — Fixed Terraform bugs
- [ ] Task 1b — Extended EKS module (IRSA + node group)
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

**Restructured the Terraform layout before touching any code.** The original configuration had providers, data sources, locals, and module calls all in a single `main.tf`. Splitting these into `providers.tf`, `data.tf`, `locals.tf`, `outputs.tf`, and `main.tf` follows the standard convention used across most Terraform codebases. The motivation is practical: when multiple engineers work on the same environment, a single large `main.tf` becomes a merge conflict hotspot. Separating concerns by file type means a networking change and an IAM change rarely touch the same file. The module also lacked a `versions.tf` to declare its own provider requirements, which was added to make the module self-documenting and safe to use outside this repo.

**Bug fixes applied:**

- **Wrong IAM policy on cluster role** (`modules/eks-cluster/main.tf`): `AmazonEKSWorkerNodePolicy` was attached to the EKS control plane role. That policy is for EC2 worker nodes. The cluster role needs `AmazonEKSClusterPolicy`, which grants the control plane permission to manage VPC resources, security groups, and ENIs. The cluster would provision but be non-functional without this.


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
