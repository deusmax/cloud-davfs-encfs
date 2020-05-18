#!/bin/bash
#
# Mount webdav (davfs2) encrypted with encfs
#

# check prerequisites are available
command -v encfs >/dev/null  || (echo "Error: can not find required 'encfs'"  && exit 5)
[ -e /usr/sbin/mount.davfs ] ||
    [ -e /sbin/mount.davfs ] ||
    whereis mount |grep -q davfs ||
    (echo "Error: can not find required 'davfs2'" && exit 5)


# Basic top-level configuration items here.
# These should be set once and not be changed,
# unless of course everything gets re-installed.
#
CLOUD_ROOT=~/cloud
readonly FMT_FSTAB="%s %s davfs user,rw,noauto,_netdev 0 0"
readonly ETCFSTAB=/etc/fstab

readonly WEBDAV_MPOINT_NAME=webdav
readonly CLOUD_ENCFS_NAME=encoded
readonly CLOUD_ENCFS_MP_NAME=cloudfiles
readonly CONF_FILE_NAME=cloud-davfs-encfs.conf

WEBDAV_REMOTE_PATH=""

#
# Script starts here.
# Do no modify, unless you know what you are doing.
#
CLOUD_ROOT=$(realpath $CLOUD_ROOT)
readonly -a CLOUDALL=( $(ls -d $CLOUD_ROOT/*/) )

#
# Note: PID files:
#     /var/run/mount.davfs/mnt-nextcloud-kmu.pid
#

# TODO: make this more elegant.
ACTION="$1"
CLOUDNAME="$2"
shift 2

# Utility functions
function y-or-n () {
    while true
    do
        read -r -p "$1" yn
        case $yn in
            [Yy]* )  return 0 ;;
            [Nn]* )  return 1 ;;
            * ) echo "Please answer yes or no?"
        esac
    done
}

# define directories
function cloud-dirs () {
    readonly DIR_CLOUDNAME=$CLOUD_ROOT/$CLOUDNAME
    readonly WEBDAV_MPOINT=$DIR_CLOUDNAME/$WEBDAV_MPOINT_NAME
    readonly DIR_CLOUD_ENC=$WEBDAV_MPOINT/$CLOUD_ENCFS_NAME
    readonly DIR_CLOUD_ENC_MP=$DIR_CLOUDNAME/$CLOUD_ENCFS_MP_NAME
    readonly DIR_PRIVATE=$DIR_CLOUD_ENC_MP
}

function cloud-definitions () {
    cloud-dirs
    readonly CONF_FILE_PATH="$DIR_CLOUDNAME/$CONF_FILE_NAME"

    # using FMT_FSTAB, but variables not allowed in printf
    printf -v FSTAB_TXT "%s %s davfs user,rw,noauto,_netdev 0 0" \
           "$WEBDAV_REMOTE_PATH" "$WEBDAV_MPOINT"
}

# check cloudname is valid
function check_new_cloudname () {
    local name="$1"
    case "$name" in
        *[[:space:]/]*) printf "Error: invalid CLOUDNAME '%s'\n" "$name"
                        exit 31 ;;
        "") printf "Error: empty CLOUDNAME\n"
            exit 32 ;;
        *)
    esac

    if ! in_cloudall "$name" ; then
        printf "Error: CLOUDNAME '%s' already exists\n" "$name"
        exit 33
    fi
}

function cloud-list () {
    local d
    for d in "${CLOUDALL[@]}"
    do
        echo $(basename "$d")
    done
}

# in_cloudall: check if value exists in array CLOUDALL.
#              returns 0 if value found in CLOUDALL, 1 if not.
#              -v : verbose, display a yes/no message
function in_cloudall () {
    local name="$1"
    local d v=
    if [[ "$name" == "-v" ]] ; then
        v=1
        shift
        name="$1"
    fi

    for d in "${CLOUDALL[@]}"
    do
        if [[ "$name" == $(basename "$d") ]] ; then
            [[ $v ]] && echo "yes"
            return 0
        fi
    done
    [[ $v ]] && echo "no"
    return 1
}

function read-conf-file () {
    local fconf="$1"
    local cloudn

    [ -z "$fconf" ] &&
        fconf="$CLOUD_ROOT/$CLOUDNAME/$CONF_FILE_NAME"  &&
        cloudn="$CLOUDNAME"

    WEBDAV_REMOTE_PATH=
    CLOUDNAME=

    if [ -r "$fconf" ] ; then
        . "$fconf"
    else
        printf "Error: can not read file '%s'\n" "$fconf"
        exit 3
    fi

    #
    # check the configuration is valid
    #
    # identifier mismatch
    if [[ -n "$cloudn" && "$CLOUDNAME" != "$cloudn" ]] ; then
        echo   "Error: identifier mismatch"
        printf "       '%s' given as argument\n"   "$cloudn"
        printf "       '%s' read in config file\n" "$CLOUDNAME"
        exit 20
    fi
    # paths not set
    if [[ -z "$WEBDAV_REMOTE_PATH" || -z "$CLOUDNAME" ]] ; then
        echo "Error: something wrong with definitions"
        printf "    File: %s\n, WEBDAV_REMOTE_PATH: %s\nCLOUDNAME: %s\n" \
               "$fconf" "$WEBDAV_REMOTE_PATH" "$CLOUDNAME"
        exit 21
    fi
    return 0
}

# add line to /etc/fstab
function davfs-fstab-add () {
    if mountpoint -q "$WEBDAV_MPOINT" ; then
        printf "Error: '%s' is already used and mounted\n" "$WEBDAV_MPOINT"
        exit 26
    fi
    if grep -q "$WEBDAV_MPOINT" $ETCFSTAB ; then
        printf "*Warning*: '%s' is already listed in %s.\n" "$WEBDAV_MPOINT" $ETCFSTAB
        echo   "           Check the entry for errors and remove if needed."
        echo   "           If removed, rerun the create action."
    elif echo "$FSTAB_TXT" | sudo tee -a $ETCFSTAB > /dev/null ; then
        echo "Created davfs entry to $ETCFSTAB"
    else
        printf "Error: failed to append davfs entry to %s\n" $ETCFSTAB
        exit 27
    fi
}

# create setup
function cloud-create () {
    local createfile="$1"

    read-conf-file "$createfile"

    # check the name is new
    if in_cloudall "$CLOUDNAME" ; then
        echo "Error: cloud-davfs instance '$CLOUDNAME' already exists."
        exit 22
    fi

    # setup the directory structure
    cloud-definitions

    for i in "$DIR_CLOUDNAME" "$WEBDAV_MPOINT" "$DIR_CLOUD_ENC" "$DIR_CLOUD_ENC_MP"
    do
        test -d "$i" || mkdir -p "$i" ||
            { echo "Error: failed creating directory '$i'" &&
                  exit 23 ; }
    done
    echo "Created directory structure for $CLOUDNAME"

    if [ -f "$CONF_FILE_PATH" ] ; then
        echo "Error: Configuration file $CONF_FILE_PATH aleady exists."
        echo "       Create failed."
        exit 24
    fi
    cp -av "$createfile" "$CONF_FILE_PATH" ||
        printf "WEBDAV_REMOTE_PATH=%s\nCLOUDNAME=%s\n" \
               "$WEBDAV_REMOTE_PATH" "$CLOUDNAME"  > "$CONF_FILE_PATH"  ||
        { echo "Error: could not create config file '$CONF_FILE_PATH'" &&
              exit 25 ; }
    echo "Created configuration file '$CONF_FILE_PATH'"

    davfs-fstab-add
    echo "Created cloud setup for $CLOUDNAME"
}

#
#functions to mount and unmount various mountpoints
#
function cloud-mount-webdav () {
    if [ ! -d "$WEBDAV_MPOINT" ] ; then
        printf "Error: webdav mount point '%s' not found\n" "$WEBDAV_MPOINT"
        exit 9
    fi
    if mountpoint -q "$WEBDAV_MPOINT" ; then
        return 0                # already mounted
    else
        # check fstab entry, add if missing
        grep -q "$WEBDAV_MPOINT" $ETCFSTAB ||
            { echo "$FSTAB_TXT" | sudo tee -a $ETCFSTAB > /dev/null ; } ||
            { echo "Error: failed to append $ETCFSTAB entry" ; exit 27 ; }
        printf "Added '%s' line to %s (%d)\n" $CLOUDNAME  $ETCFSTAB $?
    fi

    # do the mount
    mount "$WEBDAV_MPOINT" ||
        { echo "Error: failed to mount webdav for $CLOUDNAME" ; exit 31 ; }
    printf  "webdav-%s mounted\n" $CLOUDNAME
}

function cloud-umount-webdav () {
    mountpoint -q "$WEBDAV_MPOINT" &&
        umount    "$WEBDAV_MPOINT" &&
        printf "webdav-%s unmounted\n" $CLOUDNAME ||
            { printf "Error: failed to un-mount webdav-%s\n      %s\n" \
                     "$CLOUDNAME" "$WEBDAV_MPOINT"
              exit 35 ; }
}

function cloud-mount-encfs () {
    local d

    # check the directories for encfs exist
    for d in "$DIR_CLOUD_ENC" "$DIR_CLOUD_ENC_MP"
    do
        if [ ! -d "$d" ] ; then
           printf "Error: encfs directory '%s' not found\n" "$d"
           exit 9
        fi
    done

    # is it mounted ?
    if ! mountpoint -q "$DIR_CLOUD_ENC_MP" ; then
        encfs "$DIR_CLOUD_ENC" "$DIR_CLOUD_ENC_MP" ||
            { printf "Error: failed to mount encfs '%s' to:\n    '%s'\n" \
                     "$DIR_CLOUD_ENC" "$DIR_CLOUD_ENC_MP"
              exit 33 ; }
    fi
    printf "encfs-%s mounted\n" $CLOUDNAME
}

function cloud-umount-encfs  () {
    local mp="$DIR_CLOUD_ENC_MP"

    mountpoint -q "$mp"     &&
        fusermount -u "$mp" &&
        echo "encfs-$CLOUDNAME stopped"   ||
            { printf "Error: encfs-%s failed to un-mount\n      %s\n" \
                    "$CLOUDNAME" "$mp"
             exit 34 ; }
}

#
# Actions w/o a cloudname
#
case "$ACTION" in
    create )
        CONF_FILE=$CLOUDNAME
        WEBDAV_REMOTE_PATH=""
        CLOUDNAME=""
        cloud-create "$CONF_FILE"
        exit $?
        ;;
    statusall) cloud-status-all ; exit ;;
    list|ls )  cloud-list       ; exit ;;
    *)                          # continue
esac


#
# check the CLOUDNAME is valid
#
if ! in_cloudall $CLOUDNAME ; then
    echo "Error: cloud instance name '$CLOUDNAME' does not exist"
    exit 10
fi

function cloud-start () {
    # mount the webdav path
    cloud-mount-webdav

    # mount encfs
    cloud-mount-encfs
}

function cloud-stop () {
    # unmount encfs
    cloud-umount-encfs

    # umount nextcloud
    cloud-umount-webdav
}

function cloud-status-webdav () {
    if mountpoint -q "$WEBDAV_MPOINT" ; then
        printf "webdav-%s mounted\n" $CLOUDNAME
    else
        printf "webdav-%s NOT mounted\n" $CLOUDNAME
        return 1
    fi
}

function cloud-status-encfs () {
    if mountpoint -q "$DIR_CLOUD_ENC_MP" ; then
        printf "encfs-%s mounted\n" $CLOUDNAME
    else
        printf "encfs-%s NOT mounted\n" $CLOUDNAME
        return 1
    fi
}

function cloud-status () {
    cloud-status-webdav
    cloud-status-encfs
}

function cloud-sync () {
    if ! cloud-status-encfs ; then
        printf "Error: can not sync %s\n" $CLOUDNAME
        exit 36
    fi

    if [ -z "$SYNC_CMD" ] ; then
        printf "Error: sync command not defined '%s'\n" "$SYNC_CMD"
        exit 41
    fi

    $SYNC_CMD
}

function cloud-config-show () {
    if [ -f "$CONF_FILE_PATH" ] ; then
        cat "$CONF_FILE_PATH"
    else
        printf "Error: missing config file '%s'\n" "$CONF_FILE_PATH"
        exit 38
    fi
}

read-conf-file
cloud-definitions


#
# Actions that need CLOUDNAME defined
#
case "$ACTION" in
    start ) cloud-start  ;;
    stop  ) cloud-stop   ;;
    status) cloud-status ;;
    sync  ) cloud-sync   ;;
    config-show) cloud-config-show ;;
    *) echo "Error: invalid action '$ACTION'"
       exit 2
esac

exit;

#
# Not used functions
#
function read-cloud-path () {
    local rpath=""
    while true
    do
        read -r -p "Give cloud http path for webdav: " rpath
        echo "Cloud Path: $rpath"
        if y-or-n "Is this correct ?(Y/N)" ; then
            WEBDAV_REMOTE_PATH="$rpath"
            return 0
        fi
    done
    return 1
}
