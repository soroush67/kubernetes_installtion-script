#!/bin/bash
# =====================================================================
# Kubernetes Multi-Namespace User Provisioner (YAML-driven)
# Author: Majid Heydari
#
# Dependencies:
#   - yq (https://github.com/mikefarah/yq)
#
# Usage:
#   ./manage-k8s-users-yaml.sh create rbac-config.yaml
#   ./manage-k8s-users-yaml.sh delete rbac-config.yaml
# =====================================================================

set -euo pipefail

K8S_CA_DIR="/etc/kubernetes/pki"
OUTPUT_BASE="/tmp/k8s-users"
mkdir -p "$OUTPUT_BASE"

ACTION=${1:-}
CONFIG_FILE=${2:-}

if [[ -z "$ACTION" || -z "$CONFIG_FILE" ]]; then
  echo "Usage: $0 <create|delete> <rbac-config.yaml>"
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "❌ Please install 'yq' first: https://github.com/mikefarah/yq"
  exit 1
fi

for USERNAME in $(yq e '.users[].name' "$CONFIG_FILE"); do
  GROUP=$(yq e ".users[] | select(.name==\"${USERNAME}\") | .group" "$CONFIG_FILE")
  USER_DIR="${OUTPUT_BASE}/${USERNAME}"

  if [[ "$ACTION" == "create" ]]; then
    echo "=============================="
    echo "[*] Creating user: $USERNAME (group: $GROUP)"
    mkdir -p "$USER_DIR"

    # Generate key and CSR
    openssl genrsa -out "${USER_DIR}/${USERNAME}.key" 2048
    openssl req -new -key "${USER_DIR}/${USERNAME}.key" -subj "/CN=${USERNAME}/O=${GROUP}" -out "${USER_DIR}/${USERNAME}.csr"
    CSR_BASE64=$(base64 -w 0 "${USER_DIR}/${USERNAME}.csr")

    cat > "${USER_DIR}/${USERNAME}-csr.yaml" <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USERNAME}
spec:
  groups:
  - system:authenticated
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF

    kubectl apply -f "${USER_DIR}/${USERNAME}-csr.yaml"
    sleep 2
    kubectl certificate approve "${USERNAME}"
    kubectl get csr "${USERNAME}" -o jsonpath='{.status.certificate}' | base64 -d > "${USER_DIR}/${USERNAME}.crt"

    # Loop over namespaces
    for NS in $(yq e ".users[] | select(.name==\"${USERNAME}\") | .namespaces[].name" "$CONFIG_FILE"); do
      echo "  [+] Processing namespace: $NS"

      RESOURCES=($(yq e ".users[] | select(.name==\"${USERNAME}\") | .namespaces[] | select(.name==\"${NS}\") | .resources[]" "$CONFIG_FILE"))
      VERBS=($(yq e ".users[] | select(.name==\"${USERNAME}\") | .namespaces[] | select(.name==\"${NS}\") | .verbs[]" "$CONFIG_FILE"))

      ROLE_NAME="${USERNAME}-${NS}-role"
      BIND_NAME="${USERNAME}-${NS}-binding"

      # Create Role
      cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
  namespace: ${NS}
rules:
- apiGroups: [""]
  resources: [$(printf '"%s",' "${RESOURCES[@]}" | sed 's/,$//')]
  verbs: [$(printf '"%s",' "${VERBS[@]}" | sed 's/,$//')]
EOF

      # Create RoleBinding
      cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BIND_NAME}
  namespace: ${NS}
subjects:
- kind: User
  name: ${USERNAME}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ${ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF
    done

    # Generate kubeconfig
    CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
    CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

    cat > "${USER_DIR}/${USERNAME}.kubeconfig" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $(base64 -w 0 ${K8S_CA_DIR}/ca.crt)
    server: ${CLUSTER_SERVER}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    user: ${USERNAME}
  name: ${USERNAME}@${CLUSTER_NAME}
current-context: ${USERNAME}@${CLUSTER_NAME}
users:
- name: ${USERNAME}
  user:
    client-certificate-data: $(base64 -w 0 ${USER_DIR}/${USERNAME}.crt)
    client-key-data: $(base64 -w 0 ${USER_DIR}/${USERNAME}.key)
EOF

    echo "[✅] User '${USERNAME}' created successfully."

  elif [[ "$ACTION" == "delete" ]]; then
    echo "=============================="
    echo "[*] Deleting user: $USERNAME"

    kubectl delete csr "${USERNAME}" --ignore-not-found=true
    for NS in $(yq e ".users[] | select(.name==\"${USERNAME}\") | .namespaces[].name" "$CONFIG_FILE"); do
      kubectl delete role "${USERNAME}-${NS}-role" -n "${NS}" --ignore-not-found=true
      kubectl delete rolebinding "${USERNAME}-${NS}-binding" -n "${NS}" --ignore-not-found=true
    done
    rm -rf "${USER_DIR}" || true
    echo "[✅] User '${USERNAME}' deleted successfully."
  fi
done
