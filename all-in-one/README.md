# Kolla-Ansible All-in-One (single VM, host-driven)

Deploy **OpenStack master (master-ubuntu-noble)** onto a remote VM.  
All commands run **on your host** — no SSH into the VM needed.  
Horizon is replaced with **`ahmadfsbd/horizon-nexus:master-ubuntu-noble-latest`**.

---

## Release mapping

| Stream | Kolla image tag       | kolla-ansible branch |
|--------|-----------------------|----------------------|
| master | `master-ubuntu-noble` | `master`             |

---

## Prerequisites (host only)

```bash
# libvirt + VM tools
sudo apt install -y qemu-kvm libvirt-daemon-system virtinst \
  cloud-image-utils libguestfs-tools libosinfo-bin

# Python venv + build deps (for kolla-ansible on the host)
sudo apt install -y python3-venv python3-dev python3-dbus \
  libffi-dev gcc libssl-dev libdbus-1-dev libdbus-glib-1-dev git

# Add your user to the libvirt group (re-login after this)
sudo usermod -aG libvirt $USER

# Ensure the default NAT network is active (provides 192.168.122.x DHCP)
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default

# SSH key (skip if you already have one)
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
```

---

## Step 1 — Create the VM

```bash
sudo ./create-vm.sh
```

The script prints the VM IP when done. Set it for the rest of the steps:

```bash
export VM=<IP printed by create-vm.sh>
```

---

## Step 2 — Set VM IP in inventory

Open `all-in-one` and replace `VM_IP` with the IP printed by `create-vm.sh` in the first five group entries:

```ini
kolla-aio ansible_host=192.168.122.X ansible_user=ubuntu ansible_become=true ansible_private_key_file=~/.ssh/id_ed25519
```

Verify:

```bash
grep ansible_host all-in-one
```

---

## Step 3 — Install kolla-ansible on the HOST

```bash
python3 -m venv --system-site-packages ~/kolla-venv
source ~/kolla-venv/bin/activate
pip install -U pip
pip install git+https://opendev.org/openstack/kolla-ansible@master
pip install docker
```

---

## Step 4 — Set up /etc/kolla on the HOST

```bash
source ~/kolla-venv/bin/activate

sudo mkdir -p /etc/kolla/globals.d
sudo chown -R $USER:$USER /etc/kolla

# Copy example passwords.yml and base globals from package
cp -r ~/kolla-venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/

# Copy our globals override (image tag + horizon + networking)
cp globals.yml /etc/kolla/globals.d/globals-override.yaml
```

Key settings in `globals.yml`:

```yaml
openstack_tag: "master-ubuntu-noble"                                 # all standard containers
horizon_image_full: "ahmadfsbd/horizon-nexus:master-ubuntu-noble-latest"  # custom Horizon
network_interface: "enp1s0"        # NIC 1 — management / SSH / kolla API
neutron_external_interface: "enp2s0"  # NIC 2 — OVS br-ex (dedicated, avoids SSH loss)
kolla_internal_vip_address: "192.168.122.100"
```

---

## Step 5 — Generate passwords

```bash
source ~/kolla-venv/bin/activate
kolla-genpwd
```

---

## Step 6 — Install Ansible Galaxy dependencies

```bash
source ~/kolla-venv/bin/activate
kolla-ansible install-deps
```

---

## Step 7 — Bootstrap the VM

```bash
kolla-ansible bootstrap-servers -i ./all-in-one
```

Installs Docker and sets up kernel params on the VM over SSH.

---

## Step 8 — Pre-deployment checks

```bash
kolla-ansible prechecks -i ./all-in-one
```

Fix any failures before continuing:

| Error | Fix |
|-------|-----|
| `No module named 'docker'` | `pip install docker` (on the host venv) |
| `No module named 'dbus'` | Recreate venv with `--system-site-packages` after `sudo apt install python3-dbus` |
| `ansible-runner not found in kolla_toolbox` | `openstack_tag` must be `master-ubuntu-noble` |
| MariaDB WSREP error | `ansible-galaxy collection install community.mysql:==3.10.3 --force` |

---

## Step 9 — Deploy OpenStack

```bash
kolla-ansible deploy -i ./all-in-one
```

Pulls ~20 container images onto the VM and starts all services. Takes **20–30 min**.

---

## Step 10 — Post-deploy

```bash
kolla-ansible post-deploy -i ./all-in-one
```

Fetches `/etc/kolla/clouds.yaml` and `/etc/kolla/admin-openrc.sh` from the VM.

---

## Access OpenStack

```bash
# Horizon — open in browser
http://$VM

# Admin credentials (on the VM)
ssh ubuntu@$VM "cat /etc/kolla/admin-openrc.sh"

# Verify custom Horizon container
ssh ubuntu@$VM "sudo docker inspect horizon | grep -i image"
# Expected: ahmadfsbd/horizon-nexus:master-ubuntu-noble-latest
```

---

## Retry a failed deploy

kolla-ansible is idempotent — just re-run Step 9:

```bash
source ~/kolla-venv/bin/activate
kolla-ansible deploy -i ./all-in-one
```

---

## Files

| File | Purpose |
|------|---------|
| `create-vm.sh` | Creates the libvirt VM with SSH key injected |
| `all-in-one` | Ansible inventory — VM IP, user, SSH key |
| `globals.yml` | OpenStack config — image tag, Horizon override, networking |
| `README.md` | This file |
