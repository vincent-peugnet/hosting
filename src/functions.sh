#!/bin/bash
DIR=$(dirname "$(readlink -f "$0")")
. "$DIR/config.sh"

declare -A options=()
declare params=()
declare login=''

tryRoot() {
	[ "$USER" != 'root' ] && echo 'ERROR: This script must be run as root' >&2 && usage
}

confirm() {
	echo $*
	read -p "continue (y/N)?" choice
	case "$choice" in
	y | Y) echo "yes" ;;
	*) exit 1 ;;
	esac
}

parse() {
	local optstring=$1
	shift
	[ $# = 0 ] && usage # if no params, show usage

	while [ $# -gt 0 ]; do
		optsGet $optstring $@
		shift $lastopt
		params+=($1)
		shift
	done
}

optsGet() {
	local optstring=$1
	shift
	while getopts ":$optstring" opt; do
		case $opt in
		h)
			usage
			;;
		:)
			echo "$OPTARG : requires an argument"
			exit 1
			;;
		\?)
			echo "$OPTARG : invalid option"
			exit 1
			;;
		*)
			[ -z $OPTARG ] && options[$opt]=1 || options[$opt]=$OPTARG
			;;
		esac
	done
	lastopt=$((OPTIND - 1))
	OPTIND=1
}

verbose() {
	[[ -n ${options[v]} || -z ${options[q]} ]] && echo $*
}

loginGet() {
	[ -z ${params[0]} ] && usage # if only options, show usage
	login=${params[0]}
}

loginUpdate() {
	local loginnew=$1
	homeUpdate $loginnew
	groupUpdate $loginnew
	sqlUserUpdate $loginnew
	verbose "updating UNIX user '$login' into '$loginnew'"
	usermod -l $loginnew $login
}

homeDel() {
	verbose "deleting '$login' home directory"
	rm -f "/home/$login"
}

homeUpdate() {
	local loginnew=$1
	verbose "updating '/home/$login' into '/home/$loginnew'"
	mv "/home/$login" "/home/$loginnew"
}

groupDel() {
	verbose "deleting group '$login'"
	groupdel $login
}

groupUpdate() {
	local loginnew=$1
	verbose "updating group '$login' into '$loginnew'"
	groupmod -n $loginnew $login
}

passwordSet() {
	local login=$1
	if [ $# -gt 1 ]; then
		password=$2
		verbose "setting password of '$login': $password"
		echo "$login:$password" | chpasswd
	else
		verbose "setting password of '$login'"
		passwd $login
	fi
}

shellAdd() {
	verbose 'adding shell'
	usermod -s /bin/bash $login
}

shellDel() {
	verbose 'deleting shell'
	usermod -s /bin/false $login
}

sqlUserAdd() {
	verbose "creating MySql user '$login@localhost' identified via PAM and grant privileges"
	mysql -u root -e "
		CREATE USER $login@localhost IDENTIFIED VIA pam;
		GRANT ALL PRIVILEGES ON \`$login\_%\` . * TO '$login'@'localhost';
		INSERT INTO phpmyadmin.pma__users (username, usergroup) VALUES ('$login', '$pma_usergroup');"
}

sqlUserDel() {
	verbose "deleting MySql user '$login@localhost'"
	mysql -u root -e "
		DROP USER IF EXISTS $login@localhost;
		DELETE FROM phpmyadmin.pma__users WHERE username = '$login';"
}

sqlUserUpdate() {
	local loginnew=$1
	# nbuser=$(mysql -u root -e 'select user from mysql.user' | grep -sw $login | wc -l)
	mysql -u root -e "
		UPDATE mysql.user SET User = '$loginnew' WHERE Host = 'localhost' AND User = '$login';
		UPDATE phpmyadmin.pma__users SET username = '$loginnew' WHERE username = '$login';"
}

subdomainAdd() {
	if [ -n $1 ]; then
		local subdomain="$(cut -d : -f1 <<<$1)"
		local domain=$subdomain.$sld.$tld
		local binddb="/etc/bind/db.$sld.$tld"
		local needle=serial
		local date=$(date +%Y%m%d%H)
		confirm "create subdomain '$domain'"
		sed -i -e "s/^\(\t*\)[0-9]\{10\}\(\t*;\s*${needle}\)$/\1${date}\2/" $binddb
		printf "$subdomain\tIN\tA\t$ip\t; $login\n" | expand -t 24,32,40,56 | unexpand -a >> $binddb
		systemctl restart bind9
		vhostAdd "$domain:$(cut -d : -f2 <<<$1)"
	fi
}

subdomainDel() {
	if [ -n $1 ]; then
		local subdomain="$(cut -d : -f1 <<<$1)"
		local domain=$subdomain.$sld.$tld
		local binddb="/etc/bind/db.$sld.$tld"
		confirm "delete subdomain '$domain'"
		sed -ni "/^$subdomain	/!p" $binddb
		systemctl restart bind9
		vhostDel "$domain:$(cut -d : -f2 <<<$1)"
	fi
}

phpfpmpoolAdd() {
	if [ -n $1 ]; then
		local file="/etc/php/$phpversion/fpm/pool.d/$login.conf"
		verbose "creating fpm pool for '$login'"
		if [ ! -f $file ]; then
			sed -e "s#\${user}#$login#" "$DIR/../res/fpm-pool.conf" > $file
		fi
		systemctl restart "php$phpversion-fpm"
	fi
}

phpfpmpoolDel() {
	if [ -n $1 ]; then
		verbose "deleting fpm pool for '$login'"
		rm "/etc/php/$phpversion/fpm/pool.d/$login.conf"
		systemctl restart "php$phpversion-fpm"
	fi
}

filemanagerAdd() {
	phpfpmpoolAdd "files.club1.fr-$login"
}

filemanagerDel() {
	phpfpmpoolDel "files.club1.fr-$login"
}

vhostAdd() {
	if [ -n $1 ]; then
		local domain="$(cut -d : -f1 <<<$1)"
		local top=$(getTopDomain $domain)
		local dir="$(cut -d : -f2 <<<$1)"
		local subdir="/home/$login/$dir"
		if [ ! -z $top ]; then
			echo this is a subdomain of $top
			if [ -d /etc/letsencrypt/live/$top ]; then
				echo will use already existing certificates for this domain
			fi
		fi
		confirm "creating virtualhost '$domain' on '$subdir'"
		if [ -f $subdir ]; then
			verbose "'$subdir' is a file, making a backup"
			sudo -u $login mv $subdir $subdir.bak
		fi
		if [ ! -e $subdir ]; then
			verbose "'$subdir' does not exist, creating it"
			sudo -u $login mkdir -p $subdir
		fi
		phpfpmpoolAdd $domain
		if [ ! -z $top ] && [ -d /etc/letsencrypt/live/$top ]; then
			sed -e "s#\${domain}#$domain#" -e "s#\${email}#$email#" -e "s#\${subdir}#$subdir#" -e "s#\${user}#$login#" -e "s#\${top}#$top#" "$DIR/../res/vhost-le-ssl.conf" >"/etc/apache2/sites-available/$domain-le-ssl.conf"
			a2ensite "$domain-le-ssl.conf"
		else
			sed -e "s#\${domain}#$domain#" -e "s#\${email}#$email#" -e "s#\${subdir}#$subdir#" -e "s#\${user}#$login#" "$DIR/../res/vhost-default.conf" >"/etc/apache2/sites-available/$domain.conf"
			a2ensite "$domain.conf"
			a2dissite "$redirect_vhost-le-ssl"
			certbot -n --apache -d $domain
			a2ensite "$redirect_vhost-le-ssl"
		fi
		sed -e "s#\${domain}#$domain#" -e "s#\${email}#$email#" "$DIR/../res/vhost-redirect.conf" >"/etc/apache2/sites-available/$domain.conf"
		a2ensite "$domain.conf"
		systemctl reload apache2
	fi
}

vhostDel() {
	if [ -n $1 ]; then
		local domain="$(cut -d : -f1 <<<$1)"
		local dir="$(cut -d : -f2 <<<$1)"
		local domainle="$domain-le-ssl"
		confirm "delete virtualhost '$domain'"
		a2dissite $domainle
		a2dissite $domain
		rm "/etc/apache2/sites-available/$domainle.conf"
		rm "/etc/apache2/sites-available/$domain.conf"
		rm "/home/$login/$dir/error.log"
		rm "/home/$login/$dir/access.log"
		systemctl reload apache2
#		phpfpmpoolDel $domain
	fi
}

getTopDomain() {
	echo $1 | sed -nE 's/^.+\.(.+\..+)$/\1/p'
}
