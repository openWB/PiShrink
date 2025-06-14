#!/usr/bin/env bash

# Project: PiShrink
# Description: PiShrink is a bash script that automatically shrink a pi image that will then resize to the max size of the SD card on boot.
# Link: https://github.com/Drewsif/PiShrink

version="v24.10.23"

CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
MYNAME="${SCRIPTNAME%.*}"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"
REQUIRED_TOOLS="parted losetup tune2fs md5sum e2fsck resize2fs"
ZIPTOOLS=("gzip xz")
declare -A ZIP_PARALLEL_TOOL=( [gzip]="pigz" [xz]="xz" ) # parallel zip tool to use in parallel mode
declare -A ZIP_PARALLEL_OPTIONS=( [gzip]="-f9" [xz]="-T0" ) # options for zip tools in parallel mode
declare -A ZIPEXTENSIONS=( [gzip]="gz" [xz]="xz" ) # extensions of zipped files

function info() {
	echo "$SCRIPTNAME: $1"
}

function error() {
	echo -n "$SCRIPTNAME: ERROR occurred in line $1: "
	shift
	echo "$@"
}

function cleanup() {
	if losetup "$loopback" &>/dev/null; then
		losetup -d "$loopback"
	fi
	if [ "$debug" = true ]; then
		local old_owner
		old_owner=$(stat -c %u:%g "$src")
		chown "$old_owner" "$LOGFILE"
	fi

}

function logVariables() {
	if [ "$debug" = true ]; then
		echo "Line $1" >> "$LOGFILE"
		shift
		local v var
		for var in "$@"; do
			eval "v=\$$var"
			echo "$var: $v" >> "$LOGFILE"
		done
	fi
}

function checkFilesystem() {
	info "Checking filesystem"
	e2fsck -pf "$loopback"
	(( $? < 4 )) && return

	info "Filesystem error detected!"

	info "Trying to recover corrupted filesystem"
	e2fsck -y "$loopback"
	(( $? < 4 )) && return

	if [[ $repair == true ]]; then
		info "Trying to recover corrupted filesystem - Phase 2"
		e2fsck -fy -b 32768 "$loopback"
		(( $? < 4 )) && return
	fi
		error $LINENO "Filesystem recoveries failed. Giving up..."
		exit 9
}

function set_autoexpand() {
    #Make pi expand rootfs on next boot
    mountdir=$(mktemp -d)
    partprobe "$loopback"
    sleep 3
    umount "$loopback" > /dev/null 2>&1
    mount "$loopback" "$mountdir" -o rw
    if (( $? != 0 )); then
      info "Unable to mount loopback, autoexpand will not be enabled"
      return
    fi

		if [ ! -d "$mountdir/etc" ]; then
				info "/etc not found, autoexpand will not be enabled"
				umount "$mountdir"
				return
		fi

    if [[ ! -f "$mountdir/etc/rc.local" ]]; then
        info "An existing /etc/rc.local was not found, autoexpand may fail..."
    fi

    if ! grep -q "## PiShrink https://github.com/Drewsif/PiShrink ##" "$mountdir/etc/rc.local"; then
      echo "Creating new /etc/rc.local"
    if [ -f "$mountdir/etc/rc.local" ]; then
        mv "$mountdir/etc/rc.local" "$mountdir/etc/rc.local.bak"
    fi

cat <<'EOFRC' > "$mountdir/etc/rc.local"
#!/bin/bash
## PiShrink https://github.com/Drewsif/PiShrink ##
do_expand_rootfs() {
	ROOT_PART=$(mount | sed -n 's|^/dev/\(.*\) on / .*|\1|p')

	PART_NUM=${ROOT_PART#mmcblk0p}
	if [ "$PART_NUM" = "$ROOT_PART" ]; then
		echo "$ROOT_PART is not an SD card. Don't know how to expand"
		return 0
	fi

	# Get the starting offset of the root partition
	PART_START=$(parted /dev/mmcblk0 -ms unit s p | grep "^${PART_NUM}" | cut -f 2 -d: | sed 's/[^0-9]//g')
	[ "$PART_START" ] || return 1
	# Return value will likely be error for fdisk as it fails to reload the
	# partition table because the root fs is mounted
	fdisk /dev/mmcblk0 <<EOF
p
d
$PART_NUM
n
p
$PART_NUM
$PART_START

p
w
EOF

cat <<EOF > /etc/rc.local &&
#!/bin/sh
echo "Expanding /dev/$ROOT_PART"
resize2fs /dev/$ROOT_PART
rm -f /etc/rc.local; cp -fp /etc/rc.local.bak /etc/rc.local && /etc/rc.local

EOF
reboot
exit
}
raspi_config_expand() {
/usr/bin/env raspi-config --expand-rootfs
if [[ $? != 0 ]]; then
	return -1
else
  rm -f /etc/rc.local; cp -fp /etc/rc.local.bak /etc/rc.local && /etc/rc.local
  reboot
  exit
fi
}
raspi_config_expand
echo "WARNING: Using backup expand..."
sleep 5
do_expand_rootfs
echo "ERROR: Expanding failed..."
sleep 5
if [[ -f /etc/rc.local.bak ]]; then
  cp -fp /etc/rc.local.bak /etc/rc.local
  /etc/rc.local
fi
exit 0
EOFRC

    chmod +x "$mountdir/etc/rc.local"
    fi
    umount "$mountdir"
}

help() {
	local help
	read -r -d '' help << EOM
Usage: $0 [-adhnrsvzZ] imagefile.img [newimagefile.img]

  -s         Don't expand filesystem when image is booted the first time
  -v         Be verbose
  -n         Disable automatic update checking
  -r         Use advanced filesystem repair option if the normal one fails
  -z         Compress image after shrinking with gzip
  -Z         Compress image after shrinking with xz
  -a         Compress image in parallel using multiple cores
  -p         Remove logs, apt archives, dhcp leases and ssh hostkeys
  -o         Remove openWB specific files
  -d         Write debug messages in a debug log file
EOM
	echo "$help"
	exit 1
}

should_skip_autoexpand=false
debug=false
update_check=false  # do not check for updates as we have no releases yet
repair=false
parallel=false
verbose=false
prep=false
prep_openwb=false
ziptool=""

while getopts ":adnhoprsvzZ" opt; do
  case "${opt}" in
    a) parallel=true;;
    d) debug=true;;
    n) update_check=false;;
    h) help;;
    o) prep_openwb=true;;
    p) prep=true;;
    r) repair=true;;
    s) should_skip_autoexpand=true ;;
    v) verbose=true;;
    z) ziptool="gzip";;
    Z) ziptool="xz";;
    *) help;;
  esac
done
shift $((OPTIND-1))

if [ "$debug" = true ]; then
	info "Creating log file $LOGFILE"
	rm "$LOGFILE" &>/dev/null
	exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
	exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
fi

echo -e "PiShrink $version - https://github.com/openWB/PiShrink\n"

# Try and check for updates
if $update_check; then
  latest_release=$(curl -m 5 https://api.github.com/repos/openWB/PiShrink/releases/latest 2>/dev/null | grep -i "tag_name" 2>/dev/null | awk -F '"' '{print $4}' 2>/dev/null)
  if [[ $? ]] && [ "$latest_release" \> "$version" ]; then
    echo "WARNING: You do not appear to be running the latest version of PiShrink. Head on over to https://github.com/openWB/PiShrink to grab $latest_release"
    echo ""
  fi
fi

#Args
src="$1"
img="$1"

#Usage checks
if [[ -z "$img" ]]; then
	help
fi

if [[ ! -f "$img" ]]; then
	error $LINENO "$img is not a file..."
	exit 2
fi
if (( EUID != 0 )); then
	error $LINENO "You need to be running as root."
	exit 3
fi

# set locale to POSIX(English) temporarily
# these locale settings only affect the script and its sub processes

export LANGUAGE=POSIX
export LC_ALL=POSIX
export LANG=POSIX

# check selected compression tool is supported and installed
if [[ -n $ziptool ]]; then
	if [[ ! " ${ZIPTOOLS[*]} " =~ $ziptool ]]; then
		error $LINENO "$ziptool is an unsupported ziptool."
		exit 17
	else
		if [[ $parallel == true && $ziptool == "gzip" ]]; then
			REQUIRED_TOOLS="$REQUIRED_TOOLS pigz"
		else
			REQUIRED_TOOLS="$REQUIRED_TOOLS $ziptool"
		fi
	fi
fi

#Check that what we need is installed
for command in $REQUIRED_TOOLS; do
	command -v "$command" >/dev/null 2>&1
	if (( $? != 0 )); then
		error $LINENO "$command is not installed."
		exit 4
	fi
done

#Copy to new file if requested
if [ -n "$2" ]; then
	f="$2"
	if [[ -n $ziptool && "${f##*.}" == "${ZIPEXTENSIONS[$ziptool]}" ]]; then	# remove zip extension if zip requested because zip tool will complain about extension
		f="${f%.*}"
	fi
	info "Copying $1 to $f..."
	cp --reflink=auto --sparse=always "$1" "$f"
	if (( $? != 0 )); then
		error $LINENO "Could not copy file..."
		exit 5
	fi
	old_owner=$(stat -c %u:%g "$1")
	chown "$old_owner" "$f"
	img="$f"
fi

# cleanup at script exit
trap cleanup EXIT

#Gather info
info "Gathering data"
beforesize="$(ls -lh "$img" | cut -d ' ' -f 5)"
parted_output="$(parted -ms "$img" unit B print)"
rc=$?
if (( rc )); then
	error $LINENO "parted failed with rc $rc"
	info "Possibly invalid image. Run 'parted $img unit B print' manually to investigate"
	exit 6
fi
partnum="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 1)"
partstart="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 2 | tr -d 'B')"
if [ -z "$(parted -s "$img" unit B print | grep "$partstart" | grep logical)" ]; then
	parttype="primary"
else
	parttype="logical"
fi
loopback="$(losetup -f --show -o "$partstart" "$img")"
tune2fs_output="$(tune2fs -l "$loopback")"
rc=$?
if (( rc )); then
	echo "$tune2fs_output"
	error $LINENO "tune2fs failed. Unable to shrink this type of image"
	exit 7
fi

currentsize="$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)"
blocksize="$(echo "$tune2fs_output" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)"

logVariables $LINENO beforesize parted_output partnum partstart parttype tune2fs_output currentsize blocksize

#Check if we should make pi expand rootfs on next boot
if [ "$parttype" == "logical" ]; then
	echo "WARNING: PiShrink does not yet support autoexpanding of this type of image"
elif [ "$should_skip_autoexpand" = false ]; then
	set_autoexpand
else
	echo "Skipping autoexpanding process..."
fi

if [[ $prep == true ]]; then
	info "Syspreping: Removing logs, apt archives, dhcp leases and ssh hostkeys"
	mountdir=$(mktemp -d)
	mount "$loopback" "$mountdir"
	rm -rf "$mountdir"/var/cache/apt/archives/* "$mountdir"/var/lib/dhcpcd/* "$mountdir"/var/tmp/* "$mountdir"/tmp/* "$mountdir"/etc/ssh/*_host_*
	find "$mountdir"/var/log/ -type f -delete
	if [[ -f "$mountdir"/lib/systemd/system/regenerate_ssh_host_keys.service ]] && ! [[ -L "$mountdir"/etc/systemd/system/multi-user.target.wants/regenerate_ssh_host_keys.service ]]; then
		ln -s /lib/systemd/system/regenerate_ssh_host_keys.service "$mountdir"/etc/systemd/system/multi-user.target.wants/regenerate_ssh_host_keys.service
	fi
	umount "$mountdir"
fi

# If the prep_openwb flag is set to true, perform cleanup specific to openWB files and directories.
if [[ $prep_openwb == true ]]; then
	info "openWB: Removing logs, chart data, backup files, restore files, data migration files, mqtt broker store, python cache directories, bash history, configuration file and serial number file"
	mountdir=$(mktemp -d)
	mount "$loopback" "$mountdir"
	rm -rf "$mountdir"/var/www/html/openWB/data/charge_log/* \
			"$mountdir"/var/www/html/openWB/data/daily_log/* \
			"$mountdir"/var/www/html/openWB/data/monthly_log/* \
			"$mountdir"/var/www/html/openWB/data/log/* \
			"$mountdir"/var/www/html/openWB/data/backup/* \
			"$mountdir"/var/www/html/openWB/data/restore/* \
			"$mountdir"/var/www/html/openWB/data/data_migration/* \
			"$mountdir"/var/lib/mosquitto/mosquitto.db \
			"$mountdir"/var/lib/mosquitto_local/mosquitto.db
	find "$mountdir"/var/www/html/openWB \( -name "__pycache__" \) -type d -exec rm -rf {} \;
	find "$mountdir"/home/ \( -name ".bash_history" -o -name "configuration.json" -o -name "snnumber" \) -type f -delete
	umount "$mountdir"
fi

#Make sure filesystem is ok
checkFilesystem

if ! minsize=$(resize2fs -P "$loopback"); then
	rc=$?
	error $LINENO "resize2fs failed with rc $rc"
	exit 10
fi
minsize=$(cut -d ':' -f 2 <<< "$minsize" | tr -d ' ')
logVariables $LINENO currentsize minsize
if [[ $currentsize -eq $minsize ]]; then
  info "Filesystem already shrunk to smallest size. Skipping filesystem shrinking"
else
  #Add some free space to the end of the filesystem
  extra_space=$(($currentsize - $minsize))
  logVariables $LINENO extra_space
  for space in 5000 1000 100; do
    if [[ $extra_space -gt $space ]]; then
      minsize=$(($minsize + $space))
      break
    fi
  done
  logVariables $LINENO minsize

  #Shrink filesystem
  info "Shrinking filesystem"
  if [ -z "$mountdir" ]; then
    mountdir=$(mktemp -d)
  fi

  resize2fs -p "$loopback" $minsize
  rc=$?
  if (( $rc )); then
    error $LINENO "resize2fs failed with rc $rc"
    mount "$loopback" "$mountdir"
    mv "$mountdir/etc/rc.local.bak" "$mountdir/etc/rc.local"
    umount "$mountdir"
    losetup -d "$loopback"
    exit 12
  else
    info "Zeroing any free space left"
    mount "$loopback" "$mountdir"
    cat /dev/zero > "$mountdir/PiShrink_zero_file" 2>/dev/null
    info "Zeroed $(ls -lh "$mountdir/PiShrink_zero_file" | cut -d ' ' -f 5)"
    rm -f "$mountdir/PiShrink_zero_file"
    umount "$mountdir"
  fi
  sleep 1

  #Shrink partition
  info "Shrinking partition"
  partnewsize=$(($minsize * $blocksize))
  newpartend=$(($partstart + $partnewsize))
  logVariables $LINENO partnewsize newpartend
  parted -s -a minimal "$img" rm "$partnum"
  rc=$?
  if (( $rc )); then
    error $LINENO "parted failed with rc $rc"
    exit 13
  fi

  parted -s "$img" unit B mkpart "$parttype" "$partstart" "$newpartend"
  rc=$?
  if (( $rc )); then
    error $LINENO "parted failed with rc $rc"
    exit 14
  fi

  #Truncate the file
  info "Truncating image"
  endresult=$(parted -ms "$img" unit B print free)
  rc=$?
  if (( $rc )); then
    error $LINENO "parted failed with rc $rc"
    exit 15
  fi

  endresult=$(tail -1 <<< "$endresult" | cut -d ':' -f 2 | tr -d 'B')
  logVariables $LINENO endresult
  truncate -s "$endresult" "$img"
  rc=$?
  if (( $rc )); then
    error $LINENO "truncate failed with rc $rc"
    exit 16
  fi
fi

# handle compression
if [[ -n $ziptool ]]; then
	options=""
	envVarname="${MYNAME^^}_${ziptool^^}" # PISHRINK_GZIP or PISHRINK_XZ environment variables allow to override all options for gzip or xz
	[[ $parallel == true ]] && options="${ZIP_PARALLEL_OPTIONS[$ziptool]}"
	[[ -v $envVarname ]] && options="${!envVarname}" # if environment variable defined use these options
	[[ $verbose == true ]] && options="$options -v" # add verbose flag if requested

	if [[ $parallel == true ]]; then
		parallel_tool="${ZIP_PARALLEL_TOOL[$ziptool]}"
		info "Using $parallel_tool on the shrunk image"
		if ! $parallel_tool ${options} "$img"; then
			rc=$?
			error $LINENO "$parallel_tool failed with rc $rc"
			exit 18
		fi

	else # sequential
		info "Using $ziptool on the shrunk image"
		if ! $ziptool ${options} "$img"; then
			rc=$?
			error $LINENO "$ziptool failed with rc $rc"
			exit 19
		fi
	fi
	img=$img.${ZIPEXTENSIONS[$ziptool]}
fi

aftersize=$(ls -lh "$img" | cut -d ' ' -f 5)
logVariables $LINENO aftersize

info "Shrunk $img from $beforesize to $aftersize"
