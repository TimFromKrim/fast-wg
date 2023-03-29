#!/bin/bash

# Существует ли wg0.conf
isWg0conf() {
	if [[ -f /etc/wireguard/wg0.conf ]]; then
		return 1
	else
		return 0
	fi
}

# Существуют ли ключи
isKeys() {
	if [[ -f /etc/wireguard/privatekey ]] && [[ -f /etc/wireguard/publickey ]]; then
		return 1
	elif [[ -f /etc/wireguard/privatekey ]] || [[ -f /etc/wireguard/publickey ]]; then
		return 0
	else
		return 0
	fi
}

# Установлен ли wireguard
isWireguardInstalled() {
	if which wg >/dev/null; then
		# installed
		return 1
	else 
		# not installed
		return 0
	fi
}

isNew() {
	if [ "$1" == '-new' ]; then
		return 1
	else
		return 0
	fi
}

isAdd() {
	if [ $1 = '-add' ]; then
		return 1
	else
		return 0
	fi
}

addClientKeys() {
	echo "Creating client's keys ..."
	wg genkey | tee /etc/wireguard/${1}_privatekey | wg pubkey | tee /etc/wireguard/${1}_publickey
}

allowed_ips_amount() {
	mapfile -t allowed_ips < <(grep 'AllowedIPs' /etc/wireguard/wg0.conf | cut -d '=' -f 2 | tr -d ' ')
	lastString=$((${#allowed_ips[@]} - 1))
	return $(echo "${allowed_ips[$lastString]}" | cut -d '.' -f 4 | cut -d '/' -f 1)
}



addPeer() {
	allowed_ips_amount
	curnt_ips=$(($? + 1))

	cat >> /etc/wireguard/wg0.conf <<-EOL

	# $1
	[Peer]
	PublicKey = $(cat /etc/wireguard/${1}_publickey)
	AllowedIPs = 10.0.0.$curnt_ips/32
	EOL
}

wgRestart() {
	systemctl restart wg-quick@wg0.service
	systemctl status wg-quick@wg0.service
}



# Проверка и установка wireguard
isWireguardInstalled
if [[ $? -eq 0 ]]; then
	apt install wireguard
else
	echo "Wireguard is installed"
fi

# Проверка на пустоту или неправильность аргументов
if [ -z "$1" ] || [[ "$1" != '-new' ]] && [[ "$1" != '-add' ]]; then
	echo -e "Use:\n\n    $0 -new <userName>\n\nfor create new wg0 config and client config"
	echo ""
	echo -e "Or:\n\n    $0 -add <userName>\n\nfor add client config"
fi

if [ -z "$2" ]; then
	echo "Use client file name in second parameter"
	echo ""
	echo "$0 -new/-add <userName>"
	exit 0
fi

# Создаем новый конфиг
ip a
isNew $1
if [ $? -eq 1 ]; then
	# Генерируем ключи если их нет
	isKeys
	if [ $? -eq 0 ]; then
		read -p "The server keys were not found. Do you want to create keys? [Y/n]: " keysYN

		if [ $keysYN = "y" ] || [ $keysYN = "Y" ]; then
			echo "Creating keys ..."
			wg genkey | tee /etc/wireguard/privatekey | wg pubkey | tee /etc/wireguard/publickey
		else
			echo "Create server privatekey and publickey in /etc/wireguard/"
			exit 0
		fi
	fi

	# Определение сетевого интерфейса
	netInterface=$(ip a | sed -n 's/.*2: \(.*\):.*/\1/p')
	read -p "This is your netInterface: $netInterface? [Y/n]: " netInterfaceYN

	if [ $netInterfaceYN = "y" ] || [ $netInterfaceYN = "Y" ]; then
		echo "Saving net interface data"
	else
		read -p "Please enter the name of your net interface: " netInterface
	fi

	# Создание клиентских ключей
	addClientKeys $2


	# Создание wg0.config
	isWg0conf
	if [ $? -eq 1 ]; then
		rm -r /etc/wireguard/wg0.conf
	fi

		echo "Creating wg0.conf ..."

		cat > /etc/wireguard/wg0.conf <<-EOL
		[Interface]
		PrivateKey = $(cat /etc/wireguard/privatekey)
		Address = 10.0.0.1/24
		ListenPort = 51830
		PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $netInterface -j MASQUERADE
		PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $netInterface -j MASQUERADE 
		EOL

		cat >> /etc/wireguard/wg0.conf <<-EOL

		# $2
		[Peer]
		PublicKey = $(cat /etc/wireguard/${2}_publickey)
		AllowedIPs = 10.0.0.2/32
		EOL

		# Создание конфига клиента в домашней дирретории
		cat > ${2}_client.conf <<-EOL
			[Interface]
			PrivateKey = $(cat /etc/wireguard/${2}_privatekey)
			Address = 10.0.0.2/32
			DNS = 8.8.8.8

			[Peer]
			PublicKey = $(cat /etc/wireguard/publickey)
			Endpoint = $(curl ifconfig.me):51830
			AllowedIPs = 0.0.0.0/0
			PersistentKeepalive = 20

		EOL

		# Включаем ip ip forwarding
		echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
		sysctl -p

		# Включаем ситему
		systemctl enable wg-quick@wg0.service
		systemctl start wg-quick@wg0.service
		systemctl status wg-quick@wg0.service
fi

isAdd $1
if [ $? -eq 1 ]; then
	addClientKeys $2

	addPeer $2

	cat > ${2}_client.conf <<-EOL
			[Interface]
			PrivateKey = $(cat /etc/wireguard/${2}_privatekey)
			Address = 10.0.0.$curnt_ips/32
			DNS = 8.8.8.8

			[Peer]
			PublicKey = $(cat /etc/wireguard/publickey)
			Endpoint = $(curl ifconfig.me):51830
			AllowedIPs = 0.0.0.0/0
			PersistentKeepalive = 20

		EOL

		wgRestart
fi


exit 0