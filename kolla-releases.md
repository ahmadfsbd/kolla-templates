# Kolla Release Notes & Tag Selection

## Where to find release info

| Resource | URL |
|----------|-----|
| Kolla-Ansible release notes | https://docs.openstack.org/releasenotes/kolla-ansible/ |
| Container tags (Quay.io) | https://quay.io/repository/openstack.kolla/kolla-toolbox?tab=tags |
| Supported distros per release | https://docs.openstack.org/kolla-ansible/latest/user/support-matrix |

---

## How Quay tags map to kolla-ansible releases

> **Note:** OpenStack switched tag naming from codenames (e.g. `bobcat`) to **year.cycle** (e.g. `2024.2`) starting with the 2024.1 release. Both formats exist on Quay — use whichever matches your kolla-ansible version.

Quay tags follow this pattern:

```
<openstack-release>-<distro>-<codename>
```

### Current tags (as of May 2026)

| Quay tag | kolla-ansible branch | Stability | Host OS |
|---|---|---|---|
| `master-ubuntu-noble` | `master` | ⚠️ Daily / bleeding edge | Ubuntu 24.04 (Noble) |
| `master-debian-trixie` | `master` | ⚠️ Daily / bleeding edge | Debian 13 (Trixie) |
| `master-rocky-10` | `master` | ⚠️ Daily / bleeding edge | Rocky Linux 10 |
| `2025.2-ubuntu-noble` | `stable/2025.2` | ✅ Stable (latest) | Ubuntu 24.04 (Noble) |
| `2025.2-rocky-10` | `stable/2025.2` | ✅ Stable (latest) | Rocky Linux 10 |
| `2025.2-debian-bookworm` | `stable/2025.2` | ✅ Stable (latest) | Debian 12 (Bookworm) |
| `2025.1-ubuntu-noble` | `stable/2025.1` | ✅ Stable | Ubuntu 24.04 (Noble) |
| `2025.1-rocky-9` | `stable/2025.1` | ✅ Stable | Rocky Linux 9 |
| `2025.1-rocky-10` | `stable/2025.1` | ✅ Stable | Rocky Linux 10 |
| `2024.2-ubuntu-noble` | `stable/2024.2` | ✅ Stable | Ubuntu 24.04 (Noble) |
| `2024.2-rocky-9` | `stable/2024.2` | ✅ Stable | Rocky Linux 9 |
| `2024.1-ubuntu-noble` | `stable/2024.1` | 🔴 EOL | Ubuntu 24.04 (Noble) |
| `2024.1-ubuntu-jammy` | `stable/2024.1` | 🔴 EOL | Ubuntu 22.04 (Jammy) |

> **master** images are rebuilt **daily** — fine for development, not for production.  
> **stable/\<year.cycle\>** images are pinned and only receive bug/security fixes.

**Rule:** tag prefix == kolla-ansible branch. Mix them and deploys break.

---

## What to set in globals.yml

```yaml
# The Quay container tag — must match your kolla-ansible branch
openstack_tag: "master-ubuntu-noble"

# Distro family of the container images (not the VM/host OS)
# ubuntu  → for any ubuntu-* tag
# centos  → for any centos-* tag
# rocky   → for any rocky-* tag
kolla_base_distro: "ubuntu"
```

---

## Node (host) OS vs container base OS

These are **two separate things**:

| | What it is | Example |
|---|---|---|
| **Node/host OS** | The OS on the VM/baremetal kolla deploys onto | Ubuntu 24.04 Noble |
| **Container base (`kolla_base_distro`)** | The OS the container images were built on | `ubuntu` |

You can technically mix (e.g. Rocky host + Ubuntu containers), but best practice is to **match host OS codename to container codename** to avoid kernel module / package version mismatches.

---

## Selection flow

### Step 1 — Pick a release stream

| Goal | Choose |
|------|--------|
| Latest features / dev work | `master` (daily, may break) |
| Production / stability | Latest stable, currently `2025.2` |

### Step 2 — Pick a distro combo and provision your node OS to match

| Container tag | `kolla_base_distro` | Node OS to install |
|---|---|---|
| `2025.2-ubuntu-noble` | `ubuntu` | Ubuntu 24.04 (Noble) |
| `2025.2-rocky-10` | `rocky` | Rocky Linux 10 |
| `2025.2-debian-bookworm` | `debian` | Debian 12 (Bookworm) |
| `master-ubuntu-noble` | `ubuntu` | Ubuntu 24.04 (Noble) |

> Match the node OS to the container tag — same distro family and codename avoids kernel module / package mismatches.

### Step 3 — Install matching kolla-ansible branch

```bash
# For master:
pip install git+https://opendev.org/openstack/kolla-ansible@master

# For a stable release (e.g. 2025.2):
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2025.2
```

### Step 4 — Set globals.yml

```yaml
openstack_tag: "2025.2-ubuntu-noble"   # must match the Quay tag you chose
kolla_base_distro: "ubuntu"            # distro family from the tag (ubuntu / rocky / debian)
```

### Step 5 — Align any custom images to the same base

Custom images must be built on the same base tag as `openstack_tag`, e.g.:

```yaml
horizon_image_full: "ahmadfsbd/horizon-nexus:master-ubuntu-noble-latest"
#                                                  ^^^^^^^^^^^^^^^^^^^ same base as openstack_tag
```
