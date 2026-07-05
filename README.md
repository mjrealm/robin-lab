# Robin Lab

Bare-metal Kubernetes homelab using Talos Linux, GitOps (ArgoCD), and strict Disaster Recovery principles.

## Architecture Highlights
- **OS:** Talos Linux custom built via Talos Image Factory (includes `tailscale`, `iscsi-tools`, `util-linux-tools`).
- **Provisioning:** USB/ISO Boot via `talosctl apply-config` and `Makefile`.
- **Storage:** Longhorn CSI (with `kubernetes-csi` external snapshotter for NAS backups).
- **GitOps:** ArgoCD using `ApplicationSets` (`system/`, `platform/`, `apps/`).
- **Disaster Recovery:** Velero backing up state to Cloudflare R2, and persistent volume snapshots to local NAS via Longhorn.

## Prerequisites
Assuming you are using macOS (Apple Silicon M-chip):
```bash
brew install talosctl helm kubectl sops age go jq docker
```

## Configuration Variables
You can customize your deployment parameters by editing the variables at the top of [metal/Makefile](metal/Makefile) or passing them directly inline when running commands:
* `TALOS_VERSION`: The version of Talos Linux to install.
* `ARCH` (default: `amd64`): The target hardware CPU architecture (use `arm64` for Apple Silicon UTM VM testing).
* `CLUSTER_NAME` (default: `robin-lab`): The name of your Kubernetes/Talos cluster.

For example, to prep an ARM64 cluster running Talos v1.14.0:
```bash
make cluster ARCH=arm64 TALOS_VERSION=v1.14.0
```

## TL;DR: Standard / Disaster Recovery Workflow
If the repository is already configured and you are doing a routine cluster rebuild or a full Disaster Recovery from bare metal, just run these commands:

```bash
make cluster          # (Run once) Generate configs and download the bootable Talos ISO
make apply-config     # (Run multiple times) Push configuration to each ISO-booted node
make bootstrap-talos  # (Run once) Initialize the cluster and fetch kubeconfig
make bootstrap-k8s    # (Run once) Install GitOps, Storage, and Backup dependencies
```

---

## The Workflow in Detail

### Step 1: Boot Nodes (Talos)
First, generate your cluster configurations and download the bootable Talos ISO:

```bash
make cluster
```
This will:
1. Generate a Talos Factory custom schematic ID (with system extensions).
2. Generate (and encrypt via SOPS) a `talos-secrets.yaml` bundle if one does not exist.
3. Deterministically generate the cluster config templates (`controlplane.yaml` / `worker.yaml`) with your VIP.
4. Download the specific `metal-amd64.iso` (or arm64) for your architecture.

> [!CAUTION]
> The `make cluster` command generates `metal/talos-secrets.yaml` which is your **cluster's master PKI bundle**. It is automatically encrypted by SOPS and tracked in Git. Because everything is deterministic and encrypted in Git, you no longer need to back up `talosconfig`. **You ONLY need to back up your SOPS `age` private key to your secure vault (e.g., Bitwarden).** As long as you have your `age` key, you can recover your entire cluster!

Next, boot your machine(s) using the downloaded ISO (attach it to your VM or flash it to a USB stick). Once the machine boots, it will display an IP address on its screen.

*(Optional)* If you need to inspect the node's disks to find the correct installation path (e.g., `/dev/sda` or `/dev/nvme0n1`) for your `metal/patch.yaml`, you can run:
```bash
make get-disks
```

From your Mac, push the configuration to the node. The command is interactive and will prompt you for the node's IP address and role (controlplane or worker):
```bash
make apply-config
```
Repeat this for every node in your cluster. The nodes will automatically install Talos to their disks and reboot.

### Step 2: Wake Up the Cluster (Bootstrap Talos)
Once your nodes have rebooted from their hard drives, you must manually initialize `etcd` on the first control plane node to form the cluster.
```bash
make bootstrap-talos
```
This will prompt you for the IP address of one of your Control Plane nodes, automatically issue the bootstrap command, and pull down your `kubeconfig` so you are ready to manage Kubernetes!

### Step 3: Kubernetes Bootstrap
Once Talos is up, we must imperatively install the critical DR dependencies in strict order.

```bash
make bootstrap-k8s
```
**Strict Order Executed:**
1. SOPS Secret Injection.
2. Cilium CNI.
3. CSI External Snapshotter (CRDs required by Longhorn).
4. Cert-Manager (with Cloudflare ClusterIssuer).
5. Longhorn CSI.
6. Velero (configured for R2 + NAS).
7. ArgoCD + Root GitOps ApplicationSet.

Once ArgoCD is running, it will automatically sync `system/`, `platform/`, and `apps/` folders from this repository.

---

## Disaster Recovery (Velero)
If you lose your entire cluster:
1. **Ensure your SOPS `age` private key** is available on your machine (e.g., at `~/.config/sops/age/keys.txt`) so it can decrypt `talos-secrets.yaml`.
2. Run `make cluster` to deterministically regenerate your cluster configurations using your exact certificates.
3. Boot your nodes with the downloaded ISO, then run `make apply-config` for each node.
4. Run `make bootstrap-talos` to wake the cluster.
5. Run `make bootstrap-core`. (This installs Storage and Backup dependencies, but intentionally skips ArgoCD).
6. Run `make recover`. This will automatically list your available backups from Velero and interactively prompt you to type the name of the backup you want to restore.
7. Wait for the restore to complete. You can monitor the progress with:
   ```bash
   velero restore get
   kubectl get pvc -A
   ```
8. Once the restore is marked `Completed` and PVs are bound, install ArgoCD to resume GitOps reconciliation:
   ```bash
   make bootstrap-argocd
   ```

## Updating Node Configurations (Patches)
If you want to modify your cluster configuration (e.g. adding a new disk mount, changing network settings) after the cluster is already running, you can edit the `metal/patch.yaml` file. 

To apply these new patches to a live node without wiping it, use the interactive make target:
```bash
make patch-node
```
The node will automatically apply the changes and seamlessly restart any necessary services (or perform a rolling reboot if the configuration requires it).

## Upgrading Talos OS
Because we use Talos Factory extensions, always upgrade using the installer image that includes your custom schematic ID. We have an interactive make target that handles this safely:
```bash
make upgrade-node
```
This will automatically prompt you for the node's IP address and the target Talos version.

## Adding Worker Nodes
Adding a worker node to an existing cluster is simple because your `metal/worker.yaml` (which contains the required join tokens and cluster certificates) is already generated locally.

1. **Boot the new machine** using your downloaded ISO (Run `make iso` if you need to re-download it).
2. *(Optional)* Run `make get-disks` to inspect the disk layout of the new node once it's booted.
3. Run **`make apply-config`**.
4. When prompted, enter the new node's IP address.
5. When prompted for the role, enter **`worker`**.

The node will automatically install Talos, reboot, and securely join your existing Kubernetes cluster! *(Note: If your new worker node requires a different installation disk path than the one you originally specified during cluster generation, simply edit `metal/worker.yaml` to change the `install: disk:` path before applying the config).*

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
   Edit `k8s/system/kube-system/values.yaml` and update `loadBalancerIPPools` with a reserved block of IP addresses on your home router for Kubernetes LoadBalancers.

### 3. Update ArgoCD GitHub Repository
Edit `k8s/argocd/root-app.yaml` and change `repoURL` to point to your own GitHub fork so ArgoCD syncs your changes instead of the upstream repository!

### 4. Generate Initial Secrets
Before creating a cluster for the first time, generate the encrypted secrets (Cloudflare API for DNS, Age key for SOPS).
```bash
make init-secrets
```
Follow the prompts. Make sure to commit the resulting SOPS-encrypted `secrets.yaml` to the repo!

### 4. Why Cloudflare DNS-01?
We specifically use the Cloudflare API token for `cert-manager`'s DNS-01 challenge. This architecture choice allows your homelab to generate perfectly valid Let's Encrypt SSL certificates (even wildcards) for internal private IP addresses without ever having to expose port 80/443 to the public internet.

</details>