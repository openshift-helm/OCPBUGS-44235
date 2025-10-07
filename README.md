# OCPBUGS-44235 - Helm CA Certificate Bug Verification

OpenShift Helm + custom CA (UI install failure) — Automated Reproduction

## What We Prove

* ✅ Browse (UI) lists charts
* ❌ Create (UI) fails with `.../.cache/helm/repository/<hash>-index.yaml: no such file or directory`
* ✅ CLI install succeeds

**The Bug:** When configuring CA certificates to ProjectHelmChartRepository, console UI browse works but install fails. CLI works correctly with the same CA.

---

## Quick Start (Automated Script)

Since the AWS machine gets deleted daily, use this script for fast setup.

### Prerequisites

1. **Place SSH key in script directory:**
   ```bash
   cp ~/Downloads/helm-test-2.pem ./
   chmod 600 ./helm-test-2.pem
   ```

2. **Setup DNS resolution** (choose one):
   - **Option A:** If you control DNS, add A record: `44235.muthukadan.net` → `<EC2_IP>`
   - **Option B:** Add to `/etc/hosts`:
     ```bash
     sudo sh -c 'echo "13.51.173.182 44235.muthukadan.net" >> /etc/hosts'
     ```

3. **Login to OpenShift:**
   ```bash
   oc login https://<your-ocp-api>:443
   ```

### Daily Usage (When AWS Recreates Machine)

```bash
# 1. Update EC2_IP in verify-helm-ca-bug.sh (line 27)
sed -i.bak 's/^EC2_IP=.*/EC2_IP="NEW_IP_HERE"/' verify-helm-ca-bug.sh

# 2. Update DNS/hosts entry if IP changed

# 3. Run full automated reproduction
./verify-helm-ca-bug.sh full
```

### Script Commands

```bash
./verify-helm-ca-bug.sh help          # Show all commands
./verify-helm-ca-bug.sh full          # Run full reproduction (sections 1-5)
./verify-helm-ca-bug.sh ec2           # Setup EC2 nginx + certificate
./verify-helm-ca-bug.sh chart         # Create and publish chart
./verify-helm-ca-bug.sh ocp           # Setup OpenShift repo with CA
./verify-helm-ca-bug.sh ui            # Show UI testing instructions
./verify-helm-ca-bug.sh cli           # Verify CLI works
./verify-helm-ca-bug.sh logs          # Check console logs for debugging
./verify-helm-ca-bug.sh cleanup       # Remove demo resources
./verify-helm-ca-bug.sh full-cleanup  # Remove all resources including namespace
```

### Configuration

All files are self-contained in the script directory:

```
OCPBUGS-44235/
├── verify-helm-ca-bug.sh      # Main automation script
├── helm-test-2.pem            # SSH key (REQUIRED - place here)
├── charts-ca-bundle.crt       # Generated CA bundle
└── work/                      # Generated work directory
```

- **Domain:** `44235.muthukadan.net`
- **EC2 User:** `admin`
- **OpenShift Namespace:** `helm-lab`

---

## Manual Steps Reference

These are the official reproduction steps from the OCPBUGS-44235 issue. The script automates most of these, but they're preserved here for reference.

### Assumptions / Placeholders

* Domain: `44235.muthukadan.net` (was `charts.openshift-helm-cli-testing-1.com`)
* EC2 SSH: key file `helm-test-2.pem` in script directory
* EC2 user: `admin` (Debian)
* OpenShift project: `helm-lab`

If you lose your OpenShift cluster, just re-run Section 3. Your CA bundle source remains the same PEM on EC2.

---

### 1) EC2 (Debian) — HTTPS repo with a self-signed cert

Run on EC2 (`admin@ip-…$`). This only needs to be done once per EC2 host.

```bash
# Install and start nginx + openssl
sudo apt-get update -y
sudo apt-get install -y nginx openssl
sudo systemctl enable --now nginx

# Create a self-signed cert for your exact host
cat > ~/openssl.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = 44235.muthukadan.net
[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = 44235.muthukadan.net
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout ~/charts.key -out ~/charts.crt -config ~/openssl.cnf

# Install cert/key for nginx
sudo install -m 600 ~/charts.key /etc/ssl/private/charts.key
sudo install -m 644 ~/charts.crt /etc/ssl/certs/charts.crt

# Nginx site serving a static Helm repo directory (/var/www/charts)
sudo mkdir -p /var/www/charts
sudo tee /etc/nginx/sites-available/charts >/dev/null <<'NGINX'
server {
  listen 443 ssl;
  server_name 44235.muthukadan.net;

  ssl_certificate     /etc/ssl/certs/charts.crt;
  ssl_certificate_key /etc/ssl/private/charts.key;

  root /var/www/charts;
  autoindex on;
}
NGINX

sudo ln -sf /etc/nginx/sites-available/charts /etc/nginx/sites-enabled/charts
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx

# Quick check (200 OK expected; -k ignores self-signed)
curl -Ik https://44235.muthukadan.net/ -k
```

**Where the CA "bundle" lives (server side):**
* Original PEM you generated: `~/charts.crt`
* Nginx copy: `/etc/ssl/certs/charts.crt`

You'll use this PEM as the CA bundle in OpenShift (uploaded into a ConfigMap).

---

### 2) Laptop (Fedora/macOS) — Package a minimal chart & publish to EC2

Run on your laptop (`mszuc@fedora$`).

```bash
# Create and package a tiny chart
mkdir -p /tmp/helm-lab && cd /tmp/helm-lab
helm create hello-helm
rm -rf hello-helm/templates/tests
helm package hello-helm                      # produces hello-helm-0.1.0.tgz

# Build the repo index pointing to your HTTPS host
mkdir repo && mv hello-helm-*.tgz repo/
helm repo index repo --url https://44235.muthukadan.net/

# Upload both index.yaml and the chart .tgz to EC2 (home dir)
scp -i ./helm-test-2.pem repo/* \
  admin@44235.muthukadan.net:
```

**Back on EC2 (publish files into the web root):**

```bash
sudo cp ~/index.yaml ~/hello-helm-0.1.0.tgz /var/www/charts/
ls -l /var/www/charts/

# Verify from anywhere (-k ignores self-signed)
curl -s https://44235.muthukadan.net/index.yaml -k | head
curl -I  https://44235.muthukadan.net/hello-helm-0.1.0.tgz -k
```

You should see an `entries.hello-helm[0].urls:` pointing to your `.tgz`, and `HTTP/1.1 200 OK`.

---

### 3) Laptop — OpenShift: add CA bundle & register repo (to trigger bug)

Run on your laptop (not EC2).

```bash
# Copy the server cert (the CA "bundle") down to your laptop
scp -i ./helm-test-2.pem \
  admin@44235.muthukadan.net:~/charts.crt \
  ./charts-ca-bundle.crt

# Log in & create a fresh project (repeatable on any new cluster)
oc login https://<your-ocp-api>:443
oc new-project helm-lab || oc project helm-lab

# Create the CA ConfigMap (KEY MUST BE 'ca-bundle.crt')
oc -n helm-lab create configmap charts-ca \
  --from-file=ca-bundle.crt=./charts-ca-bundle.crt
oc -n helm-lab get cm charts-ca -o yaml | grep -A2 ca-bundle.crt

# Create the namespace-scoped Helm repo CR that references this CA
cat > repo-with-ca.yaml <<'YAML'
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: lab-repo
  namespace: helm-lab
spec:
  name: Lab Repo
  connectionConfig:
    url: https://44235.muthukadan.net/
    ca:
      name: charts-ca
YAML

oc apply -f repo-with-ca.yaml
```

**Where the CA "bundle" lives (cluster side):**
* ConfigMap/`charts-ca` in namespace `helm-lab`
* Key: `ca-bundle.crt`
* Recreate this ConfigMap on any new cluster from your saved `charts.crt`.

---

### 4) Web console — Reproduce the issue (UI)

* Developer → Helm → Browse → you should see **Lab Repo** and **hello-helm**.
* Click the chart → **Create** → expect the red banner:

```
The Helm Chart is currently unavailable.
r: Failed to retrieve chart: error locating chart:
looks like "https://44235.muthukadan.net/" is not a valid chart repository
or cannot be reached: open /.cache/helm/repository/<hash>-index.yaml: no such file or directory
```

**This is the known console bug (UI browse OK / install FAIL when `ca:` is set).**

**(Optional: quick log evidence)**

```bash
oc -n openshift-console logs deploy/console | \
  grep -i -E 'helm|repo|index.yaml|cache|x509|tls' | tail -n 200
```

---

### 5) Control — Prove CLI works (same repo + CA)

Run on your laptop; this installs in the cluster, not locally.

```bash
helm repo add lab https://44235.muthukadan.net/ \
  --ca-file ./charts-ca-bundle.crt
helm repo update
helm search repo lab -l             # should show hello-helm 0.1.0
helm install demo lab/hello-helm -n helm-lab
helm list -n helm-lab               # STATUS: deployed
oc -n helm-lab get deploy,svc,pods  # see demo-hello-helm resources
```

**To remove the sample release:**

```bash
helm uninstall demo -n helm-lab
```

---

### 6) Reset / Replay

**Minimal reset (keep repo CR/CA; just remove release):**

```bash
helm uninstall demo -n helm-lab
```

**Full cluster reset (so you can demo from scratch on any cluster):**

```bash
oc -n helm-lab delete projecthelmchartrepository lab-repo --ignore-not-found
oc -n helm-lab delete configmap charts-ca --ignore-not-found
# Optional: delete the whole project
# oc delete project helm-lab
```

---

## Summary

The script automates ~90% of these steps. Only manual actions required:

1. ⚠️ Place SSH key in script directory
2. ⚠️ Configure DNS/hosts entry
3. ⚠️ Login to OpenShift
4. ⚠️ Update EC2_IP when AWS recreates machine
5. ⚠️ Click "Create" in web console UI to observe the bug

Everything else is automated by `./verify-helm-ca-bug.sh full`
