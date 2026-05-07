#!/usr/bin/env python3
"""
Offline validation for ci-cd/pipeline.yml.

Checks YAML structure, step ordering, security hygiene, and GitHub Actions
best practices without requiring a live GitHub Actions environment.

Usage:
    python3 ci-cd/validate-pipeline.py
"""

import os
import re
import sys
import yaml

PIPELINE = os.path.join(os.path.dirname(__file__), "pipeline.yml")

results = []


def check(num, desc, passed):
    status = "PASS" if passed else "FAIL"
    results.append((num, desc, passed))
    print(f"  [{status}] {num:>2}. {desc}")
    return passed


def main():
    with open(PIPELINE) as f:
        doc = yaml.safe_load(f)
        f.seek(0)
        raw = f.read()

    code_lines = [l for l in raw.splitlines() if not l.strip().startswith("#")]
    code_only = "\n".join(code_lines)

    # PyYAML parses 'on:' as boolean True (YAML 1.1 quirk).
    # GitHub Actions handles this correctly in its own parser.
    triggers = doc.get(True) or doc.get("on")

    job = doc["jobs"]["build-and-test"]
    perms = job["permissions"]
    steps = job["steps"]
    names = [s["name"] for s in steps]

    def step(name):
        return steps[names.index(name)]

    bi = names.index("Build Docker image")
    ti = names.index("Run tests")
    si = names.index("Scan image for vulnerabilities")
    pi = names.index("Push image to ECR")
    gi = names.index("Update staging image tag")

    print("Pipeline validation: ci-cd/pipeline.yml\n")

    print("--- Structure ---")
    check(1, "YAML syntax valid", doc is not None)
    check(2, "push + pull_request triggers defined", "push" in triggers and "pull_request" in triggers)
    check(3, "Runs on ubuntu-latest", job["runs-on"] == "ubuntu-latest")
    check(4, "11 steps total", len(steps) == 11)

    print("\n--- Permissions (OIDC + GitOps) ---")
    check(5, "id-token: write (required for OIDC)", perms.get("id-token") == "write")
    check(6, "contents: write (required for GitOps push)", perms.get("contents") == "write")

    print("\n--- Step ordering ---")
    check(7, "build < test < scan < push < gitops", bi < ti < si < pi < gi)

    print("\n--- Conditional gates ---")
    push_if = steps[pi].get("if", "")
    gitops_if = steps[gi].get("if", "")
    check(8, "Push gated to refs/heads/main + push event", "refs/heads/main" in push_if and "push" in push_if)
    check(9, "GitOps gated to refs/heads/main + push event", "refs/heads/main" in gitops_if and "push" in gitops_if)
    check(10, "[skip ci] in GitOps commit message", "[skip ci]" in steps[gi]["run"])

    print("\n--- Security ---")
    check(11, "No hardcoded 12-digit account IDs in code", not re.findall(r"(?<!\w)\d{12}(?!\w)", code_only))
    check(12, "No hardcoded AWS_ACCESS_KEY_ID in code", "AWS_ACCESS_KEY_ID" not in code_only)
    check(13, "No hardcoded AWS_SECRET_ACCESS_KEY in code", "AWS_SECRET_ACCESS_KEY" not in code_only)
    check(14, "OIDC via configure-aws-credentials@v4", any("configure-aws-credentials@v4" in s.get("uses", "") for s in steps))

    print("\n--- Trivy scan ---")
    trivy = steps[si]
    check(15, "Trivy pinned to aquasecurity/trivy-action@0.30.0", "aquasecurity/trivy-action@0.30.0" in trivy["uses"])
    check(16, "exit-code: 1 (fail on findings)", trivy["with"]["exit-code"] == 1)
    check(17, "severity: CRITICAL", trivy["with"]["severity"] == "CRITICAL")

    print("\n--- Pinned dependencies ---")
    check(18, "actions/checkout@v4", "actions/checkout@v4" in steps[0]["uses"])
    check(19, "docker/setup-buildx-action@v3", "docker/setup-buildx-action@v3" in steps[1]["uses"])
    check(20, "Kustomize pinned to v5.7.1", "kustomize%2Fv5.7.1" in steps[gi]["run"])

    print("\n--- Bug fixes ---")
    check(21, "npm test (not yarn)", "npm test" in steps[ti]["run"] and "yarn" not in steps[ti]["run"])
    check(22, "IMAGE_URI shared via GITHUB_ENV", "GITHUB_ENV" in step("Set image URI")["run"])
    check(23, "ECR registry from sts get-caller-identity", "sts get-caller-identity" in step("Derive ECR registry URL")["run"])

    passed = sum(1 for _, _, p in results if p)
    total = len(results)
    print(f"\n{'=' * 50}")
    print(f"  {passed}/{total} checks passed")

    if passed < total:
        print("\n  Failed:")
        for n, d, p in results:
            if not p:
                print(f"    {n}. {d}")
        print(f"{'=' * 50}")
        sys.exit(1)
    else:
        print(f"{'=' * 50}")
        sys.exit(0)


if __name__ == "__main__":
    main()
