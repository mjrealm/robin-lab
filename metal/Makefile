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

# ==============================================================================
# Initialize Secrets
# ==============================================================================
init-secrets:
	@if [ ! -f metal.secrets.dec.yaml ] && [ ! -f metal.secrets.yaml ]; then \
		echo "secrets:\n  tailscale_auth_key: \"\"\n  cloudflare_api_token: \"\"\n  age_private_key: \"\"" > metal.secrets.dec.yaml; \
		echo "$(GREEN)Created metal.secrets.dec.yaml! Please fill it out with your keys.$(RESET)"; \
	else \
		echo "$(YELLOW)Secrets file already exists.$(RESET)"; \
	fi

view-secrets:
	@if [ -f metal.secrets.dec.yaml ]; then \
		echo "$(YELLOW)Found metal.secrets.dec.yaml, encrypting with SOPS...$(RESET)"; \
		sops -e metal.secrets.dec.yaml > metal.secrets.yaml; \
	fi; \
	if [ ! -f metal.secrets.yaml ]; then echo "$(RED)Missing metal.secrets.yaml. Run 'make init-secrets' first.$(RESET)"; exit 1; fi; \
	sops -d metal.secrets.yaml

# ==============================================================================
# Generate Talos Machine Configurations
# ==============================================================================
generate-config:
	@set -e; \
	if [ ! -f patches/controlplane.patch.yaml ]; then echo "$(RED)Missing patches/controlplane.patch.yaml$(RESET)"; exit 1; fi; \
	if [ ! -f metal.yaml ]; then echo "$(RED)Missing metal.yaml$(RESET)"; exit 1; fi; \
	if [ -f metal.secrets.dec.yaml ]; then \
		echo "$(YELLOW)Found metal.secrets.dec.yaml, encrypting with SOPS to metal.secrets.yaml...$(RESET)"; \
		sops -e metal.secrets.dec.yaml > metal.secrets.yaml; \
	fi; \
	if [ ! -f metal.secrets.yaml ]; then echo "$(RED)Missing metal.secrets.yaml. Run 'make init-secrets' first.$(RESET)"; exit 1; fi; \
	CLUSTER_NAME=$$(yq '.cluster.name' metal.yaml); \
	VIP=$$(yq '.cluster.vip' metal.yaml); \
	DISK_INPUT=$$(yq '.cluster.disk' metal.yaml); \
	TS_KEY=$$(sops -d metal.secrets.yaml | yq '.secrets.tailscale_auth_key'); \
	if [ -n "$$TS_KEY" ] && [ "$$TS_KEY" != "null" ] && [ "$$TS_KEY" != '""' ]; then \
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
	talosctl gen config $$CLUSTER_NAME https://$$VIP:6443 --with-secrets .talos-secrets.dec.yaml --config-patch-control-plane @patches/controlplane.patch.yaml --install-disk $$DISK_INPUT --install-image factory.talos.dev/installer/$(SCHEMATIC_ID):$(TALOS_VERSION) --force; \
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
# Apply Talos Configurations to a Single Node
# ==============================================================================
apply-config:
	@set -e; \
	if [ -z "$(NODE_IP)" ]; then \
		echo "$(RED)Error: NODE_IP is required. e.g. make apply-config NODE_IP=1.2.3.4$(RESET)"; exit 1; \
	fi; \
	if [ ! -f metal.yaml ]; then echo "$(RED)Error: metal.yaml not found.$(RESET)"; exit 1; fi; \
	ROLE_VAL=$$(yq '.nodes[] | select(.ip == "'$(NODE_IP)'") | .role' metal.yaml); \
	HOSTNAME_VAL=$$(yq '.nodes[] | select(.ip == "'$(NODE_IP)'") | .hostname' metal.yaml); \
	if [ -z "$$ROLE_VAL" ] || [ "$$ROLE_VAL" = "null" ]; then \
		echo "$(RED)Error: Node IP $(NODE_IP) not found in metal.yaml$(RESET)"; exit 1; \
	fi; \
	if [ ! -f "$$ROLE_VAL.yaml" ]; then \
		echo "$(RED)Error: $$ROLE_VAL.yaml not found. Run 'make generate-config' first.$(RESET)"; \
		exit 1; \
	fi; \
	PATCH_ARG="--config-patch '{\"machine\": {\"network\": {\"hostname\": \"$$HOSTNAME_VAL\"}}}'"; \
	DISKS_JSON=$$(yq -o=json '.nodes[] | select(.ip == "'$(NODE_IP)'") | .additional_disks // []' metal.yaml); \
	rm -f .user-volumes.yaml; touch .user-volumes.yaml; \
	if [ "$$DISKS_JSON" != "[]" ]; then \
		echo "$(CYAN)Found additional disks for $(NODE_IP), generating UserVolumeConfigs...$(RESET)"; \
		for diskpath in $$(echo "$$DISKS_JSON" | jq -r '.[]'); do \
			diskname=$$(basename "$$diskpath"); \
			echo "---" >> .user-volumes.yaml; \
			echo "apiVersion: v1alpha1" >> .user-volumes.yaml; \
			echo "kind: UserVolumeConfig" >> .user-volumes.yaml; \
			echo "name: $$diskname" >> .user-volumes.yaml; \
			echo "provisioning:" >> .user-volumes.yaml; \
			echo "  diskSelector:" >> .user-volumes.yaml; \
			echo "    match: disk.name == '$$diskname'" >> .user-volumes.yaml; \
			echo "  grow: false" >> .user-volumes.yaml; \
			echo ""; \
			echo "$(YELLOW)========================================================================$(RESET)"; \
			echo "$(YELLOW)REMINDER: Disk /var/mnt/$$diskname will be formatted and mounted.$(RESET)"; \
			echo "$(YELLOW)Please add it via the Longhorn UI later!$(RESET)"; \
			echo "$(YELLOW)========================================================================$(RESET)"; \
			echo ""; \
		done; \
	fi; \
	echo "$(CYAN)Applying $$ROLE_VAL configuration with hostname $$HOSTNAME_VAL to $(NODE_IP)...$(RESET)"; \
	cat $$ROLE_VAL.yaml .user-volumes.yaml > .apply.yaml; \
	eval "talosctl apply-config --insecure --nodes $(NODE_IP) --file .apply.yaml $$PATCH_ARG"; \
	rm -f .user-volumes.yaml .apply.yaml; \
	echo "$(GREEN)Configuration applied! The node will reboot and install Talos.$(RESET)"

# ==============================================================================
# Wipe Disk (Run after USB Boot, before apply-config)
# ==============================================================================
wipe-disk:
	@set -e; \
	if [ -z "$(NODE_IP)" ]; then \
		echo "$(RED)Error: NODE_IP is required. e.g. make wipe-disk NODE_IP=192.168.30.201 DISK=sdb$(RESET)"; exit 1; \
	fi; \
	if [ -z "$(DISK)" ]; then \
		echo "$(RED)Error: DISK is required. e.g. make wipe-disk NODE_IP=192.168.30.201 DISK=sdb$(RESET)"; exit 1; \
	fi; \
	DISK_CLEAN=$$(basename "$(DISK)"); \
	echo "$(CYAN)Wiping disk $$DISK_CLEAN on node $(NODE_IP)...$(RESET)"; \
	talosctl wipe disk $$DISK_CLEAN --nodes $(NODE_IP) --insecure; \
	echo "$(GREEN)Disk wiped successfully!$(RESET)"

# ==============================================================================
# Apply Configurations to All Booted Nodes
# ==============================================================================
apply-all:
	@if [ ! -f metal.yaml ]; then echo "$(RED)Error: metal.yaml not found.$(RESET)"; exit 1; fi; \
	yq e -o=j -I=0 '.nodes[]' metal.yaml | while read -r node; do \
		ip=$$(echo "$$node" | jq -r .ip); \
		role=$$(echo "$$node" | jq -r .role); \
		echo "\n$(YELLOW)=== Deploying to $$ip ($$role) ===$(RESET)"; \
		$(MAKE) apply-config NODE_IP="$$ip"; \
	done

# ==============================================================================
# Inspect Node Disks
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
# ==============================================================================
bootstrap-talos:
	@if [ ! -f metal.yaml ]; then echo "$(RED)Error: metal.yaml not found.$(RESET)"; exit 1; fi; \
	CP_IP_VAL=$$(yq '.nodes[] | select(.role == "controlplane") | .ip' metal.yaml | head -n 1); \
	if [ -z "$$CP_IP_VAL" ] || [ "$$CP_IP_VAL" = "null" ]; then \
		echo "$(RED)Error: No controlplane node found in metal.yaml$(RESET)"; exit 1; \
	fi; \
	CLUSTER_NAME=$$(yq '.cluster.name' metal.yaml); \
	echo "$(CYAN)Selected Master CP: $$CP_IP_VAL$(RESET)"; \
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
# ==============================================================================
patch-all:
	@if [ ! -f metal.yaml ]; then echo "$(RED)Error: metal.yaml not found.$(RESET)"; exit 1; fi; \
	yq e -o=j -I=0 '.nodes[]' metal.yaml | while read -r node; do \
		ip=$$(echo "$$node" | jq -r .ip); \
		role=$$(echo "$$node" | jq -r .role); \
		echo "\n$(YELLOW)=== Patching $$ip ($$role) ===$(RESET)"; \
		$(MAKE) patch-node NODE_IP="$$ip" PATCH_FILE="$(PATCH_FILE)"; \
	done

# ==============================================================================
# Rename Live Talos Node
# ==============================================================================
rename-node:
	@set -e; \
	if [ -z "$(NODE_IP)" ]; then \
		echo "$(CYAN)Enter the IP address of the node to rename:$(RESET)"; \
		read NODE_IP_VAL; \
	else \
		NODE_IP_VAL="$(NODE_IP)"; \
	fi; \
	if [ ! -f metal.yaml ]; then echo "$(RED)Error: metal.yaml not found.$(RESET)"; exit 1; fi; \
	HOSTNAME_VAL=$$(yq '.nodes[] | select(.ip == "'$$NODE_IP_VAL'") | .hostname' metal.yaml); \
	if [ -z "$$HOSTNAME_VAL" ] || [ "$$HOSTNAME_VAL" = "null" ]; then \
		echo "$(RED)Error: Hostname for IP $$NODE_IP_VAL not found in metal.yaml$(RESET)"; exit 1; \
	fi; \
	echo "$(CYAN)Updating hostname for $$NODE_IP_VAL to $$HOSTNAME_VAL via API...$(RESET)"; \
	talosctl patch HostnameConfig --nodes $$NODE_IP_VAL -p '{"hostname": "'$$HOSTNAME_VAL'", "auto": false}'; \
	echo "$(GREEN)Hostname updated!$(RESET)"

# ==============================================================================
# Upgrade Talos OS Version
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
# ==============================================================================
upgrade-all:
	@if [ ! -f metal.yaml ]; then echo "$(RED)Error: metal.yaml not found.$(RESET)"; exit 1; fi; \
	if [ -z "$(NEW_VERSION)" ]; then \
		echo "$(CYAN)Enter the new Talos version (e.g. v1.14.0):$(RESET)"; \
		read NEW_VERSION_VAL; \
	else \
		NEW_VERSION_VAL="$(NEW_VERSION)"; \
	fi; \
	yq e -o=j -I=0 '.nodes[]' metal.yaml | while read -r node; do \
		ip=$$(echo "$$node" | jq -r .ip); \
		role=$$(echo "$$node" | jq -r .role); \
		echo "\n$(YELLOW)=== Upgrading $$ip ($$role) ===$(RESET)"; \
		$(MAKE) upgrade-node NODE_IP="$$ip" NEW_VERSION="$$NEW_VERSION_VAL"; \
	done
