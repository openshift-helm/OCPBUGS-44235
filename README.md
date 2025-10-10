# OCPBUGS-44235 - Helm CA Certificate Bug Reproduction

## Bug Description

When CA certificates are configured on `HelmChartRepository` or `ProjectHelmChartRepository`, Helm chart installation fails with:
```
error locating chart: open /.cache/helm/repository/<hash>-index.yaml: no such file or directory
```

**Affected Versions:** OCP 4.14, 4.15, 4.16+

---

## Quick Reproduction Steps

### 1. Set Up Test HTTPS Helm Repository

Create any HTTPS Helm repository with a self-signed certificate. Example:

```bash
# On a server (Ubuntu/Debian):
sudo apt-get install -y nginx

# Generate self-signed cert
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/helm-repo.key \
  -out /etc/ssl/certs/helm-repo.crt \
  -subj "/CN=your-domain.com"

# Configure nginx for HTTPS
# Create Helm repository with index.yaml and chart files
# Restart nginx
```

### 2. Configure On OpenShift Cluster

```bash
# Create namespace
oc create namespace helm-lab

# Create CA certificate ConfigMap
# Extract CA from your HTTPS server:
openssl s_client -connect your-domain.com:443 -showcerts </dev/null 2>/dev/null | \
  openssl x509 -outform PEM > ca-cert.crt

# Create ConfigMap
oc create configmap charts-ca -n helm-lab --from-file=ca-bundle.crt=ca-cert.crt

# Create ProjectHelmChartRepository with CA
cat <<EOF | oc apply -f -
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: test-repo
  namespace: helm-lab
spec:
  name: Test Repo
  connectionConfig:
    url: https://your-domain.com/
    ca:
      name: charts-ca
EOF
```

### 3. Reproduce Bug in Console UI

1. Open OpenShift Console
2. Switch to **Developer** perspective
3. Select namespace: **helm-lab**
4. Go to: **+Add** → **Helm Chart**
5. **Browse works** ✅ - You see charts from "Test Repo"
6. **Click on any chart** → **Bug appears** ❌

**Error:**
```
The Helm Chart is currently unavailable. r: Failed to retrieve chart: 
error locating chart: looks like "https://..." is not a valid chart 
repository or cannot be reached: open /.cache/helm/repository/...
no such file or directory
```

### 4. Verify Helm CLI Works (Comparison)

```bash
helm repo add test https://your-domain.com/ --ca-file ca-cert.crt
helm install demo test/chart-name -n helm-lab
# ✅ Works - CLI creates cache before installing
```

---

## Root Cause

The console code sets `chartPathOptions.RepoURL` when CA is configured. This forces Helm into repository mode, which requires cache at `$HOME/.cache/helm/repository/`.

Console pods have:
- `HOME=/` (read-only root filesystem)
- No `HELM_CACHE_HOME` environment variable
- No repository cache (console never runs `helm repo add`)

Result: Helm cannot find/create cache → installation fails.

---

## The Fix

**File:** `pkg/helm/actions/auth.go` (2 places)

Remove the `RepoURL` assignment:
```diff
  if connectionConfig.CA != (configv1.ConfigMapNameReference{}) {
-     chartPathOptions.RepoURL = connectionConfig.URL
      caFile, err := setupCaCertFile(...)
      chartPathOptions.CaFile = caFile.Name()
  }
```

**Files:** `get_chart.go`, `install_chart.go`, `upgrade_release.go` (5 places total)

Always use full URL:
```diff
- if len(tlsFiles) == 0 {
-     chartLocation = url
- } else {
-     chartLocation = chartInfo.Name
- }
+ chartLocation = url
```

**Result:** Helm uses direct download mode with CA verification, no cache needed.

---

## Local Reproduction (For Developers)

The bug can be reproduced locally using the script in the console repository:

```bash
# In console repository (checkout https://github.com/martinszuc/console/commits/ocpbugs-44235-reproduction/)
git checkout ocpbugs-44235-reproduction

# Run bridge with constrained environment
./run-bridge-readonly-home.sh

# Test at http://localhost:9000
```

**Critical:** The script does NOT set `HELM_CACHE_HOME` or `HELM_CONFIG_HOME` - this is required to reproduce the bug!

---

## Files

- This repository: Documentation and test server setup instructions
- Console repository (`ocpbugs-44235-reproduction` branch): Fix + reproduction script

---

## Status

- ✅ Bug reproduced on OCP 4.16.49
- ✅ Bug reproduced locally with read-only HOME
- ✅ Fix implemented and verified working
- ✅ Ready for PR to openshift/console
