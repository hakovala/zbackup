#!/bin/bash

APP_NAME="$(basename $0)"

#DEBUG=1 # print debug messages

##
## Constants
##

ZBACKUP_BACKUP_TYPE="backup"
CMD_REMOTE_USER='$(id -un)'
CMD_REMOTE_GROUP='$(id -gn)'
CMD_CREATE_TAG='date +%Y%d%m-%H%M%S'

OPT_FS_TYPE="zbackup:type"
OPT_FS_NAME="zbackup:name"
OPT_FS_HOST="zbackup:host"
OPT_FS_SOURCE="zbackup:source"

PRUNE_LEAVE_COUNT=5

##
## Printing/debug utility functions
##

# Helper function for printing to stderr
stderr() {
	echo $@ >&2
}

# Debug print, if `DEBUG` variable is set
debug() {
	[[ -n "$DEBUG" ]] && {
		stderr "DEBUG: $*"
	}
	return 0
}

# Error print
error() {
	stderr "ERROR: $*"
}

# Error print and exit
error_exit() {
	error ${@:2}
	exit $1
}

##
## Script exit traps
##

# List of commands to run before exit
_atexit_cmds=( )
_atexit_trap_handler() {
	for cmd in "${_atexit_cmds[@]}"; do
		eval "$cmd" || true
	done
}

# Add command to be run on script exit
atexit() {
	_atexit_cmds[${#_atexit_cmds[@]}]="$1"
}

# Setup script exit trap handler
trap _atexit_trap_handler EXIT

##
## SSH control channel
##
## Persistent SSH connection that can be used through the life of the
## script.
##
## Usage:
##   `ssh_setup_control_socket`: Create persistent SSH control channel connection using
##   `ssh_target`: Run command through SSH control channel
##
## SSH control channel must be created before using `ssh_target` to run remote
## command, if not then commands are run without control channel which
## includes the normal SSH connect overhead.
##

# Run command at remote host through control socket
# Input variables:
#  - `SSH_CONTROL_SOCKET`: SSH control socket
#  - `TARGET_HOST`: Remote host
ssh_target() {
	debug "SSH: '$@'"

	if [ -z "$SSH_CONTROL_SOCKET" ]; then
		# no SSH control channel set, using slow SSH
		stderr "Warning: no SSH control channel created"
		ssh "$TARGET_HOST" "$@"
	else
		ssh -S "$SSH_CONTROL_SOCKET" "$TARGET_HOST" "$@"
	fi
	return $?
}

# Setup SSH control socket to remote host
# Input variables:
#  - `TARGET_HOST`: Remote host to create control channel to
# Output variables:
#  - `SSH_CONTROL_SOCKET`: SSH control socket
#  - `SSH_CONTROL_PID`: SSH control socket process PID
ssh_setup_control_socket() {
	SSH_CONTROL_SOCKET="/tmp/ssh-control-$TARGET_HOST-$$"
	local ssh_fifo="$SSH_CONTROL_SOCKET-fifo"
	mkfifo "$ssh_fifo"
	atexit "rm '$ssh_fifo'"

	local ssh_cmd="echo ready; while :; do sleep 100; done"
	ssh -nM -o ControlPath="$SSH_CONTROL_SOCKET" "$TARGET_HOST" "$ssh_cmd" > "$ssh_fifo" &
	SSH_CONTROL_PID="$!"
	atexit "kill $SSH_CONTROL_PID 2> /dev/null" EXIT
	debug "ssh control started with PID $SSH_CONTROL_PID"

	debug "waiting for ssh connection..."
	local ssh_line
	read -t10 ssh_line < "$ssh_fifo" || {
		error "ssh connect timeout"
		return 1
	}

	[[ "$ssh_line" != "ready" ]] && {
		error "invalid line from SSH: $ssh_line"
		return 1
	}

	# check that the SSH control channel process is running
	ps -o pid= -p "$SSH_CONTROL_PID" > /dev/null || {
		error "could not establish SSH control channel"
		return 1
	}
	debug "SSH control channel to $TARGET_HOST started at $SSH_CONTROL_SOCKET with PID $SSH_CONTROL_PID"
}

##
## CLI argument parsing
##

# Parse host, pool, backup, snapshot command line argument
# pattern: [<remote>:]<pool>[/<name>[@<snapshot>]]
#
# output variables:
#  `TARGET_HOST`
#  `BACKUP_POOL`
#  `BACKUP_NAME`
#  `BACKUP_SNAPSHOT`
parse_remote_arg() {
	local pattern='^(([^:]+):)?([^/]+)(/([^@]*)(@(.*))?)?'
	[[ $1 =~ $pattern ]]
	# skip match 1, domain with colon
	TARGET_HOST="${BASH_REMATCH[2]}"
	BACKUP_POOL="${BASH_REMATCH[3]}"
	# skip match 4, name with slash
	BACKUP_NAME="${BASH_REMATCH[5]}"
	# skip match 6, snapshot with at-sign
	BACKUP_SNAPSHOT="${BASH_REMATCH[7]}"

	debug "REMOTE ARGUMENT: '$1'"
	debug "  matches: '${BASH_REMATCH[@]}'"
	debug "  host:    '$TARGET_HOST'"
	debug "  pool:    '$BACKUP_POOL'"
	debug "  name:    '$BACKUP_NAME'"
	debug "  snap:    '$BACKUP_SNAPSHOT'"
	debug
}

##
## ZFS utility functions
##

# Get ZFS pool property value
pool_get() {
	# get raw property value, also replace '-' empty indicator with empty string
	ssh_target sudo zpool get -H "$@" | cut -f3 | sed 's/^-$//g'
}

# Set ZFS pool property value
pool_set() {
	ssh_target sudo zpool set "$@"
}

# Get ZFS filesystem property value
fs_get() {
	# get raw property value, also replace '-' empty indicator with empty string
	ssh_target sudo zfs get -H -p -o value "$@" | sed 's/^-$//g'
}

# Set ZFS filesystem property value
fs_set() {
	ssh_target sudo zfs set "$@"
}

fs_snapshot_list() {
	local name="$1"
	ssh_target sudo zfs list -H -o name -S creation -r -t snapshot "${name}"
}

fs_list() {
	local name="$1"
	ssh_target sudo zfs list -H -o name -r "${name}"
}

fs_list_backups() {
	for fs in $(fs_list "$1"); do
		if [[ "$(fs_get ${OPT_FS_TYPE} ${fs})" == "${ZBACKUP_BACKUP_TYPE}" ]]; then
			echo "$fs"
		fi
	done
}

##
## Command functions
##

# Create ZFS pool
#
# fn usage: 'zbackup_create_pool [<remote>:]<pool> <image> <size>'
# cli usage: `zbackup create-pool [<remote>:]<pool> <image> <size>`
zbackup_create_pool() {
	parse_remote_arg "$1"

	local pool_name="$BACKUP_POOL"
	local image_filepath="$2"
	local image_path="$(dirname "${image_filepath}")"
	local image_size="$3"

	# validate arguments
	[[ -z "$pool_name" ]] && { error_exit 1 "Missing pool name"; }
	[[ -z "$image_path" ]] && { error_exit 1 "Missing pool image filepath"; }
	[[ -z "$image_size" ]] && { error_exit 1 "Missing pool image size"; }

	if [[ -n "$TARGET_HOST" ]]; then
		# setup SSH control channel if target host is specified
		ssh_setup_control_socket
	fi

	# check if the pool image already exists
	ssh_target [[ -f ${image_filepath} ]] && {
		error_exit 1 "Image '${image_filepath}' file already exists"
	}

	stderr "Creating new pool ${pool_name} using image $TARGET_HOST:${image_filepath} with size ${image_size}"

	# create directory for pool image
	ssh_target "sudo mkdir -p ${image_path}" || {
		error_exit 1 "Failed to create directory '${image_path}' for pool image"
	}

	# create pool image file with given size
	ssh_target "sudo fallocate -l ${image_size} ${image_filepath}" || {
		error_exit 1 "Failed to create image file '${image_filepath}' with size ${image_size}"
	}

	# create ZFS pool using given image file
	ssh_target "sudo zpool create ${pool_name} ${image_filepath}" || {
		error_exit 1 "Failed to create ZFS pool '${pool_name}' using image file '${image_filepath}'"
	}

	stderr "ZFS pool create $1"
}

# Create ZFS backup filesystem
#
# fn usage: `zbackup_create [<remote>:]<pool>/<name> <directory>`
# cli usage: `zbackup create [<remote>:]<pool>/<name> <directory>`
zbackup_create() {
	parse_remote_arg "$1"

	local pool_name="$BACKUP_POOL"
	local backup_name="$BACKUP_NAME"
	local source_dir="$(readlink -f "$2")"
	local name="${pool_name}/${backup_name}"
	local host="$(hostname)"

	# validate arguments
	[[ -z "$pool_name" ]] && { error_exit 1 "Missing pool name"; }
	[[ -z "$backup_name" ]] && { error_exit 1 "Missing backup name"; }
	[[ -z "$source_dir" ]] && { error_exit 1 "Missing backup source directory"; }
	[[ ! -d "$source_dir" ]] && { error_exit 1 "Backup source path is not a directory '${source_dir}'"; }

	if [[ -n "$TARGET_HOST" ]]; then
		# setup SSH control channel if target host is specified
		ssh_setup_control_socket
	fi

	stderr "Creating new backup for ${host}:${source_dir} to $1"

	# create ZFS filesystem for the backup
	ssh_target "sudo zfs create '${name}'" || { error_exit 1 "Failed to create backup filesystem"; }
	# set zBackup backup properties
	fs_set "${OPT_FS_TYPE}='${ZBACKUP_BACKUP_TYPE}'" "${name}" &&
	fs_set "${OPT_FS_NAME}='${backup_name}'" "${name}" &&
	fs_set "${OPT_FS_HOST}='${host}'" "${name}" &&
	fs_set "${OPT_FS_SOURCE}='${source_dir}'" "${name}" || {
		error "Failed to set backup ZFS filesystem properties"
		stderr "Destroying newly created backup ZFS filesystem ${name}"
		ssh_target "sudo zfs destroy '${name}'"
		return 1
	}

	local backup_mount="$(fs_get mountpoint "${name}")"
	[[ -z "$backup_mount" ]] && {
		error_exit 1 "No mount point found for backup. Unable to set backup filesystem permissions."
	}
	ssh_target "sudo chown -R "${CMD_REMOTE_USER}:${CMD_REMOTE_GROUP}" ${backup_mount}" || {
		error_exit 1 "Failed to set permissions for backup mount point '${backup_mount}'"
	}

	stderr "New backup created ${source_dir} -> $TARGET_HOST:$name"
	stderr "Sync with '${APP_NAME} sync $TARGET_HOST:$name'"
}

# Sync backup
#
# fn usage: `zbackup_sync [<remote>:]<pool>/<name>`
# cli usage: `zbackup sync`[<remote>:]<pool>/<name>`
zbackup_sync() {
	parse_remote_arg "$1"

	local pool_name="$BACKUP_POOL"
	local backup_name="$BACKUP_NAME"
	local name="${pool_name}/${backup_name}"

	# validate arguments
	[[ -z "$pool_name" ]] && { error_exit 1 "Missing pool name"; }
	[[ -z "$backup_name" ]] && { error_exit 1 "Missing backup name"; }

	if [[ -n "$TARGET_HOST" ]]; then
		# setup SSH control channel if target host is specified
		ssh_setup_control_socket
	fi

	# validate ZFS backup type
	[[ "$(fs_get ${OPT_FS_TYPE} "${name}")" != "${ZBACKUP_BACKUP_TYPE}" ]] && {
		error_exit 1 "'${name}' is not a zBackup backup"
	}

	# get and validate hostname
	# hostname in backup and local hostname MUST match
	# this is to prevent syncing same backup from multiple host systems
	local host="$(fs_get ${OPT_FS_HOST} "${name}")"
	[[ -z "${host}" ]] && { error_exit 1 "Failed to get backup host property"; }
	[[ "${host}" != "$(hostname)" ]] && { error_exit 1 "Hostname in backup '${host}' doesn't match this systems hostname '$(hostname)'"; }

	# get and validate backup source directory
	local source_dir="$(fs_get ${OPT_FS_SOURCE} "${name}")"
	[[ -z "${source_dir}" ]] && { error_exit 1 "Failed to get backup source directory"; }
	[[ ! -d "${source_dir}" ]] && { error_exit 1 "Backup source directory '${source_dir}' doesn't exist"; }

	# get backup filesystem mount point, aka. where to sync files
	local dest_dir="$(fs_get mountpoint "${name}")"
	[[ -z "$dest_dir" ]] && { error_exit 1 "Failed to get backup filesystem mount point"; }
	ssh_target [[ ! -d "$dest_dir" ]] && { error_exit 1 "Backup mount point is not a directory"; }

	debug "Backup info:"
	debug "  name:   ${name}"
	debug "  type:   ${type}"
	debug "  host:   ${host}"
	debug "  source: ${source_dir}"
	debug "  mount:  ${dest_dir}"

	stderr "Syncing ${host}:${source_dir} -> $TARGET_HOST:${name}"

	# start syncing using rsync
	rsync -avz --progress --delete "${source_dir}/" "$TARGET_HOST:${dest_dir}/" || {
		error_exit 1 "Failed to sync ${host}:${source_dir} -> $TARGET_HOST:${name} using rsync"
	}

	# create snapshot of the current backup state
	local prev_snap="$(fs_snapshot_list "${name}" | head -n 1)"
	local changes
	if [[ -n "${prev_snap}" ]]; then
		# check if something changed after rsync
		changes="$(ssh_target sudo zfs diff "${prev_snap}")"
	else
		# no previous snapshot where found, this is the first sync of this backup
		changes="- First time synchronization"
	fi

	if [[ -z "${changes}" ]]; then
		stderr "Backup is up-to-date"
	else
		local tag="$($CMD_CREATE_TAG)"
		stderr "Backup has changed"
		# TODO: Print backup changes?
		stderr "Creating new snapshot '$tag'"
		ssh_target sudo zfs snapshot "${name}@${tag}"
	fi

	stderr "Sync finished successfully"
}

# List backups
#
# Use pool name `all` to print all backups
#
# fn usage: `zbackup_list [<remote>:]all|<pool>[/<name>]`
# cli usage: `zbackup list [<remote>:]all|<pool>[/<name>]`
zbackup_list() {
	parse_remote_arg "$1"

	local pool_name="${BACKUP_POOL}"
	local backup_name="${BACKUP_NAME}"
	local name="${pool_name}"
	# add optional backup name to `name` if given
	if [[ -n "$backup_name" ]]; then
		name="${name}/${backup_name}"
	fi

	# use pool name `all` to list all all
	if [[ "$pool_name" == "all" ]]; then
		name=""
	fi

	# validate arguments
	[[ -z "$pool_name" ]] && { error_exit 1 "Missing pool name"; }

	if [[ -n "$TARGET_HOST" ]]; then
		# setup SSH control channel if target host is specified
		ssh_setup_control_socket
	fi

	local fs_list="$(fs_list_backups "${name}")"
	if [[ -n "$fs_list" ]]; then
		ssh_target sudo zfs list -r "'${fs_list}'"
	fi
}

# List backup snapshots
#
# fn usage: `zbackup_list_snaps [<remote>:]<pool>/<name>`
# cli usage: `zbackup list-snaps [<remote>:]<pool>/<name>`
zbackup_list_snaps() {
	parse_remote_arg "$1"

	local pool_name="${BACKUP_POOL}"
	local backup_name="${BACKUP_NAME}"
	local name="${pool_name}/${backup_name}"

	[[ -z "$pool_name" ]] && { error_exit 1 "Missing pool name"; }
	[[ -z "$backup_name" ]] && { error_exit 1 "Missing backup name"; }

	if [[ -n "$TARGET_HOST" ]]; then
		# setup SSH control channel if target host is specified
		ssh_setup_control_socket
	fi

	fs_snapshot_list "${name}"
}

# Prune backup snapshots
#
# fn usage: `zbackup_prune [<remote>:]<pool>/<name> <count>`
# cli usage: `zbackup prune [<remote>:]<pool>/<name> <count>`
zbackup_prune() {
	parse_remote_arg "$1"

	local pool_name="${BACKUP_POOL}"
	local backup_name="${BACKUP_NAME}"
	local name="${pool_name}/${backup_name}"
	local count="$2"

	[[ -z "$pool_name" ]] && { error_exit 1 "Missing pool name"; }
	[[ -z "$backup_name" ]] && { error_exit 1 "Missing backup name"; }
	[[ -z "$count" ]] && { count=$PRUNE_LEAVE_COUNT; } # use default if empty
	[[ $count =~ ^[0-9]+$ ]] || { error_exit 1 "Count must be a number"; }

	# count needs to be one bigger for the `tail`
	let "count += 1"

	if [[ -n "$TARGET_HOST" ]]; then
		# setup SSH control channel if target host is specified
		ssh_setup_control_socket
	fi

	local snapshots="$(fs_snapshot_list "${name}" | tail -n +${count})"
	local n=0
	for snapshot in ${snapshots}; do
		if ssh_target sudo zfs destroy "${snapshot}"; then
			stderr "Destroyed snapshot: ${snapshot}"
			let "n++"
		else
			error "Failed to destroy snapshot: ${snapshot}"
		fi
	done

	stderr "$n snapshots destroyed"
}

##
## Command handling
##

error_not_implemented() {
	error "'$1' not yet implemented!"
	return 1
}

zbackup() {
	local op="$1"; shift

	case $op in
		create-pool)
			zbackup_create_pool $@
			;;
		create)
			zbackup_create $@
			;;
		sync)
			zbackup_sync $@
			;;
		list)
			zbackup_list $@
			;;
		list-snaps)
			zbackup_list_snaps $@
			;;
		prune)
			zbackup_prune $@
			;;
		check)
			error_not_implemented $op
			;;
		-h|--help)
			error_not_implemented "Help"
			error_not_implemented "Usage"
			;;
		'')
			error "Missing command"
			error_not_implemented "Usage"
			;;
		*)
			error "Invalid command '$op'"
			return 1
			;;
	esac
}

zbackup $@
