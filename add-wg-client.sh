#! /bin/bash

# This script is based on the following tutorial
# https://www.cyberciti.biz/faq/install-set-up-wireguard-on-amazon-linux-2/

client_name=$1

if [ -z $client_name ]; then
    echo "Client name missing. Pass it as first argument to the script. Example ./add-wireguard-client pdamyanov"
    exit 1
fi

# Check user
user=$(whoami)
if [ $user != "root" ]; then
	echo "This script must be run as root"
	exit 1
fi

wireguard_dir="/etc/wireguard/"
wireguard_interface_name="wg0"
wireguard_config_file="${wireguard_dir}/${wireguard_interface_name}.conf" # WG server config file
wireguard_public_key="${wireguard_dir}/${HOSTNAME}.${wireguard_interface_name}.publickey" # WG server pub key
wireguard_private_key="${wireguard_dir}/${HOSTNAME}.${wireguard_interface_name}.privatekey" # WG server private key
wireguard_preshared_key="${wireguard_dir}/${HOSTNAME}.${wireguard_interface_name}.presharedkey" # WG server shared key

echo "Check if Wireguard is installed and configured"
if yum list installed wireguard-dkms; then
    fail=false
    if [ ! -f $wireguard_config_file ]; then
        echo "Wireguard config file missing"
        fail=true
    fi
    if [ ! -f $wireguard_public_key ]; then
        echo "Wireguard public key missing"
        fail=true
    fi
    if [ ! -f $wireguard_private_key ]; then
        echo "Wireguard private key missing"
        fail=true
    fi
    if [ ! -f $wireguard_preshared_key ]; then
        echo "Wireguard preshared key missing"
        fail=true
    fi
    if [ $fail == "true" ]; then
        echo "Fix above problems and try again"
        exit 1
    fi
	echo "Wireguard installed and configured successfully"
else
    echo "Wireguard not installed. Run the install-wireguard.sh script first"
fi

client_config_dir="/etc/wireguard/client-config"

if [ -f "${client_config_dir}/next-ip" ]; then
    client_private_ip=$(cat "${client_config_dir}/next-ip")
    last_octet=$(echo $client_private_ip | cut -d "." -f4)
    if [ $last_octet -gt 255 ]; then
        echo "Reached 255 clients. Subnet doesn't allow any more clients"
        exit 1
    fi
    next=$((last_octet+1))
    first_three_octets=$(echo $client_private_ip | cut -d "." -f1-3)
    echo "${first_three_octets}.${next}" > "${client_config_dir}/next-ip"
else
    wg_ip_addr=$(cat $wireguard_config_file | grep "Address" | cut -d " " -f3 | cut -d "/" -f1)
    first_three_octets=$(echo $wg_ip_addr | cut -d "." -f1-3)
    last_octet=$(echo $wg_ip_addr | cut -d "." -f4)
    next=$((last_octet+1))
    client_private_ip="${first_three_octets}.${next}"
    next=$((next+1))
    echo "${first_three_octets}.${next}" > "${client_config_dir}/next-ip"
fi

# Define client variables
client_private_cidr="${client_private_ip}/32"
client_config_file="${client_config_dir}/${client_name}.conf" # WG server config file
client_public_key="${client_config_dir}/${client_name}.publickey" # WG server pub key
client_private_key="${client_config_dir}/${client_name}.privatekey" # WG server private key
client_preshared_key="${client_config_dir}/${client_name}.presharedkey" # WG server shared key
client_dns_ip="10.0.0.2"

# Backup the Wireguard configuration file before updating it with client's configuration
cp "${wireguard_config_file}" "${client_config_dir}/${wireguard_interface_name}.conf.bak.${client_name}"

# Generate client keys
umask 077; wg genkey | tee "$client_private_key" | wg pubkey > "$client_public_key"
umask 077; wg genpsk > "$client_preshared_key"

# Pull needed data
public_ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
wg_udp_port=$(cat $wireguard_config_file | grep "ListenPort" | cut -d " " -f3)

# Create client's config file
echo "# Config for ${client_name} client #
[Interface]
PrivateKey = $(cat ${client_private_key})
Address = ${client_private_cidr}
DNS = ${client_dns_ip}
 
[Peer]
# ${HOSTNAME}'s ${wireguard_public_key} 
PublicKey = $(cat ${wireguard_public_key}) 
AllowedIPs = 0.0.0.0/0
# EC2 public IP4 and port 
Endpoint = ${public_ip}:${wg_udp_port}
PersistentKeepalive = 15
PresharedKey = $(cat ${client_preshared_key})" > $client_config_file

# Append client's config to Wireguard's config file
echo " 
[Peer]
## ${client_name} VPN config with public key taken from ${client_config_dir} dir ##
## Must match ${client_config_file} file ##
PublicKey = $(cat ${client_public_key})
AllowedIPs = ${client_private_cidr}
PresharedKey = $(cat ${client_preshared_key})" >> $wireguard_config_file

# Restart Wireguard service
systemctl restart wg-quick@wg0.service

echo "Wireguard client ${client_name} added successfully"