#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Configuration
# ============================================================

INGRESS_NS="ingress-nginx"
MONITORING_NS="monitoring"

CLIENT_NS="iperf-client-ns"
CLIENT_POD="iperf-client"

SERVER_NS="iperf-server-ns"
SERVER_POD="iperf-server"

SERVER_SERVICE="iperf-server-service"

IPERF_PORT="5201"
TEST_DURATION="120"

TCP_CONFIGMAP="tcp-services"

GRAFANA_DASHBOARD_CM="grafana-loadtest-dashboard"
DASHBOARD_FILE_NAME="iperf-ingress-dashboard.json"
DASHBOARD_TITLE="Kubernetes iPerf ingress-nginx Test"
DASHBOARD_UID="kubernetes-iperf-ingress-test"

BACKUP_DIR="/root/monitoring-backup"

# ============================================================
# Header
# ============================================================

echo
echo "============================================================"
echo " Kubernetes iPerf via ingress-nginx"
echo "============================================================"
echo

mkdir -p "${BACKUP_DIR}"

# ============================================================
# 1. Kubernetes pre-check
# ============================================================

echo "[1/10] Checking Kubernetes..."

kubectl get nodes >/dev/null

echo "Kubernetes API: OK"

# ============================================================
# 2. Check iPerf Pods
# ============================================================

echo
echo "[2/10] Checking iPerf Pods..."

kubectl get pod \
  -n "${CLIENT_NS}" \
  "${CLIENT_POD}" >/dev/null

kubectl get pod \
  -n "${SERVER_NS}" \
  "${SERVER_POD}" >/dev/null

CLIENT_READY=$(kubectl get pod \
  -n "${CLIENT_NS}" \
  "${CLIENT_POD}" \
  -o jsonpath='{.status.containerStatuses[0].ready}')

SERVER_READY=$(kubectl get pod \
  -n "${SERVER_NS}" \
  "${SERVER_POD}" \
  -o jsonpath='{.status.containerStatuses[0].ready}')

if [[ "${CLIENT_READY}" != "true" ]]; then
    echo "ERROR: ${CLIENT_NS}/${CLIENT_POD} is not Ready"
    exit 1
fi

if [[ "${SERVER_READY}" != "true" ]]; then
    echo "ERROR: ${SERVER_NS}/${SERVER_POD} is not Ready"
    exit 1
fi

echo
kubectl get pod -n "${CLIENT_NS}" "${CLIENT_POD}" -o wide
kubectl get pod -n "${SERVER_NS}" "${SERVER_POD}" -o wide

# ============================================================
# 3. Check ingress-nginx
# ============================================================

echo
echo "[3/10] Checking ingress-nginx..."

INGRESS_POD=$(kubectl get pod \
  -n "${INGRESS_NS}" \
  -l app.kubernetes.io/name=ingress-nginx \
  -o jsonpath='{.items[0].metadata.name}')

if [[ -z "${INGRESS_POD}" ]]; then
    echo "ERROR: ingress-nginx controller Pod was not found"
    exit 1
fi

echo "Ingress Pod: ${INGRESS_POD}"

HOST_NETWORK=$(kubectl get pod \
  -n "${INGRESS_NS}" \
  "${INGRESS_POD}" \
  -o jsonpath='{.spec.hostNetwork}')

echo "hostNetwork: ${HOST_NETWORK}"

if [[ "${HOST_NETWORK}" != "true" ]]; then
    echo "ERROR: This script expects ingress-nginx hostNetwork=true"
    exit 1
fi

# ============================================================
# 4. Detect ingress/node IP
# ============================================================

echo
echo "[4/10] Detecting ingress IP..."

INGRESS_IP=$(kubectl get pod \
  -n "${INGRESS_NS}" \
  "${INGRESS_POD}" \
  -o jsonpath='{.status.podIP}')

INGRESS_NODE=$(kubectl get pod \
  -n "${INGRESS_NS}" \
  "${INGRESS_POD}" \
  -o jsonpath='{.spec.nodeName}')

echo "Ingress Node : ${INGRESS_NODE}"
echo "Ingress IP   : ${INGRESS_IP}"

# ============================================================
# 5. Verify TCP services support
# ============================================================

echo
echo "[5/10] Checking TCP forwarding support..."

INGRESS_ARGS=$(kubectl get pod \
  -n "${INGRESS_NS}" \
  "${INGRESS_POD}" \
  -o jsonpath='{.spec.containers[0].args}')

if ! echo "${INGRESS_ARGS}" | grep -q "tcp-services-configmap"; then
    echo "ERROR: --tcp-services-configmap is not enabled"
    exit 1
fi

kubectl get configmap \
  -n "${INGRESS_NS}" \
  "${TCP_CONFIGMAP}" >/dev/null

echo "TCP services ConfigMap: OK"

# ============================================================
# 6. Create Service for iperf-server
# ============================================================

echo
echo "[6/10] Creating Service for iperf-server..."

cat > /tmp/iperf-ingress-service.yaml <<EOF_SERVICE
apiVersion: v1
kind: Service
metadata:
  name: ${SERVER_SERVICE}
  namespace: ${SERVER_NS}
spec:
  selector:
    app: ${SERVER_POD}
  ports:
  - name: iperf
    protocol: TCP
    port: ${IPERF_PORT}
    targetPort: ${IPERF_PORT}
EOF_SERVICE

kubectl apply -f /tmp/iperf-ingress-service.yaml

echo
echo "Service:"
kubectl get svc \
  -n "${SERVER_NS}" \
  "${SERVER_SERVICE}" \
  -o wide

echo
echo "Endpoints:"
kubectl get endpoints \
  -n "${SERVER_NS}" \
  "${SERVER_SERVICE}" \
  -o wide

ENDPOINT_IP=$(kubectl get endpoints \
  -n "${SERVER_NS}" \
  "${SERVER_SERVICE}" \
  -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)

if [[ -z "${ENDPOINT_IP}" ]]; then
    echo
    echo "ERROR: Service has no endpoint."
    echo "Check Pod labels and Service selector."
    exit 1
fi

echo
echo "Backend Pod IP: ${ENDPOINT_IP}"

# ============================================================
# 7. Backup and configure TCP ConfigMap
# ============================================================

echo
echo "[7/10] Configuring ingress-nginx TCP forwarding..."

BACKUP_FILE="${BACKUP_DIR}/${TCP_CONFIGMAP}-before-iperf-$(date +%Y%m%d-%H%M%S).yaml"

kubectl -n "${INGRESS_NS}" \
  get configmap "${TCP_CONFIGMAP}" \
  -o yaml > "${BACKUP_FILE}"

echo "Backup created:"
echo "${BACKUP_FILE}"

kubectl -n "${INGRESS_NS}" \
  patch configmap "${TCP_CONFIGMAP}" \
  --type merge \
  -p "{
    \"data\": {
      \"${IPERF_PORT}\": \"${SERVER_NS}/${SERVER_SERVICE}:${IPERF_PORT}\"
    }
  }"

echo
echo "TCP forwarding configuration:"
kubectl -n "${INGRESS_NS}" \
  get configmap "${TCP_CONFIGMAP}" \
  -o yaml

# ============================================================
# 8. Wait for ingress-nginx to listen
# ============================================================

echo
echo "[8/10] Waiting for ingress-nginx TCP/${IPERF_PORT}..."

LISTEN_OK="false"

for i in $(seq 1 20); do

    if ss -lnt | grep -q ":${IPERF_PORT} "; then
        LISTEN_OK="true"
        break
    fi

    echo "Waiting... ${i}/20"
    sleep 2
done

if [[ "${LISTEN_OK}" != "true" ]]; then
    echo
    echo "ERROR: ingress-nginx did not start listening on ${IPERF_PORT}"
    echo
    echo "Recent ingress-nginx logs:"
    kubectl -n "${INGRESS_NS}" \
      logs "${INGRESS_POD}" \
      --tail=100
    exit 1
fi

echo
echo "Ingress listener:"
ss -lntp | grep ":${IPERF_PORT}" || true

# ============================================================
# 9. Create dedicated Grafana dashboard
# ============================================================

echo
echo "[9/10] Creating Grafana ingress dashboard..."

if kubectl -n "${MONITORING_NS}" \
     get configmap "${GRAFANA_DASHBOARD_CM}" >/dev/null 2>&1; then

    BACKUP_GRAFANA="${BACKUP_DIR}/${GRAFANA_DASHBOARD_CM}-before-ingress-$(date +%Y%m%d-%H%M%S).yaml"

    kubectl -n "${MONITORING_NS}" \
      get configmap "${GRAFANA_DASHBOARD_CM}" \
      -o yaml > "${BACKUP_GRAFANA}"

    cat > /tmp/iperf-ingress-dashboard.json <<EOF_DASH
{
  "annotations": {
    "list": []
  },
  "editable": true,
  "graphTooltip": 1,
  "panels": [
    {
      "type": "timeseries",
      "title": "iPerf via ingress-nginx Throughput",
      "description": "${CLIENT_NS}/${CLIENT_POD} -> ${INGRESS_IP}:${IPERF_PORT} -> ${SERVER_NS}/${SERVER_SERVICE} -> ${SERVER_POD}",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 12,
        "w": 24,
        "x": 0,
        "y": 0
      },
      "fieldConfig": {
        "defaults": {
          "unit": "bps",
          "min": 0,
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "linear",
            "lineWidth": 2,
            "fillOpacity": 10,
            "showPoints": "never",
            "spanNulls": true
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(container_network_transmit_bytes_total{namespace=\"${CLIENT_NS}\",pod=\"${CLIENT_POD}\",interface!=\"lo\"}[30s])) * 8",
          "legendFormat": "${CLIENT_NS}/${CLIENT_POD} TX",
          "range": true
        },
        {
          "refId": "B",
          "expr": "sum(rate(container_network_receive_bytes_total{namespace=\"${SERVER_NS}\",pod=\"${SERVER_POD}\",interface!=\"lo\"}[30s])) * 8",
          "legendFormat": "${SERVER_NS}/${SERVER_POD} RX",
          "range": true
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "iPerf Client / Server CPU",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 9,
        "w": 12,
        "x": 0,
        "y": 12
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "linear",
            "lineWidth": 2,
            "fillOpacity": 10,
            "showPoints": "never",
            "spanNulls": true
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi"
        }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"${CLIENT_NS}\",pod=\"${CLIENT_POD}\",container!=\"\",container!=\"POD\"}[30s])) * 100",
          "legendFormat": "iperf-client",
          "range": true
        },
        {
          "refId": "B",
          "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"${SERVER_NS}\",pod=\"${SERVER_POD}\",container!=\"\",container!=\"POD\"}[30s])) * 100",
          "legendFormat": "iperf-server",
          "range": true
        }
      ]
    },
    {
      "type": "timeseries",
      "title": "ingress-nginx CPU Usage",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "h": 9,
        "w": 12,
        "x": 12,
        "y": 12
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "custom": {
            "drawStyle": "line",
            "lineInterpolation": "linear",
            "lineWidth": 2,
            "fillOpacity": 10,
            "showPoints": "never",
            "spanNulls": true
          }
        },
        "overrides": []
      },
      "options": {
        "legend": {
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi"
        }
      },
      "targets": [
        {
          "refId": "A",
          "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"${INGRESS_NS}\",pod=~\"ingress-nginx-controller-.*\",container!=\"\",container!=\"POD\"}[30s])) * 100",
          "legendFormat": "ingress-nginx",
          "range": true
        }
      ]
    }
  ],
  "refresh": "5s",
  "schemaVersion": 41,
  "tags": [
    "iperf",
    "ingress-nginx",
    "performance",
    "tcp"
  ],
  "templating": {
    "list": []
  },
  "time": {
    "from": "now-5m",
    "to": "now"
  },
  "timezone": "browser",
  "title": "${DASHBOARD_TITLE}",
  "uid": "${DASHBOARD_UID}",
  "version": 1
}
EOF_DASH

    python3 -m json.tool \
      /tmp/iperf-ingress-dashboard.json >/dev/null

    echo "Dashboard JSON: OK"

    python3 - <<PY > /tmp/grafana-ingress-dashboard-patch.json
import json

with open("/tmp/iperf-ingress-dashboard.json") as f:
    dashboard = f.read()

print(json.dumps({
    "data": {
        "${DASHBOARD_FILE_NAME}": dashboard
    }
}))
PY

    kubectl -n "${MONITORING_NS}" \
      patch configmap "${GRAFANA_DASHBOARD_CM}" \
      --type merge \
      --patch-file=/tmp/grafana-ingress-dashboard-patch.json

    echo
    echo "Restarting Grafana..."

    kubectl -n "${MONITORING_NS}" \
      rollout restart deployment/grafana

    kubectl -n "${MONITORING_NS}" \
      rollout status deployment/grafana \
      --timeout=120s

else
    echo "WARNING: Grafana dashboard ConfigMap not found."
    echo "Skipping dashboard creation."
fi

# ============================================================
# 10. Show final test information
# ============================================================

echo
echo "[10/10] Environment ready."

CLIENT_IP=$(kubectl get pod \
  -n "${CLIENT_NS}" \
  "${CLIENT_POD}" \
  -o jsonpath='{.status.podIP}')

SERVER_IP=$(kubectl get pod \
  -n "${SERVER_NS}" \
  "${SERVER_POD}" \
  -o jsonpath='{.status.podIP}')

SERVICE_IP=$(kubectl get svc \
  -n "${SERVER_NS}" \
  "${SERVER_SERVICE}" \
  -o jsonpath='{.spec.clusterIP}')

echo
echo "============================================================"
echo " iPerf ingress-nginx Test Environment"
echo "============================================================"
echo
echo "Client:"
echo "  Namespace   : ${CLIENT_NS}"
echo "  Pod         : ${CLIENT_POD}"
echo "  Pod IP      : ${CLIENT_IP}"
echo
echo "Ingress:"
echo "  Node        : ${INGRESS_NODE}"
echo "  IP          : ${INGRESS_IP}"
echo "  TCP Port    : ${IPERF_PORT}"
echo
echo "Service:"
echo "  Namespace   : ${SERVER_NS}"
echo "  Name        : ${SERVER_SERVICE}"
echo "  ClusterIP   : ${SERVICE_IP}"
echo
echo "Server:"
echo "  Pod         : ${SERVER_POD}"
echo "  Pod IP      : ${SERVER_IP}"
echo
echo "Traffic path:"
echo
echo "  ${CLIENT_NS}/${CLIENT_POD}"
echo "          |"
echo "          | TCP ${IPERF_PORT}"
echo "          v"
echo "  ${INGRESS_IP}:${IPERF_PORT}"
echo "          |"
echo "          v"
echo "  ingress-nginx"
echo "          |"
echo "          v"
echo "  ${SERVER_NS}/${SERVER_SERVICE}:${IPERF_PORT}"
echo "          |"
echo "          v"
echo "  ${SERVER_NS}/${SERVER_POD}"
echo
echo "Dashboard:"
echo "  ${DASHBOARD_TITLE}"
echo
echo "============================================================"

# ============================================================
# Connectivity pre-test
# ============================================================

echo
echo "Running short 3-second connectivity test..."

kubectl exec \
  -n "${CLIENT_NS}" \
  "${CLIENT_POD}" -- \
  iperf3 \
  -c "${INGRESS_IP}" \
  -p "${IPERF_PORT}" \
  -t 3 \
  -i 1

echo
echo "Connectivity test: OK"

# ============================================================
# Wait before main test
# ============================================================

echo
echo "Waiting 15 seconds before main test..."
sleep 15

# ============================================================
# Main test
# ============================================================

RESULT_FILE="/root/iperf-ingress-$(date +%Y%m%d-%H%M%S).log"

echo
echo "============================================================"
echo " Starting iPerf via ingress-nginx"
echo "============================================================"
echo
echo "Target   : ${INGRESS_IP}:${IPERF_PORT}"
echo "Duration : ${TEST_DURATION}s"
echo "Started  : $(date)"
echo
echo "Grafana Dashboard:"
echo "  ${DASHBOARD_TITLE}"
echo
echo "Recommended Time Range:"
echo "  Last 5 minutes"
echo

kubectl exec \
  -n "${CLIENT_NS}" \
  "${CLIENT_POD}" -- \
  iperf3 \
  -c "${INGRESS_IP}" \
  -p "${IPERF_PORT}" \
  -t "${TEST_DURATION}" \
  -i 1 | tee "${RESULT_FILE}"

echo
echo "============================================================"
echo " Test completed"
echo "============================================================"
echo
echo "Result saved to:"
echo "  ${RESULT_FILE}"
echo
echo "Traffic path tested:"
echo
echo "Pod -> ingress-nginx -> Service -> Pod"
echo
