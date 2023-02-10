#! /bin/bash

# This script is based on the following tutorial
# https://www.cyberciti.biz/faq/install-set-up-wireguard-on-amazon-linux-2/

###################
## CONFIGURATION ##
###################

# Define Wireguard variables
internet_network_interface="eth0"
wireguard_dir="/etc/wireguard" # WG server main config dir
wireguard_cidr="10.106.28.0/24" # WG server's CIDR
wireguard_private_ip="10.106.28.1/32" # WG server's private IP
wireguard_udp_port="51111" # WG server UDP port
wireguard_interface_name="wg0" # WG interface name
wireguard_config_file="${wireguard_dir}/${wireguard_interface_name}.conf" # WG server config file
wireguard_public_key="${wireguard_dir}/${HOSTNAME}.${wireguard_interface_name}.publickey" # WG server pub key
wireguard_private_key="${wireguard_dir}/${HOSTNAME}.${wireguard_interface_name}.privatekey" # WG server private key
wireguard_preshared_key="${wireguard_dir}/${HOSTNAME}.${wireguard_interface_name}.presharedkey" # WG server shared key

# Collect the needed info
public_ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
mac_address=$(curl -s http://169.254.169.254/latest/meta-data/mac)
subnet_cidr=$(curl -s http://169.254.169.254/latest/meta-data/network/interfaces/macs/${mac_address}/subnet-ipv4-cidr-block)

echo "Public IP: ${public_ip}"
echo "MAC Address: ${mac_address}"
echo "Subnet CIDR: ${subnet_cidr}"

# Check user
user=$(whoami)
if [ $user != "root" ]; then
	echo "This script must be run as root"
	exit 1
fi

# Verify if the chosen CIDR is not the same as the VM's subnet one
if [ $wireguard_cidr == $subnet_cidr ]; then
	echo "CIDR same as the subnet - ${wireguard_cidr} - choose another CIDR for Wireguard"
	exit 1
fi

# Install Wireguard
if yum list installed wireguard-dkms; then
	echo "Wireguard already installed"
else
	# Disable yum-plugin-priorities
	printf "[main]\nenabled = 0\n" > /etc/yum/pluginconf.d/priorities.conf
	amazon-linux-extras install -y epel
	wget --output-document="/etc/yum.repos.d/wireguard.repo" "https://copr.fedorainfracloud.org/coprs/jdoss/wireguard/repo/epel-7/jdoss-wireguard-epel-7.repo"
	yum clean all
	yum install wireguard-dkms wireguard-tools -y
fi

sleep 5

# Verify if the installation is successful
find / -iname "wireguard.ko" 2>/dev/null
if [ $? -ne 0 ]; then
	echo "Installation unsuccessful"
	exit 1
fi

# Generate keys
if [ ! -f "${wireguard_private_key}" ]; then
	wg genkey | tee "${wireguard_private_key}" | wg pubkey > "${wireguard_public_key}"
	wg genpsk > "${wireguard_preshared_key}"
else
	echo "Keys exist"
fi

# Generate config file
echo "## Set Up WireGuard VPN server on $HOSTNAME  ##

[Interface]
## My VPN server private IP address ##
Address = ${wireguard_private_ip}

## My VPN server port ##
ListenPort = ${wireguard_udp_port}

## VPN server's private key
PrivateKey = $(cat ${wireguard_private_key})

## Set up firewall routing here
PostUp = ${wireguard_dir}/scripts/${wireguard_interface_name}.firewall-up.sh
PostDown = ${wireguard_dir}/scripts/${wireguard_interface_name}.firewall-down.sh" > $wireguard_config_file

# Generate WG VPN firewall config
if [ ! -d "${wireguard_dir}/scripts" ]; then
	mkdir "${wireguard_dir}/scripts"
fi

IPT="/sbin/iptables"
IPT6="/sbin/ip6tables"
# Uncomment for IPV6
#SUB_NET_6="" # WG IPv6 sub/net (set IPv6 CIDR)

echo "#!/bin/bash
 
## IPv4 ##
$IPT -t nat -I POSTROUTING 1 -s ${wireguard_cidr} -o ${internet_network_interface} -j MASQUERADE
$IPT -I INPUT 1 -i ${wireguard_interface_name} -j ACCEPT
$IPT -I FORWARD 1 -i ${internet_network_interface} -o ${wireguard_interface_name} -j ACCEPT
$IPT -I FORWARD 1 -i ${wireguard_interface_name} -o ${internet_network_interface} -j ACCEPT
$IPT -I INPUT 1 -i ${internet_network_interface} -p udp --dport ${wireguard_udp_port} -j ACCEPT" > "${wireguard_dir}/scripts/${wireguard_interface_name}.firewall-up.sh"

echo "#!/bin/bash

# IPv4 rules #
$IPT -t nat -D POSTROUTING -s ${wireguard_cidr} -o ${internet_network_interface} -j MASQUERADE
$IPT -D INPUT -i ${wireguard_interface_name} -j ACCEPT
$IPT -D FORWARD -i ${internet_network_interface} -o ${wireguard_interface_name} -j ACCEPT
$IPT -D FORWARD -i ${wireguard_interface_name} -o ${internet_network_interface} -j ACCEPT
$IPT -D INPUT -i ${internet_network_interface}E -p udp --dport ${wireguard_udp_port} -j ACCEPT" > "${wireguard_dir}/scripts/${wireguard_interface_name}.firewall-down.sh"

# Enabling routing and packet forwarding on the Amazon Linux
echo "net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1" > "/etc/sysctl.d/10-wireguard.conf"

# Reload all changes and turn on NAT routing using the sysctl command
sysctl -p /etc/sysctl.d/10-wireguard.conf

chmod -v +x ${wireguard_dir}/scripts/*.sh

# Create client config dir
if [ ! -d "${wireguard_dir}/client-config" ]; then
	mkdir -v "${wireguard_dir}/client-config"
fi

# Enable the Wireguard service
systemctl enable wg-quick@wg0.service

# Start the Wireguard service
systemctl start wg-quick@wg0.service
