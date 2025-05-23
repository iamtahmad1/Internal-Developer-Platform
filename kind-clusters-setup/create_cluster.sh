#!/usr/bin/env bash
set -e

# ------------------------ Config ------------------------
CLUSTER_NAME=${1:-kind}  # Pass as first argument or default to "kind"
KIND_NODE_IMAGE=kindest/node:v1.31.0

# ------------------------ Helpers ------------------------
log() {
  echo "---------------------------------------------------------------------------------------"
  echo "$1"
  echo "---------------------------------------------------------------------------------------"
}

wait_ready() {
  local KIND=$1       # e.g., pods
  local TIMEOUT=$2    # e.g., 5m
  local NS=$3         # e.g., metallb-system or argocd
  local SELECTOR=$4   # optional

  log "Waiting for $KIND in namespace $NS to be ready..."
  if [[ -z "$SELECTOR" ]]; then
    kubectl wait --context "kind-${CLUSTER_NAME}" --namespace "$NS" --timeout="$TIMEOUT" --for=condition=ready "$KIND" --all
  else
    kubectl wait --context "kind-${CLUSTER_NAME}" --namespace "$NS" --timeout="$TIMEOUT" --for=condition=ready "$KIND" --selector="$SELECTOR"
  fi
}

# ------------------------ Steps ------------------------

create_kind_cluster() {
  log "Creating Kind cluster named $CLUSTER_NAME..."
  kind create cluster --name "$CLUSTER_NAME" --image "$KIND_NODE_IMAGE"
}

install_metallb() {
  log "Installing MetalLB..."

  local subnet
  subnet=$(docker network inspect "kind" -f '{{(index .IPAM.Config 0).Subnet}}')
  local start_ip end_ip
  start_ip=$(echo "$subnet" | sed 's@0.0/16@255.200@')
  end_ip=$(echo "$subnet" | sed 's@0.0/16@255.250@')

  helm upgrade --install metallb metallb \
    --repo https://metallb.github.io/metallb \
    --namespace metallb-system \
    --create-namespace \
    --kube-context "kind-${CLUSTER_NAME}" \
    --wait

  cat <<EOF | kubectl apply --context "kind-${CLUSTER_NAME}" -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - ${start_ip}-${end_ip}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF

  wait_ready pods 5m metallb-system
}

install_argocd() {
  log "Installing Argo CD..."

  kubectl create namespace argocd --context "kind-${CLUSTER_NAME}" || true

  helm upgrade --install argo-cd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --namespace argocd \
    --kube-context "kind-${CLUSTER_NAME}" \
    --wait

  wait_ready pods 5m argocd
}

create_argo_app() {
  log "Creating ArgoCD Application..."

  cat <<EOF | kubectl apply --context "kind-${CLUSTER_NAME}" -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kind-clusters
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:iamtahmad1/Internal-Developer-Platform.git
    targetRevision: main
    path: clusters/dev/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}

# ------------------------ Run All ------------------------

create_kind_cluster
install_metallb
install_argocd
create_argo_app
