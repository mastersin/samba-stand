#!/bin/bash -x

create_iface()
{
	local iface="$1"; shift
	local bootproto="$1"; shift
	mkdir -p /etc/net/ifaces/$iface
	cat > /etc/net/ifaces/$iface/options <<__EOF
BOOTPROTO=$bootproto
TYPE=eth
__EOF
	if [ "$bootproto" == "static" ]; then
		echo "$1/24" > /etc/net/ifaces/$iface/ipv4address
		shift
	fi
	if [ "nameserver" == "${1-}" ]; then
		set_nameserver "$iface" "$2"
		shift 2
	fi
	iface_restart $iface
}

set_nameserver()
{
	local iface="$1"; shift
	local nameserver="$1"; shift
	echo "nameserver $nameserver" > /etc/net/ifaces/$iface/resolv.conf
	grep -q "interface_order=.*$iface " /etc/resolvconf.conf || sed -i "s/interface_order='\(.*\)'/interface_order='$iface \1'/" /etc/resolvconf.conf
	iface_restart $iface
}

iface_restart()
{
	local iface="$1"; shift
	ifdown $iface
	ifup $iface
}

set_hostname()
{
	sed -i "s/HOSTNAME=.*/HOSTNAME=$1/" /etc/sysconfig/network
	hostname $1
}

init_krb5_conf()
{
	local realm="$1"
	sed -i "s/[#[:space:]]*default_realm\s*=\s*.*/        default_realm = $realm/" /etc/krb5.conf
	sed -i "s/[#[:space:]]*dns_lookup_realm\s*=\s*.*/        dns_lookup_kdc = true/" /etc/krb5.conf
	sed -i "s/\s*dns_lookup_realm\s*=\s*.*/        dns_lookup_realm = false/" /etc/krb5.conf
}

get_ip()
{
	local ip="$1"
	[ "$ip" == "dhcp" ] || echo -n "static "
	echo "$ip"
}

pub_ip="$1"; shift
host_ip="$1"; shift
host_name="$1"; shift
host_nameserver="${1-}"

create_iface eth1 $(get_ip "$pub_ip")
create_iface eth2 $(get_ip "$host_ip") $(test -z "$host_nameserver" || echo nameserver "$host_nameserver")
set_hostname "$host_name"

apt-get update
apt-get dist-upgrade -y -qq
apt-get clean

HOST=$(hostname -s)
DOMAIN=$(hostname -d)
REALM="$(hostname -d | tr [a-z] [A-Z])"
WORKGROUP=${REALM%%.*}
PASSWORD='Pa$$word'

COMMON_TOOLS="bind-utils krb5-kinit"

case "$(hostname -s)" in
	client)
		apt-get install -y -qq samba-client sssd-ad $COMMON_TOOLS
		apt-get clean
		apt-get install -y -qq task-auth-ad-sssd
		apt-get clean
		init_krb5_conf
		system-auth write ad $DOMAIN $HOST $WORKGROUP 'Administrator' "$PASSWORD"
		;;
	server)
		apt-get install -y -qq samba-DC samba-DC-client $COMMON_TOOLS
		apt-get clean
		mv /etc/samba/smb.conf /etc/samba/smb.conf.saved
		init_krb5_conf
		samba-tool domain provision --realm="$REALM" --domain "$WORKGROUP" --adminpass="$PASSWORD" --dns-backend=SAMBA_INTERNAL --server-role=dc --use-rfc2307 --host-ip="$host_ip"
		set_nameserver eth2 127.0.0.1
		service samba start
		chkconfig samba on
		;;
esac
