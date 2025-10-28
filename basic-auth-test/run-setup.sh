#!/bin/bash
# Wrapper script to run setup-basic-auth-repo.sh on EC2 from your Mac
# Usage: ./run-setup.sh [EC2_IP]

set -e

# Configuration
EC2_IP="${1:-13.60.201.122}"
SSH_KEY="$(dirname "$0")/../helm-test-2.pem"
SSH_USER="admin"

echo "Setting up Helm repository on EC2: ${EC2_IP}"

# Check if SSH key exists
if [ ! -f "${SSH_KEY}" ]; then
    echo "❌ Error: SSH key not found at ${SSH_KEY}"
    exit 1
fi

# Upload and run setup script
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "$(dirname "$0")/setup-basic-auth-repo.sh" \
    "${SSH_USER}@${EC2_IP}:/tmp/"

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "${SSH_USER}@${EC2_IP}" \
    "chmod +x /tmp/setup-basic-auth-repo.sh && /tmp/setup-basic-auth-repo.sh ${EC2_IP}"

scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "${SSH_USER}@${EC2_IP}:/tmp/openshift-helm-basic-auth-setup.yaml" \
    /tmp/

echo ""
echo "Setup complete!"
echo "  oc apply -f /tmp/openshift-helm-basic-auth-setup.yaml"
echo ""

