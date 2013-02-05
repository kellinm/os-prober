newns () {
  [ "$OS_PROBER_NEWNS" ] || exec /usr/lib/newns "$0" "$@"
}

cleanup_tmpdir=false
cleanup_ro_partitions=
cleanup () {
  local partition
  for partition in $cleanup_ro_partitions; do
    blockdev --setrw "$partition"
  done
  if $cleanup_tmpdir; then
    rm -rf "$OS_PROBER_TMP"
  fi
}

require_tmpdir() {
  if [ -z "$OS_PROBER_TMP" ]; then
    if type mktemp >/dev/null 2>&1; then
      export OS_PROBER_TMP="$(mktemp -d /tmp/os-prober.XXXXXX)"
      cleanup_tmpdir=:
      trap cleanup EXIT HUP INT QUIT TERM
    else
      export OS_PROBER_TMP=/tmp
    fi
  fi
}

count_for() {
  _labelprefix="$1"
  _result=$(grep "^${_labelprefix} " /var/lib/os-prober/labels 2>/dev/null || true)

  if [ -z "$_result" ]; then
    return
  else
    echo "$_result" | cut -d' ' -f2
  fi
}

count_next_label() {
  require_tmpdir

  _labelprefix="$1"
  _cfor="$(count_for "${_labelprefix}")"

  if [ -z "$_cfor" ]; then
    echo "${_labelprefix} 1" >> /var/lib/os-prober/labels
  else
    sed "s/^${_labelprefix} ${_cfor}/${_labelprefix} $(($_cfor + 1))/" /var/lib/os-prober/labels > "$OS_PROBER_TMP/os-prober.tmp"
    mv "$OS_PROBER_TMP/os-prober.tmp" /var/lib/os-prober/labels
  fi
  
  echo "${_labelprefix}${_cfor}"
}

progname=
cache_progname() {
  case $progname in
    '')
      progname="${0##*/}"
      ;;
  esac
}

# fd_logger: bind value now, possibly after assigning default. 
eval '
  log() {
    cache_progname
    echo "$progname: $@"  1>&'${fd_logger:=9}'
  }
'
export fd_logger  # so subshells inherit current value by default

error() {
  log "error: $@"
}

warn() {
  log "warning: $@"
}

debug() {
  if [ -z "$OS_PROBER_DISABLE_DEBUG" ]; then
    log "debug: $@" 
  fi
}

# fd_result: bind value now, possibly after assigning default.
eval '
  result() {
    log "result:" "$@"
    echo "$@"  1>&'${fd_result:=1}'
  }
'
export fd_result  # so subshells inherit current value by default

# shim to make it easier to use os-prober outside d-i
if ! type mapdevfs >/dev/null 2>&1; then
  mapdevfs () {
    readlink -f "$1"
  }
fi

item_in_dir () {
	if [ "$1" = "-q" ]; then
		q="-q"
		shift 1
	else
		q=""
	fi
	[ -d "$2" ] || return 1
	# find files with any case
	ls -1 "$2" | grep $q -i "^$1$"
}

# We can't always tell the filesystem type up front, but if we have the
# information then we should use it. Note that we can't use block-attr here
# as it's only available in udebs.
fs_type () {
	if (export PATH="/lib/udev:$PATH"; type vol_id) >/dev/null 2>&1; then
		PATH="/lib/udev:$PATH" vol_id --type "$1" 2>/dev/null
	elif type blkid >/dev/null 2>&1; then
		blkid -o value -s TYPE "$1" 2>/dev/null
	else
		return 0
	fi
}

is_dos_extended_partition() {
	if type blkid >/dev/null 2>&1; then
		local output

		output="$(blkid -o export $1)"

		# old blkid (util-linux << 2.24) errors out on extended p.
		if [ "$?" = "2" ]; then
			return 0
		fi

		# dos partition type and no filesystem type?...
		if echo $output | grep -q ' PTTYPE=dos ' &&
				! echo $output | grep -q ' TYPE='; then
			return 0
		else
			return 1
		fi
	fi

	return 1
}

parse_proc_mounts () {
	while read -r line; do
		set -f
		set -- $line
		set +f
		printf '%s %s %s %s\n' "$(mapdevfs "$1")" "$2" "$3" "$1"
	done
}

# add forth parameter to pickup btrfs subvol info
parsefstab () {
	while read -r line; do
		case "$line" in
			"#"*)
				:	
			;;
			*)
				set -f
				set -- $line
				set +f
				printf '%s %s %s %s\n' "$1" "$2" "$3" "$4"
			;;
		esac
	done
}

#check_btrfs_mounted $bootsv $bootuuid)
check_btrfs_mounted () {
	bootsv="$1"
	bootuuid="$2"
	bootdev=$(blkid | grep "$bootuuid" | cut -d ':' -f  1)
	bindfrom=$(grep " btrfs " /proc/self/mountinfo | 
		   grep " $bootdev " | grep " /$bootsv " | cut -d ' ' -f 5)
	printf "%s" "$bindfrom"
}

unescape_mount () {
	printf %s "$1" | \
		sed 's/\\011/	/g; s/\\012/\n/g; s/\\040/ /g; s/\\134/\\/g'
}

ro_partition () {
	if type blockdev >/dev/null 2>&1 && \
	   [ "$(blockdev --getro "$1")" = 0 ] && \
	   blockdev --setro "$1"; then
		cleanup_ro_partitions="${cleanup_ro_partitions:+$cleanup_ro_partitions }$1"
		trap cleanup EXIT HUP INT QUIT TERM
	fi
}

find_label () {
	local output
	if type blkid >/dev/null 2>&1; then
		# Hopefully everyone has blkid by now
		output="$(blkid -o device -t LABEL="$1")" || return 1
		echo "$output" | head -n1
	elif [ -h "/dev/disk/by-label/$1" ]; then
		# Last-ditch fallback
		readlink -f "/dev/disk/by-label/$1"
	else
		return 1
	fi
}

find_uuid () {
	local output
	if type blkid >/dev/null 2>&1; then
		# Hopefully everyone has blkid by now
		output="$(blkid -o device -t UUID="$1")" || return 1
		echo "$output" | head -n1
	elif [ -h "/dev/disk/by-uuid/$1" ]; then
		# Last-ditch fallback
		readlink -f "/dev/disk/by-uuid/$1"
	else
		return 1
	fi
}

# Sets $mountboot as output variable.  (We do this rather than requiring a
# subshell so that we can run ro_partition without the cleanup trap firing
# when the subshell exits.)
linux_mount_boot () {
	partition="$1"
	tmpmnt="$2"

	bootpart=""
	mounted=""
	if [ -e "$tmpmnt/etc/fstab" ]; then
		# Try to mount any /boot partition.
		bootmnt=$(parsefstab < "$tmpmnt/etc/fstab" | grep " /boot ") || true
		if [ -n "$bootmnt" ]; then
			set -f
			set -- $bootmnt
			set +f
			boottomnt=""

			# Try to map labels and UUIDs ourselves if possible,
			# so that we can check whether they're already
			# mounted somewhere else.
			tmppart="$1"
			if echo "$1" | grep -q "LABEL="; then
				label="$(echo "$1" | cut -d = -f 2)"
				if tmppart="$(find_label "$label")"; then
					debug "mapped LABEL=$label to $tmppart"
				else
					debug "found boot partition LABEL=$label for Linux system on $partition, but cannot map to existing device"
					mountboot="$partition 0"
					return
				fi
			elif echo "$1" | grep -q "UUID="; then
				uuid="$(echo "$1" | cut -d = -f 2)"
				if tmppart="$(find_uuid "$uuid")"; then
					debug "mapped UUID=$uuid to $tmppart"
				else
					debug "found boot partition UUID=$uuid for Linux system on $partition, but cannot map to existing device"
					mountboot="$partition 0"
					return
				fi
			fi
			shift
			set -- "$(mapdevfs "$tmppart")" "$@"

			if grep -q "^$1 " "$OS_PROBER_TMP/mounted-map"; then
				bindfrom="$(grep "^$1 " "$OS_PROBER_TMP/mounted-map" | head -n1 | cut -d " " -f 2)"
				bindfrom="$(unescape_mount "$bindfrom")"
				if [ "$bindfrom" != "$tmpmnt/boot" ]; then
					if mount --bind "$bindfrom" "$tmpmnt/boot"; then
						mounted=1
						bootpart="$tmppart"
					else
						debug "failed to bind-mount $bindfrom onto $tmpmnt/boot"
					fi
				fi
			fi
			if [ "$mounted" ]; then
				:
			elif [ -e "$tmppart" ]; then
				bootpart="$tmppart"
				boottomnt="$tmppart"
			elif [ -e "$tmpmnt/$tmppart" ]; then
				bootpart="$tmppart"
				boottomnt="$tmpmnt/$tmppart"
			elif [ -e "/target/$tmppart" ]; then
				bootpart="$tmppart"
				boottomnt="/target/$tmppart"
			elif [ -e "$1" ]; then
				bootpart="$1"
				boottomnt="$1"
			elif [ -e "$tmpmnt/$1" ]; then
				bootpart="$1"
				boottomnt="$tmpmnt/$1"
			elif [ -e "/target/$1" ]; then
				bootpart="$1"
				boottomnt="/target/$1"
			else
				bootpart=""
			fi

			if [ ! "$mounted" ]; then
				if [ -z "$bootpart" ]; then
					debug "found boot partition $1 for linux system on $partition, but cannot map to existing device"
				else
					debug "found boot partition $bootpart for linux system on $partition"
					if type grub-mount >/dev/null 2>&1 && \
					   grub-mount "$boottomnt" "$tmpmnt/boot" 2>/dev/null; then
						mounted=1
					else
						ro_partition "$boottomnt"
						if mount -o ro "$boottomnt" "$tmpmnt/boot" -t "$3"; then
							mounted=1
						else
							error "failed to mount $boottomnt on $tmpmnt/boot"
						fi
					fi
				fi
			fi
		fi
	fi
	if [ -z "$bootpart" ]; then
		bootpart="$partition"
	fi
	if [ -z "$mounted" ]; then
		mounted=0
	fi

	mountboot="$bootpart $mounted"
}
