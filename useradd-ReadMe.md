عالی ✅ — اینم یک **README.md کاملاً آماده و حرفه‌ای** برای GitHub که می‌تونی مستقیم در کنار اسکریپتت (`create-k8s-users.sh`) بذاری.
با Markdown تمیز، توضیح کامل، مثال‌ها، و ساختار زیبا.

---

## 📄 File: `README.md`

````markdown
# 🚀 Kubernetes User Provisioning Script

[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.28+-blue.svg)](https://kubernetes.io)
[![Shell Script](https://img.shields.io/badge/Made%20with-Bash-lightgrey.svg)](https://www.gnu.org/software/bash/)
[![Automation](https://img.shields.io/badge/Automation-DevOps-orange.svg)]()

---

### 🧭 Overview

This script automates the **creation and management of Kubernetes users** using the native Certificate Signing Request (CSR) workflow.  
It allows you to easily generate users, sign their certificates, apply RBAC roles, and produce ready-to-use `kubeconfig` files.

Perfect for DevOps teams managing multi-tenant Kubernetes clusters.

---

### ⚙️ Features

- ✅ Generate private keys and CSRs automatically  
- ✅ Approve and retrieve signed certificates via Kubernetes API  
- ✅ Create and bind **Role** or **ClusterRole** permissions  
- ✅ Build individual **kubeconfig** files for each user  
- ✅ Support for **bulk user creation** from a CSV file  
- ✅ Clean structure & portable — works with any Kubernetes admin node  

---

### 🧩 Requirements

- Linux host with admin access to your Kubernetes cluster  
- `kubectl` configured with cluster-admin privileges  
- `openssl` installed  
- Access to CA certificate (default: `/etc/kubernetes/pki/ca.crt`)

---

### 📦 Installation

Clone the repository:

```bash
git clone https://github.com/<your-username>/k8s-user-management.git
cd k8s-user-management
chmod +x create-k8s-users.sh
````

---

### 🚀 Usage

#### 🔹 Single User Mode

```bash
sudo ./create-k8s-users.sh <username> <group> <role> <namespace>
```

Example:

```bash
sudo ./create-k8s-users.sh anisa dev-team readonly dev
```

#### 🔹 Bulk Mode (CSV)

Prepare a `users.csv` file:

```csv
# username,group,role,namespace
anisa,dev-team,readonly,dev
majid,backend,edit,staging
alex,ops,cluster-admin,default
```

Then run:

```bash
sudo ./create-k8s-users.sh -f users.csv
```

---

### 📁 Output Structure

Each user gets a dedicated folder under `/tmp/k8s-users/<username>/`:

| File                | Description                        |
| ------------------- | ---------------------------------- |
| `<user>.key`        | Private key                        |
| `<user>.csr`        | Certificate Signing Request        |
| `<user>.crt`        | Signed certificate                 |
| `<user>-csr.yaml`   | CSR manifest applied to Kubernetes |
| `<user>.kubeconfig` | Ready-to-use kubeconfig file       |

You can test the generated kubeconfig like this:

```bash
kubectl --kubeconfig=/tmp/k8s-users/anisa/anisa.kubeconfig get pods -n dev
```

---

### 🧠 RBAC Role Explanation

| Role            | Type        | Description                                                  |
| --------------- | ----------- | ------------------------------------------------------------ |
| `readonly`      | Role        | View-only access within a namespace (`get`, `list`, `watch`) |
| `edit`          | ClusterRole | Edit access across the namespace (includes create/delete)    |
| `cluster-admin` | ClusterRole | Full cluster-wide administrative privileges                  |

---

### 🛠 Example Directory Tree

```
/tmp/k8s-users/
 ├── anisa/
 │   ├── anisa.key
 │   ├── anisa.csr
 │   ├── anisa.crt
 │   ├── anisa-csr.yaml
 │   └── anisa.kubeconfig
 └── majid/
     ├── majid.key
     ├── majid.crt
     └── majid.kubeconfig
```

---

### 🧰 Example: Assign Existing Cluster Role

If you want to assign an existing cluster role manually:

```bash
kubectl create clusterrolebinding myuser-binding \
  --clusterrole=view \
  --user=myuser
```

---

### 🧾 License

MIT License © [Soroush Farzamnik](https://github.com/<your-username>)

---

### 🌟 Contributing

Pull requests are welcome!
If you'd like to improve this script or add support for other authentication methods (like OIDC or ServiceAccounts), feel free to fork and submit your ideas.

---

### 💬 Contact

For questions or feedback, open an issue on GitHub or reach out on LinkedIn.

---

🧡 **Star this repo** if it helped you — and make managing Kubernetes users easier for everyone!

```

---

این دو تا باعث می‌شن GitHub به‌صورت خودکار badge و license info نمایش بده.
```
