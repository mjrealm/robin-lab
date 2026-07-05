# Terminal Colors
GREEN  := $(shell printf "\033[32m")
YELLOW := $(shell printf "\033[33m")
RED    := $(shell printf "\033[31m")
CYAN   := $(shell printf "\033[36m")
RESET  := $(shell printf "\033[0m")

.PHONY: help init-secrets bootstrap-k8s bootstrap-core recover bootstrap-secrets bootstrap-cni bootstrap-csi bootstrap-cert-manager bootstrap-longhorn bootstrap-velero bootstrap-argocd

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

init-secrets: ## Interactively prompt for secrets
	@echo "$(CYAN)Enter Cloudflare API Token (for external-dns/cert-manager):$(RESET)"
	@read -s CF_TOKEN; \
	 echo "apiVersion: v1\nkind: Secret\nmetadata:\n  name: cloudflare-api-token\n  namespace: cert-manager\ntype: Opaque\nstringData:\n  api-token: $$CF_TOKEN" > secrets.yaml
	@echo "$(CYAN)Enter your SOPS/Age Private Key:$(RESET)"
	@read -s AGE_KEY; \
	 echo "apiVersion: v1\nkind: Secret\nmetadata:\n  name: sops-age\n  namespace: argocd\ntype: Opaque\nstringData:\n  keys.txt: $$AGE_KEY" >> secrets.yaml
	@echo "$(YELLOW)Encrypting secrets.yaml with SOPS...$(RESET)"
	@sops -e -i secrets.yaml
	@echo "$(GREEN)secrets.yaml has been encrypted safely!$(RESET)"

bootstrap-k8s: bootstrap-core bootstrap-argocd ## Run strict full bootstrap sequence

bootstrap-core: bootstrap-secrets bootstrap-cni bootstrap-csi bootstrap-cert-manager bootstrap-longhorn bootstrap-velero ## Run core bootstrap (Stop before ArgoCD for DR)

bootstrap-secrets:
	@echo "$(CYAN)Applying secrets...$(RESET)"
	sops -d secrets.yaml | kubectl apply -f -

bootstrap-cni:
	@echo "$(CYAN)Installing Cilium CNI...$(RESET)"
	helm dep update system/kube-system
	helm upgrade --install cilium system/kube-system --namespace kube-system
	@echo "$(YELLOW)Waiting for Cilium operator to be ready...$(RESET)"
	kubectl wait --for=condition=Available deployment/cilium-operator -n kube-system --timeout=120s
	@echo "$(GREEN)Applying Cilium LoadBalancer IP Pools and Policies...$(RESET)"
	kubectl apply -f system/kube-system/templates/

bootstrap-csi:
	@echo "$(CYAN)Installing CSI External Snapshotter...$(RESET)"
	@echo "$(YELLOW)Note: external-snapshotter v8.0.1 is specifically chosen for compatibility with Kubernetes v1.30+$(RESET)"
	kubectl apply -k github.com/kubernetes-csi/external-snapshotter/client/config/crd?ref=v8.0.1
	kubectl apply -k github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/snapshot-controller?ref=v8.0.1

bootstrap-longhorn:
	@echo "$(CYAN)Installing Longhorn...$(RESET)"
	helm dep update system/longhorn-system
	helm upgrade --install longhorn system/longhorn-system --namespace longhorn-system --create-namespace

bootstrap-velero:
	@echo "$(CYAN)Installing Velero...$(RESET)"
	helm dep update system/velero
	helm upgrade --install velero system/velero --namespace velero --create-namespace

bootstrap-cert-manager:
	@echo "$(CYAN)Installing cert-manager...$(RESET)"
	helm dep update platform/cert-manager
	helm upgrade --install cert-manager platform/cert-manager --namespace cert-manager --create-namespace
	@echo "$(YELLOW)Waiting for cert-manager webhooks to be ready...$(RESET)"
	kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s
	@echo "$(GREEN)Applying Cloudflare ClusterIssuer...$(RESET)"
	kubectl apply -f platform/cert-manager/templates/cluster-issuer.yaml

bootstrap-argocd:
	@echo "$(CYAN)Installing ArgoCD...$(RESET)"
	helm dep update system/argocd
	helm upgrade --install argocd system/argocd --namespace argocd --create-namespace
	@echo "$(YELLOW)Waiting for ArgoCD server to be ready...$(RESET)"
	kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
	@echo "$(GREEN)Applying Root ApplicationSet...$(RESET)"
	kubectl apply -f argocd/root-app.yaml

recover:
	@echo "$(CYAN)Triggering Velero disaster recovery...$(RESET)"
	velero restore create --from-backup latest-backup
	@echo "\n$(RED)=======================================================================$(RESET)"
	@echo "$(RED)⚠️  WARNING: DO NOT INSTALL ARGOCD YET!$(RESET)"
	@echo "$(YELLOW)Please wait for Velero to finish restoring all PVs and cluster state.$(RESET)"
	@echo "$(CYAN)You can monitor progress with: velero restore get$(RESET)"
	@echo "$(GREEN)Once complete, run 'make bootstrap-argocd' to resume GitOps!$(RESET)"
	@echo "$(RED)=======================================================================\n$(RESET)"
