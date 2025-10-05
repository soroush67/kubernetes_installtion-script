#!/bin/bash
# ========================================================================
# Kubernetes User Provisioning Script (Dynamic RBAC version)
# Author: Majid Heydari
# Description:
#   Dynamically create Kubernetes users using CSR-based authentication.
#   - You define resources and roles at the top of the script.
#   - No hardcoded roles (like readonly).
#
# Usage:
#   ./create-k8s-user-dynamic.sh <username> <group> <namespace>
#   Example: ./create-k8s-user-dynamic.sh anisa dev-team dev
# ========================================================================

set -euo pipefail

# =========[ ADMIN CONFIGURATION SECTION ]=========
# These variables define the scope of access for all users you create.
# Edit them before running the script.

# List of Kubernetes resources the user should access
RESOURCES=("pods" "services" "configmaps")

# Verbs that define allowed actions for the user
# Example: ("get" "list" "watch") or ("get" "list" "create" "update" "delete")
VERBS=("get" "list" "watch")

# Role type: "Role" (namespace-level) or "ClusterRole" (cluster-wide)
ROLE_KIND="Role"

# Existing role name to use (if you don't want to create a custom one)
# Leave empty ("") to create a new one dynamically
EXISTING_ROLE=""

# =========[ SCRIPT CONFIG ]=========
K8S_CA_DIR="/etc/kubernetes/pki"
OUTPUT_BASE="/tmp/k8s-users"
mkdir -p "$OUTPUT_BASE"

# =========[ ARGUMENTS ]=========
if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <username> <group> <namespace>"
    exit 1
fi

USERNAME=$1
GROUP=$2
NAMESPACE=$3

USER_DIR="${OUTPUT_BASE}/${USERNAME}"
mkdir -p "$USER_DIR"

echo "[*] Creating user: $USERNAME (group: $GROUP, namespace: $NAMESPACE)"

# =========[ 1. Generate Private Key and CSR ]=========
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

# =========[ 2. Create or Reuse Role ]=========
ROLE_NAME="${USERNAME}-custom-role"

if [[ -z "$EXISTING_ROLE" ]]; then
    echo "[*] Creating new ${ROLE_KIND} '${ROLE_NAME}' with custom rules..."
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ${ROLE_KIND}
metadata:
  name: ${ROLE_NAME}
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: [$(printf '"%s",' "${RESOURCES[@]}" | sed 's/,$//')]
  verbs: [$(printf '"%s",' "${VERBS[@]}" | sed 's/,$//')]
EOF
else
    ROLE_NAME="$EXISTING_ROLE"
    echo "[*] Using existing ${ROLE_KIND} '${ROLE_NAME}'"
fi

# =========[ 3. Create Binding ]=========
BIND_NAME="${USERNAME}-binding"

if [[ "$ROLE_KIND" == "Role" ]]; then
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BIND_NAME}
  namespace: ${NAMESPACE}
subjects:
- kind: User
  name: ${USERNAME}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ${ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF
else
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${BIND_NAME}
subjects:
- kind: User
  name: ${USERNAME}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ${ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF
fi

# =========[ 4. Create Kubeconfig ]=========
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
echo "[📁] Files located at: ${USER_DIR}"
echo "[🔑] Kubeconfig: ${USER_DIR}/${USERNAME}.kubeconfig"
