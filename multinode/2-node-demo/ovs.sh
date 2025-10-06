#!/bin/bash
# filepath: install-ovs.sh

# Script to install and configure OpenVSwitch on compute nodes
# Run this on all compute nodes before Kolla deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

log_info "Installing OpenVSwitch on compute node..."

# Update package list
apt update

# Install OpenVSwitch
log_info "Installing openvswitch-switch package..."
apt install -y openvswitch-switch openvswitch-common

# Start and enable OpenVSwitch services
log_info "Starting OpenVSwitch services..."
systemctl start openvswitch-switch
systemctl enable openvswitch-switch

# Verify OVS is running
log_info "Verifying OpenVSwitch installation..."
if systemctl is-active --quiet openvswitch-switch; then
    log_info "✅ OpenVSwitch is running"
else
    log_error "❌ OpenVSwitch failed to start"
    exit 1
fi

# Check OVS database
if [ -S /var/run/openvswitch/db.sock ]; then
    log_info "✅ OVS database socket is available"
else
    log_error "❌ OVS database socket not found"
    exit 1
fi

# Test OVS commands
log_info "Testing OVS commands..."
ovs-vsctl --version
ovs-vsctl show

log_info "✅ OpenVSwitch installation completed successfully!"

# Show current bridge configuration
log_info "Current OVS bridges:"
ovs-vsctl list-br || log_warn "No bridges configured yet (this is normal)"

log_info "OpenVSwitch is ready for Kolla deployment!"