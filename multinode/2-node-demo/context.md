Note: This demo was run on a linux machine using libvirt to create virtual servers (Ubuntu 24.04 linux machines).
Pre-requisites
Host Machine
make sure that nested virtualization is enabled in BIOS.
Boot into the BIOS then navigate Advanced Frequency Settings and Advanced CPU Settings
Find the Intel Virtualization Technology (VT-x) and Intel VT-d options to set them to [Enabled]. 
Save your changes with F10 and exit to apply the settings
Note: These settings might be at different locations on different motherboard models and maybe named differently in case of AMD.
Install Dependencies
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils wget cloud-image-utils
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt,kvm $USER
newgrp libvirt
sudo systemctl start libvirtd

Check KVM support:
egrep -c '(vmx|svm)' /proc/cpuinfo


How Linux reports virtualization flags
vmx = Intel VT-x support


egrep -c '(vmx|svm)' /proc/cpuinfo counts all logical processors (threads) with that flag.


My CPU has:
8 physical cores × 2 threads/core = 16 logical processors


If you have Hyper-Threading enabled and maybe SMT or a BIOS setting, sometimes the kernel exposes extra virtual threads to the OS (for example if nested virtualization is enabled).



Download Ubuntu Server Image
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img -O /var/lib/libvirt/images/ubuntu-24.04.qcow2


Network Setup
We will create three libvirt networks (pxe-net, os-net, float-net).
Create three .xml files for network definitions with following contents:
a) PXE Network (10.10.1.0/24, NAT for MAAS only) (MAAS will run dhcp server on this to commission nodes)
# pxe-net.xml
<network>
  <name>pxe-net</name>
  <bridge name="br-pxe"/>
  <forward mode="nat"/>
  <ip address="10.10.1.1" netmask="255.255.255.0">
  </ip>
</network>

b) OpenStack Service/Management Network (10.10.2.0/24, host-only): for Openstack services and tenant networks
# os-net.xml
<network>
  <name>os-net</name>
  <bridge name="br-os"/>
  <ip address="10.10.2.1" netmask="255.255.255.0">
  </ip>
</network>

c) Floating Network (10.10.3.0/24, isolated): For floating network through physical NIC (Home Network)
# float-net.xml
<network>
  <name>float-net</name>
  <forward mode="bridge"/>
  <bridge name="br-ext"/>
</network>



Bridging floating network to physical NIC
If you want your floating network to connect to the outside, you need a Linux bridge on the host that attaches a physical NIC.
Get IP of your physical machine’s NIC:
$ ip a

Example: your host NIC is enp3s0 (connected to your LAN).

IP: 192.168.0.25/24 (from home network/router)
Since it’s dynamic (scope global dynamic), your gateway is your home router — usually the .1 address of your subnet. Check GW:
$ ip route | grep default


Gateway: 192.168.0.1
# Create bridge for external network
sudo ip link add name br-ext type bridge
sudo ip link set br-ext up


Move physical NIC’s IP to the bridge:
sudo ip addr flush dev enp3s0
sudo ip addr add 192.168.0.25/24 dev br-ext
sudo ip route add default via 192.168.0.1


# Add physical NIC to bridge
sudo ip link set enp3s0 master br-ext
sudo ip link set enp3s0 up



Bridged to a physical NIC
Host bridge (e.g., br-ext) is attached to a physical NIC connected to your LAN.


OpenStack’s Neutron uses this bridge for the external network. (openstack ports on this floating network will have same MAC on physical network as Physical Port - home network)


You can configure the subnet for floating IPs to be within your LAN’s IP range, via Static IP pool managed by OpenStack.


Example:
Physical LAN: 192.168.0.0/24


Host bridge: br-ext attached to enp3s0


OpenStack floating network: 192.168.0.100-192.168.0.150


Instances requesting floating IPs will get addresses from that pool and are directly reachable from your LAN.


Finally, create bridges and virt networks using following command:
for n in pxe-net os-net float-net; do
  sudo virsh net-define ./$n.xml
  sudo virsh net-autostart $n
  sudo virsh net-start $n
done



Host Nodes (Virsh VMs)
In this case we are using virtualbox VMs to simulate physical hosts for MAAS and OpenStack nodes.

MAAS VM: 2 vCPU, 3 GB RAM, 30 GB disk


Control/Compute VMs: 2 vCPU, 3 GB RAM, 25 GB disk
Create VMs
a) MAAS Node (2 vCPU, 3 GB RAM, 30 GB disk, PXE + OS NICs)
Create meta-data and user-data (cloudinit) files with following content:
maas-meta-data
instance-id: maas-vm
local-hostname: maas


maas-user-data
#cloud-config
users:
  - name: ubuntu
    ssh-authorized-keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHaJZb/L9BL2ABPqkc8rHZKYxJ60Cdu6l/jsrX80lvGK ahmad@ahmad-Z590-AORUS-ELITE
    sudo: ["ALL=(ALL) NOPASSWD:ALL"]
    shell: /bin/bash

ssh_pwauth: false
disable_root: true

# Set static IPs
network:
  version: 2
  ethernets:
    enp3s0:   # PXE NIC
      dhcp4: false
      addresses: [10.10.1.10/24]
      gateway4: 10.10.1.1
      nameservers:
        addresses: [8.8.8.8,8.8.4.4]
    enp8s0:   # OS NIC
      dhcp4: false
      addresses: [10.10.2.10/24]



Create sed image and place in correct location:
cloud-localds maas-seed.iso maas-user-data maas-meta-data
sudo chown libvirt-qemu:kvm maas-seed.iso
sudo chmod 644 maas-seed.iso
sudo cp ~/openstack/meta-data/maas-seed.iso /var/lib/libvirt/images/


Create maas vm:
virt-install \
  --name maas \
  --memory 3072 --vcpus 2 \
  --disk path=/var/lib/libvirt/images/maas.qcow2,size=30,backing_store=/var/lib/libvirt/images/ubuntu-24.04.qcow2 \
  --cdrom /var/lib/libvirt/images/maas-seed.iso \
  --network network=pxe-net \
  --network network=os-net \
  --os-variant ubuntu24.04 \
  --graphics none \
  --import \
  --check path_in_use=off




After setup completes, you might be stuck at login screen for vm, pres ctrl+] to exit.




Control and Compute Nodes
These nodes are bare-metal “nodes” for MAAS to commission.


Do not install Ubuntu on them — just create VMs with the required CPU, RAM, and disk.


PXE NIC must be attached so MAAS can provision them.


Add a second NIC for OS/management (same as your previous OS network).


Controller VM creation without OS:
virt-install \
  --name control-node \
  --memory 3072 --vcpus 2 \
  --disk path=/var/lib/libvirt/images/control.qcow2,size=25 \
  --network network=pxe-net \
  --network network=os-net \
  --graphics none \
  --import

Do the same for compute node.




