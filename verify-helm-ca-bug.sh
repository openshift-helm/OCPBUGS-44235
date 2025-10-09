#!/bin/bash
#
# OCPBUGS-44235 - Helm CA Certificate Bug Verification Script
# 
# This script automates the reproduction of the Helm Chart Repository CA certificate bug
# where console UI install fails but CLI works with self-signed certificates.
#
# Use Case: AWS machine gets deleted daily, so run './verify-helm-ca-bug.sh full' 
# each day to quickly recreate the entire test environment.
#

set -e  # Exit on error

# ============================================================================
# CONFIGURATION - Change these values as needed
# ============================================================================

# Get script directory (all files will be stored here)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Helm repository domain (change this in one place)
CHART_DOMAIN="16-170-141-85.nip.io"

# EC2 connection details
# NOTE: AWS machine gets deleted daily, update EC2_IP each day
EC2_SSH_KEY="${SCRIPT_DIR}/helm-test-2.pem"
EC2_IP="16.170.141.85"
EC2_USER="admin"
EC2_HOST="${EC2_USER}@${EC2_IP}"

# OpenShift configuration
OCP_NAMESPACE="helm-lab"
HELM_REPO_NAME="lab-repo"
CA_CONFIGMAP_NAME="charts-ca"

# Local paths (all in script directory)
LOCAL_WORK_DIR="${SCRIPT_DIR}/work"
LOCAL_CA_FILE="${SCRIPT_DIR}/charts-ca-bundle.crt"

# Chart details
CHART_NAME="hello-helm"
CHART_VERSION="0.1.0"

# ============================================================================
# COLOR OUTPUT
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

section() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

check_prerequisites() {
    section "Checking Prerequisites"
    
    local missing=0
    
    # Check required commands
    for cmd in ssh scp helm oc curl; do
        if ! command -v $cmd &> /dev/null; then
            error "Required command not found: $cmd"
            missing=1
        else
            success "Found: $cmd"
        fi
    done
    
    # Check SSH key
    if [ ! -f "$EC2_SSH_KEY" ]; then
        error "SSH key not found: $EC2_SSH_KEY"
        error "Please place your SSH key at: $EC2_SSH_KEY"
        missing=1
    else
        success "Found SSH key: $EC2_SSH_KEY"
    fi
    
    # Check OpenShift connection
    if ! oc whoami &> /dev/null; then
        error "Not logged into OpenShift. Run: oc login <api-server>"
        missing=1
    else
        success "Logged into OpenShift as: $(oc whoami)"
    fi
    
    # Check DNS resolution
    info "Checking DNS resolution for $CHART_DOMAIN..."
    if ! host "$CHART_DOMAIN" &> /dev/null && ! nslookup "$CHART_DOMAIN" &> /dev/null; then
        warn "DNS resolution check inconclusive for $CHART_DOMAIN"
        warn "Make sure $CHART_DOMAIN resolves to $EC2_IP"
        warn "You may need to update DNS or add to /etc/hosts:"
        warn "  sudo sh -c 'echo \"$EC2_IP $CHART_DOMAIN\" >> /etc/hosts'"
    else
        local resolved_ip=$(host "$CHART_DOMAIN" 2>/dev/null | grep "has address" | awk '{print $4}' | head -n1)
        if [ -n "$resolved_ip" ]; then
            if [ "$resolved_ip" = "$EC2_IP" ]; then
                success "DNS resolves correctly: $CHART_DOMAIN -> $EC2_IP"
            else
                warn "DNS resolves to $resolved_ip (expected: $EC2_IP)"
                warn "You may need to update DNS or add to /etc/hosts:"
                warn "  sudo sh -c 'echo \"$EC2_IP $CHART_DOMAIN\" >> /etc/hosts'"
            fi
        fi
    fi
    
    if [ $missing -eq 1 ]; then
        error "Prerequisites check failed. Please install missing components."
        exit 1
    fi
    
    success "All prerequisites met!"
}

# ============================================================================
# SECTION 1: EC2 SETUP (NGINX + SELF-SIGNED CERT)
# ============================================================================

setup_ec2_nginx() {
    section "Section 1: Setting up HTTPS Helm Repository on EC2"
    
    info "Connecting to EC2: $EC2_HOST"
    
    ssh -i "$EC2_SSH_KEY" "$EC2_HOST" bash <<EOF
set -e

echo "Installing nginx and openssl..."
sudo apt-get update -y
sudo apt-get install -y nginx openssl

echo "Enabling and starting nginx..."
sudo systemctl enable --now nginx

echo "Creating OpenSSL configuration..."
cat > ~/openssl.cnf <<'SSLCONF'
[req]
distinguished_name = dn
x509_extensions = v3_req
prompt = no
[dn]
CN = ${CHART_DOMAIN}
[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = ${CHART_DOMAIN}
SSLCONF

echo "Generating self-signed certificate..."
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \\
  -keyout ~/charts.key -out ~/charts.crt -config ~/openssl.cnf

echo "Installing certificate and key..."
sudo install -m 600 ~/charts.key /etc/ssl/private/charts.key
sudo install -m 644 ~/charts.crt /etc/ssl/certs/charts.crt

echo "Creating web root directory..."
sudo mkdir -p /var/www/charts

echo "Configuring nginx site..."
sudo tee /etc/nginx/sites-available/charts >/dev/null <<'NGINX'
server {
  listen 443 ssl;
  server_name ${CHART_DOMAIN};

  ssl_certificate     /etc/ssl/certs/charts.crt;
  ssl_certificate_key /etc/ssl/private/charts.key;

  root /var/www/charts;
  autoindex on;
}
NGINX

echo "Enabling nginx site..."
sudo ln -sf /etc/nginx/sites-available/charts /etc/nginx/sites-enabled/charts
sudo rm -f /etc/nginx/sites-enabled/default

echo "Testing and reloading nginx..."
sudo nginx -t && sudo systemctl reload nginx

echo "Testing HTTPS endpoint..."
curl -Ik https://${CHART_DOMAIN}/ -k | head -n 1

echo "✓ EC2 nginx setup complete!"
EOF
    
    success "EC2 HTTPS repository is ready!"
}

# ============================================================================
# SECTION 2: CREATE AND PUBLISH HELM CHART
# ============================================================================

create_and_publish_chart() {
    section "Section 2: Creating and Publishing Helm Chart"
    
    info "Creating local work directory: $LOCAL_WORK_DIR"
    rm -rf "$LOCAL_WORK_DIR"
    mkdir -p "$LOCAL_WORK_DIR"
    cd "$LOCAL_WORK_DIR"
    
    info "Creating helm chart: $CHART_NAME"
    helm create "$CHART_NAME"
    rm -rf "${CHART_NAME}/templates/tests"
    
    info "Packaging chart..."
    helm package "$CHART_NAME"
    
    info "Building repository index..."
    mkdir -p repo
    mv "${CHART_NAME}-${CHART_VERSION}.tgz" repo/
    helm repo index repo --url "https://${CHART_DOMAIN}/"
    
    info "Uploading chart and index to EC2..."
    scp -i "$EC2_SSH_KEY" repo/* "$EC2_HOST":
    
    info "Publishing files to web root on EC2..."
    ssh -i "$EC2_SSH_KEY" "$EC2_HOST" bash <<EOF
set -e
sudo cp ~/index.yaml ~/${CHART_NAME}-${CHART_VERSION}.tgz /var/www/charts/
ls -lh /var/www/charts/
EOF
    
    info "Verifying published files..."
    curl -s "https://${CHART_DOMAIN}/index.yaml" -k | head -n 10
    
    success "Chart published successfully!"
    
    info "Leaving work directory for reference..."
    cd - > /dev/null
    success "Chart files saved in: $LOCAL_WORK_DIR"
}

# ============================================================================
# SECTION 3: OPENSHIFT CA BUNDLE & REPO SETUP
# ============================================================================

setup_openshift_repo() {
    section "Section 3: Setting up OpenShift Helm Repository with CA Bundle"
    
    info "Downloading CA certificate from EC2..."
    scp -i "$EC2_SSH_KEY" "${EC2_HOST}:~/charts.crt" "$LOCAL_CA_FILE"
    success "CA certificate saved to: $LOCAL_CA_FILE"
    
    info "Creating/switching to OpenShift namespace: $OCP_NAMESPACE"
    oc new-project "$OCP_NAMESPACE" 2>/dev/null || oc project "$OCP_NAMESPACE"
    
    info "Deleting existing ConfigMap (if any)..."
    oc -n "$OCP_NAMESPACE" delete configmap "$CA_CONFIGMAP_NAME" --ignore-not-found
    
    info "Creating CA bundle ConfigMap..."
    oc -n "$OCP_NAMESPACE" create configmap "$CA_CONFIGMAP_NAME" \
        --from-file=ca-bundle.crt="$LOCAL_CA_FILE"
    
    success "ConfigMap created: $CA_CONFIGMAP_NAME"
    
    info "Verifying ConfigMap..."
    oc -n "$OCP_NAMESPACE" get cm "$CA_CONFIGMAP_NAME" -o yaml | grep -A2 ca-bundle.crt | head -n 5
    
    info "Creating ProjectHelmChartRepository..."
    cat <<YAML | oc apply -f -
apiVersion: helm.openshift.io/v1beta1
kind: ProjectHelmChartRepository
metadata:
  name: ${HELM_REPO_NAME}
  namespace: ${OCP_NAMESPACE}
spec:
  name: Lab Repo
  connectionConfig:
    url: https://${CHART_DOMAIN}/
    ca:
      name: ${CA_CONFIGMAP_NAME}
YAML
    
    success "ProjectHelmChartRepository created: $HELM_REPO_NAME"
    
    info "Waiting for repository to be ready..."
    sleep 5
    
    oc -n "$OCP_NAMESPACE" get projecthelmchartrepository "$HELM_REPO_NAME"
}

# ============================================================================
# SECTION 4: UI TESTING INSTRUCTIONS
# ============================================================================

show_ui_instructions() {
    section "Section 4: Web Console UI Testing (Manual Step)"
    
    echo ""
    echo -e "${BLUE}Now test in the OpenShift Web Console:${NC}"
    echo ""
    echo "1. Navigate to: Developer → Helm → Browse"
    echo "2. You should see 'Lab Repo' and the '${CHART_NAME}' chart ✅"
    echo "3. Click on the chart → Click 'Create'"
    echo ""
    echo -e "${YELLOW}Expected Result (THE BUG):${NC}"
    echo -e "${RED}The Helm Chart is currently unavailable.${NC}"
    echo -e "${RED}r: Failed to retrieve chart: error locating chart:${NC}"
    echo -e "${RED}looks like \"https://${CHART_DOMAIN}/\" is not a valid chart repository${NC}"
    echo -e "${RED}or cannot be reached: open /.cache/helm/repository/<hash>-index.yaml:${NC}"
    echo -e "${RED}no such file or directory${NC}"
    echo ""
    echo "This demonstrates the bug: Browse works ✅ but Create fails ❌"
    echo ""
    
    read -p "Press ENTER when you've completed the UI test..."
}

# ============================================================================
# OPTIONAL: CHECK CONSOLE LOGS
# ============================================================================

check_console_logs() {
    section "Optional: Checking Console Logs for Debugging"
    
    info "Checking OpenShift console logs for Helm-related errors..."
    echo ""
    
    oc -n openshift-console logs deploy/console | \
        grep -i -E 'helm|repo|index.yaml|cache|x509|tls' | tail -n 50
    
    echo ""
    success "Log check complete!"
}

# ============================================================================
# SECTION 5: CLI VERIFICATION (CONTROL - PROVES CLI WORKS)
# ============================================================================

verify_with_cli() {
    section "Section 5: CLI Verification (Control Test)"
    
    info "This proves the CLI works with the same CA certificate..."
    
    info "Adding Helm repository to local Helm CLI..."
    helm repo remove lab 2>/dev/null || true
    helm repo add lab "https://${CHART_DOMAIN}/" --ca-file "$LOCAL_CA_FILE"
    
    info "Updating repository index..."
    helm repo update
    
    info "Searching for charts..."
    helm search repo lab -l
    
    info "Installing chart via CLI..."
    helm upgrade --install demo "lab/${CHART_NAME}" -n "$OCP_NAMESPACE"
    
    success "Helm CLI installation successful!"
    
    info "Listing Helm releases..."
    helm list -n "$OCP_NAMESPACE"
    
    info "Checking deployed resources..."
    oc -n "$OCP_NAMESPACE" get deploy,svc,pods -l app.kubernetes.io/instance=demo
    
    success "CLI test completed successfully! ✅"
    echo ""
    echo -e "${GREEN}Summary:${NC}"
    echo -e "  • UI Browse: ✅ Works"
    echo -e "  • UI Create: ❌ Fails (BUG)"
    echo -e "  • CLI Install: ✅ Works"
    echo ""
}

# ============================================================================
# SECTION 6: CLEANUP
# ============================================================================

cleanup_demo() {
    section "Cleanup: Removing Demo Resources"
    
    info "Uninstalling Helm release..."
    helm uninstall demo -n "$OCP_NAMESPACE" || true
    
    info "Deleting ProjectHelmChartRepository..."
    oc -n "$OCP_NAMESPACE" delete projecthelmchartrepository "$HELM_REPO_NAME" --ignore-not-found
    
    info "Deleting CA ConfigMap..."
    oc -n "$OCP_NAMESPACE" delete configmap "$CA_CONFIGMAP_NAME" --ignore-not-found
    
    info "Removing local Helm repo..."
    helm repo remove lab 2>/dev/null || true
    
    info "Cleaning local work directory..."
    rm -rf "$LOCAL_WORK_DIR"
    
    success "Cleanup complete!"
}

full_cleanup() {
    section "Full Cleanup: Removing All Resources"
    
    cleanup_demo
    
    warn "Deleting namespace: $OCP_NAMESPACE"
    oc delete project "$OCP_NAMESPACE" --ignore-not-found
    
    success "Full cleanup complete!"
}

# ============================================================================
# MAIN MENU
# ============================================================================

show_menu() {
    echo ""
    echo -e "${BLUE}=====================================================${NC}"
    echo -e "${BLUE}  OCPBUGS-44235 - Helm CA Bug Verification Script${NC}"
    echo -e "${BLUE}=====================================================${NC}"
    echo ""
    echo "Configuration:"
    echo "  Domain:        $CHART_DOMAIN"
    echo "  EC2:           $EC2_HOST"
    echo "  Namespace:     $OCP_NAMESPACE"
    echo "  Script Dir:    $SCRIPT_DIR"
    echo ""
    echo "Required files in script directory:"
    echo "  SSH Key:       helm-test-2.pem"
    echo ""
    echo "Generated files (created by script):"
    echo "  CA Bundle:     charts-ca-bundle.crt"
    echo "  Work Dir:      work/"
    echo ""
    echo "Commands:"
    echo "  full          - Run full reproduction (sections 1-5)"
    echo "  ec2           - Setup EC2 nginx + certificate (section 1)"
    echo "  chart         - Create and publish chart (section 2)"
    echo "  ocp           - Setup OpenShift repo with CA (section 3)"
    echo "  ui            - Show UI testing instructions (section 4)"
    echo "  cli           - Verify with CLI (section 5)"
    echo "  logs          - Check console logs for debugging"
    echo "  cleanup       - Remove demo resources"
    echo "  full-cleanup  - Remove all resources including namespace"
    echo "  help          - Show this menu"
    echo ""
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main() {
    local command="${1:-help}"
    
    case "$command" in
        full)
            check_prerequisites
            setup_ec2_nginx
            create_and_publish_chart
            setup_openshift_repo
            show_ui_instructions
            verify_with_cli
            echo ""
            success "Full reproduction complete!"
            ;;
        ec2)
            check_prerequisites
            setup_ec2_nginx
            ;;
        chart)
            check_prerequisites
            create_and_publish_chart
            ;;
        ocp)
            check_prerequisites
            setup_openshift_repo
            ;;
        ui)
            show_ui_instructions
            ;;
        cli)
            check_prerequisites
            verify_with_cli
            ;;
        logs)
            check_console_logs
            ;;
        cleanup)
            cleanup_demo
            ;;
        full-cleanup)
            full_cleanup
            ;;
        help|*)
            show_menu
            ;;
    esac
}

# Run main with all arguments
main "$@"

