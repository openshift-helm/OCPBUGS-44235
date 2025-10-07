# OCPBUGS-44235
CA steps to reproduce
OpenShift Helm + custom CA (UI install failure) — Repro Runbook

What we prove

* Browse (UI) lists charts ✅
* Create (UI) fails with
    .../.cache/helm/repository/<hash>-index.yaml: no such file or directory ❌
* CLI install succeeds ✅

Assumptions / placeholders (adjust as needed)

* Domain: charts.openshift-helm-cli-testing-1.com
* EC2 SSH: key file on your laptop at ~/Downloads/baiju-helm-testing.pem
* EC2 user: admin (yours is Debian)
* OpenShift project: helm-lab

If you lose your OpenShift cluster, just re-run Section 3.
 Your CA bundle source remains the same PEM on EC2 (and a copy on your laptop).


1) EC2 (Debian) — HTTPS repo with a self-signed cert

Run on EC2 (admin@ip-…$). This only needs to be done once per EC2 host.

bash
Copy code
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
CN = charts.openshift-helm-cli-testing-1.com
[v3_req]
subjectAltName = @alt_names
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = charts.openshift-helm-cli-testing-1.com
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
  server_name charts.openshift-helm-cli-testing-1.com;

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
curl -Ik https://charts.openshift-helm-cli-testing-1.com/ -k



Where the CA “bundle” lives (server side):

* Original PEM you generated: ~/charts.crt
* Nginx copy: /etc/ssl/certs/charts.crt

You’ll use this PEM as the CA bundle in OpenShift (uploaded into a ConfigMap).

2) Laptop (Fedora/macOS) — Package a minimal chart & publish to EC2

Run on your laptop (mszuc@fedora$).

bash
Copy code
# Create and package a tiny chart
mkdir -p /tmp/helm-lab && cd /tmp/helm-lab
helm create hello-helmrm -rf hello-helm/templates/tests
helm package hello-helm                      # produces hello-helm-0.1.0.tgz
# Build the repo index pointing to your HTTPS host
mkdir repo && mv hello-helm-*.tgz repo/
helm repo index repo --url https://charts.openshift-helm-cli-testing-1.com/
# Upload both index.yaml and the chart .tgz to EC2 (home dir)
scp -i ~/Downloads/baiju-helm-testing.pem repo/* \
  admin@charts.openshift-helm-cli-testing-1.com:



Back on EC2 (publish files into the web root):

bash
Copy code
sudo cp ~/index.yaml ~/hello-helm-0.1.0.tgz /var/www/charts/ls -l /var/www/charts/
# Verify from anywhere (-k ignores self-signed)
curl -s https://charts.openshift-helm-cli-testing-1.com/index.yaml -k | head
curl -I  https://charts.openshift-helm-cli-testing-1.com/hello-helm-0.1.0.tgz -k



You should see an entries.hello-helm[0].urls: pointing to your .tgz, and HTTP/1.1 200 OK.

3) Laptop — OpenShift: add CA bundle & register repo (to trigger bug)

Run on your laptop (not EC2).

bash
Copy code
# Copy the server cert (the CA “bundle”) down to your laptop
scp -i ~/Downloads/baiju-helm-testing.pem \
  admin@charts.openshift-helm-cli-testing-1.com:~/charts.crt \
  ~/Downloads/charts.crt
# Log in & create a fresh project (repeatable on any new cluster)
oc login https://<your-ocp-api>:443
oc new-project helm-lab || oc project helm-lab
# Create the CA ConfigMap (KEY MUST BE 'ca-bundle.crt')
oc -n helm-lab create configmap charts-ca \
  --from-file=ca-bundle.crt=$HOME/Downloads/charts.crt
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
    url: https://charts.openshift-helm-cli-testing-1.com/
    ca:
      name: charts-ca
YAML

oc apply -f repo-with-ca.yaml



Where the CA “bundle” lives (cluster side):

* ConfigMap/charts-ca in namespace helm-lab
* Key: ca-bundle.crt
* Recreate this ConfigMap on any new cluster from your saved charts.crt.


4) Web console — Reproduce the issue (UI)

* Developer → Helm → Browse → you should see Lab Repo and hello-helm.
* Click the chart → Create → expect the red banner:

vbnet
Copy code
The Helm Chart is currently unavailable.r: Failed to retrieve chart: error locating chart:
looks like "https://charts.openshift-helm-cli-testing-1.com/" is not a valid chart repositoryor cannot be reached: open /.cache/helm/repository/<hash>-index.yaml: no such file or directory



This is the known console bug (UI browse OK / install FAIL when ca: is set).
(Optional: quick log evidence)

bash
Copy code
oc -n openshift-console logs deploy/console | \
  grep -i -E 'helm|repo|index.yaml|cache|x509|tls' | tail -n 200




5) Control — Prove CLI works (same repo + CA)

Run on your laptop; this installs in the cluster, not locally.

bash
Copy code
helm repo add lab https://charts.openshift-helm-cli-testing-1.com/ \
  --ca-file $HOME/Downloads/charts.crt
helm repo update
helm search repo lab -l             # should show hello-helm 0.1.0
helm install demo lab/hello-helm -n helm-lab
helm list -n helm-lab               # STATUS: deployed
oc -n helm-lab get deploy,svc,pods  # see demo-hello-helm resources




To remove the sample release:

bash
Copy code
helm uninstall demo -n helm-lab




6) Reset / Replay

Minimal reset (keep repo CR/CA; just remove release):

bash
Copy code
helm uninstall demo -n helm-lab



Full cluster reset (so you can demo from scratch on any cluster):

bash
Copy code
oc -n helm-lab delete projecthelmchartrepository lab-repo --ignore-not-found
oc -n helm-lab delete configmap charts-ca --ignore-not-found# Optional: delete the whole project
# oc delete project helm-lab

