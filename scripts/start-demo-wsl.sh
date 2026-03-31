#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NAMESPACE="ai-platform"
MON_NS="monitoring"
ARGO_NS="argocd"

GATEWAY_PORT_FORWARD_LPORT="8080"
GATEWAY_PORT_INCLUSTER="8080"

GRAFANA_LPORT="3000"
PROM_LPORT="9090"
ARGO_LPORT="8443"
UI_LPORT="3001"

VLLM_CONTAINER_NAME="vllm-host-openai"
VLLM_HOST_PORT="8000"
VLLM_MODEL="TinyLlama/TinyLlama-1.1B-Chat-v1.0"
VLLM_SERVED_MODEL="tinyllama"
VLLM_GPU_MEMORY_UTIL="0.80"

API_KEY="demo-api-key-12345"

PF_LOG_DIR="/tmp/ai-platform-demo-pf"
mkdir -p "$PF_LOG_DIR"

log() {
  echo "[start-demo] $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1"
    exit 1
  }
}

start_port_forward() {
  local namespace="$1"
  local resource="$2"
  local local_port="$3"
  local remote_port="$4"
  local tag="$5"

  # Avoid duplicate tunnels.
  pkill -f "kubectl port-forward.*${resource}.*${local_port}:${remote_port}" >/dev/null 2>&1 || true

  log "Port-forwarding ${resource} -> localhost:${local_port}"
  # Keep tunnel alive even if the underlying pod restarts.
  nohup bash -lc "while true; do kubectl port-forward -n '${namespace}' '${resource}' '${local_port}:${remote_port}'; sleep 2; done" \
    > "${PF_LOG_DIR}/${tag}.log" 2>&1 &
}

wait_http_ok() {
  local url="$1"
  local timeout_s="${2:-120}"
  local start
  start="$(date +%s)"
  while true; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > timeout_s )); then
      echo "Timed out waiting for: $url"
      return 1
    fi
    sleep 2
  done
}

wait_gateway_backend_ok() {
  local url="$1"
  local timeout_s="${2:-180}"
  local start
  start="$(date +%s)"
  while true; do
    resp="$(curl -fsS "$url" 2>/dev/null || true)"
    if [ -n "$resp" ]; then
      # Check JSON shape: {"gateway":"ok","backend_vllm":"ok"|...}
      if python3 - "$resp" <<'PY' >/dev/null 2>&1
import json,sys
data=json.loads(sys.argv[1])
sys.exit(0 if data.get("gateway")=="ok" and str(data.get("backend_vllm","")).startswith("ok") else 1)
PY
      then
        return 0
      fi
    fi

    now="$(date +%s)"
    if (( now - start > timeout_s )); then
      echo "Timed out waiting for gateway backend OK at: $url"
      return 1
    fi
    sleep 2
  done
}

monitor_gateway_backend() {
  # Keeps gateway->vLLM wiring healthy (useful when ArgoCD self-heals or pods restart).
  nohup bash -lc '
    while true; do
      resp=$(curl -fsS "http://localhost:'"${GATEWAY_PORT_FORWARD_LPORT}"'/health" 2>/dev/null || true)
      ok=1
      if [ -n "$resp" ]; then
        python3 - "$resp" <<'"'"'PY'"'"' >/dev/null 2>&1
import json,sys
data=json.loads(sys.argv[1])
raise SystemExit(0 if data.get("gateway")=="ok" and str(data.get("backend_vllm","")).startswith("ok") else 1)
PY
        ok=$?
      fi

      if [ "$ok" -ne 0 ]; then
        echo "[gateway-monitor] backend not OK; re-applying env + restarting gateway..."
        kubectl set env deployment/ai-gateway -n "'"${NAMESPACE}"'" \
          "VLLM_BASE_URL=http://host.minikube.internal:'"${VLLM_HOST_PORT}"'" --overwrite >/dev/null 2>&1 || true
        kubectl rollout restart deployment/ai-gateway -n "'"${NAMESPACE}"'" >/dev/null 2>&1 || true
      fi
      sleep 30
    done
  ' > "${PF_LOG_DIR}/gateway-monitor.log" 2>&1 &
}

ensure_vllm_host() {
  # need_cmd docker
  log "Ensuring host vLLM container: ${VLLM_CONTAINER_NAME}"

  # If vLLM is already reachable on host:8000, don't force another container.
  if curl -fsS "http://127.0.0.1:${VLLM_HOST_PORT}/health" >/dev/null 2>&1; then
    log "Host vLLM already reachable on :${VLLM_HOST_PORT}."
    return 0
  fi

  if ! docker ps --format '{{.Names}}' | grep -q "^${VLLM_CONTAINER_NAME}$"; then
    log "Starting vLLM host container..."

    # Best-effort: image pull if missing.
    if ! docker image inspect vllm/vllm-openai:latest >/dev/null 2>&1; then
      log "Pulling vllm/vllm-openai:latest ..."
      docker pull vllm/vllm-openai:latest
    fi

    if ! docker run -d \
      --name "${VLLM_CONTAINER_NAME}" \
      --gpus all \
      -p "${VLLM_HOST_PORT}:8000" \
      -v "${HOME}/.cache/huggingface:/root/.cache/huggingface" \
      --ipc=host \
      vllm/vllm-openai:latest \
      --model "${VLLM_MODEL}" \
      --gpu-memory-utilization "${VLLM_GPU_MEMORY_UTIL}" \
      --max-model-len "2048" \
      --dtype "float16" \
      --host "0.0.0.0" \
      --port "8000" \
      --served-model-name "${VLLM_SERVED_MODEL}"; then
      log "docker run failed; checking if an existing vLLM is already bound to :${VLLM_HOST_PORT} ..."
    fi
  else
    log "Host vLLM container already running."
  fi

  log "Waiting for host vLLM /health ..."
  wait_http_ok "http://127.0.0.1:${VLLM_HOST_PORT}/health" 180
}

ensure_helm_gateway() {
  need_cmd helm
  need_cmd kubectl

  log "Upgrading/Installing gateway Helm chart..."

  # Ensure chart values point gateway to host vLLM.
  cat > "${REPO_ROOT}/helm-chart/ai-inference/values.yaml" <<EOF
namespace: ${NAMESPACE}

vllm:
  enabled: false

gateway:
  image:
    repository: ai-gateway
    tag: latest
    pullPolicy: Never
  port: 8080
  nodePort: 30080
  apiKey: "${API_KEY}"
  logLevel: "INFO"
  resources:
    limits:
      cpu: "500m"
      memory: "512Mi"
    requests:
      cpu: "100m"
      memory: "256Mi"
  env:
    # This hostname works reliably inside Minikube pods.
    VLLM_BASE_URL: "http://host.minikube.internal:${VLLM_HOST_PORT}"
EOF

  helm upgrade --install ai-platform "${REPO_ROOT}/helm-chart/ai-inference" \
    --namespace "${NAMESPACE}" \
    --create-namespace

  log "Waiting for gateway deployment rollout..."
  kubectl rollout status deployment/ai-gateway -n "${NAMESPACE}" --timeout=3m

  # Hard-force the env so even if templates/overrides drift, the live gateway talks to host vLLM.
  kubectl set env deployment/ai-gateway -n "${NAMESPACE}" \
    "VLLM_BASE_URL=http://host.minikube.internal:${VLLM_HOST_PORT}" --overwrite >/dev/null 2>&1 || true
}

ensure_monitoring_and_scrape() {
  need_cmd helm
  need_cmd kubectl

  if ! kubectl get ns "${MON_NS}" >/dev/null 2>&1; then
    log "Installing monitoring stack (kube-prometheus-stack)..."
    "${REPO_ROOT}/monitoring/install-monitoring.sh"
  else
    log "Monitoring namespace exists. Installing/upgrading monitoring stack..."
    "${REPO_ROOT}/monitoring/install-monitoring.sh"
  fi

  # Scrape host vLLM metrics via an in-cluster proxy so dashboards work reliably.
  log "Applying vLLM metrics proxy..."
  kubectl -n "${NAMESPACE}" apply -f "${REPO_ROOT}/monitoring/vllm-metrics-proxy.yaml" >/dev/null 2>&1 || true

  # Give Prometheus time to discover targets.
  sleep 20
}

ensure_argocd() {
  need_cmd kubectl
  if kubectl get ns "${ARGO_NS}" >/dev/null 2>&1; then
    log "ArgoCD namespace exists."
    if kubectl get deploy argocd-server -n "${ARGO_NS}" >/dev/null 2>&1; then
      log "ArgoCD is already installed."
      return 0
    fi
  fi
  log "ArgoCD not detected in cluster. Skipping install (already handled elsewhere)."
}

smoke_test_gateway() {
  # Needs gateway port-forward to localhost:8080.
  log "Running smoke test against gateway..."
  python3 -c "import sys" >/dev/null 2>&1 || true

  # Prefer repo venv if exists.
  if [ -f "${REPO_ROOT}/venv/bin/activate" ]; then
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/venv/bin/activate"
  fi

  python3 "${REPO_ROOT}/test/test_api.py" \
    --base-url "http://localhost:${GATEWAY_PORT_FORWARD_LPORT}" \
    --api-key "${API_KEY}" \
    --model "tinyllama" || true
}

start_ui_server() {
  need_cmd python3
  log "Starting TinyLlama UI on http://localhost:${UI_LPORT}"

  pkill -f "http.server.*${UI_LPORT}" >/dev/null 2>&1 || true
  nohup python3 -m http.server "${UI_LPORT}" --directory "${REPO_ROOT}/ui" \
    > "${PF_LOG_DIR}/ui.log" 2>&1 &
}

main() {
  need_cmd curl
  need_cmd python3

  ensure_vllm_host
  ensure_helm_gateway
  ensure_monitoring_and_scrape
  ensure_argocd

  # Port-forwards (keep alive via nohup).
  start_port_forward "${MON_NS}" "svc/prometheus-grafana" "${GRAFANA_LPORT}" 80 "grafana"
  start_port_forward "${MON_NS}" "svc/prometheus-kube-prometheus-prometheus" "${PROM_LPORT}" 9090 "prometheus"
  start_port_forward "${NAMESPACE}" "svc/ai-gateway-service" "${GATEWAY_PORT_FORWARD_LPORT}" "${GATEWAY_PORT_INCLUSTER}" "gateway"

  if kubectl get svc argocd-server -n "${ARGO_NS}" >/dev/null 2>&1; then
    start_port_forward "${ARGO_NS}" "svc/argocd-server" "${ARGO_LPORT}" 443 "argocd"
  fi

  # Wait for local gateway to respond.
  log "Waiting for local gateway backend (/health) ..."
  wait_gateway_backend_ok "http://localhost:${GATEWAY_PORT_FORWARD_LPORT}/health" 180

  monitor_gateway_backend

  # Start local UI.
  start_ui_server

  # Import dashboards is optional; dashboards will still update once traffic exists.
  # We will generate some traffic so Grafana panels become “moving”.
  log "Generating a short streaming request to warm metrics..."
  nohup curl -N \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${API_KEY}" \
    -d '{
      "model": "tinyllama",
      "messages": [
        {"role": "system", "content": "You are a helpful AI assistant."},
        {"role": "user", "content": "Explain in detail how PagedAttention works in vLLM and why it is so memory efficient."}
      ],
      "max_tokens": 220,
      "temperature": 0.7,
      "stream": true
    }' \
    "http://localhost:${GATEWAY_PORT_FORWARD_LPORT}/v1/chat/completions" \
    > /dev/null 2>&1 &

  # Smoke test (non-blocking-ish; it may take time).
  smoke_test_gateway

  log "Startup complete."
  cat <<EOF
Open:
  Grafana:    http://localhost:${GRAFANA_LPORT} (admin / admin123)
  Prometheus: http://localhost:${PROM_LPORT}
  ArgoCD:     https://localhost:${ARGO_LPORT} (admin / (check secret if needed))
  UI:         http://localhost:${UI_LPORT}

Logs:
  Port-forward logs in: ${PF_LOG_DIR}
This script is kept alive (Ctrl+C to stop, or use Stop-Demo.ps1).
EOF

  # Keep the orchestrator alive.
  while true; do
    sleep 30
  done
}

main "$@"

