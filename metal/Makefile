TALOS_VERSION ?= v1.13.5
ARCH ?= amd64
CLUSTER_NAME ?= robin-lab

HOST_IP ?= $(shell ipconfig getifaddr $$(route get default | awk '/interface:/ {print $$2}') 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1")
ACTIVE_IFACE ?= $(shell route get default | awk '/interface:/ {print $$2}' 2>/dev/null || echo "en0")
SUBNET ?= $(shell echo $(HOST_IP) | cut -d. -f1-3).0

# By default, try to read the schematic ID if it exists, otherwise tell the user to generate one
SCHEMATIC_ID = $(shell cat schematic.id 2>/dev/null || echo "REPLACE_ME")

# Terminal Colors
GREEN  := $(shell printf "\033[32m")
YELLOW := $(shell printf "\033[33m")
RED    := $(shell printf "\033[31m")
CYAN   := $(shell printf "\033[36m")
RESET  := $(shell printf "\033[0m")

.PHONY: help cluster schematic generate-config fetch-assets matchbox-start matchbox-stop fetch-bootloaders bootstrap-talos patch-node upgrade-node

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

cluster: schematic generate-config iso ## Generate configs and download the Talos ISO
	@echo "$(GREEN)Cluster assets generated!$(RESET)"
	@echo "$(YELLOW)Next Steps:$(RESET)"
	@echo "1. Boot your machine(s) using the downloaded metal-$(ARCH).iso"
	@echo "2. Once booted, the machine will display an IP address on its console."
	@echo "3. Run: $(CYAN)make apply-config$(RESET)"
	@echo "4. Repeat for all nodes, then run: $(CYAN)make bootstrap-talos$(RESET)"

schematic: ## Generate Talos Factory schematic ID
	@echo "$(CYAN)Generating schematic ID for Tailscale, iscsi-tools, and util-linux-tools...$(RESET)"
	@curl -s -X POST -d '{"customization": {"systemExtensions": {"officialExtensions": ["siderolabs/iscsi-tools", "siderolabs/tailscale", "siderolabs/util-linux-tools"]}}}' https://factory.talos.dev/schematics | grep -o '"id":"[^"]*' | cut -d'"' -f4 > schematic.id
	@echo "$(GREEN)Schematic ID saved to schematic.id: `cat schematic.id`$(RESET)"

generate-config: ## Generate Talos configs
	@if [ ! -f patch.yaml ]; then echo "$(RED)Missing patch.yaml$(RESET)"; exit 1; fi
	@if [ -f talosconfig ]; then \
		echo "$(YELLOW)talosconfig already exists. Skipping config generation to preserve PKI.$(RESET)"; \
		echo "$(YELLOW)(Run 'make destroy' if you truly want to destroy your cluster's certificates and start fresh)$(RESET)"; \
	else \
		echo "$(CYAN)Enter Cluster Name [default: $(CLUSTER_NAME)]:$(RESET)"; \
		read CLUSTER_INPUT; \
		if [ -z "$$CLUSTER_INPUT" ]; then CLUSTER_INPUT="$(CLUSTER_NAME)"; fi; \
		echo "$(CYAN)Enter Cluster VIP / API Server IP:$(RESET)"; \
		read VIP; \
		talosctl gen config $$CLUSTER_INPUT https://$$VIP:6443 --config-patch @patch.yaml --install-image factory.talos.dev/installer/$(SCHEMATIC_ID):$(TALOS_VERSION); \
		echo "$(CYAN)Validating generated configs...$(RESET)"; \
		talosctl validate --config controlplane.yaml --mode metal; \
		talosctl validate --config worker.yaml --mode metal; \
	fi

clean: ## Remove temporary boot assets (preserves your talosconfig PKI)
	@echo "$(YELLOW)Cleaning up temporary configurations...$(RESET)"
	@rm -f controlplane.yaml worker.yaml

destroy: clean ## DANGER: Completely destroys your Talos admin certificates and downloads
	@echo "$(RED)WARNING: This will completely destroy your cluster's PKI and you will lose access!$(RESET)"
	@echo "$(RED)Are you sure you want to proceed? [y/N]$(RESET)"
	@read -r ans; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		rm -f talosconfig schematic.id metal-*.iso; \
		echo "$(RED)PKI and ISO destroyed.$(RESET)"; \
	else \
		echo "$(YELLOW)Aborted.$(RESET)"; \
	fi

iso: ## Fetch Talos ISO (Boot your VMs or flash to USB with this)
	@if [ "$(SCHEMATIC_ID)" = "REPLACE_ME" ]; then echo "$(RED)Run 'make schematic' first!$(RESET)"; exit 1; fi
	@if [ ! -f metal-$(ARCH).iso ]; then \
		echo "$(CYAN)Fetching Talos $(ARCH) ISO for schematic $(SCHEMATIC_ID)...$(RESET)"; \
		curl -LO https://factory.talos.dev/image/$(SCHEMATIC_ID)/$(TALOS_VERSION)/metal-$(ARCH).iso; \
	else \
		echo "$(GREEN)metal-$(ARCH).iso already exists.$(RESET)"; \
	fi

apply-config: ## Push configuration to a booted Talos node
	@if [ -z "$(NODE_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of the booted node:$(RESET)"; \
		read NODE_IP_VAL; \
	else \
		NODE_IP_VAL="$(NODE_IP)"; \
	fi; \
	if [ -z "$(ROLE)" ]; then \
		echo "$(CYAN)Enter the role for this node (controlplane/worker):$(RESET)"; \
		read ROLE_VAL; \
	else \
		ROLE_VAL="$(ROLE)"; \
	fi; \
	if [ "$$ROLE_VAL" != "controlplane" ] && [ "$$ROLE_VAL" != "worker" ]; then \
		echo "$(RED)Error: Role must be 'controlplane' or 'worker'.$(RESET)"; \
		exit 1; \
	fi; \
	if [ ! -f "$$ROLE_VAL.yaml" ]; then \
		echo "$(RED)Error: $$ROLE_VAL.yaml not found. Run 'make generate-config' first.$(RESET)"; \
		exit 1; \
	fi; \
	echo "$(CYAN)Applying $$ROLE_VAL configuration to $$NODE_IP_VAL...$(RESET)"; \
	talosctl apply-config --insecure --nodes $$NODE_IP_VAL --file $$ROLE_VAL.yaml; \
	echo "$(GREEN)Configuration applied! The node will reboot and install Talos.$(RESET)"

bootstrap-talos: ## Bootstrap the Talos cluster (initialize etcd)
	@if [ -z "$(CP_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of ONE of your Control Plane nodes:$(RESET)"; \
		read CP_IP_VAL; \
	else \
		CP_IP_VAL="$(CP_IP)"; \
	fi; \
	echo "$(CYAN)Configuring talosconfig with endpoint and node $$CP_IP_VAL...$(RESET)"; \
	talosctl --talosconfig=./talosconfig config endpoint $$CP_IP_VAL; \
	talosctl --talosconfig=./talosconfig config node $$CP_IP_VAL; \
	echo "$(CYAN)Sending bootstrap command to $$CP_IP_VAL...$(RESET)"; \
	talosctl bootstrap --nodes $$CP_IP_VAL --talosconfig=./talosconfig; \
	echo "$(YELLOW)Waiting for Kubernetes API to become ready (this may take a few minutes)...$(RESET)"; \
	echo "$(CYAN)Fetching kubeconfig...$(RESET)"; \
	talosctl kubeconfig --nodes $$CP_IP_VAL --talosconfig=./talosconfig --force
	@echo "$(GREEN)Cluster is awake! You can now use kubectl.$(RESET)"

patch-node: ## Apply configuration patches to a live Talos node
	@if [ -z "$(NODE_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of the node to patch:$(RESET)"; \
		read NODE_IP_VAL; \
	else \
		NODE_IP_VAL="$(NODE_IP)"; \
	fi; \
	echo "$(CYAN)Applying patch.yaml to $$NODE_IP_VAL...$(RESET)"; \
	talosctl patch machineconfig --nodes $$NODE_IP_VAL --patch @patch.yaml; \
	echo "$(GREEN)Patch applied successfully!$(RESET)"

upgrade-node: ## Upgrade the Talos OS version on a node
	@if [ -z "$(NODE_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of the node to upgrade:$(RESET)"; \
		read NODE_IP_VAL; \
	else \
		NODE_IP_VAL="$(NODE_IP)"; \
	fi; \
	if [ -z "$(NEW_VERSION)" ]; then \
		echo "$(CYAN)Enter the new Talos version (e.g. v1.14.0):$(RESET)"; \
		read NEW_VERSION_VAL; \
	else \
		NEW_VERSION_VAL="$(NEW_VERSION)"; \
	fi; \
	SCHEMATIC=$$(cat schematic.id 2>/dev/null); \
	if [ -z "$$SCHEMATIC" ] || [ "$$SCHEMATIC" = "REPLACE_ME" ]; then \
		echo "$(RED)Error: schematic.id not found. Run 'make schematic' first.$(RESET)"; exit 1; \
	fi; \
	echo "$(CYAN)Upgrading $$NODE_IP_VAL to $$NEW_VERSION_VAL using schematic $$SCHEMATIC...$(RESET)"; \
	talosctl upgrade --nodes $$NODE_IP_VAL --image factory.talos.dev/installer/$$SCHEMATIC:$$NEW_VERSION_VAL; \
	echo "$(GREEN)Upgrade initiated! The node will reboot when ready.$(RESET)"
