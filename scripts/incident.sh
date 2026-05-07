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
