# Basic Auth UI Feature Testing - RFE-7965

HTTPS Helm repository with Basic Authentication for testing ProjectHelmChartRepository UI.

## Setup

Run on EC2 instance (Ubuntu/Debian):

```bash
cd basic-auth-test
./setup-basic-auth-repo.sh <EC2_PUBLIC_IP>
```

Script creates:
- HTTPS nginx server with self-signed cert
- HTTP Basic Auth (username: `helmuser`, password: `HelmPass123!`)
- Sample Helm charts
- OpenShift YAML: `/tmp/openshift-helm-basic-auth-setup.yaml`

## Apply to OpenShift

```bash
oc apply -f /tmp/openshift-helm-basic-auth-setup.yaml
```

## Test

Console UI → Helm → Create ProjectHelmChartRepository:
- Set URL to `https://<EC2_IP>/`
- Select CA cert and basic auth secret
- Try HTTP + basic auth → should show validation error

**Issue:** https://issues.redhat.com/browse/RFE-7965
