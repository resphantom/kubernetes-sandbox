#!/bin/bash

# Following setup guide: https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-cert-manager
# As well as this setup guide: https://developer.hashicorp.com/vault/tutorials/secrets-management/pki-engine
# REQUIREMENTS:
#   - kubectl
#   - jq

# -----------------------------------------------------------------------
# git repo: https://github.com/hashicorp/vault-helm/blob/main/values.yaml
# helm artifact: https://artifacthub.io/packages/helm/hashicorp/vault
# -----------------------------------------------------------------------

. $(dirname $(readlink -f $0))/../install-lib.sh

NAMESPACE="cert-manager"
HOSTNAME="vault.${DOMAIN}"
LOCAL_HOSTNAME="vault.${NAMESPACE}.svc.cluster.local:8200"

enable_debug=true

# install vault
helm upgrade --install vault hashicorp/vault --namespace ${NAMESPACE} --create-namespace \
             --set server.ingress.enabled=true \
             --set server.ingress.hosts[0].host=${HOSTNAME} \
             --set server.ingress.tls[0].secretName=${HOSTNAME} \
             --set server.ingress.tls[0].hosts[0]=${HOSTNAME} \
             --set injector.enabled=false

# kubectl patch svc app-ingress-ingress-nginx-controller -n ingress -p '{"spec": {"type": "LoadBalancer", "externalIPs":["172.31.71.218"]}}'

# -----------------------------------------------------------------------
# Set up vault
# -----------------------------------------------------------------------

VAULT_EXEC="kubectl exec vault-0 --namespace ${NAMESPACE}"

countdown 10

#wait ping $HOSTNAME -c 1

if ${enable_debug};then set -x;fi

# vault init
${VAULT_EXEC} -- vault operator init -key-shares=1 \
                    -key-threshold=1 \
                    -format=json > keys.json

# kubectl exec vault-0 --namespace cert-manager -- vault operator init -key-shares=1 -key-threshold=1 -format=json > keys.json

# vault unseal
VAULT_UNSEAL_KEY=$(cat keys.json | jq -r ".unseal_keys_b64[]")
${VAULT_EXEC} -- vault operator unseal ${VAULT_UNSEAL_KEY}

# vault login
VAULT_ROOT_TOKEN=$(cat keys.json | jq -r ".root_token")
${VAULT_EXEC} -- vault login ${VAULT_ROOT_TOKEN}

# -----------------------------------------------------------------------
# Configure PKI Secrets Engine - Root Certificate
# -----------------------------------------------------------------------

# enable pki
${VAULT_EXEC} -- vault secrets enable pki
${VAULT_EXEC} -- vault secrets tune -max-lease-ttl=8760h pki

# generate certificate
${VAULT_EXEC} -- vault write pki/root/generate/internal \
                  common_name=${DOMAIN} \
                  issuer_name="vault-isser" \
                  ttl=8760h > vault-isser-ca.crt

${VAULT_EXEC} -- vault write pki/config/urls \
                  issuing_certificates="http://${HOSTNAME}/v1/pki/ca" \
                  crl_distribution_points="http://${HOSTNAME}/v1/pki/crl"


# -----------------------------------------------------------------------
#  Generate PKI role - Root Certificate
# -----------------------------------------------------------------------

${VAULT_EXEC} -- vault write pki/roles/vault \
                  allowed_domains=${DOMAIN} \
                  allow_subdomains=true \
                  require_cn=false \
                  max_ttl=87600h

${VAULT_EXEC} -- sh -c 'vault policy write pki - <<EOF
path "pki*"                         { capabilities = ["read", "list"] }
path "pki/sign/vault"               { capabilities = ["create", "update"] }
path "pki/issue/vault"              { capabilities = ["create"] }
EOF'

# -----------------------------------------------------------------------
# Configure PKI Secrets Engine - Intermediate Certificate
# -----------------------------------------------------------------------

# enable pki - intermediate
${VAULT_EXEC} -- vault secrets enable -path=pki_int pki
${VAULT_EXEC} -- vault secrets tune -max-lease-ttl=43800h pki_int

# generate certificate
${VAULT_EXEC} -- vault write -format=json pki_int/intermediate/generate/internal \
                  common_name="*.${DOMAIN} Intermediate Authority" \
                  issuer_name="vault-isser-int" \
                  | jq -r '.data.csr' > pki_intermediate.csr

# sign intermediate with root certificate key
${VAULT_EXEC} -- vault write -format=json pki/root/sign-intermediate \
                  issuer_ref="vault-isser" \
                  csr=@pki_intermediate.csr \
                  format=pem_bundle ttl=43800h \
                  | jq -r '.data.certificate' > intermediate.cert.pem

# add signed certificate back to vault
${VAULT_EXEC} -- vault write pki_int/intermediate/set-signed certificate=@intermediate.cert.pem

# -----------------------------------------------------------------------
#  Generate PKI role - Intermediate Certificate
# -----------------------------------------------------------------------

${VAULT_EXEC} -- vault write pki_int/roles/vault-int \
                  issuer_ref="vault-isser-int" \
                  allowed_domains="${DOMAIN}" \
                  allow_subdomains=true \
                  require_cn=false \
                  max_ttl=720h

# -----------------------------------------------------------------------
# Configure Kubernetes Authentication
# -----------------------------------------------------------------------

${VAULT_EXEC} -- vault auth enable kubernetes

${VAULT_EXEC} -- sh -c 'vault write auth/kubernetes/config \
                kubernetes_host="https://$KUBERNETES_PORT_443_TCP_ADDR:443"'


${VAULT_EXEC} -- vault write auth/kubernetes/role/issuer \
                  bound_service_account_names=issuer \
                  bound_service_account_namespaces=cert-manager \
                  policies=pki \
                  ttl=20m
set +x

# -----------------------------------------------------------------------
# git repo: https://github.com/cert-manager/cert-manager/tree/master/deploy/charts/cert-manager
# helm artifact: https://artifacthub.io/packages/helm/cert-manager/cert-manager
# -----------------------------------------------------------------------

CERT_MANAGER_VERSION="v1.12.1"
ISSUER_SA_REF="issuer"
ISSUER_SECRET_REF="issuer-token"

# Install cert-manager CRD's
kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.crds.yaml

# install cert-manager
helm upgrade --install cert-manager jetstack/cert-manager --version ${CERT_MANAGER_VERSION} --namespace ${NAMESPACE} --create-namespace


# -----------------------------------------------------------------------
# Configure an issuer and generate a certificate
# -----------------------------------------------------------------------

kubectl create serviceaccount ${ISSUER_SA_REF} --namespace ${NAMESPACE}

kubectl apply --filename - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${ISSUER_SECRET_REF}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${ISSUER_SA_REF}
type: kubernetes.io/service-account-token
EOF

kubectl apply --filename - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-issuer
  namespace: ${NAMESPACE}
spec:
  vault:
    server: http://${LOCAL_HOSTNAME}
    path: pki/sign/vault
    auth:
      kubernetes:
        mountPath: /v1/auth/kubernetes
        role: issuer
        secretRef:
          name: ${ISSUER_SECRET_REF}
          key: token
EOF

# TO DELETE

# kubectl delete clusterissuer vault-issuer
# helm uninstall vault -n cert-manager
# helm uninstall cert-manager -n cert-manager
# kubectl delete pvc data-vault-0 -n cert-manager 
# kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.12.1/cert-manager.crds.yaml
# kubectl delete ns cert-manager


# Look into using Vault as a kubernetes cert manager
# https://developer.hashicorp.com/vault/tutorials/kubernetes/kubernetes-cert-manager
# https://cert-manager.io/docs/configuration/vault/


kubectl apply --filename -<<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: vault-cert
  namespace: cert-manager
spec:
  secretName: vault.127.0.0.1.nip.io
  issuerRef:
    name: vault-issuer
    kind: ClusterIssuer
  commonName: vault.127.0.0.1.nip.io
  dnsNames:
  - vault.127.0.0.1.nip.io
EOF