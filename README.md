# kolla-templates

Kolla-Ansible deployment templates, plus a guide to picking a matching kolla-ansible branch, container tag, host OS and Python version.

## Repository layout

| Path | What it is |
|---|---|
| [all-in-one/](all-in-one/) | Single-node deploy driven from a separate deployment host: `2025.2-ubuntu-noble` with a custom Horizon image. Step-by-step guide in [all-in-one/README.md](all-in-one/README.md). |
| [multinode/2-node-demo/](multinode/2-node-demo/) | Two-node deploy using OVN. `globals-basic.yml` is plain OVN; `globals-provider-net.yml` / `globals.yml` add provider networks with distributed floating IPs. Build notes in [context.md](multinode/2-node-demo/context.md). |

---

# Kolla release selection and deployment

## Official docs and release info

| Resource | URL |
|----------|-----|
| Kolla-Ansible Quick Start (full install and deploy walkthrough) | https://docs.openstack.org/kolla-ansible/2026.1/user/quickstart.html |
| Multinode deployment | https://docs.openstack.org/kolla-ansible/2026.1/user/multinode.html |
| Production architecture guide | https://docs.openstack.org/kolla-ansible/2026.1/admin/production-architecture-guide.html |
| Operating Kolla (upgrades, reconfigure, day-2 tasks) | https://docs.openstack.org/kolla-ansible/2026.1/user/operating-kolla.html |
| Supported host OS per release | https://docs.openstack.org/kolla-ansible/2026.1/user/support-matrix.html |
| Kolla-Ansible release notes | https://docs.openstack.org/releasenotes/kolla-ansible/ |
| OpenStack series status (maintained / EOL dates) | https://releases.openstack.org/ |
| Python per kolla-ansible branch | See [Step 3](#step-3-create-a-python-venv-for-this-release) |
| Container tags (Quay.io) | https://quay.io/repository/openstack.kolla/kolla-toolbox?tab=tags |

> The docs URLs contain the release (`2026.1`). Change it to match your kolla-ansible branch, e.g. `/kolla-ansible/2025.2/…`. `latest` documents `master`, not the newest stable release.

---

## How Quay tags map to kolla-ansible releases

> These are upstream's **test images**. For production, see [Test images vs production images](#test-images-vs-production-images).

Quay tags follow this pattern:

```
<openstack-release>-<distro>-<distro-version>[-aarch64]
```

`<distro-version>` is a codename for Ubuntu/Debian (`noble`, `trixie`) and a number for Rocky (`9`, `10`). ARM images have an `-aarch64` suffix.

> **Note:** Up to Zed, the release part was the codename (e.g. `zed-ubuntu-jammy`). From **2023.1** (Antelope) onwards it is **year.cycle** (e.g. `2023.2-ubuntu-jammy`, not `bobcat-…`).

### Current tags (as of September 2026, x86_64)

| Quay tag | kolla-ansible branch | Status | Host OS |
|---|---|---|---|
| `master-ubuntu-noble` | `master` | ⚠️ Daily / bleeding edge | Ubuntu 24.04 (Noble) |
| `master-debian-trixie` | `master` | ⚠️ Daily / bleeding edge | Debian 13 (Trixie) |
| `master-rocky-10` | `master` | ⚠️ Daily / bleeding edge | Rocky Linux 10 |
| `2026.1-ubuntu-noble` | `stable/2026.1` | ✅ Maintained (latest) | Ubuntu 24.04 (Noble) |
| `2026.1-debian-trixie` | `stable/2026.1` | ✅ Maintained (latest) | Debian 13 (Trixie) |
| `2026.1-rocky-10` | `stable/2026.1` | ✅ Maintained (latest) | Rocky Linux 10 |
| `2025.2-ubuntu-noble` | `stable/2025.2` | ✅ Maintained | Ubuntu 24.04 (Noble) |
| `2025.2-debian-bookworm` | `stable/2025.2` | ✅ Maintained | Debian 12 (Bookworm) |
| `2025.2-rocky-10` | `stable/2025.2` | ✅ Maintained | Rocky Linux 10 |
| `2025.1-ubuntu-noble` | `stable/2025.1` | 🟡 Maintained, goes Unmaintained ~2026-10-02 | Ubuntu 24.04 (Noble) |
| `2025.1-debian-bookworm` | `stable/2025.1` | 🟡 Maintained, goes Unmaintained ~2026-10-02 | Debian 12 (Bookworm) |
| `2025.1-rocky-9` / `2025.1-rocky-10` | `stable/2025.1` | 🟡 Maintained, goes Unmaintained ~2026-10-02 | Rocky Linux 9 / 10 |
| `2024.2-{ubuntu-noble,debian-bookworm,rocky-9}` | `stable/2024.2` | 🔴 EOL (2026-04-29); images no longer rebuilt | — |
| `2024.1-{ubuntu-noble,ubuntu-jammy,debian-bookworm,rocky-9}` | `stable/2024.1` | 🔴 Unmaintained; images no longer rebuilt | — |

> **master** images are rebuilt **daily** from a moving branch. Fine for development, not for production.  
> **stable/\<year.cycle\>** images are also rebuilt regularly, but only pick up bug and security fixes from the stable branch. The tag itself moves, so mirror the images to a local registry if you need exactly repeatable deploys.

To refresh this table, list the tags with their last rebuild date. A branch that has stopped being rebuilt is EOL or unmaintained:

```bash
curl -s "https://quay.io/api/v1/repository/openstack.kolla/kolla-toolbox/tag/?limit=100&onlyActiveTags=true" \
  | jq -r '.tags[] | select(.name | endswith("aarch64") | not) | "\(.last_modified[5:16])  \(.name)"'
```

**Rule:** tag prefix == kolla-ansible branch. If they don't match, deploys break (e.g. `ansible-runner not found in kolla_toolbox`).

---

## Test images vs production images

The quay.io images above are built automatically by upstream's CI every day, to test kolla's own code. Nobody reviews or releases them. The same tag is overwritten with new builds, and upstream makes no promise that they're secure or will stay available. They're fine for trying Kolla out, but not meant for production. From 2026.1, `kolla-ansible prechecks` stops if you use them:

```
Kolla images from quay.io/openstack.kolla namespace are meant only for testing purposes,
if you want to continue using them please use --use-test-images CLI argument
```

**For testing,** acknowledge it with `kolla-ansible prechecks -i ./multinode --use-test-images` (only `prechecks` has this flag), or set `kolla_test_images: true` in `globals.yml`.

**For production,** build your own images and serve them from your own registry:

1. **Run a container registry**, e.g. Harbor, Nexus or a plain Docker registry.
2. **Build the images with `kolla-build`** from the same release, on a machine with Docker, in its own venv:
   ```bash
   pip install git+https://opendev.org/openstack/kolla@stable/2026.1 docker
   kolla-build --base ubuntu --tag 2026.1-ubuntu-noble --profile default \
     --registry registry.example.org:5000 --namespace kolla --push
   ```
   - Pass `--tag` explicitly. By default `kolla-build` tags images with its own version number, not the tag kolla-ansible expects.
   - Without `--profile` or image names it builds every image (184 for Ubuntu). `--profile default` builds 57. You can also list just the images you deploy, e.g. `kolla-build … nova neutron horizon`.
3. **Point kolla-ansible at your registry** in `globals.yml`:
   ```yaml
   docker_registry: "registry.example.org:5000"
   docker_namespace: "kolla"
   ```

With your own images:

- **You control the version.** You decide exactly which version runs, and it only changes when you rebuild.
- **You apply security fixes** by rebuilding on your own schedule.
- **You can customise images**, e.g. a custom Horizon.
- **Nodes pull locally**, from your registry instead of the internet.

See the [image building guide](https://docs.openstack.org/kolla/2026.1/admin/image-building.html) for customising images.

A middle ground some sites use is to copy the quay.io images into their own registry once and deploy from there. That stops the images changing under you, but they're still untested daily builds.

---

## Node (host) OS vs container base OS

These are **two separate things**:

| | What it is | Example |
|---|---|---|
| **Node/host OS** | The OS on the VM/baremetal kolla deploys onto | Ubuntu 24.04 Noble |
| **Container base (`kolla_base_distro`)** | The OS the container images were built on | `ubuntu` |

You can technically mix them (e.g. Rocky host + Ubuntu containers), but it's best to **match the host OS to the container distro and version** to avoid kernel module / package version mismatches.

---

## Deployment flow

These steps follow the official [Quick Start](https://docs.openstack.org/kolla-ansible/2026.1/user/quickstart.html) and [multinode guide](https://docs.openstack.org/kolla-ansible/2026.1/user/multinode.html). Check them for details on your release.

### Step 1: Pick a release stream

| Goal | Choose |
|------|--------|
| Latest features / dev work | `master` (daily, may break) |
| Production / stability | Latest stable, currently `2026.1`, with [your own images](#test-images-vs-production-images) |

### Step 2: Pick a distro and provision your node OS to match

| Container tag | `kolla_base_distro` | Node OS to install |
|---|---|---|
| `2026.1-ubuntu-noble` | `ubuntu` | Ubuntu 24.04 (Noble) |
| `2026.1-debian-trixie` | `debian` | Debian 13 (Trixie) |
| `2026.1-rocky-10` | `rocky` | Rocky Linux 10 |

Other releases follow the same pattern; see the tag table above for which distro versions each release has.

### Step 3: Create a Python venv for this release

Each kolla-ansible branch needs a minimum Python version on the deployment host:

| kolla-ansible branch | Python | ansible-core it installs |
|---|---|---|
| `master` / `stable/2026.1` | ≥ 3.11 | 2.19 – 2.20 (2.20 needs Python ≥ 3.12) |
| `stable/2025.2` | ≥ 3.11 | 2.18 – 2.19 |
| `stable/2025.1` | ≥ 3.10 | 2.17 – 2.18 |

No single page lists this. The table combines three sources (for other branches, change `stable/2026.1` in the URL):

- Minimum Python that pip enforces: `python_requires` in kolla-ansible's [setup.cfg](https://opendev.org/openstack/kolla-ansible/src/branch/stable/2026.1/setup.cfg)
- ansible-core range: kolla-ansible's [requirements.txt](https://opendev.org/openstack/kolla-ansible/src/branch/stable/2026.1/requirements.txt)
- Python that each ansible-core version needs: the [ansible-core control node Python support](https://docs.ansible.com/projects/ansible/latest/reference_appendices/release_and_maintenance.html#ansible-core-control-node-python-support) table

The default Python on Ubuntu 24.04 (3.12), Debian 13 (3.13) and Rocky 10 (3.12) is new enough. Ubuntu 22.04 ships 3.10, which is too old for 2025.2 onwards. A venv built on it makes pip fail with `No matching distribution found for ansible-core...`.

Use one venv per kolla-ansible branch, so different releases (and their pinned Ansible versions) never share dependencies.

**1. Check the system Python first**

```bash
python3 -V
```

`python3 -m venv` builds the venv on this interpreter, so compare it with the table above before creating anything.

**2a. If it's new enough**, create the venv with it:

```bash
sudo apt install -y python3-venv python3-dev libffi-dev gcc libssl-dev libdbus-glib-1-dev git

python3 -m venv ~/kolla-venv-2026.1
source ~/kolla-venv-2026.1/bin/activate
pip install -U pip
```

**2b. If it's too old** (e.g. `Python 3.10.12` on Ubuntu 22.04), install a newer Python alongside it and build the venv on that. Don't replace the system `python3` (e.g. with `update-alternatives`). apt and other OS tools depend on it.

Option A: deadsnakes PPA (Ubuntu)

```bash
sudo add-apt-repository -y ppa:deadsnakes/ppa
sudo apt update
sudo apt install -y python3.12 python3.12-venv python3.12-dev libffi-dev gcc libssl-dev libdbus-glib-1-dev git

python3.12 -m venv ~/kolla-venv-2026.1
source ~/kolla-venv-2026.1/bin/activate
pip install -U pip
```

Option B: uv (any distro)

```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
uv venv --python 3.12 --seed ~/kolla-venv-2026.1   # downloads Python 3.12 if missing; --seed adds pip
source ~/kolla-venv-2026.1/bin/activate
```

Either way, `python -V` inside the activated venv should now meet the table.

### Step 4: Install the matching kolla-ansible branch

```bash
# For a stable release (e.g. 2026.1):
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2026.1

# For master:
pip install git+https://opendev.org/openstack/kolla-ansible@master

# Then install the Ansible Galaxy collections pinned by that branch
kolla-ansible install-deps
```

### Step 5: Copy the sample config files

pip puts kolla-ansible's sample files inside the venv, under `share/kolla-ansible/`:

| File in the venv | What it is |
|---|---|
| `etc_examples/kolla/globals.yml` | Main deployment settings: release and distro, network interfaces, VIP address, which services to enable. Every option is listed with its default, commented out. |
| `etc_examples/kolla/passwords.yml` | Empty password entries for every service. |
| `ansible/inventory/all-in-one` | Inventory for a single node that runs everything. |
| `ansible/inventory/multinode` | Inventory with separate `control`, `network`, `compute`, `storage` and `monitoring` groups. List your hosts under each group; one host can be in several groups. |
| `init-runonce` | Optional script to run after deploy. Creates demo networks, an image and flavors. |

Copy them into place and generate the passwords:

```bash
sudo mkdir -p /etc/kolla
sudo chown $USER:$USER /etc/kolla
cp -r ~/kolla-venv-2026.1/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp ~/kolla-venv-2026.1/share/kolla-ansible/ansible/inventory/multinode .   # or all-in-one

kolla-genpwd    # fills /etc/kolla/passwords.yml with random passwords
```

**`passwords.yml` is not encrypted.** `kolla-genpwd` writes it as plain YAML, with file mode `0640`, owned by whoever ran it. The SSH private keys in it have no passphrase, because services must use them unattended. The passwords also end up in plain text in the generated service configs on each target node (`/etc/kolla/<service>/`), because the services need to read them. Encrypting `passwords.yml` (see below) only protects the copy on the deployment host.

**The SSH keys in `passwords.yml` (`*_ssh_key`)** are for kolla's own connections, not your logins:

| Key | Used for |
|---|---|
| `nova_ssh_key` | Nova copying instances between compute nodes (migration, resize) |
| `keystone_ssh_key` | Keystone syncing its Fernet token keys between Keystone nodes |
| `haproxy_ssh_key` | Let's Encrypt pushing renewed certificates to HAProxy (only if Let's Encrypt is enabled) |
| `neutron_ssh_key` | Neutron logging in to physical switches (e.g. networking-generic-switch) |
| `octavia_amp_ssh_key`, `bifrost_ssh_key` | Operator SSH access to Octavia load-balancer VMs and Bifrost bare-metal nodes |
| `kolla_ssh_key` | An optional `kolla` user that `bootstrap-servers` can create (off by default; see below) |

Each deployment gets its own random key pairs, and keeping the generated ones is normal, in production too. You only need to act if:

- you use Neutron with physical switches. Authorise `neutron_ssh_key`'s public key on them.
- you want to log in to Octavia or Bifrost machines with your own key. Put your key pair in that entry before running `kolla-genpwd`, which keeps entries that are already set.
- you set `create_kolla_user: true` in `globals.yml`. `bootstrap-servers` then creates a `kolla` user on every host, with `kolla_ssh_key` authorised and passwordless sudo. Anyone who has `passwords.yml` and can reach the hosts over SSH then has root on them. See the next section.

**Which user does kolla-ansible deploy as?** Whatever your inventory says (`ansible_user`, with `ansible_become=true` for sudo), or your current user if it says nothing. kolla-ansible never switches to the `kolla` user by itself, which is why `create_kolla_user` has defaulted to `false` since 2022. The docs still say `true`; the code says `false`.

Setting it to `true` gives you a ready-made deploy account on every host. To use it, you would:

1. Run `bootstrap-servers` as an existing account (e.g. `ubuntu` or `root`), since the `kolla` user doesn't exist yet.
2. Save `kolla_ssh_key.private_key` from `passwords.yml` to a file.
3. Change the inventory to `ansible_user=kolla ansible_ssh_private_key_file=<that file>`.

In production, leave it `false`. Deploy with an account created by your normal provisioning (cloud-init, MAAS, LDAP/IdM or config management), using a key you manage. The `kolla` user would make `passwords.yml` a root login for every host, and kolla-ansible has no way to rotate `kolla_ssh_key`.

In production you still generate passwords with `kolla-genpwd`, but also:

- **Choose passwords first if you need to.** `kolla-genpwd` only fills empty entries. Anything you set beforehand (e.g. `keystone_admin_password`) is kept.
- **Encrypt it.** Either use `ansible-vault encrypt /etc/kolla/passwords.yml` and run kolla-ansible with `--ask-vault-pass` / `--vault-password-file`, or keep the passwords in [HashiCorp Vault](https://docs.openstack.org/kolla-ansible/2026.1/user/operating-kolla.html#using-hashicorp-vault-for-password-storage) with `kolla-writepwd` / `kolla-readpwd`. `kolla-genpwd` and `kolla-mergepwd` can't read an encrypted file, so decrypt it before running them.
- **Back it up.** Every `deploy`, `reconfigure` and `upgrade` needs the same file. If it's lost or regenerated, it no longer matches the running cloud.
- **On upgrade, merge instead of regenerating.** New releases add entries: generate a fresh file and combine it with the old one using `kolla-mergepwd`, as described in [Operating Kolla](https://docs.openstack.org/kolla-ansible/2026.1/user/operating-kolla.html).
- **To change passwords on a running cloud**, follow the [password rotation guide](https://docs.openstack.org/kolla-ansible/2026.1/admin/password-rotation.html). Most can be applied with `kolla-ansible reconfigure`, but some (e.g. `nova_database_password`, `kolla_ssh_key`) need manual steps.

kolla-ansible then reads these from the deployment host. Use `--configdir` to point it somewhere other than `/etc/kolla`, and `-i` for the inventory, e.g. `kolla-ansible deploy -i ./multinode`:

| Path on the deployment host | Purpose |
|---|---|
| `/etc/kolla/globals.yml` | Your main settings (next step). |
| `/etc/kolla/globals.d/*.yml` | Optional extra settings files. Loaded after `globals.yml` in alphabetical order, so they override it. Useful for keeping your changes separate from the long sample file. |
| `/etc/kolla/passwords.yml` | Service passwords. Keep it secret. |
| `/etc/kolla/config/` | Optional per-service config overrides (e.g. `config/nova.conf`), merged into the config kolla generates. |
| `/etc/kolla/admin-openrc.sh`, `/etc/kolla/clouds.yaml` | Admin credentials, written by `kolla-ansible post-deploy`. |

On the target nodes, kolla-ansible writes each service's generated config to `/etc/kolla/<service>/`. Don't edit those files; every deploy overwrites them.

### Step 6: Set globals.yml

Edit `/etc/kolla/globals.yml`, or put your settings in a file under `/etc/kolla/globals.d/`. The release-related settings are:

```yaml
# Container image distro family: ubuntu | debian | rocky
kolla_base_distro: "ubuntu"

# Optional. kolla-ansible builds the tag automatically as
#   <openstack_release>-<kolla_base_distro>-<kolla_base_distro_version>
# where openstack_release defaults to the installed kolla-ansible branch.
openstack_tag: "2026.1-ubuntu-noble"
```

Setting `kolla_base_distro` alone is usually enough. Each branch picks a default distro version (on `stable/2025.2`: `noble`, `bookworm`, `10`; on `stable/2026.1` Debian moves to `trixie`).

Set `openstack_tag` explicitly only to pin a tag or choose a non-default variant (or override `kolla_base_distro_version` instead). If you hard-code it, remember to update it whenever you upgrade kolla-ansible, or you'll break the rule above.

### Step 7: Align any custom images to the same base

Build custom images on the same base tag as `openstack_tag`, e.g.:

```yaml
horizon_image_full: "registry.example.com/horizon-custom:2026.1-ubuntu-noble-latest"
#                                                        ^^^^^^^^^^^^^^^^^^^ same base as openstack_tag
```

### Step 8: Fill in the inventory and check SSH access

kolla-ansible connects to every host over SSH and runs everything with sudo. Before deploying, check that:

- **The SSH user already exists on every host and has passwordless sudo.** kolla-ansible doesn't create it and can't prompt for a sudo password. Cloud images' default user (e.g. `ubuntu`, reached with the instance's key pair) already meets this.
- **The deployment host can resolve the host names**, or each host's IP is set with `ansible_host`.
- **The hosts' SSH keys are in `~/.ssh/known_hosts`.** Otherwise Ansible stops at the `Are you sure you want to continue connecting (yes/no)?` prompt.

Example `multinode` inventory for one controller and two computes. Put your real host names in every group, and don't leave sample names like `storage01` in place. kolla-ansible will try to connect to them and fail.

```ini
[control]
ctl-01 ansible_host=10.0.0.11

[network]
ctl-01

[compute]
cmp-01 ansible_host=10.0.0.21
cmp-02 ansible_host=10.0.0.22

[monitoring]
ctl-01

[storage]
ctl-01

# Connection settings for every target host (not the local deployment host).
# `baremetal` is defined further down in the sample file; keep the rest of it unchanged.
[baremetal:vars]
ansible_user=ubuntu
ansible_become=true
ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

**What goes in `[storage]`?** In 2026.1 it only matters for the Cinder **LVM** backend. Those hosts run `cinder-volume` and need an LVM volume group named `cinder-volumes`. Cinder is off by default (`enable_cinder: false`) and has no default backend: prechecks fail if you enable it without choosing one. With other backends (Ceph, NFS, ...), `cinder-volume` runs on the `control` hosts. If you don't use LVM, putting your controller here is fine; it only gets the common containers.

Then check that every host answers, with sudo working. Run it with the venv active. A distro `ansible` package (e.g. Ubuntu 22.04's Ansible 2.10) is too old for Python 3.12 hosts and fails with `No module named 'ansible.module_utils.six.moves'`:

```bash
which ansible                                         # should point into your kolla venv
ssh-keyscan -H 10.0.0.11 10.0.0.21 10.0.0.22 >> ~/.ssh/known_hosts
ansible -i ./multinode baremetal -m ping --become     # every host should reply "pong"
```

`ssh-keyscan` trusts whatever key a host presents the first time, just like typing `yes`. That's common practice on a trusted management network. In production, prefer one of these:

- **SSH host certificates** (e.g. FreeIPA or the HashiCorp Vault SSH engine). The deployment host trusts every host with a single `@cert-authority` line in `known_hosts`, with no scanning.
- **Keys known from provisioning.** Inject pre-generated host keys at build time (e.g. with cloud-init `ssh_keys:`), or have config management distribute `known_hosts`.
- **Check fingerprints before trusting them.** On OpenStack VMs, cloud-init prints the host key fingerprints to the console log, which you read through the API rather than over the network:
  ```bash
  openstack console log show <host> | sed -n '/BEGIN SSH HOST KEY FINGERPRINTS/,/END SSH HOST KEY FINGERPRINTS/p'
  ssh-keyscan <host> 2>/dev/null | ssh-keygen -lf -      # must match the lines above
  ```

Avoid `host_key_checking = False` / `StrictHostKeyChecking no`. It turns off the check completely, including for keys that change later.

### Step 9: Deploy

```bash
kolla-ansible bootstrap-servers -i ./multinode   # installs Docker and host prerequisites on every host
kolla-ansible prechecks -i ./multinode           # checks config, ports and interfaces; fix any failures first
                                                 # add --use-test-images if you use the quay.io images
kolla-ansible pull -i ./multinode                # optional: pre-pulls all images so deploy doesn't stall on downloads
kolla-ansible deploy -i ./multinode              # deploys the OpenStack containers
kolla-ansible post-deploy -i ./multinode         # writes /etc/kolla/clouds.yaml and /etc/kolla/admin-openrc.sh
```

Every command can safely be re-run. After a failure, fix the cause and run the same command again. See the [troubleshooting guide](https://docs.openstack.org/kolla-ansible/2026.1/user/troubleshooting.html).

### Step 10: Use OpenStack

```bash
# install the CLI, pinned to the same release
pip install python-openstackclient -c https://releases.openstack.org/constraints/upper/2026.1

# use the admin credentials from post-deploy
mkdir -p ~/.config/openstack && cp /etc/kolla/clouds.yaml ~/.config/openstack/
export OS_CLOUD=kolla-admin          # or: source /etc/kolla/admin-openrc.sh
openstack service list
```

Horizon is at `http://<kolla_external_vip_address>` (the internal VIP unless you set a separate external one). Log in as `admin` with `keystone_admin_password` from `/etc/kolla/passwords.yml`.

Optional, for testing only: `~/kolla-venv-2026.1/share/kolla-ansible/init-runonce` creates a demo network, a CirrOS image and flavors. Set `EXT_NET_CIDR`, `EXT_NET_RANGE` and `EXT_NET_GATEWAY` to match your external network before running it.
