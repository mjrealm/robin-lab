# Robin Lab

Bare-metal Kubernetes homelab using Talos Linux, GitOps (ArgoCD), and strict Disaster Recovery principles.

## Architecture Highlights
- **OS:** Talos Linux (v1.13.5) custom built via Talos Image Factory (includes `tailscale`, `iscsi-tools`, `util-linux-tools`).
- **Provisioning:** Network boot (iPXE) via `pixiecore` directly from the `Makefile`.
- **Storage:** Longhorn CSI (with `kubernetes-csi` external snapshotter for NAS backups).
- **GitOps:** ArgoCD using `ApplicationSets` (`system/`, `platform/`, `apps/`).
- **Disaster Recovery:** Velero backing up state to Cloudflare R2, and persistent volume snapshots to local NAS via Longhorn.

## Prerequisites
Assuming you are using macOS (Apple Silicon M-chip):
```bash
brew install talosctl helm kubectl sops age go
go install go.universe.tf/netboot/cmd/pixiecore@latest
```

## TL;DR: Standard / Disaster Recovery Workflow
If the repository is already configured and you are doing a routine cluster rebuild or a full Disaster Recovery from bare metal, just run these three commands:

```bash
make cluster     # PXE boot the Talos OS onto your nodes
make ignite      # Wake up the cluster and fetch kubeconfig
make bootstrap   # Install GitOps, Storage, and Backup dependencies
```

---

## The Workflow in Detail

### Step 1: Boot Nodes (Talos)
Generate a Talos Factory schematic, patch your config, and boot the nodes via `pixiecore`.

```bash
make cluster
```
This will:
1. Generate a Talos factory schematic ID.
2. Generate `controlplane.yaml` and `worker.yaml` with your VIP.
3. Download the specific `vmlinuz` and `initramfs` for your schematic.
4. Run `pixiecore` to serve the iPXE boot process over your network.
*Note: Make sure your nodes are configured to PXE boot.*

### Step 2: Wake Up the Cluster (Ignite)
Once your nodes have rebooted from their hard drives, you must manually initialize `etcd` on the first control plane node to form the cluster.
```bash
make ignite
```
This will automatically issue the bootstrap command and pull down your `kubeconfig` so you are ready to manage Kubernetes!

### Step 3: Kubernetes Bootstrap
Once Talos is up, we must imperatively install the critical DR dependencies in strict order.

```bash
make bootstrap
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
1. Run `make cluster` to rebuild the Talos nodes.
2. Run `make ignite` to wake the cluster.
3. Run `make bootstrap-core`. (This installs Storage and Backup dependencies, but intentionally skips ArgoCD).
4. Run `make recover` which triggers:
   ```bash
   velero restore create --from-backup latest-backup
   ```
5. Wait for PVs and state to restore. Then install ArgoCD (`make bootstrap-argocd`) to resume GitOps reconciliation.

## Upgrading Talos
Because we use Talos Factory extensions, always upgrade using the installer image that includes your schematic ID.
```bash
# Check schematic.id file
talosctl upgrade --nodes <NODE_IP> --image factory.talos.dev/installer/$(cat metal/schematic.id):v1.14.0
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