#!/bin/bash
# setup-basic-auth-repo.sh
# Sets up an HTTPS Helm repository with Basic Authentication for testing RFE-7965
# Usage: ./setup-basic-auth-repo.sh [DOMAIN_OR_IP]

set -e

DOMAIN="${1:-$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)}"
HELM_USER="helmuser"
HELM_PASS="HelmPass123!"
REPO_DIR="/var/www/helm-basic-auth"

echo "🔧 Setting up HTTPS Helm Repository with Basic Auth"
echo "📍 Domain/IP: ${DOMAIN}"
echo "👤 Username: ${HELM_USER}"
echo "🔑 Password: ${HELM_PASS}"
echo ""

# ============================================
# 1. Install required packages
# ============================================
echo "📦 Installing nginx and apache2-utils..."
sudo apt-get update -qq
sudo apt-get install -y nginx apache2-utils openssl curl

# ============================================
# 2. Create htpasswd file for basic auth
# ============================================
echo "🔐 Creating basic auth credentials..."
sudo mkdir -p /etc/nginx/auth
sudo htpasswd -bc /etc/nginx/auth/helm.htpasswd "${HELM_USER}" "${HELM_PASS}"
echo "✅ Basic auth file created at /etc/nginx/auth/helm.htpasswd"

# ============================================
# 3. Generate self-signed SSL certificate
# ============================================
echo "🔒 Generating self-signed SSL certificate..."
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/helm-repo.key \
  -out /etc/ssl/certs/helm-repo.crt \
  -subj "/CN=${DOMAIN}/O=Helm Testing/C=US"

echo "✅ SSL certificate created"

# ============================================
# 4. Configure nginx with HTTPS + Basic Auth
# ============================================
echo "⚙️  Configuring nginx..."
sudo tee /etc/nginx/sites-available/helm-basic-auth <<EOF
server {
    listen 443 ssl;
    server_name ${DOMAIN};
    
    # SSL Configuration
    ssl_certificate /etc/ssl/certs/helm-repo.crt;
    ssl_certificate_key /etc/ssl/private/helm-repo.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    
    # Basic Authentication
    auth_basic "Helm Repository";
    auth_basic_user_file /etc/nginx/auth/helm.htpasswd;
    
    # Repository Root
    root ${REPO_DIR};
    
    location / {
        autoindex on;
        add_header Content-Type text/plain;
    }
    
    # Health check endpoint (no auth required)
    location /health {
        auth_basic off;
        return 200 "OK\n";
        add_header Content-Type text/plain;
    }
}

# HTTP server - for testing validation (should fail with basic auth)
server {
    listen 80;
    server_name ${DOMAIN};
    
    # Basic Authentication (INSECURE - for testing validation)
    auth_basic "Helm Repository (HTTP - INSECURE)";
    auth_basic_user_file /etc/nginx/auth/helm.htpasswd;
    
    root ${REPO_DIR};
    
    location / {
        autoindex on;
    }
}
EOF

# Enable the site
sudo ln -sf /etc/nginx/sites-available/helm-basic-auth /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Create repository directory
sudo mkdir -p ${REPO_DIR}

# Test nginx configuration
sudo nginx -t

# Reload nginx
sudo systemctl reload nginx

echo "✅ Nginx configured and reloaded"

# ============================================
# 5. Create and publish sample Helm charts
# ============================================
echo "📊 Creating sample Helm charts..."

# Install Helm if not present
if ! command -v helm &> /dev/null; then
    echo "📥 Installing Helm..."
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

cd /tmp

# Create multiple test charts
for chart_name in hello-world nginx-demo redis-test; do
    echo "  Creating ${chart_name}..."
    helm create ${chart_name} 2>/dev/null || true
    
    # Customize chart
    cat > ${chart_name}/Chart.yaml <<CHARTEOF
apiVersion: v2
name: ${chart_name}
description: Test chart for basic auth (${chart_name})
type: application
version: 1.0.0
appVersion: "1.0"
CHARTEOF
    
    # Package chart
    helm package ${chart_name}
done

# Generate repository index
helm repo index . --url "https://${DOMAIN}/"

# Move charts to nginx directory
sudo mv *.tgz index.yaml ${REPO_DIR}/
sudo chmod -R 755 ${REPO_DIR}

echo "✅ Helm charts published"

# ============================================
# 6. Extract CA certificate for OpenShift
# ============================================
echo "📜 Extracting CA certificate..."
CA_CERT_FILE="/tmp/helm-ca-cert.pem"
sudo cp /etc/ssl/certs/helm-repo.crt ${CA_CERT_FILE}
sudo chmod 644 ${CA_CERT_FILE}

echo "✅ CA certificate saved to: ${CA_CERT_FILE}"

# ============================================
# 7. Test the repository
# ============================================
echo ""
echo "🧪 Testing repository access..."

# Test without auth (should fail)
echo -n "  Testing without auth (should fail 401): "
if curl -s -k -o /dev/null -w "%{http_code}" "https://${DOMAIN}/" | grep -q "401"; then
    echo "✅ PASS"
else
    echo "❌ FAIL"
fi

# Test with auth (should succeed)
echo -n "  Testing with auth (should succeed 200): "
if curl -s -k -u "${HELM_USER}:${HELM_PASS}" -o /dev/null -w "%{http_code}" "https://${DOMAIN}/" | grep -q "200"; then
    echo "✅ PASS"
else
    echo "❌ FAIL"
fi

# Test HTTP with auth (insecure but should work)
echo -n "  Testing HTTP with auth (should work but insecure): "
if curl -s -u "${HELM_USER}:${HELM_PASS}" -o /dev/null -w "%{http_code}" "http://${DOMAIN}/" | grep -q "200"; then
    echo "✅ PASS (but should be blocked by Console validation)"
else
    echo "❌ FAIL"
fi

# ============================================
# 8. Generate OpenShift configuration
# ============================================
echo ""
echo "📋 Generating OpenShift configuration files..."

# Create namespace and resources YAML
cat > /tmp/openshift-helm-basic-auth-setup.yaml <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: helm-basic-auth-test

---
# ConfigMap with CA certificate
apiVersion: v1
kind: ConfigMap
metadata:
  name: helm-repo-ca
  namespace: helm-basic-auth-test
data:
  ca-bundle.crt: |
$(sudo sed 's/^/    /' ${CA_CERT_FILE})

---
# Secret with basic auth credentials
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
# ProjectHelmChartRepository with Basic Auth + CA
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: secure-helm-repo
  namespace: helm-basic-auth-test
spec:
  name: "Secure Helm Repository (Basic Auth + HTTPS)"
  description: "Test repository with basic authentication and custom CA for RFE-7965"
  connectionConfig:
    url: https://${DOMAIN}/
    ca:
      name: helm-repo-ca
    basicAuthConfig:
      name: helm-basic-auth

---
# Test: HTTP with Basic Auth (should be rejected by validation)
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: insecure-http-repo
  namespace: helm-basic-auth-test
spec:
  name: "HTTP Helm Repository (Should Fail Validation)"
  description: "This should fail validation - HTTP with basic auth is insecure"
  disabled: true
  connectionConfig:
    url: http://${DOMAIN}/
    basicAuthConfig:
      name: helm-basic-auth
EOF

echo "✅ Configuration saved to: /tmp/openshift-helm-basic-auth-setup.yaml"

# ============================================
# 9. Output summary
# ============================================
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ SETUP COMPLETE!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "📍 Repository URL (HTTPS): https://${DOMAIN}/"
echo "📍 Repository URL (HTTP):  http://${DOMAIN}/"
echo "👤 Username: ${HELM_USER}"
echo "🔑 Password: ${HELM_PASS}"
echo ""
echo "📂 Published Charts:"
curl -s -k -u "${HELM_USER}:${HELM_PASS}" "https://${DOMAIN}/index.yaml" | grep -E "^\s+name:" | awk '{print "   - " $2}'
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "🚀 NEXT STEPS - Apply to OpenShift:"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "1. Apply the configuration to your cluster:"
echo "   oc apply -f /tmp/openshift-helm-basic-auth-setup.yaml"
echo ""
echo "2. Test in Console UI:"
echo "   - Navigate to: Developer → +Add → Helm Chart"
echo "   - Select project: helm-basic-auth-test"
echo "   - You should see charts from 'Secure Helm Repository'"
echo "   - Try to install a chart"
echo ""
echo "3. Test the validation (HTTP + Basic Auth should fail):"
echo "   - Try to create 'insecure-http-repo'"
echo "   - Console should show validation error"
echo ""
echo "4. Test via CLI:"
echo "   helm repo add secure https://${DOMAIN}/ \\"
echo "     --ca-file ${CA_CERT_FILE} \\"
echo "     --username ${HELM_USER} \\"
echo "     --password ${HELM_PASS}"
echo "   helm search repo secure/"
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "📝 Files created:"
echo "════════════════════════════════════════════════════════════════"
echo "  • CA Certificate: ${CA_CERT_FILE}"
echo "  • OpenShift Config: /tmp/openshift-helm-basic-auth-setup.yaml"
echo "  • Nginx Config: /etc/nginx/sites-available/helm-basic-auth"
echo "  • Auth File: /etc/nginx/auth/helm.htpasswd"
echo ""
echo "🔍 Quick Tests:"
echo "  • curl -k https://${DOMAIN}/               # Should fail (401)"
echo "  • curl -k -u ${HELM_USER}:${HELM_PASS} https://${DOMAIN}/  # Should work"
echo "  • curl https://${DOMAIN}/health            # Health check (no auth)"
echo ""

