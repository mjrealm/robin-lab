.PHONY: help init-secrets cluster ignite bootstrap recover check-tools

REQUIRED_BINS := curl helm kubectl talosctl sops dnsmasq age go

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

cluster: check-tools ## Boot nodes via Matchbox/dnsmasq and generate Talos configs
	@$(MAKE) -C metal cluster

ignite: check-tools ## Wake up the cluster (initialize etcd)
	@$(MAKE) -C metal talos-bootstrap

bootstrap: check-tools ## Run the imperative Kubernetes bootstrap sequence
	@$(MAKE) -C k8s bootstrap

recover: check-tools ## Trigger disaster recovery using Velero
	@$(MAKE) -C k8s recover
