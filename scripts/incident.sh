#!/usr/bin/env bash
# =============================================================================
# incident.sh — Kubernetes deployment incident triage helper
# =============================================================================
#
# ## Usage
#   ./scripts/incident.sh -n <namespace> -d <deployment>
#
#   Flags:
#     -n  Kubernetes namespace (default: default)
#     -d  Deployment name (required)
#     -h  Show this help
#
#   Example:
#     ./scripts/incident.sh -n payments -d api-service
#
#   Output:
#     - Triage report printed to stdout
#     - Report saved to /tmp/triage-<deployment>-<timestamp>.log
#
# =============================================================================
set -euo pipefail

# =============================================================================
# Defaults
# =============================================================================
NAMESPACE="default"
DEPLOYMENT=""
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# =============================================================================
# Helper functions
# =============================================================================

usage() {
  cat <<EOF
Usage: $0 -n <namespace> -d <deployment>

Flags:
  -n  Kubernetes namespace (default: default)
  -d  Deployment name (required)
  -h  Show this help

Example:
  $0 -n payments -d api-service

Output:
  Triage report printed to stdout and saved to
  /tmp/triage-<deployment>-<timestamp>.log
EOF
  exit 0
}

# Print a clearly visible section header for readability in both
# stdout and the log file
section() {
  echo ""
  echo "============================================================"
  echo "  $1"
  echo "  $(date '+%Y-%m-%d %H:%M:%S')"
  echo "============================================================"
}

# =============================================================================
# Argument parsing
# =============================================================================
while getopts ":n:d:h" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    d) DEPLOYMENT="$OPTARG" ;;
    h) usage ;;
    :)
      echo "ERROR: flag -${OPTARG} requires an argument" >&2
      exit 1
      ;;
    \?)
      echo "ERROR: unknown flag -${OPTARG}" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$DEPLOYMENT" ]]; then
  echo "ERROR: -d <deployment> is required" >&2
  echo "Run with -h for usage" >&2
  exit 1
fi

LOG_FILE="/tmp/triage-${DEPLOYMENT}-${TIMESTAMP}.log"

# Tee all output to log file from this point forward
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Triage report: $LOG_FILE"
echo "Started: $(date)"
echo "Target: namespace=${NAMESPACE}, deployment=${DEPLOYMENT}"

# =============================================================================
# Pre-flight: cluster connectivity and RBAC permissions
# We assume the engineer is authenticated — we don't handle auth itself.
# We verify the minimum permissions needed upfront so failures are clear
# rather than cryptic kubectl errors mid-report.
# =============================================================================
check_permissions() {
  echo "Checking cluster connectivity..."

  if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: cannot reach Kubernetes API server" >&2
    echo "Check your kubeconfig: kubectl cluster-info" >&2
    exit 1
  fi

  echo "Checking namespace access..."

  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    echo "ERROR: namespace '${NAMESPACE}' does not exist or you lack permission to view it" >&2
    echo ""
    echo "Namespaces you can see:"
    kubectl get namespaces 2>/dev/null \
      | awk 'NR>1 {print "  "$1}' \
      || echo "  (none visible — check your kubeconfig and RBAC)"
    exit 1
  fi

  echo "Checking RBAC permissions in namespace '${NAMESPACE}'..."

  local FAILED=0

  local -A CHECKS=(
    ["get deployments"]="get deployments"
    ["get pods"]="get pods"
    ["get events"]="get events"
    ["get hpa"]="get horizontalpodautoscalers"
    ["logs"]="get pods/log"
  )

  for label in "${!CHECKS[@]}"; do
    resource="${CHECKS[$label]}"
    verb=$(echo "$resource" | awk '{print $1}')
    res=$(echo "$resource" | awk '{print $2}')

    if ! kubectl auth can-i "$verb" "$res" -n "$NAMESPACE" &>/dev/null; then
      echo "  ✗ missing: $verb $res"
      FAILED=1
    else
      echo "  ✓ $label"
    fi
  done

  # kubectl top requires metrics-server — non-fatal, handled gracefully later
  if ! kubectl auth can-i get nodes.metrics.k8s.io --all-namespaces &>/dev/null; then
    echo "  ⚠ kubectl top may be unavailable (metrics-server or RBAC missing)"
  fi

  if [[ "$FAILED" -ne 0 ]]; then
    echo "" >&2
    echo "ERROR: insufficient RBAC permissions in namespace '${NAMESPACE}'" >&2
    echo "Bind a Role with get/list on deployments, pods, pods/log, events, horizontalpodautoscalers" >&2
    exit 1
  fi

  echo ""
  echo "All permission checks passed."
}

check_permissions

# Validate deployment exists — exit 1 with a clear message rather than
# letting kubectl fail silently mid-report
if ! kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" &>/dev/null; then
  echo ""
  echo "ERROR: deployment '${DEPLOYMENT}' not found in namespace '${NAMESPACE}'" >&2
  echo ""
  echo "Available deployments in namespace '${NAMESPACE}':"
  kubectl get deployments -n "$NAMESPACE" 2>/dev/null \
    || echo "  (none found)"
  exit 1
fi

# =============================================================================
# Section 1 — Deployment status
# Desired vs ready replicas and rollout conditions tell you immediately
# whether this is a partial outage or complete failure.
# =============================================================================
section "1. DEPLOYMENT STATUS"

kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o wide

echo ""
echo "--- Rollout conditions ---"
# --timeout=5s avoids hanging on a stalled rollout; || true so we continue
kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=5s 2>&1 || true

echo ""
echo "--- Full deployment description ---"
kubectl describe deployment "$DEPLOYMENT" -n "$NAMESPACE"

# =============================================================================
# Section 2 — Pod states
# Restart counts and node placement are the first things to check —
# a pod in CrashLoopBackOff or OOMKilled tells you the failure mode fast.
# =============================================================================
section "2. POD STATES"

# Derive label selector from the deployment spec rather than assuming
# a fixed label — works for any deployment regardless of label convention
SELECTOR=$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" \
  -o jsonpath='{.spec.selector.matchLabels}' \
  | sed 's/[{}"]//g' | tr ',' '\n' \
  | awk -F: '{print $1"="$2}' | tr '\n' ',' | sed 's/,$//')

echo "Label selector: ${SELECTOR}"
echo ""

kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
  -o custom-columns=\
"NAME:.metadata.name,\
STATUS:.status.phase,\
READY:.status.containerStatuses[0].ready,\
RESTARTS:.status.containerStatuses[0].restartCount,\
NODE:.spec.nodeName,\
AGE:.metadata.creationTimestamp"

echo ""
echo "--- Pod describe (all matching pods) ---"
kubectl describe pods -n "$NAMESPACE" -l "$SELECTOR"
