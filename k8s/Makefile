.PHONY: help init-secrets bootstrap bootstrap-core recover bootstrap-secrets bootstrap-cni bootstrap-csi bootstrap-cert-manager bootstrap-longhorn bootstrap-velero bootstrap-argocd

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

init-secrets: ## Interactively prompt for secrets
	@echo "Enter Cloudflare API Token (for external-dns/cert-manager):"
	@read -s CF_TOKEN; \
	 echo "apiVersion: v1\nkind: Secret\nmetadata:\n  name: cloudflare-api-token\n  namespace: cert-manager\ntype: Opaque\nstringData:\n  api-token: $$CF_TOKEN" > secrets.yaml
	@echo "Enter your SOPS/Age Private Key:"
	@read -s AGE_KEY; \
	 echo "apiVersion: v1\nkind: Secret\nmetadata:\n  name: sops-age\n  namespace: argocd\ntype: Opaque\nstringData:\n  keys.txt: $$AGE_KEY" >> secrets.yaml
	@echo "Encrypting secrets.yaml with SOPS..."
	@sops -e -i secrets.yaml
	@echo "secrets.yaml has been encrypted safely!"

bootstrap: bootstrap-core bootstrap-argocd ## Run strict full bootstrap sequence

bootstrap-core: bootstrap-secrets bootstrap-cni bootstrap-csi bootstrap-cert-manager bootstrap-longhorn bootstrap-velero ## Run core bootstrap (Stop before ArgoCD for DR)

bootstrap-secrets:
	@echo "Applying secrets..."
	sops -d secrets.yaml | kubectl apply -f -

bootstrap-cni:
	@echo "Installing Cilium CNI..."
	helm dep update system/kube-system
	helm upgrade --install cilium system/kube-system --namespace kube-system
	@echo "Waiting for Cilium operator to be ready..."
	kubectl wait --for=condition=Available deployment/cilium-operator -n kube-system --timeout=120s
	@echo "Applying Cilium LoadBalancer IP Pools and Policies..."
	kubectl apply -f system/kube-system/templates/

bootstrap-csi:
	@echo "Installing CSI External Snapshotter..."
	@echo "Note: external-snapshotter v8.0.1 is specifically chosen for compatibility with Kubernetes v1.30+"
	kubectl apply -k github.com/kubernetes-csi/external-snapshotter/client/config/crd?ref=v8.0.1
	kubectl apply -k github.com/kubernetes-csi/external-snapshotter/deploy/kubernetes/snapshot-controller?ref=v8.0.1

bootstrap-longhorn:
	@echo "Installing Longhorn..."
	helm dep update system/longhorn-system
	helm upgrade --install longhorn system/longhorn-system --namespace longhorn-system --create-namespace

bootstrap-velero:
	@echo "Installing Velero..."
	helm dep update system/velero
	helm upgrade --install velero system/velero --namespace velero --create-namespace

bootstrap-cert-manager:
	@echo "Installing cert-manager..."
	helm dep update platform/cert-manager
	helm upgrade --install cert-manager platform/cert-manager --namespace cert-manager --create-namespace
	@echo "Waiting for cert-manager webhooks to be ready..."
	kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s
	@echo "Applying Cloudflare ClusterIssuer..."
	kubectl apply -f platform/cert-manager/templates/cluster-issuer.yaml

bootstrap-argocd:
	@echo "Installing ArgoCD..."
	helm dep update system/argocd
	helm upgrade --install argocd system/argocd --namespace argocd --create-namespace
	@echo "Waiting for ArgoCD server to be ready..."
	kubectl wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
	@echo "Applying Root ApplicationSet..."
	kubectl apply -f argocd/root-app.yaml

recover:
	@echo "Triggering Velero disaster recovery..."
	velero restore create --from-backup latest-backup
	@echo "\n======================================================================="
	@echo "⚠️  WARNING: DO NOT INSTALL ARGOCD YET!"
	@echo "Please wait for Velero to finish restoring all PVs and cluster state."
	@echo "You can monitor progress with: velero restore get"
	@echo "Once complete, run 'make bootstrap-argocd' to resume GitOps!"
	@echo "=======================================================================\n"
