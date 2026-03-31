#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAMESPACE="ai-platform"
MON_NS="monitoring"
ARGO_NS="argocd"

UI_LPORT="3001"
VLLM_CONTAINER_NAME="vllm-host-openai"

log() {
  echo "[stop-demo] $*"
}

kill_port_forward() {
  # Kill kubectl port-forward processes for our demo ports.
  pkill -f "kubectl port-forward.*${MON_NS}.*3000:80" >/dev/null 2>&1 || true
  pkill -f "kubectl port-forward.*${MON_NS}.*9090:9090" >/dev/null 2>&1 || true
  pkill -f "kubectl port-forward.*${NAMESPACE}.*8080:8080" >/dev/null 2>&1 || true
  pkill -f "kubectl port-forward.*${ARGO_NS}.*8443:443" >/dev/null 2>&1 || true
}

main() {
  log "Stopping UI server..."
  pkill -f "http.server.*${UI_LPORT}" >/dev/null 2>&1 || true

  log "Stopping port-forwards..."
  kill_port_forward

  log "Stopping host vLLM container (if running)..."
  docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER_NAME}$" >/dev/null 2>&1 || true
  if docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER_NAME}$"; then
    docker stop "${VLLM_CONTAINER_NAME}" >/dev/null 2>&1 || true
  fi

  log "Done."
}

main "$@"

