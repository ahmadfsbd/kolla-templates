#!/usr/bin/env bash
# Creates a single Ubuntu 24.04 VM for kolla-ansible all-in-one deployment.
# Runs from the HOST - no need to SSH in. 
# Usage: sudo ./create-vm.sh [VM_IP]  (default IP: 192.168.122.200)
set -euo pipefail

VM_NAME="kolla-aio"
VM_IP="${1:-192.168.122.200}"
VM_CPUS=4
VM_MEM=12288   # MB
VM_DISK=80G
BASE_IMG="/var/lib/libvirt/images/ubuntu-24.04.qcow2"
VM_IMG="/var/lib/libvirt/images/${VM_NAME}.qcow2"
CIDATA_ISO="/var/lib/libvirt/images/${VM_NAME}-cidata.iso"
# Use the real user's home dir even when called with sudo
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
SSH_KEY="${REAL_HOME}/.ssh/id_ed25519.pub"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Preflight ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then echo "Run with sudo: sudo $0"; exit 1; fi

if [[ ! -f "$BASE_IMG" ]]; then
  echo "Ubuntu 24.04 cloud image not found at $BASE_IMG"
  echo "Downloading..."
  wget -O "$BASE_IMG" \
    "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  chown libvirt-qemu:kvm "$BASE_IMG"
fi

if [[ ! -f "$SSH_KEY" ]]; then
  echo "No SSH key found at $SSH_KEY"
  echo "Run: ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519"
  exit 1
fi

# ── Cleanup existing VM ───────────────────────────────────────────────────────
virsh destroy  "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
rm -f "$VM_IMG" "$CIDATA_ISO"

# ── Disk image ───────────────────────────────────────────────────────────────
qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$VM_IMG" "$VM_DISK"
chown libvirt-qemu:kvm "$VM_IMG"

# ── Cloud-init ISO ───────────────────────────────────────────────────────────
PUB_KEY="$(cat "$SSH_KEY")"
TMPDIR="$(mktemp -d)"
cat > "$TMPDIR/user-data" << USERDATA
#cloud-config
hostname: kolla-aio
manage_etc_hosts: true

users:
  - name: ubuntu
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${PUB_KEY}

ssh_pwauth: false

package_update: false

runcmd:
  - sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
USERDATA

cat > "$TMPDIR/meta-data" << META
instance-id: ${VM_NAME}
local-hostname: kolla-aio
META

cloud-localds "$CIDATA_ISO" "$TMPDIR/user-data" "$TMPDIR/meta-data"
chown libvirt-qemu:kvm "$CIDATA_ISO"
rm -rf "$TMPDIR"

# ── Create VM ────────────────────────────────────────────────────────────────
virt-install \
  --name "$VM_NAME" \
  --vcpus "$VM_CPUS" \
  --memory "$VM_MEM" \
  --disk path="$VM_IMG",format=qcow2 \
  --disk path="$CIDATA_ISO",device=cdrom \
  --os-variant ubuntu24.04 \
  --network network=default,model=virtio \
  --network network=default,model=virtio \
  --import \
  --noautoconsole
# NIC layout inside the VM:
#   enp1s0 — management / SSH / kolla API  (network_interface)
#   enp2s0 — Neutron external bridge       (neutron_external_interface)

# ── Wait for DHCP lease ──────────────────────────────────────────────────────
echo "Waiting for VM to get DHCP lease..."
for i in {1..30}; do
  IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d/ -f1)
  [[ -n "$IP" ]] && break
  sleep 3
done

# ── Ensure SSH key is injected (virt-customize fallback) ─────────────────────
# cloud-init sometimes doesn't apply on first boot; this guarantees access.
echo "Ensuring SSH key is injected via virt-customize..."
virsh shutdown "$VM_NAME" 2>/dev/null || true
sleep 10
virt-customize -a "$VM_IMG" \
  --ssh-inject ubuntu:file:"$SSH_KEY" \
  --run-command "sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config" \
  || echo "⚠️  virt-customize failed — relying on cloud-init for SSH key injection"
virsh start "$VM_NAME"

echo "Waiting for SSH to come up on $IP..."
for i in {1..30}; do
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 ubuntu@"$IP" "echo ok" &>/dev/null && break || true
  sleep 5
done

echo ""
echo "✅  VM created: ${VM_NAME}"
echo "    IP address: ${IP}"
echo "    NIC layout:  enp1s0 = management (${IP})  |  enp2s0 = OVS external (br-ex)"
echo ""
echo "Next steps:"
echo "  1. Update inventory:  sed -i \"s/VM_IP/${IP}/g\" all-in-one"
echo "  2. Copy globals:      sudo cp globals.yml /etc/kolla/globals.d/globals-override.yml"
echo "  3. Deploy:            kolla-ansible bootstrap-servers -i ./all-in-one"
