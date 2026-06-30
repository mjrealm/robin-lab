TALOS_VERSION ?= v1.13.5
ARCH ?= amd64
CLUSTER_NAME ?= robin-lab

# By default, try to read the schematic ID if it exists, otherwise tell the user to generate one
SCHEMATIC_ID := $(shell cat schematic.id 2>/dev/null || echo "REPLACE_ME")

.PHONY: help cluster schematic generate-config fetch-assets pixiecore talos-bootstrap

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

cluster: schematic generate-config fetch-assets pixiecore ## Complete cluster prep and boot

schematic: ## Generate Talos Factory schematic ID
	@echo "Generating schematic ID for Tailscale, iscsi-tools, and util-linux-tools..."
	@curl -s -X POST -d '{"customization": {"systemExtensions": {"officialExtensions": ["siderolabs/iscsi-tools", "siderolabs/tailscale", "siderolabs/util-linux-tools"]}}}' https://factory.talos.dev/schematics | grep -o '"id":"[^"]*' | cut -d'"' -f4 > schematic.id
	@echo "Schematic ID saved to schematic.id: `cat schematic.id`"

generate-config: ## Generate Talos configs
	@if [ ! -f patch.yaml ]; then echo "Missing patch.yaml"; exit 1; fi
	@if [ -f talosconfig ]; then \
		echo "talosconfig already exists. Skipping config generation to preserve PKI."; \
		echo "(Run 'make destroy' if you truly want to destroy your cluster's certificates and start fresh)"; \
	else \
		echo "Enter Cluster VIP / API Server IP:"; \
		read VIP; \
		talosctl gen config $(CLUSTER_NAME) https://$$VIP:6443 --config-patch @patch.yaml --install-image factory.talos.dev/installer/$(SCHEMATIC_ID):$(TALOS_VERSION); \
	fi

clean: ## Remove temporary boot assets (preserves your talosconfig PKI)
	@echo "Cleaning up temporary boot assets (preserving PKI)..."
	@rm -f controlplane.yaml worker.yaml schematic.id vmlinuz initramfs.xz

destroy: clean ## DANGER: Completely destroys your Talos admin certificates
	@echo "WARNING: This will completely destroy your cluster's PKI and you will lose access!"
	@echo "Are you sure you want to proceed? [y/N]"
	@read -r ans; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		rm -f talosconfig; \
		echo "PKI destroyed."; \
	else \
		echo "Aborted."; \
	fi

fetch-assets: ## Fetch iPXE kernel and initramfs from Talos Factory
	@if [ "$(SCHEMATIC_ID)" = "REPLACE_ME" ]; then echo "Run 'make schematic' first!"; exit 1; fi
	@echo "Fetching Talos vmlinuz and initramfs for schematic $(SCHEMATIC_ID)..."
	curl -LO https://factory.talos.dev/image/$(SCHEMATIC_ID)/$(TALOS_VERSION)/metal-$(ARCH)/vmlinuz
	curl -LO https://factory.talos.dev/image/$(SCHEMATIC_ID)/$(TALOS_VERSION)/metal-$(ARCH)/initramfs.xz

pixiecore: ## Run pixiecore to serve iPXE assets over network
	@echo "Ensure you have vmlinuz and initramfs.xz in this directory"
	@echo "Enter the IP address of this machine (to serve the config files):"
	@read HOST_IP; \
	 echo "Are you booting Control Plane nodes or Worker nodes? [c/w]"; \
	 read -r node_type; \
	 if [ "$$node_type" = "w" ] || [ "$$node_type" = "W" ]; then \
	 	CONFIG_FILE="worker.yaml"; \
	 else \
	 	CONFIG_FILE="controlplane.yaml"; \
	 fi; \
	 echo "Serving $$CONFIG_FILE on port 8000 in the background..."; \
	 python3 -m http.server 8000 & HTTP_PID=$$!; \
	 echo "Running pixiecore to boot $$CONFIG_FILE nodes... (Press Ctrl+C to stop)"; \
	 sudo pixiecore boot vmlinuz initramfs.xz --cmdline="talos.config=http://$$HOST_IP:8000/$$CONFIG_FILE page_alloc.shuffle=1 init_on_alloc=1 slab_nomerge pti=on console=tty0 console=ttyS0 talos.platform=metal"; \
	 kill $$HTTP_PID

talos-bootstrap: ## Bootstrap the Talos cluster (initialize etcd)
	@echo "Enter the IP address of ONE of your Control Plane nodes:"
	@read CP_IP; \
	echo "Sending bootstrap command to $$CP_IP..."; \
	talosctl bootstrap --nodes $$CP_IP --endpoints $$CP_IP --talosconfig talosconfig; \
	echo "Waiting for Kubernetes API to become ready (this may take a few minutes)..."; \
	echo "Fetching kubeconfig..."; \
	talosctl kubeconfig --nodes $$CP_IP --endpoints $$CP_IP --talosconfig talosconfig --force
	@echo "Cluster is awake! You can now run 'make bootstrap'"
