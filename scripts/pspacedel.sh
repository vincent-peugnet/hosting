#!/bin/bash
DIR=$(dirname "$0")
. "$DIR/functions.sh"

usage() {
	echo "Usage:"
	echo "  hostedspace-del [options] NAME"
	echo ""
	echo "Options:"
	echo "  -h               Show help."
	echo "  -v               Verbose."
	echo "  -r               Remove home directory"
	echo "  -m               Remove MariaDb MySql account."
	echo "  -g               Keep group."
	exit 0
}

optstring="hvrmg"
userdel_options=()

parse $optstring $@
[ -z ${params[0]} ] && usage # if only options, show usage
login=${params[0]}

if [[ -n ${options[r]} ]]; then
	[[ -n ${options[v]} ]] && echo 'option remove home directory'
	userdel_options+=('-r')
fi

userdel_options+=('')
[[ -n ${options[v]} ]] && echo "userdel ${userdel_options[*]}$login"
sudo userdel ${userdel_options[*]}$login

if [[ -z ${options[g]} ]]; then
	[[ -n ${options[v]} ]] && echo "delete group '$login'"
	sudo groupdel $login
fi
if [[ -n ${options[m]} ]]; then
	sqlUserDel
fi

exit 0
