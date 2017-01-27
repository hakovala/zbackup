# zBackup

zBackup is a tool for creating backups to a remote or local ZFS host.

ZFS is only needed at the backup host. Local host needs to have `rsync` for
syncing.

**NOTE**: ZFS has some weird permissions stuff, it requires all the commands to
be run as `root`, at least with version `v6.x.x`.
Because of this restriction **all** ZFS commands are executed using `sudo`.

**NOTE**: For now in all commands the `remote` argument is **NOT** optional.

## Install ZFS on backup host system

### Ubuntu 14.04

```
sudo apt-add-repository ppa:zfs-native/stable
sudo apt-get update
sudo apt-get install ubuntu-zfs
```

### Ubuntu 16.04

```
sudo apt-get update
sudo apt-get install ubuntu-zfs
```

## Usage

```
zbackup create-pool [<remote>:]<pool> <image> <size>
zbackup create [<remote>:]<pool>/<name> <directory>
zbackup sync [<remote>:]<pool>/<name>
zbackup list [<remote>:]all|[<pool>[/<name>]]
zbackup list-snaps [<remote>:]<pool>/<name>
zbackup check [<remote>:]<pool>/<name>
zbackup prune [<remote>:]<pool>/<name> [<count>]
```

### Create backup pool

Create ZFS pool for backups using image file.
This is optional, because _any_ ZFS pool can be used for the backups.

```
zbackup create-pool [<remote>:]<pool> <image> <size>
```

Arguments:
 - `remote`: Remote backup host
 - `pool`: ZFS pool to create
 - `image`: Image filename or device to use for pool
 - `size`: Image size to create

**TODO:**
 - [ ] Add optional mountpoint argument

### Create new backup

Create new backup to existing ZFS pool.
The backup will be linked to specified directory and local hostname.
Hostname check is for preventing backup corruption by syncing backup from
different host.

zBackup stores relevant information to the ZFS filesystem, such as the hostname
of the backup source and the absolute path of the backup. This simplifies the
command line arguments for other commands, and makes the commands more safer.
These properties are stored with `zbackup:` prefix in the ZFS filesystem
properties.

```
zbackup create [<remote>:]<pool>/<name> <directory>
```

Arguments:
 - `remote`: Remote backup host
 - `pool`: ZFS pool name
 - `name`: ZFS filesystem name for the backup
 - `directory`: Local directory to assign for the backup

**TODO:**
 - [ ] Add optional backup description argument

### Sync backup

Synchronize local changes to the backup.
After local changes have been successfully synchronized to the backup filesystem
a snapshot is created.

```
zbackup sync [<remote>:]<pool>/<name>
```

Arguments:
 - `remote`: Remote backup host
 - `pool`: ZFS pool name
 - `name`: ZFS filesystem name for the backup

**TODO:**
 - [ ] Add optional backup snapshot comment message

### List backups

List zBackup backups at remote host or in local host.
If `pool` is specifies lists backups in that pool.
If `pool` and `name` is specifies only lists that backup.
If no `pool` is given lists all backups on that host.

```
zbackup list [<remote>:][<pool>[/<name>]]
```

Arguments:
 - `remote`: Remote backup host
 - `pool`: ZFS pool name
 - `name`: ZFS filesystem name of the backup

### List backup snapshots

List snapshots in backup.

```
zbackup list-snaps [<remote>:]<pool>/<name>
```

Arguments:
 - `remote`: Remote backup host
 - `pool`: ZFS pool name
 - `name`: ZFS filesystem name of the backup

### Check if backup is up-to-date

Checks if there is local changes against the latest backup snapshot.

```
zbackup check [<remote>:]<pool>/<name>
```

Arguments:
 - `remote`: Remote backup host
 - `pool`: ZFS pool name
 - `name`: ZFS filesystem name of the backup

**TODO:**
 - [ ] Decide proper return codes

### Remove old backup snapshots

Remove old backup snapshots.

```
zbackup prune [<remote>:]<pool>/<name> [<count>]
```

Arguments:
 - `remote`: Remote backup host
 - `pool`: ZFS pool name
 - `name`: ZFS filesystem name of the backup
 - `count`: Number of snapshots to keep, defaults to 5

**TODO:**
 - [ ] Add support for removing snapshots by date or time

## Examples

Create new 10 gigabyte ZFS pool to remote host.
```
zbackup create-pool user@domain.com:backups /images/backups.img 10G
```

Create new backup for specified directory.
```
zbackup create user@domain.com:backups/my-home /home/user
```

Sync backup
```
zbackup sync user@domain.com:backups/my-home
```

## TODO

 - [ ] Add usage help print
 - [ ] Add local ZFS support
 - [ ] Add restore feature
 - [ ] Add checkout feature
 - [ ] Use snapshot argument in commands

## Install system wide

```
make install
```
or to a specific prefix
```
make prefix=$HOME install
```
