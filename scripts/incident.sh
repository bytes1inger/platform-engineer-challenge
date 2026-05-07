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

# =============================================================================
# Section 3 — Recent events
# Events surface scheduling failures, image pull errors, OOMKills — sorted
# by last seen time so the most recent problem is at the bottom.
# =============================================================================
section "3. RECENT EVENTS (last 20, sorted by time)"

kubectl get events -n "$NAMESPACE" \
  --field-selector "involvedObject.name=${DEPLOYMENT}" \
  --sort-by='.lastTimestamp' \
  | tail -20

echo ""
echo "--- Events for pods in this deployment ---"

# Capture pod names into an array — reused across sections 3, 4, 5
mapfile -t POD_NAMES < <(kubectl get pods -n "$NAMESPACE" -l "$SELECTOR" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

for pod in "${POD_NAMES[@]}"; do
  echo ""
  echo "Events for pod: ${pod}"
  kubectl get events -n "$NAMESPACE" \
    --field-selector "involvedObject.name=${pod}" \
    --sort-by='.lastTimestamp' \
    | tail -10
done

# =============================================================================
# Section 4 — Recent logs
# Last 50 lines with timestamps from each pod's primary container.
# Timestamps are critical for correlating with external events or deploys.
# =============================================================================
section "4. RECENT LOGS (last 50 lines per pod, with timestamps)"

for pod in "${POD_NAMES[@]}"; do
  echo ""
  echo "--- Logs: ${pod} ---"

  CONTAINER=$(kubectl get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.spec.containers[0].name}')
  echo "Container: ${CONTAINER}"
  echo ""

  kubectl logs "$pod" -n "$NAMESPACE" \
    --container="$CONTAINER" \
    --tail=50 \
    --timestamps=true 2>&1 || echo "  (could not retrieve logs for ${pod})"

  # Fetch previous container logs if the pod has restarted — the current
  # container may look healthy while the crash that caused the restart is
  # only visible in the terminated container's logs
  RESTART_COUNT=$(kubectl get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

  if [[ "$RESTART_COUNT" -gt 0 ]]; then
    echo ""
    echo "  ⚠ Pod has restarted ${RESTART_COUNT} time(s) — previous container logs:"
    kubectl logs "$pod" -n "$NAMESPACE" \
      --container="$CONTAINER" \
      --previous \
      --tail=50 \
      --timestamps=true 2>&1 || echo "  (previous logs not available)"
  fi
done

# =============================================================================
# Section 5 — Resource usage
# CPU and memory actuals vs requests/limits. OOMKill and CPU throttling
# are invisible without this. kubectl top requires metrics-server.
# =============================================================================
section "5. RESOURCE USAGE (kubectl top)"

if kubectl top pods -n "$NAMESPACE" -l "$SELECTOR" --containers 2>/dev/null; then
  : # success
else
  echo "WARNING: kubectl top unavailable — metrics-server may not be installed"
fi

# =============================================================================
# Section 6 — HPA status
# If an HPA exists, its current vs desired replica count and metric values
# explain scaling behaviour — missing replicas often trace back here.
# =============================================================================
section "6. HPA STATUS"

if kubectl get hpa -n "$NAMESPACE" 2>/dev/null | grep -q "$DEPLOYMENT"; then
  echo "HPA found for deployment: ${DEPLOYMENT}"
  echo ""
  kubectl get hpa -n "$NAMESPACE" -o wide | grep -E "NAME|${DEPLOYMENT}"

  echo ""
  echo "--- HPA description ---"
  HPA_NAME=$(kubectl get hpa -n "$NAMESPACE" \
    -o jsonpath="{range .items[?(@.spec.scaleTargetRef.name=='${DEPLOYMENT}')]}{.metadata.name}{end}")

  if [[ -n "$HPA_NAME" ]]; then
    kubectl describe hpa "$HPA_NAME" -n "$NAMESPACE"
  fi
else
  echo "No HPA found for deployment '${DEPLOYMENT}' in namespace '${NAMESPACE}'"
fi

# =============================================================================
# Summary footer
# =============================================================================
section "TRIAGE COMPLETE"
echo "Report saved to: ${LOG_FILE}"
echo "Finished: $(date)"
echo ""
echo "Next steps if issue not resolved:"
echo "  1. Check node conditions:  kubectl get nodes"
echo "  2. Check PV/PVC status:    kubectl get pvc -n ${NAMESPACE}"
echo "  3. Check network policies: kubectl get networkpolicy -n ${NAMESPACE}"
echo "  4. Check RBAC:             kubectl auth can-i --list --as=system:serviceaccount:${NAMESPACE}:default"
