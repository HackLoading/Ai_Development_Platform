#!/usr/bin/env bash
# install-monitoring.sh
# Installs kube-prometheus-stack (Prometheus + Grafana + Alertmanager) via Helm
# and configures it to scrape vLLM metrics.
set -euo pipefail

MONITORING_NAMESPACE="monitoring"

echo "==> Adding Prometheus Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "==> Creating monitoring namespace..."
kubectl create namespace ${MONITORING_NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

echo "==> Installing kube-prometheus-stack..."
helm upgrade --install prometheus \
  prometheus-community/kube-prometheus-stack \
  --namespace ${MONITORING_NAMESPACE} \
  --set grafana.adminPassword="admin123" \
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.podMonitorNamespaceSelector.matchLabels.monitoring=enabled \
  --wait \
  --timeout 10m

echo "==> Waiting for Grafana pod..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=grafana \
  -n ${MONITORING_NAMESPACE} \
  --timeout=300s

echo ""
echo "==> Creating PodMonitor for vLLM metrics..."
# vLLM exposes Prometheus metrics at /metrics on port 8000
# This PodMonitor tells Prometheus to scrape it
kubectl apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: vllm-metrics
  namespace: monitoring
  labels:
    release: prometheus
spec:
  namespaceSelector:
    matchNames:
      - ai-platform
  selector:
    matchLabels:
      app: vllm-server
  podMetricsEndpoints:
    - port: http
      path: /metrics
      interval: 15s
EOF

echo ""
echo "==> Monitoring installation complete!"
echo ""
echo "    Grafana:    kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80"
echo "                http://localhost:3000  (admin / admin123)"
echo ""
echo "    Prometheus: kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090"
echo "                http://localhost:9090"
echo ""
echo "==> Key vLLM metrics to watch in Grafana:"
echo "    vllm:num_requests_running           — Inflight requests on GPU"
echo "    vllm:num_requests_waiting           — Queued requests"
echo "    vllm:gpu_cache_usage_perc           — KV cache utilization (0.0-1.0)"
echo "    vllm:prompt_tokens_total            — Total prompt tokens processed"
echo "    vllm:generation_tokens_total        — Total tokens generated"
echo "    vllm:time_to_first_token_seconds    — TTFT latency histogram"
echo "    vllm:e2e_request_latency_seconds    — End-to-end latency histogram"
