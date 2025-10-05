#!/bin/bash
# ==============================================
# Kubernetes Flexible Access Provisioner v2
# ==============================================

USER_NAME=${1:-user1}
ROLE_TYPE=${2:-readonly}
RESOURCES=${3:-pods,deployments,services}
VERBS=${4:-get,list,watch}
# آرایه از namespaceها (با فاصله جدا کن)
NAMESPACES=${5:-"dev test"}

echo "🚀 Creating access for user '$USER_NAME' on namespaces: $NAMESPACES"
echo "Resources: $RESOURCES"
echo "Verbs: $VERBS"

#  مرحله 1: ایجاد ServiceAccount در هر namespace
for ns in $NAMESPACES; do
  echo "⚙️ Processing namespace: $ns"
  kubectl get ns $ns >/dev/null 2>&1 || kubectl create ns $ns
  kubectl create sa $USER_NAME -n $ns --dry-run=client -o yaml | kubectl apply -f -

  #  مرحله 2: Role یا ClusterRole
  if [[ $ROLE_TYPE == "cluster" ]]; then
    ROLE_KIND="ClusterRole"
  else
    ROLE_KIND="Role"
  fi

  cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: $ROLE_KIND
metadata:
  name: ${USER_NAME}-${ROLE_TYPE}
  namespace: $ns
rules:
- apiGroups: [""]
  resources: [${RESOURCES}]
  verbs: [${VERBS}]
EOF

  #  مرحله 3: RoleBinding
  if [[ $ROLE_TYPE == "cluster" ]]; then
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${USER_NAME}-binding-${ns}
subjects:
- kind: ServiceAccount
  name: $USER_NAME
  namespace: $ns
roleRef:
  kind: ClusterRole
  name: ${USER_NAME}-${ROLE_TYPE}
  apiGroup: rbac.authorization.k8s.io
EOF
  else
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${USER_NAME}-binding
  namespace: $ns
subjects:
- kind: ServiceAccount
  name: $USER_NAME
  namespace: $ns
roleRef:
  kind: Role
  name: ${USER_NAME}-${ROLE_TYPE}
  apiGroup: rbac.authorization.k8s.io
EOF
  fi
done

#  مرحله 4: ساخت Kubeconfig (فقط از namespace اول token می‌گیریم)
FIRST_NS=$(echo $NAMESPACES | awk '{print $1}')
SECRET_NAME=$(kubectl get sa $USER_NAME -n $FIRST_NS -o jsonpath="{.secrets[0].name}")
TOKEN=$(kubectl get secret $SECRET_NAME -n $FIRST_NS -o jsonpath="{.data.token}" | base64 --decode)
SERVER=$(kubectl config view -o jsonpath="{.clusters[0].cluster.server}")
CA=$(kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

cat <<EOF > kubeconfig-${USER_NAME}
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $CA
    server: $SERVER
  name: my-cluster
contexts:
EOF

for ns in $NAMESPACES; do
cat <<EOF >> kubeconfig-${USER_NAME}
- context:
    cluster: my-cluster
    namespace: $ns
    user: $USER_NAME
  name: ${USER_NAME}@${ns}
EOF
done

cat <<EOF >> kubeconfig-${USER_NAME}
current-context: ${USER_NAME}@$(echo $NAMESPACES | awk '{print $1}')
users:
- name: $USER_NAME
  user:
    token: $TOKEN
EOF

echo "✅ Finished! File created: kubeconfig-${USER_NAME}"
