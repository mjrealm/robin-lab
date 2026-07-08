# Terminal Colors
GREEN  := $(shell printf "\033[32m")
YELLOW := $(shell printf "\033[33m")
RED    := $(shell printf "\033[31m")
CYAN   := $(shell printf "\033[36m")
RESET  := $(shell printf "\033[0m")

# ==============================================================================
# CONFIGURATION
# ==============================================================================
# Variables
GATEWAY_API_VERSION ?= v1.4.1
CSI_SNAPSHOTTER_VERSION ?= v8.6.0
-include .cluster.env

# ==============================================================================
# TARGETS
# ==============================================================================
.PHONY: help init-secrets bootstrap-k8s bootstrap-core recover bootstrap-secrets bootstrap-gateway-api bootstrap-cni bootstrap-csi bootstrap-cert-manager bootstrap-longhorn bootstrap-velero bootstrap-argocd

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# ==============================================================================
# Initialize SOPS Secrets
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Prompt for Cloudflare API token.
# 2. Prompt for SOPS/Age private key.
# 3. Generate a combined `secrets.yaml` containing the raw values.
# 4. Immediately encrypt the file using SOPS.
# ==============================================================================
init-secrets:
	@echo "$(CYAN)Enter Cloudflare API Token (for external-dns/cert-manager):$(RESET)"
	@read CF_TOKEN; \
	 echo "apiVersion: v1\nkind: Secret\nmetadata:\n  name: cloudflare-api-token\n  namespace: cert-manager\ntype: Opaque\nstringData:\n  api-token: $$CF_TOKEN" > secrets.yaml
	@echo "$(CYAN)Enter your SOPS/Age Private Key:$(RESET)"
	@read AGE_KEY; \
	 echo "---" >> secrets.yaml; \
	 echo "apiVersion: v1\nkind: Secret\nmetadata:\n  name: sops-age\n  namespace: argocd\ntype: Opaque\nstringData:\n  keys.txt: $$AGE_KEY" >> secrets.yaml
	@echo "$(YELLOW)Encrypting secrets.yaml with SOPS...$(RESET)"
	@sops -e -i secrets.yaml
	@echo "$(GREEN)secrets.yaml has been encrypted safely!$(RESET)"

# ==============================================================================
# Initialize Cilium Network Pool
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Prompt for the reserved IP Pool CIDR block.
# 2. Generate the CiliumLoadBalancerIPPool CRD manifest.
# ==============================================================================
init-network:
	@if [ ! -f system/kube-system/resources/lb-ippool.yaml ]; then \
		echo "$(CYAN)Enter LoadBalancer IP Pool CIDRs (space-separated, e.g. 192.168.30.200/29):$(RESET)"; \
		echo "$(YELLOW)Tip: Use https://www.ipaddressguide.com/cidr to calculate the CIDR for an IP range.$(RESET)"; \
		read LB_CIDRS; \
		echo "apiVersion: cilium.io/v2\nkind: CiliumLoadBalancerIPPool\nmetadata:\n  name: default\nspec:\n  blocks:" > system/kube-system/resources/lb-ippool.yaml; \
		for cidr in $$LB_CIDRS; do \
			echo "    - cidr: $$cidr" >> system/kube-system/resources/lb-ippool.yaml; \
		done; \
		echo "$(GREEN)Created lb-ippool.yaml!$(RESET)"; \
	fi

# ==============================================================================
# META TARGETS
# ==============================================================================
# Full bootstrap: Core infra plus ArgoCD
bootstrap-k8s: bootstrap-core bootstrap-argocd

# Core only. Stop before ArgoCD for DR
bootstrap-core: bootstrap-secrets bootstrap-cni bootstrap-csi bootstrap-cert-manager bootstrap-longhorn bootstrap-velero

# ==============================================================================
# BOOTSTRAP COMPONENTS
# ==============================================================================
# ==============================================================================
# Apply SOPS Secrets to Cluster
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Verify secrets.yaml exists.
# 2. Idempotently create the `cert-manager` and `argocd` namespaces.
# 3. Decrypt secrets.yaml on the fly (never touches disk) and apply to cluster.
# ==============================================================================
bootstrap-secrets:
# Prompt for secrets if file is missing
	@if [ ! -f secrets.yaml ]; then \
		echo "$(YELLOW)secrets.yaml not found. Initializing secrets...$(RESET)"; \
		$(MAKE) init-secrets; \
	fi
	@echo "$(CYAN)Ensuring namespaces exist...$(RESET)"
# Create namespaces idempotently
	kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	@echo "$(CYAN)Applying secrets...$(RESET)"
# Decrypt and pipe (never touch disk)
	sops -d secrets.yaml | kubectl apply -f -


# ==============================================================================
# Install Kubernetes Gateway API
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Apply experimental Gateway API CRDs directly from upstream.
# ==============================================================================
bootstrap-gateway-api:
	@echo "$(CYAN)Installing Gateway API CRDs ($(GATEWAY_API_VERSION))...$(RESET)"
# Must install before CNI or Ingress
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/experimental-install.yaml

# ==============================================================================
# Install Cilium CNI
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Pull and render the Cilium Helm chart into kube-system.
# 2. Wait for the Cilium Operator and CRDs to establish.
# 3. Apply the generated local IP Pool manifests for LoadBalancing.
# 4. Modify the local kubeconfig context to use the highly available VIP.
# ==============================================================================
bootstrap-cni: init-network
	@echo "$(CYAN)Installing Cilium CNI...$(RESET)"
	helm dep update system/kube-system
# Pipe to server-side apply for big CRDs
	helm template cilium system/kube-system --namespace kube-system --include-crds | kubectl apply --server-side --force-conflicts -f -
	@rm -rf system/kube-system/charts system/kube-system/Chart.lock
	@echo "$(YELLOW)Waiting for Cilium operator to be ready...$(RESET)"
	kubectl rollout status deployment/cilium-operator -n kube-system --timeout=120s
	@echo "$(YELLOW)Waiting for Cilium CRDs to be established...$(RESET)"
# 1. Loop wait until CRD exists in API
	@for i in $$(seq 1 12); do \
		kubectl get crd ciliumloadbalancerippools.cilium.io >/dev/null 2>&1 && break || sleep 5; \
	done
# 2. Wait for API to establish CRD
	kubectl wait --for=condition=established --timeout=120s crd/ciliumloadbalancerippools.cilium.io
	kubectl wait --for=condition=established --timeout=120s crd/ciliuml2announcementpolicies.cilium.io
	
	@echo "$(GREEN)Applying Cilium LoadBalancer IP Pools and Policies...$(RESET)"
	kubectl apply -f system/kube-system/resources/
	
# Switch local kubeconfig to HA VIP
	@if [ -n "$(CLUSTER_NAME)" ] && [ -n "$(VIP)" ]; then \
		echo "$(YELLOW)Restoring kubeconfig to use highly available VIP ($(VIP))...$(RESET)"; \
		kubectl config set-cluster $(CLUSTER_NAME) --server=https://$(VIP):6443; \
	fi

# ==============================================================================
# Install CSI Snapshotter
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Deploy the external snapshot controller and CRDs to support volume snaps.
# ==============================================================================
bootstrap-csi:
	@echo "$(CYAN)Installing CSI External Snapshotter...$(RESET)"	
# Required for Longhorn volume snaps
	kubectl create -k "https://github.com/kubernetes-csi/external-snapshotter/client/config/crd?ref=$(CSI_SNAPSHOTTER_VERSION)"
	kubectl create -k "https://github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/snapshot-controller?ref=$(CSI_SNAPSHOTTER_VERSION)"

# ==============================================================================
# Install Longhorn Storage
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Create the `longhorn-system` namespace.
# 2. Label the namespace to bypass strict Pod Security Policies (required).
# 3. Deploy Longhorn via Helm to manage persistent volumes.
# ==============================================================================
bootstrap-longhorn:
	@echo "$(CYAN)Installing Longhorn...$(RESET)"
	kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
# Longhorn requires privileged access
	kubectl label namespace longhorn-system pod-security.kubernetes.io/enforce=privileged --overwrite
	helm dep update system/longhorn-system
	helm upgrade --install longhorn system/longhorn-system --namespace longhorn-system
	@rm -rf system/longhorn-system/charts system/longhorn-system/Chart.lock

# ==============================================================================
# Install Velero
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Deploy Velero via Helm for cluster and volume backups.
# ==============================================================================
bootstrap-velero:
# Install Velero for backups/restores
	@echo "$(CYAN)Installing Velero...$(RESET)"
	helm dep update system/velero
	helm upgrade --install velero system/velero --namespace velero --create-namespace
	@rm -rf system/velero/charts system/velero/Chart.lock

# ==============================================================================
# Install Cert-Manager
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Deploy cert-manager via Helm into the cert-manager namespace.
# 2. Wait for webhooks and CRDs to establish.
# 3. Apply the Cloudflare DNS ClusterIssuer.
# ==============================================================================
bootstrap-cert-manager:
# Install cert-manager and wait for webhooks
	@echo "$(CYAN)Installing cert-manager...$(RESET)"
	helm dep update platform/cert-manager
	helm upgrade --install cert-manager platform/cert-manager --namespace cert-manager --create-namespace
	@rm -rf platform/cert-manager/charts platform/cert-manager/Chart.lock
	@echo "$(YELLOW)Waiting for cert-manager webhooks to be ready...$(RESET)"
	kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s
	@echo "$(YELLOW)Waiting for cert-manager CRDs to be established...$(RESET)"
# Loop and wait for CRD registration
	@for i in $$(seq 1 12); do \
		kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1 && break || sleep 5; \
	done
	kubectl wait --for=condition=established --timeout=120s crd/clusterissuers.cert-manager.io
# Apply ClusterIssuer after CRDs exist
	@echo "$(GREEN)Applying Cloudflare ClusterIssuer...$(RESET)"
	kubectl apply -f platform/cert-manager/resources/cluster-issuer.yaml

# ==============================================================================
# Install ArgoCD
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Deploy ArgoCD via Helm into the argocd namespace.
# 2. Wait for the ArgoCD server and ApplicationSet CRD.
# 3. Deploy the Root ApplicationSet to trigger GitOps sync of all cluster apps.
# ==============================================================================
bootstrap-argocd:
# Install ArgoCD and wait for server
	@echo "$(CYAN)Installing ArgoCD...$(RESET)"
	helm dep update system/argocd
	helm upgrade --install argocd system/argocd --namespace argocd --create-namespace
	@rm -rf system/argocd/charts system/argocd/Chart.lock
	@echo "$(YELLOW)Waiting for ArgoCD server to be ready...$(RESET)"
	kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
	@echo "$(YELLOW)Waiting for ArgoCD CRDs to be established...$(RESET)"
# Wait for ApplicationSet CRD registration
	@for i in $$(seq 1 12); do \
		kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1 && break || sleep 5; \
	done
	kubectl wait --for=condition=established --timeout=120s crd/applicationsets.argoproj.io
# Deploy root app to trigger GitOps sync
	@echo "$(GREEN)Applying Root ApplicationSet...$(RESET)"
	kubectl apply -f argocd/root-app.yaml

# ==============================================================================
# DISASTER RECOVERY
# ==============================================================================
# ==============================================================================
# Recover Cluster from Backup (Disaster Recovery)
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Fetch available backups from Velero.
# 2. Prompt the user for the target backup ID.
# 3. Trigger the Velero restore.
# 4. Display a warning to delay ArgoCD installation.
# 5. Launch `watch` to monitor PV restoration progress.
# ==============================================================================
recover:
# Prompt for backup, then trigger Velero restore
	@if [ -z "$(BACKUP)" ]; then \
		echo "$(CYAN)Available Backups:$(RESET)"; \
		velero backup get; \
		echo ""; \
		echo "$(CYAN)Enter the name of the backup to restore:$(RESET)"; \
		read BACKUP_VAL; \
		if [ -z "$$BACKUP_VAL" ]; then echo "$(RED)Error: Backup name required.$(RESET)"; exit 1; fi; \
	else \
		BACKUP_VAL="$(BACKUP)"; \
	fi; \
	echo "$(CYAN)Triggering Velero disaster recovery from backup $$BACKUP_VAL...$(RESET)"; \
	velero restore create --from-backup $$BACKUP_VAL
# Warn user to hold off on ArgoCD during restore
	@echo "\n$(RED)=======================================================================$(RESET)"
	@echo "$(RED)⚠️  WARNING: DO NOT INSTALL ARGOCD YET!$(RESET)"
	@echo "$(YELLOW)Please wait for Velero to finish restoring all PVs and cluster state.$(RESET)"
	@echo "$(CYAN)Launching live monitor... (Press Ctrl+C to exit when PVs are Bound and restore is Completed)$(RESET)"
	@echo "$(RED)=======================================================================\n$(RESET)"
	@sleep 3
# Launch interactive monitor for PVCs and restore
	@watch -n 5 "velero restore get && echo '\n--- PVC STATUS ---\n' && kubectl get pvc -A"
