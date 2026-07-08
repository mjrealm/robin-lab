# ==============================================================================
# CONFIGURATION
# ==============================================================================
TALOS_VERSION ?= v1.13.5
ARCH ?= amd64
CLUSTER_NAME ?= robin

HOST_IP ?= $(shell ipconfig getifaddr $$(route get default | awk '/interface:/ {print $$2}') 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1")
ACTIVE_IFACE ?= $(shell route get default | awk '/interface:/ {print $$2}' 2>/dev/null || echo "en0")
SUBNET ?= $(shell echo $(HOST_IP) | cut -d. -f1-3).0

# By default, try to read the schematic ID if it exists, otherwise tell the user to generate one
SCHEMATIC_ID = $(shell cat schematic.id 2>/dev/null || echo "REPLACE_ME")

# ==============================================================================
# TERMINAL COLORS
# ==============================================================================
GREEN  := $(shell printf "\033[32m")
YELLOW := $(shell printf "\033[33m")
RED    := $(shell printf "\033[31m")
CYAN   := $(shell printf "\033[36m")
RESET  := $(shell printf "\033[0m")

.PHONY: help cluster schematic generate-config clean destroy iso apply-config get-disks bootstrap-talos patch-node upgrade-node

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

# ==============================================================================
# PROVISIONING & GENERATION
# ==============================================================================
cluster: schematic iso generate-config
	@echo "$(GREEN)Cluster assets generated!$(RESET)"
	@echo "$(YELLOW)Next Steps:$(RESET)"
	@echo "1. Boot your machine(s) using the downloaded metal-$(ARCH).iso"
	@echo "2. Once booted, the machine will display an IP address on its console."
	@echo "3. Run: $(CYAN)make apply-config$(RESET)"
	@echo "4. Repeat for all nodes, then run: $(CYAN)make bootstrap-talos$(RESET)"

# ==============================================================================
# Generate Talos Schematic
# ------------------------------------------------------------------------------
# Process Flow:
# 1. POST the required system extensions to the Talos Factory API.
# 2. Extract and save the returned schematic ID to `schematic.id`.
# ==============================================================================
schematic:
	@echo "$(CYAN)Generating schematic ID for Tailscale, iscsi-tools, and util-linux-tools...$(RESET)"
	@curl -s -X POST -d '{"customization": {"systemExtensions": {"officialExtensions": ["siderolabs/iscsi-tools", "siderolabs/tailscale", "siderolabs/util-linux-tools"]}}}' https://factory.talos.dev/schematics | grep -o '"id":"[^"]*' | cut -d'"' -f4 > schematic.id
	@echo "$(GREEN)Schematic ID saved to schematic.id: `cat schematic.id`$(RESET)"

# ==============================================================================
# Generate Talos Configs
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Prompt for Cluster Name, VIP, and primary Install Disk.
# 2. Save these variables to `k8s/.cluster.env` for downstream k8s bootstrap.
# 3. Prompt for Tailscale Auth Key and inject into a local patch file.
# 4. Generate or Decrypt PKI secrets (talos-secrets.yaml) using SOPS.
# 5. Generate final controlplane/worker YAMLs via talosctl using the secrets,
#    Tailscale patch, and custom ISO schematic ID.
# 6. Validate the output YAMLs against the Talos metal spec.
# ==============================================================================
generate-config:
	@set -e; \
	if [ ! -f patches/controlplane.patch.yaml ]; then echo "$(RED)Missing patches/controlplane.patch.yaml$(RESET)"; exit 1; fi; \
	echo "$(CYAN)Enter Cluster Name [default: $(CLUSTER_NAME)]:$(RESET)"; \
	read CLUSTER_INPUT; \
	if [ -z "$$CLUSTER_INPUT" ]; then CLUSTER_INPUT="$(CLUSTER_NAME)"; fi; \
	echo "$(CYAN)Enter Cluster VIP / API Server IP:$(RESET)"; \
	read VIP; \
	echo "$(CYAN)Enter the primary install disk (e.g. /dev/sda or /dev/nvme0n1) [default: /dev/sda]:$(RESET)"; \
	echo "$(YELLOW)(Hint: If you don't know your disk, metal-$(ARCH)-$(TALOS_VERSION)-$(SCHEMATIC_ID).iso is already downloaded! Boot it, open a new terminal, and run 'make get-disks')$(RESET)"; \
	read DISK_INPUT; \
	if [ -z "$$DISK_INPUT" ]; then DISK_INPUT="/dev/sda"; fi; \
	echo "CLUSTER_NAME=$$CLUSTER_INPUT" > ../k8s/.cluster.env; \
	echo "VIP=$$VIP" >> ../k8s/.cluster.env; \
	echo "$(CYAN)Enter your Tailscale Auth Key (leave blank to skip):$(RESET)"; \
	read TS_KEY; \
	echo ""; \
	if [ -n "$$TS_KEY" ]; then \
		export TS_AUTHKEY="$$TS_KEY"; \
		envsubst < patches/tailscale.patch.yaml > .tailscale.patch.yaml; \
	fi; \
	if [ ! -f talos-secrets.yaml ]; then \
		echo "$(YELLOW)No talos-secrets.yaml found. Generating new cluster secrets...$(RESET)"; \
		talosctl gen secrets -o .talos-secrets.dec.yaml; \
		echo "$(YELLOW)Encrypting secrets to talos-secrets.yaml with SOPS...$(RESET)"; \
		sops -e .talos-secrets.dec.yaml > talos-secrets.yaml; \
	else \
		echo "$(CYAN)Found talos-secrets.yaml. Decrypting for deterministic generation...$(RESET)"; \
		sops -d talos-secrets.yaml > .talos-secrets.dec.yaml; \
	fi; \
	echo "$(CYAN)Generating configurations...$(RESET)"; \
	talosctl gen config $$CLUSTER_INPUT https://$$VIP:6443 --with-secrets .talos-secrets.dec.yaml --config-patch-control-plane @patches/controlplane.patch.yaml --install-disk $$DISK_INPUT --install-image factory.talos.dev/installer/$(SCHEMATIC_ID):$(TALOS_VERSION) --force; \
	if [ -f .tailscale.patch.yaml ]; then \
		echo "---" >> controlplane.yaml; \
		cat .tailscale.patch.yaml >> controlplane.yaml; \
		echo "---" >> worker.yaml; \
		cat .tailscale.patch.yaml >> worker.yaml; \
	fi; \
	rm -f .talos-secrets.dec.yaml .tailscale.patch.yaml; \
	echo "$(CYAN)Validating generated configs...$(RESET)"; \
	talosctl validate --config controlplane.yaml --mode metal; \
	talosctl validate --config worker.yaml --mode metal; \
	echo "$(GREEN)Cluster configs deterministically generated!$(RESET)"

# ==============================================================================
# CLEANUP
# ==============================================================================
clean:
	@echo "$(YELLOW)Cleaning up temporary configurations...$(RESET)"
	@rm -f controlplane.yaml worker.yaml talosconfig ../k8s/.cluster.env

# ==============================================================================
# Destroy Cluster PKI
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Display a critical warning about data and access loss.
# 2. Prompt for explicit user confirmation before proceeding.
# 3. Delete PKI certificates, ISOs, and decrypted SOPS secrets.
# ==============================================================================
destroy: clean
	@echo "$(RED)WARNING: This will completely destroy your cluster's PKI and you will lose access!$(RESET)"
	@echo "$(RED)Are you sure you want to proceed? [y/N]$(RESET)"
	@read -r ans; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		rm -f talosconfig schematic.id metal-*.iso talos-secrets.yaml .talos-secrets.dec.yaml; \
		echo "$(RED)PKI, ISO, and SOPS secrets destroyed. Ready for a fresh install.$(RESET)"; \
	else \
		echo "$(YELLOW)Aborted.$(RESET)"; \
	fi

# ==============================================================================
# LIFECYCLE & MANAGEMENT
# ==============================================================================
# ==============================================================================
# Fetch Bootable ISO
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Verify that a custom schematic ID has been generated.
# 2. Download the Talos metal ISO tailored with our extensions.
# ==============================================================================
iso: schematic
	@if [ ! -f metal-$(ARCH)-$(TALOS_VERSION)-$(SCHEMATIC_ID).iso ]; then \
		echo "$(CYAN)Fetching Talos $(ARCH) ISO for schematic $(SCHEMATIC_ID) version $(TALOS_VERSION)...$(RESET)"; \
		curl -Lo metal-$(ARCH)-$(TALOS_VERSION)-$(SCHEMATIC_ID).iso https://factory.talos.dev/image/$(SCHEMATIC_ID)/$(TALOS_VERSION)/metal-$(ARCH).iso; \
	else \
		echo "$(GREEN)metal-$(ARCH)-$(TALOS_VERSION)-$(SCHEMATIC_ID).iso already exists.$(RESET)"; \
	fi

# ==============================================================================
# Apply Talos Configuration (Single Node)
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Prompt for the IP address of the target booted node.
# 2. Look up the corresponding role and hostname from nodes.csv.
# 3. Apply the configuration (and hostname patch) insecurely to the target node.
# ==============================================================================
apply-config:
	@if [ -z "$(NODE_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of the booted node:$(RESET)"; \
		read NODE_IP_VAL; \
	else \
		NODE_IP_VAL="$(NODE_IP)"; \
	fi; \
	if [ ! -f nodes.csv ]; then echo "$(RED)Error: nodes.csv not found.$(RESET)"; exit 1; fi; \
	ROLE_VAL=$$(grep "^$$NODE_IP_VAL," nodes.csv | cut -d',' -f2); \
	HOSTNAME_VAL=$$(grep "^$$NODE_IP_VAL," nodes.csv | cut -d',' -f3); \
	if [ -z "$$ROLE_VAL" ]; then \
		echo "$(RED)Error: Node IP $$NODE_IP_VAL not found in nodes.csv$(RESET)"; exit 1; \
	fi; \
	if [ ! -f "$$ROLE_VAL.yaml" ]; then \
		echo "$(RED)Error: $$ROLE_VAL.yaml not found. Run 'make generate-config' first.$(RESET)"; \
		exit 1; \
	fi; \
	if [ -n "$$HOSTNAME_VAL" ]; then \
		echo "$(CYAN)Applying $$ROLE_VAL configuration with hostname $$HOSTNAME_VAL to $$NODE_IP_VAL...$(RESET)"; \
		talosctl apply-config --insecure --nodes $$NODE_IP_VAL --file $$ROLE_VAL.yaml --config-patch '{"machine": {"network": {"hostname": "'$$HOSTNAME_VAL'"}}}'; \
	else \
		echo "$(CYAN)Applying $$ROLE_VAL configuration to $$NODE_IP_VAL...$(RESET)"; \
		talosctl apply-config --insecure --nodes $$NODE_IP_VAL --file $$ROLE_VAL.yaml; \
	fi; \
	echo "$(GREEN)Configuration applied! The node will reboot and install Talos.$(RESET)"

# ==============================================================================
# Apply Talos Configuration (All Nodes)
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Loop through all nodes in nodes.csv and sequentially apply their configs.
# ==============================================================================
apply-all:
	@if [ ! -f nodes.csv ]; then echo "$(RED)Error: nodes.csv not found.$(RESET)"; exit 1; fi; \
	grep -v '^#' nodes.csv | while IFS=',' read -r ip role host; do \
		if [ -n "$$ip" ]; then \
			echo "\n$(YELLOW)=== Deploying to $$ip ($$role) ===$(RESET)"; \
			$(MAKE) apply-config NODE_IP="$$ip"; \
		fi; \
	done

# ==============================================================================
# Inspect Node Disks
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Prompt for the IP address of the target booted node.
# 2. Fetch and display the disk information securely from Talos.
# ==============================================================================
get-disks:
	@if [ -z "$(NODE_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of the booted node:$(RESET)"; \
		read NODE_IP_VAL; \
	else \
		NODE_IP_VAL="$(NODE_IP)"; \
	fi; \
	echo "$(CYAN)Fetching disk information for $$NODE_IP_VAL...$(RESET)"; \
	talosctl get disks --insecure --nodes $$NODE_IP_VAL

# ==============================================================================
# Bootstrap Talos (Initialize etcd)
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Prompt for the IP address of one Control Plane node.
# 2. Configure the local talosconfig to point to this node.
# 3. Send the bootstrap command to initialize etcd on the cluster.
# 4. Fetch the kubeconfig once the Kubernetes API server is ready.
# 5. Reroute the kubeconfig context directly to the physical node IP.
# 6. Merge the generated talosconfig into the global ~/.talos/config.
# ==============================================================================
bootstrap-talos:
	@if [ -z "$(CP_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of ONE of your Control Plane nodes:$(RESET)"; \
		read CP_IP_VAL; \
	else \
		CP_IP_VAL="$(CP_IP)"; \
	fi; \
	echo "CP_IP=$$CP_IP_VAL" >> ../k8s/.cluster.env; \
	echo "$(CYAN)Configuring talosconfig with endpoint and node $$CP_IP_VAL...$(RESET)"; \
	talosctl --talosconfig=./talosconfig config endpoint $$CP_IP_VAL; \
	talosctl --talosconfig=./talosconfig config node $$CP_IP_VAL; \
	echo "$(CYAN)Sending bootstrap command to $$CP_IP_VAL...$(RESET)"; \
	talosctl bootstrap --nodes $$CP_IP_VAL --talosconfig=./talosconfig; \
	echo "$(YELLOW)Waiting for Kubernetes API to become ready (this may take a few minutes)...$(RESET)"; \
	echo "$(CYAN)Fetching kubeconfig...$(RESET)"; \
	talosctl kubeconfig --nodes $$CP_IP_VAL --talosconfig=./talosconfig --force; \
	echo "$(YELLOW)Rerouting kubeconfig to physical node for initial bootstrap...$(RESET)"; \
	kubectl config set-cluster $$CLUSTER_NAME --server=https://$$CP_IP_VAL:6443; \
	echo "$(CYAN)Merging talosconfig into your global ~/.talos/config...$(RESET)"; \
	talosctl config merge ./talosconfig; \
	rm -f ./talosconfig
	@echo "$(GREEN)Cluster is awake! You can now use 'kubectl' and 'talosctl' natively!$(RESET)"

# ==============================================================================
# Patch Live Talos Node
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Prompt for the IP address of the target node.
# 2. Prompt for the patch file to apply (default: patches/talos-patch.yaml).
# 3. Apply the machine config patch to the live node.
# ==============================================================================
patch-node:
	@set -e; \
	if [ -z "$(NODE_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of the node to patch:$(RESET)"; \
		read NODE_IP_VAL; \
	else \
		NODE_IP_VAL="$(NODE_IP)"; \
	fi; \
	if [ -z "$(PATCH_FILE)" ]; then \
		echo "$(CYAN)Enter the path to the patch file [default: patches/controlplane.patch.yaml]:$(RESET)"; \
		read PATCH_FILE_INPUT; \
		if [ -z "$$PATCH_FILE_INPUT" ]; then \
			PATCH_FILE_VAL="patches/controlplane.patch.yaml"; \
		else \
			PATCH_FILE_VAL="$$PATCH_FILE_INPUT"; \
		fi; \
	else \
		PATCH_FILE_VAL="$(PATCH_FILE)"; \
	fi; \
	if [ ! -f "$$PATCH_FILE_VAL" ]; then echo "$(RED)Error: Patch file $$PATCH_FILE_VAL not found.$(RESET)"; exit 1; fi; \
	echo "$(CYAN)Applying $$PATCH_FILE_VAL to $$NODE_IP_VAL...$(RESET)"; \
	talosctl patch machineconfig --nodes $$NODE_IP_VAL --patch @$$PATCH_FILE_VAL; \
	echo "$(GREEN)Patch applied successfully!$(RESET)"

# ==============================================================================
# Patch All Live Talos Nodes
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Loop through all nodes in nodes.csv and sequentially apply the patch file.
# ==============================================================================
patch-all:
	@if [ ! -f nodes.csv ]; then echo "$(RED)Error: nodes.csv not found.$(RESET)"; exit 1; fi; \
	grep -v '^#' nodes.csv | while IFS=',' read -r ip role host; do \
		if [ -n "$$ip" ]; then \
			echo "\n$(YELLOW)=== Patching $$ip ($$role) ===$(RESET)"; \
			$(MAKE) patch-node NODE_IP="$$ip" PATCH_FILE="$(PATCH_FILE)"; \
		fi; \
	done

# ==============================================================================
# Rename Live Talos Node
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Read the IP from arguments or prompt interactively.
# 2. Extract the corresponding hostname from nodes.csv.
# 3. Directly patch the HostnameConfig API resource on the live node.
# ==============================================================================
rename-node:
	@set -e; \
	if [ -z "$(NODE_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of the node to rename:$(RESET)"; \
		read NODE_IP_VAL; \
	else \
		NODE_IP_VAL="$(NODE_IP)"; \
	fi; \
	if [ ! -f nodes.csv ]; then echo "$(RED)Error: nodes.csv not found.$(RESET)"; exit 1; fi; \
	HOSTNAME_VAL=$$(grep "^$$NODE_IP_VAL," nodes.csv | cut -d',' -f3); \
	if [ -z "$$HOSTNAME_VAL" ]; then \
		echo "$(RED)Error: Hostname for IP $$NODE_IP_VAL not found in nodes.csv$(RESET)"; exit 1; \
	fi; \
	echo "$(CYAN)Updating hostname for $$NODE_IP_VAL to $$HOSTNAME_VAL via API...$(RESET)"; \
	talosctl patch HostnameConfig --nodes $$NODE_IP_VAL -p '{"hostname": "'$$HOSTNAME_VAL'", "auto": false}'; \
	echo "$(GREEN)Hostname updated!$(RESET)"

# ==============================================================================
# Upgrade Talos OS Version
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Prompt for the IP address of the target node.
# 2. Prompt for the target Talos version.
# 3. Read the custom schematic ID to maintain extensions.
# 4. Initiate the OS upgrade and reboot sequence.
# ==============================================================================
upgrade-node: schematic
	@set -e; \
	if [ -z "$(NODE_IP)" ]; then \
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
	echo "$(CYAN)Upgrading $$NODE_IP_VAL to $$NEW_VERSION_VAL using schematic $(SCHEMATIC_ID)...$(RESET)"; \
	talosctl upgrade --nodes $$NODE_IP_VAL --image factory.talos.dev/installer/$(SCHEMATIC_ID):$$NEW_VERSION_VAL; \
	echo "$(GREEN)Upgrade initiated! The node will reboot when ready.$(RESET)"

# ==============================================================================
# Upgrade All Talos OS Nodes
# ------------------------------------------------------------------------------
# Process Flow:
# 1. Loop through all nodes in nodes.csv and sequentially upgrade them.
# ==============================================================================
upgrade-all:
	@if [ ! -f nodes.csv ]; then echo "$(RED)Error: nodes.csv not found.$(RESET)"; exit 1; fi; \
	if [ -z "$(NEW_VERSION)" ]; then \
		echo "$(CYAN)Enter the new Talos version (e.g. v1.14.0):$(RESET)"; \
		read NEW_VERSION_VAL; \
	else \
		NEW_VERSION_VAL="$(NEW_VERSION)"; \
	fi; \
	grep -v '^#' nodes.csv | while IFS=',' read -r ip role host; do \
		if [ -n "$$ip" ]; then \
			echo "\n$(YELLOW)=== Upgrading $$ip ($$role) ===$(RESET)"; \
			$(MAKE) upgrade-node NODE_IP="$$ip" NEW_VERSION="$$NEW_VERSION_VAL"; \
		fi; \
	done
