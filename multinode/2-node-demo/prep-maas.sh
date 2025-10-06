#!/bin/bash

# MAAS Setup Script
# This script automates the complete MAAS installation and configuration

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration variables
DBUSER="maas"
DBPASS="maas123"
DBNAME="maasdb"
ADMIN_USERNAME="admin"
ADMIN_EMAIL="ahmadfsbd@gmail.com"
ADMIN_PASSWORD="admin"
SSH_KEY_IMPORT=""  # Set to lp:your-launchpad-id or gh:your-github-id, or leave empty
MAAS_IP="10.10.1.10"
MAAS_URL="http://${MAAS_IP}:5240/MAAS"
KERNEL_OPTS="console=ttyS0,115200n8 net.ifnames=0 biosdevname=0"

# Function to print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_status "Starting MAAS setup..."

# Step 1: Update and upgrade system packages
print_status "Updating and upgrading system packages..."
sudo apt update && sudo apt upgrade -y

# Step 2: Disable conflicting NTP services
print_status "Disabling conflicting NTP services..."
sudo systemctl disable --now systemd-timesyncd

# Step 3: Install MAAS if not installed
if ! snap list | grep -q maas; then
    print_status "Installing MAAS..."
    sudo snap install --channel=3.6/stable maas
else
    print_warning "MAAS is already installed, skipping installation."
fi

# Step 4: Install and configure PostgreSQL
print_status "Installing PostgreSQL..."
sudo apt install -y postgresql

print_status "Creating database user and database (if not exists)..."
USER_EXISTS=$(sudo -i -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DBUSER'")
if [ "$USER_EXISTS" != "1" ]; then
    sudo -i -u postgres psql -c "CREATE USER \"$DBUSER\" WITH ENCRYPTED PASSWORD '$DBPASS'"
else
    print_warning "PostgreSQL user '$DBUSER' already exists, skipping creation."
fi

# Step 5: Configure PostgreSQL authentication
print_status "Configuring PostgreSQL authentication..."
PG_VERSION=$(sudo -u postgres psql -t -c "SELECT version();" | grep -o '[0-9]\+\.[0-9]\+' | head -1 | cut -d. -f1)
PG_HBA_CONF="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"

# Add database access rule
if ! grep -q "host.*${DBNAME}.*${DBUSER}" "$PG_HBA_CONF"; then
    echo "host    ${DBNAME}    ${DBUSER}    0/0     md5" | sudo tee -a "$PG_HBA_CONF"
fi

# Step 6: Configure PostgreSQL to listen on any IP
print_status "Configuring PostgreSQL to listen on all addresses..."
if ! grep -q "listen_addresses = '\*'" "$PG_CONF"; then
    sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
fi

# Restart PostgreSQL
print_status "Restarting PostgreSQL..."
sudo systemctl restart postgresql

# Step 7: Initialize MAAS with database (only if not already initialized)
print_status "Checking if MAAS is already initialized..."
if sudo maas status >/dev/null 2>&1; then
    print_warning "MAAS appears to be already initialized. Skipping initialization."
else
    print_status "Initializing MAAS with database..."
    echo "$MAAS_URL" | sudo maas init region+rack --database-uri "postgres://$DBUSER:$DBPASS@localhost/$DBNAME"
fi

# Step 8: Create MAAS admin user
print_status "Creating MAAS admin user..."

# Check if admin user already exists
if sudo maas apikey --username="$ADMIN_USERNAME" >/dev/null 2>&1; then
    print_warning "MAAS admin user '$ADMIN_USERNAME' already exists, skipping creation."
else
    print_status "Creating new MAAS admin user..."
    sudo maas createadmin \
        --username="$ADMIN_USERNAME" \
        --email="$ADMIN_EMAIL" \
        --password="$ADMIN_PASSWORD" <<EOF
$SSH_KEY_IMPORT
EOF
    print_status "Admin user '$ADMIN_USERNAME' created successfully."
fi


print_status "MAAS GUI is now accessible at: $MAAS_URL"

# Step 9: Setup MAAS using CLI
print_status "Setting up MAAS CLI..."

# Get admin user's API key
print_status "Getting admin user API key..."
sudo maas apikey --username "$ADMIN_USERNAME" > api-key-file

# Login using username and API key
print_status "Logging in to MAAS CLI..."
maas login "$ADMIN_USERNAME" "$MAAS_URL" "$(cat api-key-file)"

# Step 10: Configure DNS
print_status "Configuring DNS..."
maas "$ADMIN_USERNAME" maas set-config name=upstream_dns value="8.8.8.8"

# Step 11: Generate and add SSH key
print_status "Generating SSH key..."
if [ ! -f ~/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
fi

print_status "Adding SSH public key to MAAS..."
maas "$ADMIN_USERNAME" sshkeys create "key=$(cat ~/.ssh/id_rsa.pub)"

# Step 12: Network Configuration
print_status "Configuring MAAS networks..."

# Wait a moment for MAAS to discover networks
print_status "Waiting for MAAS to discover networks..."
sleep 15

# Verify networks are discovered
print_status "Checking discovered subnets..."
maas "$ADMIN_USERNAME" subnets read || print_warning "Could not list subnets"

# Set discovered networks as MAAS managed
print_status "Setting networks as MAAS managed..."
maas "$ADMIN_USERNAME" subnet update 10.10.1.0/24 managed=true || print_warning "Failed to set 10.10.1.0/24 as managed"
maas "$ADMIN_USERNAME" subnet update 10.10.2.0/24 managed=true || print_warning "Failed to set 10.10.2.0/24 as managed"

# Create dynamic IP range for PXE network
print_status "Creating dynamic IP range for PXE network..."
maas "$ADMIN_USERNAME" ipranges create type=dynamic subnet=1 start_ip='10.10.1.100' end_ip='10.10.1.200' || print_warning "Failed to create IP range"

# Reserve static IP range for OS network
print_status "Creating static IP range for OS network..."
maas "$ADMIN_USERNAME" ipranges create type=reserved subnet=2 start_ip='10.10.2.50' end_ip='10.10.2.100' || print_warning "Failed to create IP range"


# Enable DHCP on PXE network
print_status "Enabling DHCP on PXE network..."
maas "$ADMIN_USERNAME" vlan update fabric-0 0 dhcp_on=True primary_rack=maas || print_warning "Failed to enable DHCP"

print_status "MAAS setup completed successfully!"
print_status "You can now access MAAS at: $MAAS_URL"
print_status "Admin username: $ADMIN_USERNAME"
print_status "Admin email: $ADMIN_EMAIL"

# Step 13: Set kernel options for deployed machines
print_status "Setting kernel options for deployed machines..."
maas "$ADMIN_USERNAME" maas set-config name=kernel_opts value="$KERNEL_OPTS"

# Step 14: Set kernel options for deployed machines
print_status "Setting kernel options for deployed machines..."
maas "$ADMIN_USERNAME" maas set-config name=kernel_opts value="$KERNEL_OPTS"

# Step 15: Generate SSH keys in MAAS snap environment
print_status "Generating SSH keys in MAAS snap environment..."
sudo snap run --shell maas <<'SNAP_EOF'
# Generate SSH key if it doesn't exist
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ""
    chmod 600 /root/.ssh/id_rsa
    chmod 644 /root/.ssh/id_rsa.pub
fi

# Display the public key
echo "=== MAAS SSH Public Key ==="
cat /root/.ssh/id_rsa.pub
echo "=========================="
SNAP_EOF

print_status "MAAS SSH public key generated and displayed above."
print_status "Copy this key to use on other hosts for MAAS access."

# Clean up
rm -f api-key-file

print_status "Script execution finished."