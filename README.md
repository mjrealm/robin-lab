# Robin Lab

Bare-metal Kubernetes homelab using Talos Linux, GitOps (ArgoCD), and strict Disaster Recovery principles.

## Architecture Highlights
- **OS:** Talos Linux custom built via Talos Image Factory (includes `tailscale`, `iscsi-tools`, `util-linux-tools`).
- **Provisioning:** Declarative node configuration and SOPS-encrypted PKI via GitOps Makefiles.
- **Networking:** Cilium CNI (with kube-proxy replacement and L2 Announcement for LoadBalancer VIPs).
- **Storage:** Longhorn CSI (with `kubernetes-csi` external snapshotter for NAS backups).
- **GitOps:** ArgoCD using `ApplicationSets` (`system/`, `platform/`, `apps/`).
- **Disaster Recovery:** Velero backing up state to Cloudflare R2, and persistent volume snapshots to local NAS via Longhorn.

## Prerequisites
Assuming you are using macOS (Apple Silicon M-chip):
```bash
brew install talosctl helm kubectl sops age gettext watch yamllint
```

## Configuration Variables
You can customize your deployment parameters by editing the variables at the top of [metal/Makefile](metal/Makefile) or passing them directly inline when running commands:
* `TALOS_VERSION`: The version of Talos Linux to install.
* `ARCH` (default: `amd64`): The target hardware CPU architecture (use `arm64` for Apple Silicon UTM VM testing).
* `CLUSTER_NAME` (default: `robin`): The name of your Kubernetes/Talos cluster.

For example, to prep an ARM64 cluster running Talos v1.14.0:
```bash
make cluster ARCH=arm64 TALOS_VERSION=v1.14.0
```

## TL;DR (Quick Start)

Assuming your configuration files (`metal/metal.secrets.dec.yaml` and `metal/metal.yaml`) are filled out, run these in order from the root directory:

```bash
make cluster          # (Run once) Generate configs and download the bootable Talos ISO
# make wipe-disk NODE_IP=x.x.x.x DISK=sdb  # (Optional) If you have additional disks, wipe them first!
make apply-all        # (Run once) Push configuration to all nodes defined in metal.yaml
make bootstrap-talos  # (Run once) Initialize the cluster and fetch kubeconfig
make bootstrap-k8s    # (Run once) Install GitOps, Storage, and Backup dependencies
```

> [!WARNING]
> **Performing a Disaster Recovery?** Do NOT run `make bootstrap-k8s`. You must restore your Velero backups *before* installing ArgoCD. Follow the full instructions in the [Disaster Recovery](#disaster-recovery-velero) section below!

---

## The Workflow in Detail

### Step 1: Boot Nodes and Define Cluster

1. Boot your servers using the customized `talos-metal-amd64.iso` from the `metal/` directory.
2. Once booted, the console will display an IP address. Note these down.
3. Edit `metal/metal.yaml` to define your cluster network, load balancer IP pools, and your physical machines:
   ```yaml
   cluster:
     name: robin
     vip: 192.168.30.200
     disk: /dev/sda
     lb_ippools:
       - 192.168.30.200/29

    nodes:
      - ip: 192.168.30.200
        role: controlplane
        hostname: robin-cp-01
      - ip: 192.168.30.201
        role: worker
        hostname: robin-worker-01
        install_disk: /dev/nvme0n1  # (Optional) Override the cluster base disk for this specific node
        additional_disks:
          - /dev/sdb
    ```
4. Run `make init-secrets` from the root directory to generate your `metal/metal.secrets.dec.yaml` template, and fill it in with your keys:
   ```yaml
   secrets:
     tailscale_auth_key: "..."
     cloudflare_api_token: "..."
     age_private_key: "..."
   ```
   *Note: `.dec.yaml` files are `.gitignore`d. When you run `make cluster`, the Makefile will automatically encrypt this file into `metal.secrets.yaml` via SOPS! All processes safely read from the encrypted version.*

### Step 2: Push Configurations

From the root directory, deploy the OS securely to all your nodes at once:

```bash
make apply-all
```

*(Alternatively, you can deploy a specific node using `make apply-config NODE_IP=x.x.x.x`. If `additional_disks` are defined, they will be formatted and mounted at `/var/mnt/<disk>`, ready for Longhorn!)*

### Step 3: Wake Up the Cluster (Bootstrap Talos)
Once your nodes have rebooted from their hard drives, you must manually initialize `etcd` on the first control plane node to form the cluster.
```bash
make bootstrap-talos
```
This will automatically parse `metal.yaml` for the first control plane node, issue the bootstrap command, and pull down your kubeconfig so you are ready to manage Kubernetes!

### Step 4: Kubernetes Bootstrap
Once Talos is up, we must imperatively install the critical DR dependencies in strict order.

```bash
make bootstrap-k8s
```
**Strict Order Executed:**
1. SOPS Secret Injection (Silently reads from `metal.secrets.yaml`).
2. Cilium CNI.
3. CSI External Snapshotter (CRDs required by Longhorn).
4. Cert-Manager (with Cloudflare ClusterIssuer).
5. Longhorn CSI.
6. Velero (configured for R2 + NAS).
7. ArgoCD + Root GitOps ApplicationSet.

Once ArgoCD is running, it will automatically sync `system/`, `platform/`, and `apps/` folders from this repository.

---

## Disaster Recovery (Velero)
If you lose your entire cluster, ensure your `metal/metal.secrets.yaml` is securely tracked and filled out locally. Then, rebuild your cluster and restore state in this exact sequence:

```bash
make cluster          # Deterministically regenerate your configs using your exact certificates
# Boot your nodes with the downloaded ISO here before proceeding
make apply-all        # Push the generated configurations to all your nodes
make bootstrap-talos  # Wake the cluster and initialize etcd
make bootstrap-core   # Install Storage/Backup dependencies (intentionally skips ArgoCD)

# -------------------------------------------------------------------------------------- #
# WARNING: The next command launches an interactive dashboard. 
# You MUST wait for the restore to show "Completed" and all PVs to show "Bound".
# Once completely finished, press Ctrl+C to exit and run the final ArgoCD command!
# -------------------------------------------------------------------------------------- #

make recover          # Select a Velero backup and launch the interactive restore monitor
make bootstrap-argocd # Resume GitOps reconciliation (ONLY AFTER RECOVERY IS COMPLETE)
```

## Updating Node Configurations (Patches)
If you want to modify your cluster configuration (e.g. adding a new disk mount, changing network settings) after the cluster is already running, you can create or edit a YAML patch file in the `metal/patches/` directory.

To apply a patch to a live node without wiping it, use:
```bash
make patch-node NODE_IP=192.168.30.200 PATCH_FILE=metal/patches/controlplane.patch.yaml
```
*(Note: If you run `make patch-node` without arguments, it will interactively prompt you for the IP and file. You can also run `make patch-all PATCH_FILE=...` to apply a patch to every node).*

The node will automatically apply the changes and seamlessly restart any necessary services (or perform a rolling reboot if the configuration requires it).
## Upgrading Talos OS
Because we use Talos Factory extensions, always upgrade using the installer image that includes your custom schematic ID. We have an interactive make target that handles this safely:
```bash
make upgrade-node
```
This will automatically prompt you for the node's IP address and the target Talos version.

## Adding Worker Nodes
Adding a worker node to an existing cluster is simple because your cluster PKI and identity is safely encrypted in Git.

1. **Add the new node** to the `nodes` list in your `metal.yaml`.
2. **Run `make generate-config`** (This decrypts your `talos-secrets.yaml` and deterministically recreates your `worker.yaml` template).
3. **Boot the new machine** using your downloaded ISO (Run `make iso` if you need to re-download it).
4. *(Optional)* Run `make get-disks NODE_IP=x.x.x.x` to inspect the disk layout of the new node once it's booted.
5. Run **`make apply-config NODE_IP=x.x.x.x`**.

The Makefile will automatically read the node's role, hostname, and disk settings from `metal.yaml`, inject any necessary patches dynamically, and push the configuration! The node will automatically install Talos, reboot, and securely join your existing Kubernetes cluster.

## Wiping and Destroying
If you need to wipe a specific disk on a booted (but unconfigured) node:
```bash
make wipe-disk NODE_IP=192.168.30.200 DISK=sdb
```

If you want to clean up local generated templates (`.yaml` and `.iso` files):
```bash
make clean
```

If you want to permanently **destroy** your cluster's cryptographic identity and start a brand new cluster from scratch (This deletes `talos-secrets.yaml`):
```bash
make destroy
```

---

<details>
<summary><h2>First-Time Repository Setup (Expand if cloning for the first time)</h2></summary>

If you are setting this up for the very first time, you must configure SOPS and your storage endpoints *before* running the TL;DR commands.

### 1. Setup SOPS Configuration
You must generate an `age` key pair and configure SOPS to encrypt your secrets.

1. **Generate your Age keys:**
   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/keys.txt
   ```
2. **Get your Public Key:**
   ```bash
   age-keygen -y ~/.config/sops/age/keys.txt
   ```
3. **Create `.sops.yaml`:**
   Create a `.sops.yaml` file in the root of this repository and paste your public key inside:
   ```yaml
   creation_rules:
     - path_regex: .*.yaml
       age: "<YOUR_PUBLIC_KEY_HERE>"
   ```

### 2. Configure Local Endpoints
Ensure your storage targets and network pools are correctly defined in your repository:

1. **Longhorn NAS Backup Target:**
   Edit `k8s/system/longhorn-system/values.yaml` and update `backupTarget` with your NAS IP address and NFS path.
2. **Velero Cloudflare R2 Target:**
   Edit `k8s/system/velero/values.yaml` and update your `bucket` and `s3Url`.
3. **Cilium LoadBalancer IP Pool:**
   Define your reserved IP block (CIDR) directly in the `lb_ippools` array within your `metal/metal.yaml`. The Makefile will automatically parse this and deploy the CRD during `make bootstrap-k8s`.

### 3. Update ArgoCD GitHub Repository
Edit `k8s/argocd/root-app.yaml` and change `repoURL` to point to your own GitHub fork so ArgoCD syncs your changes instead of the upstream repository!

### 4. Generate Initial Secrets
Before creating a cluster for the first time, generate the secret template:
```bash
make init-secrets
```
This will generate a `metal/metal.secrets.dec.yaml` file. Open this file and fill in your keys (Cloudflare API for DNS, Age key for SOPS, etc). The Makefile will automatically encrypt it to `metal.secrets.yaml` and `.gitignore` the plain-text version when you run `make cluster`.

### 5. Why Cloudflare DNS-01?
We specifically use the Cloudflare API token for `cert-manager`'s DNS-01 challenge. This architecture choice allows your homelab to generate perfectly valid Let's Encrypt SSL certificates (even wildcards) for internal private IP addresses without ever having to expose port 80/443 to the public internet.

</details>