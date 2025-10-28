#!/bin/bash
# Setup HTTPS Helm repository with Basic Authentication for testing RFE-7965
# Usage: ./setup-basic-auth-repo.sh [IP_ADDRESS]

set -e

EC2_IP="${1:-$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)}"
HELM_USER="helmuser"
HELM_PASS="HelmPass123!"
REPO_DIR="/var/www/helm-basic-auth"
CA_CERT_FILE="/tmp/helm-ca-cert.pem"

echo "Setting up Helm repository: ${EC2_IP}"

# Install dependencies
sudo apt-get update -qq
sudo apt-get install -y nginx apache2-utils openssl curl

# Create basic auth credentials
sudo mkdir -p /etc/nginx/auth
sudo htpasswd -bc /etc/nginx/auth/helm.htpasswd "${HELM_USER}" "${HELM_PASS}"

# Generate SSL certificate with IP SAN
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/helm-repo.key \
  -out /etc/ssl/certs/helm-repo.crt \
  -subj "/CN=${EC2_IP}/O=Helm Testing/C=US" \
  -addext "subjectAltName=IP:${EC2_IP}"

# Configure nginx
sudo tee /etc/nginx/sites-available/helm-basic-auth <<EOF > /dev/null
server {
    listen 443 ssl;
    server_name ${EC2_IP};
    ssl_certificate /etc/ssl/certs/helm-repo.crt;
    ssl_certificate_key /etc/ssl/private/helm-repo.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    auth_basic "Helm Repository";
    auth_basic_user_file /etc/nginx/auth/helm.htpasswd;
    root ${REPO_DIR};
    location / { autoindex on; }
    location /health { auth_basic off; return 200 "OK\n"; }
}
server {
    listen 80;
    server_name ${EC2_IP};
    auth_basic "Helm Repository";
    auth_basic_user_file /etc/nginx/auth/helm.htpasswd;
    root ${REPO_DIR};
    location / { autoindex on; }
}
EOF

sudo ln -sf /etc/nginx/sites-available/helm-basic-auth /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo mkdir -p ${REPO_DIR}
sudo nginx -t && sudo systemctl reload nginx

# Install Helm if needed
if ! command -v helm &> /dev/null; then
    curl -s https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Create and publish sample charts
cd /tmp
for chart in hello-world nginx-demo redis-test; do
    helm create ${chart} 2>/dev/null || true
    cat > ${chart}/Chart.yaml <<EOF
apiVersion: v2
name: ${chart}
description: Test chart for RFE-7965 (${chart})
type: application
version: 1.0.0
appVersion: "1.0"
EOF
    helm package ${chart} >/dev/null
done

helm repo index . --url "https://${EC2_IP}/"
sudo mv *.tgz index.yaml ${REPO_DIR}/
sudo chmod -R 755 ${REPO_DIR}

# Extract CA certificate
sudo cp /etc/ssl/certs/helm-repo.crt ${CA_CERT_FILE}
sudo chmod 644 ${CA_CERT_FILE}

# Test repository
echo -n "Testing without auth: "
curl -s -k -o /dev/null -w "%{http_code}" "https://${EC2_IP}/" | grep -q "401" && echo "✅ 401" || echo "❌"

echo -n "Testing with auth: "
curl -s -k -u "${HELM_USER}:${HELM_PASS}" -o /dev/null -w "%{http_code}" "https://${EC2_IP}/" | grep -q "200" && echo "✅ 200" || echo "❌"

# Generate OpenShift configuration
cat > /tmp/openshift-helm-basic-auth-setup.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: helm-basic-auth-test
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: helm-repo-ca
  namespace: helm-basic-auth-test
data:
  ca-bundle.crt: |
$(sudo sed 's/^/    /' ${CA_CERT_FILE})
---
apiVersion: v1
kind: Secret
metadata:
  name: helm-basic-auth
  namespace: helm-basic-auth-test
type: Opaque
stringData:
  username: ${HELM_USER}
  password: ${HELM_PASS}
---
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: secure-helm-repo
  namespace: helm-basic-auth-test
spec:
  name: "Secure Helm Repository (Basic Auth + HTTPS)"
  description: "Test repository for RFE-7965"
  connectionConfig:
    url: https://${EC2_IP}/
    ca:
      name: helm-repo-ca
    basicAuthConfig:
      name: helm-basic-auth
---
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: insecure-http-repo
  namespace: helm-basic-auth-test
spec:
  name: "HTTP Repository (Should Fail Validation)"
  description: "Test HTTP + basic auth validation"
  disabled: true
  connectionConfig:
    url: http://${EC2_IP}/
    basicAuthConfig:
      name: helm-basic-auth
EOF

# Summary
echo ""
echo "Setup complete!"
echo "  Repository: https://${EC2_IP}/"
echo "  Username: ${HELM_USER}"
echo "  Password: ${HELM_PASS}"
echo ""
echo "Next: oc apply -f /tmp/openshift-helm-basic-auth-setup.yaml"
echo ""
