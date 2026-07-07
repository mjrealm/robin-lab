.PHONY: help init-secrets cluster apply-config bootstrap-talos bootstrap-k8s bootstrap-core bootstrap-argocd patch-node upgrade-node get-disks recover check-tools

REQUIRED_BINS := curl helm kubectl talosctl sops dnsmasq age yamllint

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

check-tools: ## Verify all required CLI tools are installed
	@for bin in $(REQUIRED_BINS); do \
		if ! command -v $$bin >/dev/null 2>&1; then \
			echo "Error: $$bin is not installed. Please install it first."; exit 1; \
		fi \
	done

init-secrets: check-tools ## Prompt and generate SOPS encrypted secrets for Age and Cloudflare
	@$(MAKE) -C k8s init-secrets

lint: check-tools ## Run yamllint on all YAML files
	@echo "$(CYAN)Running yamllint...$(RESET)"
	@yamllint .

cluster: check-tools ## Generate configs and download the bootable Talos ISO
	@$(MAKE) -C metal cluster

apply-config: check-tools ## Push configuration to each ISO-booted node
	@$(MAKE) -C metal apply-config

bootstrap-talos: check-tools ## Wake up the cluster (initialize etcd)
	@$(MAKE) -C metal bootstrap-talos

bootstrap-k8s: check-tools ## Run the imperative Kubernetes bootstrap sequence
	@$(MAKE) -C k8s bootstrap-k8s

bootstrap-core: check-tools ## Run core Kubernetes bootstrap (Stop before ArgoCD for DR)
	@$(MAKE) -C k8s bootstrap-core

bootstrap-argocd: check-tools ## Install ArgoCD to resume GitOps reconciliation
	@$(MAKE) -C k8s bootstrap-argocd

patch-node: check-tools ## Apply configuration patches to a live Talos node
	@$(MAKE) -C metal patch-node

upgrade-node: check-tools ## Upgrade the Talos OS version on a node
	@$(MAKE) -C metal upgrade-node

get-disks: check-tools ## Inspect disks on a booted (unconfigured) node
	@$(MAKE) -C metal get-disks

recover: check-tools ## Trigger disaster recovery using Velero
	@$(MAKE) -C k8s recover
