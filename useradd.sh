
## 📄 File: `create-k8s-users.sh`

#!/bin/bash
# ========================================================================
# Kubernetes User Provisioning Script
# Author: Majid Heydari
# Description:
#   This script automates the creation of Kubernetes users using CSR.
#   It generates keys, signs certificates, assigns RBAC roles, 
#   and produces ready-to-use kubeconfig files.
#
# Usage:
#   1. Single user mode:
#        ./create-k8s-users.sh <username> <group> <role> <namespace>
#        Example: ./create-k8s-users.sh anisa dev-team readonly dev
#
#   2. Bulk mode (from CSV):
#        ./create-k8s-users.sh -f users.csv
#        CSV format: username,group,role,namespace
#
# Requirements:
#   - Must be executed by a Kubernetes admin node with kubectl access
#   - OpenSSL installed
# ========================================================================

set -euo pipefail

K8S_CA_DIR="/etc/kubernetes/pki"
OUTPUT_BASE="/tmp/k8s-users"
mkdir -p "$OUTPUT_BASE"

# -------------------------------
# Functions
# -------------------------------

generate_user() {
    local USERNAME=$1
    local GROUP=$2
    local ROLE=$3
    local NAMESPACE=$4

    local USER_DIR="${OUTPUT_BASE}/${USERNAME}"
    mkdir -p "$USER_DIR"

    echo "[*] Creating user: $USERNAME | group: $GROUP | role: $ROLE | namespace: $NAMESPACE"

    # 1. Generate private key & CSR
    openssl genrsa -out "${USER_DIR}/${USERNAME}.key" 2048
    openssl req -new -key "${USER_DIR}/${USERNAME}.key" -subj "/CN=${USERNAME}/O=${GROUP}" -out "${USER_DIR}/${USERNAME}.csr"

    local CSR_BASE64
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

    # 2. Submit CSR and approve
    kubectl apply -f "${USER_DIR}/${USERNAME}-csr.yaml"
    sleep 2
    kubectl certificate approve "${USERNAME}"

    # 3. Retrieve the signed certificate
    kubectl get csr "${USERNAME}" -o jsonpath='{.status.certificate}' | base64 -d > "${USER_DIR}/${USERNAME}.crt"

    # 4. Create Role or use existing ClusterRole
    local ROLE_NAME ROLE_KIND
    if [[ "$ROLE" == "readonly" ]]; then
        ROLE_KIND="Role"
        ROLE_NAME="${USERNAME}-readonly"
        cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${ROLE_NAME}
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods","services","configmaps","secrets"]
  verbs: ["get","list","watch"]
EOF
    elif [[ "$ROLE" == "edit" ]]; then
        ROLE_KIND="ClusterRole"
        ROLE_NAME="edit"
    else
        ROLE_KIND="ClusterRole"
        ROLE_NAME="cluster-admin"
    fi

    # 5. Create RoleBinding or ClusterRoleBinding
    local BIND_NAME="${USERNAME}-binding"
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

    # 6. Generate kubeconfig for the user
    local CLUSTER_NAME CLUSTER_SERVER
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

    echo "[+] User ${USERNAME} created successfully. Files saved in ${USER_DIR}"
}

# -------------------------------
# Bulk mode (CSV file)
# -------------------------------
if [[ "${1:-}" == "-f" ]]; then
    CSV_FILE=$2
    if [[ ! -f "$CSV_FILE" ]]; then
        echo "Error: File '$CSV_FILE' not found."
        exit 1
    fi

    echo "[*] Processing bulk user creation from: $CSV_FILE"
    while IFS=',' read -r USERNAME GROUP ROLE NAMESPACE; do
        [[ "$USERNAME" =~ ^#.*$ || -z "$USERNAME" ]] && continue
        generate_user "$USERNAME" "$GROUP" "$ROLE" "$NAMESPACE"
    done < "$CSV_FILE"

else
    if [[ $# -lt 4 ]]; then
        echo "Usage:"
        echo "  ./create-k8s-users.sh <username> <group> <role> <namespace>"
        echo "  ./create-k8s-users.sh -f <users.csv>"
        exit 1
    fi

    generate_user "$1" "$2" "$3" "$4"
fi
```

---

##  Example CSV (`users.csv`)

```csv
# username,group,role,namespace
anisa,dev-team,readonly,dev
majid,backend,edit,staging
alex,ops,cluster-admin,default
```

---

##  Example usage

### Create one user:

```bash
sudo ./create-k8s-users.sh anisa dev-team readonly dev
```

### Create multiple users:

```bash
sudo ./create-k8s-users.sh -f users.csv
```

---

##  Output structure

Each user gets a directory at `/tmp/k8s-users/<username>` containing:

| File                | Description                  |
| ------------------- | ---------------------------- |
| `<user>.key`        | Private key                  |
| `<user>.csr`        | Certificate Signing Request  |
| `<user>.crt`        | Signed certificate           |
| `<user>.kubeconfig` | Ready-to-use kubeconfig file |
| `<user>-csr.yaml`   | YAML manifest for the CSR    |

---

##  Bonus tip

You can commit this script to GitHub in a repo like:


github.com/<your-username>/k8s-user-management


and include a `README.md` explaining:

* Prerequisites (`kubectl`, `openssl`)
* Usage examples
* CSV format

---

Would you like me to generate a **`README.md`** template for this script (clean, GitHub-ready, with badges and usage examples)? It’ll make your repo look fully professional.
