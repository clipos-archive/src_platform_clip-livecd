#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

# Copyright (C) 2008 SGDN/DCSSI
# Copyright (C) 2011-2013 SGDSN/ANSSI
# Authors:
#    Olivier Levillain <clipos@ssi.gouv.fr>
#    Vincent Strubel <clipos@ssi.gouv.fr>
#    Mickaël Salaün <clipos@ssi.gouv.fr>
# All rights reserved

# remember the clip-livecd path and the program name
BIN_PATH=${0%/*}
PERSONNALITY="${0}"

# Default config
TMP_DIR=`mktemp -d /var/tmp/init_parts.XXXX`
RAID_ENABLED=""
OLD_PARTS="${TMP_DIR}/partitions.bak"
OLD_PARTS_1="${TMP_DIR}/partitions1.bak"
OLD_PARTS_2="${TMP_DIR}/partitions2.bak"
NEW_PARTS=""

export LC_ALL=C
source "/opt/clip-installer/clip-disk-common"
source "/usr/share/clip-livecd/lib/keys_common.sh"

if [[ $? -ne 0 ]]; then
    einfo() {
        echo " $*"
    }
    ewarn() {
        echo " $*" >&2
    }
    ebegin() {
        echo " $* ..."
    }
    eend() {
        :
    }
    eindent() {
        :
    }
    eoutdent() {
        :
    }
fi

error() {
    ewarn "init_partitions error: ${1}"
    exit 1
}

usage() {
    echo "Usage: $0 [-R <device1> <device2> | <device>] [-P <pass>] [-E <key>] [<partitions>]"
    echo "   -R <device1> <device2> : create a RAID array and prepare gateway partitions"
    echo "   -P <pass> : encrypt partitions using <pass> as master password"
    echo "   -T <pass> : in case of tpm encryption scheme, for the second"
         "               distribution"
    echo "   -E <file> : escrow key file for encrypted partitions"
    echo "   <device> : use <device> directly to initialise client partitions"
    echo "   <partitions> : indicates which file contain the new partition table"
    echo "         (if RAID is enabled, only the first partition is needed; the second "
    echo "         one is the same; if no file is given, a table will be proposed)"
    echo
    echo "The old partition table(s), and the table proposed (in case no file is given)"
    echo "will be written in a temporary directory /var/tmp/init_parts.XXXX"
}


proposition () {
    NEW_PARTS="${TMP_DIR}/partitions"

    # CLIP_JAILS and CLIP_TYPE should be in the environment
    # if they are not, default values will be used

    local env=""

    if [[ -n ${EFI} ]]; then
    	export UEFI=yes
    fi

    if ! "${BIN_PATH}/generate_parted_script.sh" "$DISK1" "$DISK2" > "${NEW_PARTS}"; then
        error "Impossible to compute a partition table"
    fi

    [[ -n "${QUIET}" ]] && return 0

    if [[ -n "${RAID_ENABLED}" ]]; then
        echo "Here is the computed partition scheme for ${DISK1} and ${DISK2}:"
    else
        echo "Here is the computed partition scheme for ${DISK1}:"
    fi

    echo
    cat "${NEW_PARTS}"
}


prepare () {
    if [[ -z "${QUIET}" ]]; then
        if [[ -n ${RAID_ENABLED} ]]; then
            einfo "Disks ${DISK1} and ${DISK2} are going to be erased"
        else
            einfo "Disk ${DISK1} is going to be erased"
        fi
        einfo "You have 10 seconds to cancel the operation."

        for i in {10..1}; do
            echo -n "$i... "
            sleep 1
        done
        echo 0
    fi

    cleanup_disks "${INSTALL_DISK}"
}


load_new_partitions () {
    ebegin "Writing new partition table for ${DISK1}"
    bash -x ${NEW_PARTS} || error "Writing table failed"
    eend 0

    if [[ -n ${RAID_ENABLED} ]]; then

        ebegin "Writing partition table for ${DISK2}"
        sed "s+${DISK1}+${DISK2}+g" "${NEW_PARTS}" | bash -x &> /dev/null \
            || error "Writing second table failed"
        eend 0
    fi
}

wait_device() {
    local disk="$1"
    while ! blockdev --getsz "${disk}" &>/dev/null; do
        ewarn "Waiting for ${disk}"
        sleep 1
    done
}

make_raid () {
    local parts="1 2 3 5 6 7 8 9 10 11"
    local disk
    if [[ -n ${RAID_ENABLED} ]]; then
        for i in ${parts}; do
            wait_device "${DISK1}$i"
            wait_device "${DISK2}$i"
        done
        einfo "Creating RAID arrays"
        eindent
        for i in ${parts}; do
            disk="${INSTALL_DISK}$i"
            ebegin "${disk}"
            mdadm --zero-superblock "${DISK1}$i" 2>/dev/null
            mdadm --zero-superblock "${DISK2}$i" 2>/dev/null
            mdadm --create --force -R "${disk}" --level 1 \
                --raid-devices=2 "--auto=${disk#/dev/}" \
		"${DISK1}$i" "${DISK2}$i" &>/dev/null \
                || error "mdadm failed for ${disk}"
            eend 0
        done
        eoutdent
   fi
}

map_partition() {
        local num="${1}"
        local ret=0

        [[ -n "${num}" ]] || error "Missing device number"

        local name="${INSTALL_DISK#/dev/}${num}"

        wait_device "/dev/${name}"
        ebegin "Creating encrypted partition : ${name}"
        local key=""
        key="$(derive_key "${CRYPT_PW}" "${num}")"

        if [[ -z "${key}" ]]; then
                eend 1 "Failed to derive key for ${INSTALL_DISK} - ${num}"
                return 1
        fi

        echo -n "${key}" | \
                cryptsetup luksFormat -c "aes-xts-plain" -s 512 -h sha512 -d -\
                        "${INSTALL_DISK}${num}"  || ret=1

	      if [[ ! -z "${ESCROW_FILE}" ]]; then
	            local escrow=""
              escrow="$(derive_key "$(cat "${ESCROW_FILE}")" "${num}")"

                      if [[ -z "${escrow}" ]]; then
                              eend 1 "Failed to derive escrow key for ${INSTALL_DISK} - ${num}"
                              return 1
                      fi
	      	    (echo "${key}"; echo -n "${escrow}") | \
	      	            cryptsetup luksAddKey "${INSTALL_DISK}${num}" -S 2 || ret=2
	      fi

	      if [[ ! -z "${SND_PW}" ]]; then
	            local snd=""
              snd="$(derive_key "${SND_PW}" "${num}")"

                      if [[ -z "${snd}" ]]; then
                              eend 1 "Failed to derive a second key for ${INSTALL_DISK} - ${num}"
                              return 1
                      fi
	      	    (echo "${key}"; echo -n "${snd}") | \
	      	            cryptsetup luksAddKey "${INSTALL_DISK}${num}" -S 1 || ret=2
	      fi

        echo -n "${key}" | cryptsetup luksOpen "${INSTALL_DISK}${num}" "${name}"  || ret=1
        eend $ret "Failed to create encrypted mapping"
}

create_mappings() {
        [[ -n "${CRYPT_PW}" ]] || return 0
        einfo "Initializing encrypted partitions"
        eindent
        for i in 3 5 6 7 8 10 11; do
            map_partition "${i}" || error "Failed to initialize encrypted partitions"
        done
        eoutdent
}

format_partitions () {
    local first_is_ext3=@DO_EXT3_SDA1@
    local first=true
    local -i ret
    einfo "Creating filesystems (init)"
    eindent
    for i in ${PARTS_TO_MAKE}; do
	      local fstype="ext4"
	      if ${first}; then
	          first=false
            if [[ -n "${EFI}" ]]; then
	              fstype="vfat"
            elif ${first_is_ext3}; then
	              fstype="ext3"
            fi
	      fi
        wait_device "${i}"
        ebegin "${i}"
        /sbin/mkfs.${fstype} "${i}" &> /dev/null
	      ret=$?
	      eend ${ret}
        [[ ${ret} -eq 0 ]] || error "mkfs failed for ${i}"
    done
    eoutdent
}

check_disk() {
        local disk="${1}"
        local root="$(awk '$2 == "/mnt/cdrom" {print $1}' /proc/mounts)"
        [[ -n "${root}" ]] || error "Could not find livecd root disk"
        root="${root%?}"

        if [[ "${disk}" == "${root}" ]]; then
            error "${disk} is the livecd root disk, cannot install on it"
        fi
}

################## MAIN ####################

CRYPT_PW=""
SND_PW=""
QUIET=""
export KEEP_DATA=""
NEW_PARTS=""
EFI=""
ESCROW_FILE=""
# Collect parameters and test if the options are coherent
while getopts c:RUE:P:T:qk arg ; do
    case $arg in
        c)
            NEW_PARTS="${OPTARG}"
            ;;
        R)
            RAID_ENABLED="yes"
            ;;
        P)
            CRYPT_PW="${OPTARG}"
            ;;
        T)
            SND_PW="${OPTARG}"
            ;;
        E)
            ESCROW_FILE="${OPTARG}"
            ;;
        q)
            QUIET="yes"
            ;;
        k)
            export KEEP_DATA="yes"
            ;;
        U)
            EFI="yes"
            ;;
        *)
            ewarn "Unsupported option: ${arg}"
            usage
            exit 1
            ;;
    esac
done
shift `expr $OPTIND - 1`


DISK1=$1
[[ -b "${DISK1}" ]] || error "Disk1 (${DISK1}) is not a valid block device."

check_disk "${DISK1}"

if [[ -n "${RAID_ENABLED}" ]]; then
    DISK2=$2
    check_disk "${DISK2}"
    [[ -b "${DISK2}" ]] || error "Disk2 (${DISK2}) is not a valid block device."
    INSTALL_DISK="/dev/md"
    shift 2
else
    INSTALL_DISK=$DISK1
    shift 1
fi

PARTS_TO_MAKE="${INSTALL_DISK}1"
[[ -z "${KEEP_DATA}" ]] && PARTS_TO_MAKE="${PARTS_TO_MAKE} ${INSTALL_DISK}2"
if [[ -n "${CRYPT_PW}" ]]; then
    PARTS_TO_MAKE="${PARTS_TO_MAKE} /dev/mapper${INSTALL_DISK#/dev}3"
else
    PARTS_TO_MAKE="${PARTS_TO_MAKE} ${INSTALL_DISK}3"
fi

if [[ -n "${NEW_PARTS}" ]]; then
    [[ -f "${NEW_PARTS}" ]] || error "${NEW_PARTS} is not a regular file"
else
    proposition
fi

prepare
load_new_partitions
make_raid
create_mappings
format_partitions
