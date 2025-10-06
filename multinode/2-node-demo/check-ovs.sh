#!/bin/bash

# Script to check and ensure OpenVSwitch is running on all nodes
# Run this before kolla-ansible deployment

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check and setup OVS on a node
check_ovs_on_node() {
    local node=$1
    local ssh_user=$2
    local ssh_key=$3
    
    print_status "Checking OpenVSwitch on $node..."
    
    # SSH command with proper key
    ssh_cmd="ssh -i $ssh_key -o StrictHostKeyChecking=no $ssh_user@$node"
    
    # Check if OVS is installed
    if ! $ssh_cmd "which ovs-vsctl >/dev/null 2>&1"; then
        print_status "Installing OpenVSwitch on $node..."
        $ssh_cmd "sudo apt update && sudo apt install -y openvswitch-switch"
    fi
    
    # Check if OVS service is running
    if ! $ssh_cmd "sudo systemctl is-active --quiet openvswitch-switch"; then
        print_status "Starting OpenVSwitch service on $node..."
        $ssh_cmd "sudo systemctl enable openvswitch-switch"
        $ssh_cmd "sudo systemctl start openvswitch-switch"
        
        # Wait a moment for the service to start
        sleep 3
    fi
    
    # Verify OVS is working
    if $ssh_cmd "sudo ovs-vsctl show >/dev/null 2>&1"; then
        print_status "OpenVSwitch is running correctly on $node"
    else
        print_error "OpenVSwitch failed to start properly on $node"
        return 1
    fi
    
    # Create br-int bridge if it doesn't exist (OVN requirement)
    if ! $ssh_cmd "sudo ovs-vsctl br-exists br-int"; then
        print_status "Creating br-int bridge on $node..."
        $ssh_cmd "sudo ovs-vsctl add-br br-int"
    fi
    
    print_status "OpenVSwitch setup completed on $node"
}

# Read the multinode inventory file and check each compute and network node
print_status "Starting OpenVSwitch verification on all nodes..."

# Check control/network nodes
print_status "Checking control-01 node..."
check_ovs_on_node "control-01" "ubuntu" "/home/ubuntu/.ssh/id_rsa"

# Check compute nodes  
print_status "Checking compute-01 node..."
check_ovs_on_node "compute-01" "ubuntu" "/home/ubuntu/.ssh/id_rsa"

print_status "OpenVSwitch verification completed on all nodes!"
print_status "You can now proceed with kolla-ansible deployment."