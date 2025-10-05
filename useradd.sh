خیلی عالی 👏
الان دقیقاً رسیدیم به نقطه‌ای که باید کل **فرآیند ایجاد کاربر، صدور گواهی، و دادن دسترسی‌ها (RBAC)** رو به‌صورت یکپارچه و خودکار بسازیم — دقیقاً مثل یک شرکت واقعی که بخواد چندین تیم DevOps، QA یا Developer رو مدیریت کنه.

بذار بر اساس تجربه‌ی واقعی DevOps بنویسمش:
اسکریپت همه‌چیز رو از صفر انجام می‌ده — از تولید گواهی تا ساخت Role و Binding.
کافیه اسم کاربر و گروهش رو بدی ✅

---

## 🧰 فایل: `create-k8s-user.sh`

```bash
#!/bin/bash
# =============================
# Kubernetes User Provisioning Script
# Author: Majid (DevOps Automation)
# =============================

# Usage:
# ./create-k8s-user.sh <username> <group> <role> <namespace>
# Example:
# ./create-k8s-user.sh anisa dev-team readonly dev

set -e

# =========[ Variables ]=========
USER=${1:-anisa}
GROUP=${2:-dev-team}
ROLE=${3:-readonly}      # readonly | edit | cluster-admin
NAMESPACE=${4:-default}
K8S_CA_DIR="/etc/kubernetes/pki"
TMP_DIR="/tmp/k8s-users/$USER"
mkdir -p $TMP_DIR

# =========[ 1. Generate Private Key & CSR ]=========
echo "[*] Generating private key and CSR for user: $USER"

openssl genrsa -out $TMP_DIR/$USER.key 2048
openssl req -new -key $TMP_DIR/$USER.key -subj "/CN=${USER}/O=${GROUP}" -out $TMP_DIR/$USER.csr

CSR_BASE64=$(base64 -w 0 $TMP_DIR/$USER.csr)

cat > $TMP_DIR/${USER}-csr.yaml <<EOF
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${USER}
spec:
  groups:
  - system:authenticated
  request: ${CSR_BASE64}
  signerName: kubernetes.io/kube-apiserver-client
  usages:
  - client auth
EOF

echo "[+] CSR manifest created at: $TMP_DIR/${USER}-csr.yaml"

# =========[ 2. Submit CSR & Approve it ]=========
kubectl apply -f $TMP_DIR/${USER}-csr.yaml
sleep 2
kubectl certificate approve ${USER}

# =========[ 3. Retrieve Signed Certificate ]=========
kubectl get csr ${USER} -o jsonpath='{.status.certificate}' | base64 -d > $TMP_DIR/${USER}.crt
echo "[+] Certificate signed and saved to $TMP_DIR/${USER}.crt"

# =========[ 4. Create Role / ClusterRole if needed ]=========
if [[ "$ROLE" == "readonly" ]]; then
    echo "[*] Creating readonly Role in namespace $NAMESPACE"
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${USER}-readonly
  namespace: ${NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods","services","configmaps","secrets"]
  verbs: ["get","list","watch"]
EOF
    ROLE_NAME="${USER}-readonly"
    ROLE_KIND="Role"
elif [[ "$ROLE" == "edit" ]]; then
    ROLE_NAME="edit"
    ROLE_KIND="ClusterRole"
else
    ROLE_NAME="cluster-admin"
    ROLE_KIND="ClusterRole"
fi

# =========[ 5. Create RoleBinding or ClusterRoleBinding ]=========
BIND_NAME="${USER}-binding"

if [[ "$ROLE_KIND" == "Role" ]]; then
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BIND_NAME}
  namespace: ${NAMESPACE}
subjects:
- kind: User
  name: ${USER}
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
  name: ${USER}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ${ROLE_NAME}
  apiGroup: rbac.authorization.k8s.io
EOF
fi

echo "[+] Role/Binding created for user: $USER"

# =========[ 6. Create kubeconfig for the user ]=========
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

cat <<EOF > $TMP_DIR/$USER.kubeconfig
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
    user: ${USER}
  name: ${USER}@${CLUSTER_NAME}
current-context: ${USER}@${CLUSTER_NAME}
users:
- name: ${USER}
  user:
    client-certificate-data: $(base64 -w 0 $TMP_DIR/${USER}.crt)
    client-key-data: $(base64 -w 0 $TMP_DIR/${USER}.key)
EOF

echo "[✅] User kubeconfig ready: $TMP_DIR/$USER.kubeconfig"
echo "[✔] All done for user: $USER (group: $GROUP, role: $ROLE)"
```

---

## 🧭 نحوه استفاده

### 🔹 ایجاد کاربر فقط‌خواندنی (readonly)

```bash
sudo ./create-k8s-user.sh anisa dev-team readonly dev
```

### 🔹 ایجاد کاربر با سطح ویرایش (edit)

```bash
sudo ./create-k8s-user.sh majid backend edit staging
```

### 🔹 ایجاد کاربر ادمین کامل

```bash
sudo ./create-k8s-user.sh admin1 ops cluster-admin
```

---

## 💡 نتیجه اجرای هر بار:

در مسیر `/tmp/k8s-users/<username>/` این فایل‌ها ساخته می‌شن:

| فایل                | توضیح                         |
| ------------------- | ----------------------------- |
| `<user>.key`        | کلید خصوصی                    |
| `<user>.csr`        | درخواست گواهی                 |
| `<user>.crt`        | گواهی امضاشده توسط Kubernetes |
| `<user>.kubeconfig` | فایل اتصال آماده برای kubectl |
| `<user>-csr.yaml`   | YAML مربوط به CSR             |

---

## 🧠 نکته مهم امنیتی

* فقط کاربرانی که CA (در مسیر `/etc/kubernetes/pki/ca.key`) در دسترسشونه می‌تونن این اسکریپت رو اجرا کنن.
* این اسکریپت مخصوص ادمین‌های Kubernetes هست (نه کاربران معمولی).

---

می‌خوای نسخه‌ی دومش رو هم بنویسم که بتونه **از فایل CSV یا YAML لیست کاربران بخونه** (مثلاً ۱۰ نفر با گروه‌ها و نقش‌های مختلف رو هم‌زمان بسازه)؟
این برای محیط سازمانی خیلی کاربردیه.
