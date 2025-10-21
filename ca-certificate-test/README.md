# OCPBUGS-44235 - Helm CA Certificate Bug Reproduction

## Bug Description

Helm chart installation fails when CA certificates or client TLS certificates are configured on `HelmChartRepository` or `ProjectHelmChartRepository`:

```
error locating chart: open /.cache/helm/repository/<hash>-index.yaml: no such file or directory
```

Browsing charts works. Installing fails.

**Affected:** OCP 4.14, 4.15, 4.16+

---

## Manual Reproduction Steps

### 1. Create HTTPS Helm Repository

On a server (Debian/Ubuntu):

```bash
# Install nginx
sudo apt-get install -y nginx

# Generate self-signed certificate
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/helm-repo.key \
  -out /etc/ssl/certs/helm-repo.crt \
  -subj "/CN=your-domain.com"

# Configure nginx for HTTPS
sudo tee /etc/nginx/sites-available/helm-repo <<'EOF'
server {
    listen 443 ssl;
    server_name your-domain.com;
    ssl_certificate /etc/ssl/certs/helm-repo.crt;
    ssl_certificate_key /etc/ssl/private/helm-repo.key;
    root /var/www/helm;
    location / {
        autoindex on;
    }
}
EOF

sudo ln -s /etc/nginx/sites-available/helm-repo /etc/nginx/sites-enabled/
sudo mkdir -p /var/www/helm
sudo nginx -t && sudo systemctl reload nginx
```

### 2. Create and Publish Helm Chart

```bash
# Create chart
helm create hello-helm

# Package chart
helm package hello-helm

# Generate repository index
helm repo index . --url https://your-domain.com/

# Publish to nginx
sudo mv hello-helm-*.tgz index.yaml /var/www/helm/
```

### 3. Configure on OpenShift

```bash
# Extract CA certificate from server
openssl s_client -connect your-domain.com:443 -showcerts </dev/null 2>/dev/null | \
  openssl x509 -outform PEM > ca-cert.crt

# Create namespace
oc create namespace helm-lab

# Create CA ConfigMap
oc create configmap charts-ca -n helm-lab --from-file=ca-bundle.crt=ca-cert.crt

# Create Helm repository with CA
cat <<EOF | oc apply -f -
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-repo
  namespace: helm-lab
spec:
  connectionConfig:
    url: https://your-domain.com/
    ca:
      name: charts-ca
EOF
```

### 4. Reproduce Bug

**In Console UI:**
1. Developer → Project: helm-lab → +Add → Helm Chart
2. Browse works (charts visible)
3. Click on chart → Error appears

**Via Helm CLI (for comparison):**
```bash
helm repo add test https://your-domain.com/ --ca-file ca-cert.crt
helm install demo test/hello-helm -n helm-lab
# Works correctly
```

---

## Root Cause

Console uses Kubernetes CRDs to store repository configuration, not Helm's repository cache. Setting `chartPathOptions.RepoURL` during authentication forced Helm to look for `$HOME/.cache/helm/repository/` which doesn't exist in read-only pod filesystems.

---

## Additional Resources

- Automated setup script: `verify-helm-ca-bug.sh` (requires EC2 instance)
- Issue: https://issues.redhat.com/browse/OCPBUGS-44235
