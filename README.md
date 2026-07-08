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

## TL;DR: Fresh Install / Cluster Rebuild
If the repository is already configured and you are doing a routine cluster rebuild or a fresh installation, ensure you have filled out your configuration files:
1. Copy `metal/metal.secrets.example.yaml` to `metal/metal.secrets.yaml` and fill it out with your keys (Tailscale Auth Key, Cloudflare API Token, Age Private Key).
2. Edit `metal/metal.yaml` to define your cluster VIP, install disk, load balancer IP pools, and all your physical nodes (IPs, roles, hostnames, and extra disks).

Once ready, just run these commands from the root directory:

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
4. Copy `metal/metal.secrets.example.yaml` (if it exists) or create `metal/metal.secrets.dec.yaml` with the following structure:
   ```yaml
   secrets:
     tailscale_auth_key: "..."
     cloudflare_api_token: "..."
     age_private_key: "..."
   ```
   *Note: `.dec.yaml` files are `.gitignore`d. When you run `make apply-all`, the Makefile will automatically encrypt this file into `metal.secrets.yaml` via SOPS and commit-safe! All processes read from the encrypted version.*

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
If you lose your entire cluster:
1. **Ensure `metal/metal.secrets.yaml` is filled out** locally with your age private key, cloudflare token, and tailscale key.
2. Run `make cluster` to deterministically regenerate your cluster configurations using your exact certificates.
3. Boot your nodes with the downloaded ISO, then run `make apply-all` to push the configurations.
4. Run `make bootstrap-talos` to wake the cluster.
5. Run `make bootstrap-core`. (This installs Storage and Backup dependencies, but intentionally skips ArgoCD).
6. Run `make recover`. This will automatically list your available backups from Velero and interactively prompt you to type the name of the backup you want to restore.
7. Once triggered, `make recover` will automatically launch a live dashboard in your terminal showing the Velero restore status and your PVC bindings. Monitor it until the restore is `Completed` and PVs are `Bound`, then press `Ctrl+C` to exit.
8. Once the restore is marked `Completed` and PVs are bound, install ArgoCD to resume GitOps reconciliation:
   ```bash
   make bootstrap-argocd
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