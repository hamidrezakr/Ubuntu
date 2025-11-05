#!/bin/bash

# Script: netplan-auto-config.sh
# Description: Auto-configure netplan based on current network settings

NETPLAN_DIR="/etc/netplan"
CONFIG_FILE="$NETPLAN_DIR/01-auto-config.yaml"
TEMP_FILE=$(mktemp)

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Function to get network interfaces
get_interfaces() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo
}

# Function to get current IP address
get_current_ip() {
    local interface=$1
    ip -4 addr show dev "$interface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | head -1
}

# Function to get default gateway interface
get_default_gateway_interface() {
    ip route | grep '^default' | awk '{print $5}' | head -1
}

# Function to get default gateway IP
get_default_gateway_ip() {
    ip route | grep '^default' | awk '{print $3}' | head -1
}

# Function to get DNS servers
get_dns_servers() {
    cat /etc/resolv.conf | grep '^nameserver' | awk '{print $2}' | head -2
}

# Function to get additional routes
get_additional_routes() {
    ip route | grep -v '^default' | grep -v '^kernel' | grep -v 'linkdown' | while read route; do
        if [[ $route =~ ^([0-9.]+/[0-9]+).*via.([0-9.]+).*dev.([a-zA-Z0-9]+) ]]; then
            echo "      - to: ${BASH_REMATCH[1]}"
            echo "        via: ${BASH_REMATCH[2]}"
            echo "        metric: 100"
        fi
    done
}

# Function to check if interface is connected
is_interface_connected() {
    local interface=$1
    if ip link show "$interface" | grep -q "state UP"; then
        return 0
    else
        return 1
    fi
}

# Create netplan directory if it doesn't exist
mkdir -p "$NETPLAN_DIR"

# Start writing netplan configuration
cat > "$TEMP_FILE" << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
EOF

# Get default gateway interface
DEFAULT_GW_INTERFACE=$(get_default_gateway_interface)
DEFAULT_GW_IP=$(get_default_gateway_ip)
DNS_SERVERS=($(get_dns_servers))

# Process each interface
INTERFACES=($(get_interfaces))
FIRST_INTERFACE="${INTERFACES[0]}"

for INTERFACE in "${INTERFACES[@]}"; do
    echo "Processing interface: $INTERFACE"
    
    CURRENT_IP=$(get_current_ip "$INTERFACE")
    IS_CONNECTED=$(is_interface_connected "$INTERFACE" && echo "true" || echo "false")
    
    cat >> "$TEMP_FILE" << EOF
    $INTERFACE:
      dhcp4: false
      optional: true
EOF

    # Add IP configuration if exists
    if [ -n "$CURRENT_IP" ]; then
        cat >> "$TEMP_FILE" << EOF
      addresses:
        - $CURRENT_IP
EOF
    else
        # If no IP and this is the first interface and connected, set DHCP
        if [ "$INTERFACE" = "$FIRST_INTERFACE" ] && [ "$IS_CONNECTED" = "true" ]; then
            sed -i "/$INTERFACE:/,/^$/s/dhcp4: false/dhcp4: true/" "$TEMP_FILE"
        fi
    fi

    # Add gateway if this is the default gateway interface
    if [ "$INTERFACE" = "$DEFAULT_GW_INTERFACE" ] && [ -n "$DEFAULT_GW_IP" ]; then
        cat >> "$TEMP_FILE" << EOF
      routes:
        - to: default
          via: $DEFAULT_GW_IP
EOF
        
        # Add DNS servers for default gateway interface
        if [ ${#DNS_SERVERS[@]} -gt 0 ]; then
            cat >> "$TEMP_FILE" << EOF
      nameservers:
        addresses: [$(IFS=,; echo "${DNS_SERVERS[*]}")]
EOF
        fi
    fi
    
    # Add additional routes for this interface
    ADDITIONAL_ROUTES=$(get_additional_routes | grep -A2 "dev $INTERFACE" | grep -v "dev $INTERFACE" || true)
    if [ -n "$ADDITIONAL_ROUTES" ]; then
        cat >> "$TEMP_FILE" << EOF
      routes:
EOF
        echo "$ADDITIONAL_ROUTES" >> "$TEMP_FILE"
    fi
    
    echo >> "$TEMP_FILE"
done

# Backup existing config if exists
if [ -f "$CONFIG_FILE" ]; then
    BACKUP_FILE="$NETPLAN_DIR/01-auto-config.yaml.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CONFIG_FILE" "$BACKUP_FILE"
    echo "Backed up existing config to: $BACKUP_FILE"
fi

# Move temp file to final location
mv "$TEMP_FILE" "$CONFIG_FILE"

# Set correct permissions
chmod 600 "$CONFIG_FILE"

echo "Netplan configuration generated: $CONFIG_FILE"
echo ""
echo "Current network configuration summary:"
echo "======================================"
ip addr show
echo ""
echo "Routing table:"
echo "=============="
ip route
echo ""
echo "Generated netplan configuration:"
echo "================================"
cat "$CONFIG_FILE"
echo ""
echo "To apply the configuration, run: sudo netplan apply"
