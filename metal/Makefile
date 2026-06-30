TALOS_VERSION ?= v1.13.5
ARCH ?= amd64
CLUSTER_NAME ?= robin-lab

HOST_IP ?= $(shell ipconfig getifaddr $$(route get default | awk '/interface:/ {print $$2}') 2>/dev/null || ipconfig getifaddr en0 2>/dev/null || echo "127.0.0.1")
SUBNET ?= $(shell echo $(HOST_IP) | cut -d. -f1-3).0

# By default, try to read the schematic ID if it exists, otherwise tell the user to generate one
SCHEMATIC_ID = $(shell cat schematic.id 2>/dev/null || echo "REPLACE_ME")

# Terminal Colors
GREEN  := $(shell printf "\033[32m")
YELLOW := $(shell printf "\033[33m")
RED    := $(shell printf "\033[31m")
CYAN   := $(shell printf "\033[36m")
RESET  := $(shell printf "\033[0m")

.PHONY: help cluster schematic generate-config fetch-assets matchbox-start matchbox-stop fetch-bootloaders talos-bootstrap

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

cluster: schematic generate-config fetch-assets matchbox-start ## Complete cluster prep and boot

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
		echo "$(CYAN)Enter Cluster VIP / API Server IP:$(RESET)"; \
		read VIP; \
		talosctl gen config $(CLUSTER_NAME) https://$$VIP:6443 --config-patch @patch.yaml --install-image factory.talos.dev/installer/$(SCHEMATIC_ID):$(TALOS_VERSION); \
		echo "$(CYAN)Validating generated configs...$(RESET)"; \
		talosctl validate --config controlplane.yaml --mode metal; \
		talosctl validate --config worker.yaml --mode metal; \
	fi

clean: ## Remove temporary boot assets (preserves your talosconfig PKI)
	@echo "$(YELLOW)Cleaning up temporary boot assets (preserving PKI)...$(RESET)"
	@rm -f controlplane.yaml worker.yaml schematic.id vmlinuz initramfs.xz
	@rm -f matchbox/dnsmasq.conf matchbox/dnsmasq.log matchbox/dnsmasq.pid
	@rm -rf matchbox/data/assets/*
	@find matchbox/tftp -type f ! -name '.gitkeep' -delete

destroy: clean ## DANGER: Completely destroys your Talos admin certificates
	@echo "$(RED)WARNING: This will completely destroy your cluster's PKI and you will lose access!$(RESET)"
	@echo "$(RED)Are you sure you want to proceed? [y/N]$(RESET)"
	@read -r ans; \
	if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
		rm -f talosconfig; \
		echo "$(RED)PKI destroyed.$(RESET)"; \
	else \
		echo "$(YELLOW)Aborted.$(RESET)"; \
	fi

fetch-assets: ## Fetch iPXE kernel and initramfs from Talos Factory
	@if [ "$(SCHEMATIC_ID)" = "REPLACE_ME" ]; then echo "$(RED)Run 'make schematic' first!$(RESET)"; exit 1; fi
	@echo "$(CYAN)Fetching Talos vmlinuz and initramfs for schematic $(SCHEMATIC_ID)...$(RESET)"
	curl -LO https://factory.talos.dev/image/$(SCHEMATIC_ID)/$(TALOS_VERSION)/metal-$(ARCH)/vmlinuz
	curl -LO https://factory.talos.dev/image/$(SCHEMATIC_ID)/$(TALOS_VERSION)/metal-$(ARCH)/initramfs.xz

iso: ## Fetch Talos ISO (Useful for UTM/VM testing)
	@if [ "$(SCHEMATIC_ID)" = "REPLACE_ME" ]; then echo "$(RED)Run 'make schematic' first!$(RESET)"; exit 1; fi
	@echo "$(CYAN)Fetching Talos $(ARCH) ISO for schematic $(SCHEMATIC_ID)...$(RESET)"
	curl -LO https://factory.talos.dev/image/$(SCHEMATIC_ID)/$(TALOS_VERSION)/metal-$(ARCH).iso

fetch-bootloaders: ## Download iPXE bootloaders for TFTP
	@mkdir -p matchbox/tftp
	@if [ ! -f matchbox/tftp/undionly.kpxe ]; then \
		echo "$(CYAN)Downloading AMD64 BIOS bootloader (undionly.kpxe)...$(RESET)"; \
		curl -sL --connect-timeout 5 http://boot.ipxe.org/undionly.kpxe -o matchbox/tftp/undionly.kpxe; \
	fi
	@if [ ! -f matchbox/tftp/ipxe.efi ]; then \
		echo "$(CYAN)Downloading AMD64 UEFI bootloader (ipxe.efi)...$(RESET)"; \
		curl -sL --connect-timeout 5 http://boot.ipxe.org/ipxe.efi -o matchbox/tftp/ipxe.efi; \
	fi
	@if [ ! -f matchbox/tftp/ipxe-arm64.efi ]; then \
		echo "$(CYAN)Downloading ARM64 UEFI bootloader (ipxe-arm64.efi)...$(RESET)"; \
		curl -sL --connect-timeout 5 http://boot.ipxe.org/arm64-efi/ipxe.efi -o matchbox/tftp/ipxe-arm64.efi; \
	fi

matchbox-start: fetch-bootloaders ## Start Matchbox and dnsmasq services
	@which dnsmasq >/dev/null || (echo "$(RED)Error: dnsmasq is not installed. Please run: brew install dnsmasq$(RESET)"; exit 1)
	@echo "$(CYAN)Detected Host IP: $(HOST_IP)$(RESET)"
	@echo "$(CYAN)Detected Subnet: $(SUBNET)$(RESET)"
	@mkdir -p matchbox/data/assets
	@# Copy Talos assets to Matchbox assets directory
	@cp -f vmlinuz initramfs.xz matchbox/data/assets/ 2>/dev/null || true
	@cp -f controlplane.yaml worker.yaml matchbox/data/assets/ 2>/dev/null || true
	@# Render dnsmasq.conf from template
	@sed -e "s|__HOST_IP__|$(HOST_IP)|g" \
	     -e "s|__SUBNET__|$(SUBNET)|g" \
	     -e "s|__PROJECT_ROOT__|$(shell pwd)|g" \
	     matchbox/dnsmasq.conf.template > matchbox/dnsmasq.conf
	@# Render autoexec.ipxe from template
	@sed -e "s|__HOST_IP__|$(HOST_IP)|g" \
	     matchbox/autoexec.ipxe.template > matchbox/tftp/autoexec.ipxe
	@# Start Matchbox container
	@cd matchbox && docker compose up -d
	@# Start dnsmasq natively
	@echo "$(YELLOW)Starting dnsmasq natively (requires sudo to bind ports 67 & 69)...$(RESET)"
	@sudo -v
	@sudo dnsmasq -C matchbox/dnsmasq.conf -d > matchbox/dnsmasq.log 2>&1 & echo $$! > matchbox/dnsmasq.pid
	@echo "$(GREEN)Matchbox and dnsmasq are running!$(RESET)"
	@echo "$(CYAN)Tailing logs (Press Ctrl+C to exit logs, services will remain running)...$(RESET)"
	@sleep 1 && tail -n 15 -f matchbox/dnsmasq.log

matchbox-stop: ## Stop Matchbox and dnsmasq services
	@echo "$(YELLOW)Stopping Matchbox...$(RESET)"
	@cd matchbox && docker compose down
	@echo "$(YELLOW)Stopping dnsmasq...$(RESET)"
	@if [ -f matchbox/dnsmasq.pid ]; then \
		sudo kill $$(cat matchbox/dnsmasq.pid) 2>/dev/null || true; \
		rm -f matchbox/dnsmasq.pid matchbox/dnsmasq.log matchbox/tftp/autoexec.ipxe; \
	else \
		sudo pkill dnsmasq || true; \
		rm -f matchbox/dnsmasq.log matchbox/tftp/autoexec.ipxe; \
	fi
	@echo "$(GREEN)All services stopped.$(RESET)"

talos-bootstrap: ## Bootstrap the Talos cluster (initialize etcd)
	@echo "$(CYAN)Enter the IP address of ONE of your Control Plane nodes:$(RESET)"
	@read CP_IP; \
	echo "$(CYAN)Sending bootstrap command to $$CP_IP...$(RESET)"; \
	talosctl bootstrap --nodes $$CP_IP --endpoints $$CP_IP --talosconfig talosconfig; \
	echo "$(YELLOW)Waiting for Kubernetes API to become ready (this may take a few minutes)...$(RESET)"; \
	echo "$(CYAN)Fetching kubeconfig...$(RESET)"; \
	talosctl kubeconfig --nodes $$CP_IP --endpoints $$CP_IP --talosconfig talosconfig --force
	@echo "$(GREEN)Cluster is awake! You can now run 'make bootstrap'$(RESET)"
