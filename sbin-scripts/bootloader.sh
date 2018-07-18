#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

# Copyright (C) 2008 SGDN/DCSSI
# Author: Olivier Levillain <clipos@ssi.gouv.fr>
# All rights reserved

export LC_ALL=C


PERSONNALITY="${0}"

# Default config
[[ -z "${MBR_DEVICE}" ]] && MBR_DEVICE=""
[[ -z "${MBR_DEVICE_ALT}" ]] && MBR_DEVICE_ALT=""
[[ -z "${FW}" ]] && FW=""
[[ -z "${EXTLINUX_DEVICE}" ]] && EXTLINUX_DEVICE=""
MASTERBOOTRECORD=/usr/share/syslinux/mbr.bin
TMP_CLIP_BOOT=/tmp/clip-boot

if [[ -e "/lib/rc/sh/functions.sh" ]]; then
	source "/lib/rc/sh/functions.sh" # openRC
else
	source "/sbin/functions.sh" 
fi
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


cleanup() {
	trap - EXIT

	local -i ret=0
	ebegin "Cleaning up"

	if [ -n "${BOOT_MOUNTED}" ]; then
	    umount /dev/md1 2> /dev/null || let "ret+=1"
	fi

	eend $ret
}

error() {
	trap - EXIT
	ewarn "error: ${1}"
	usage
	cleanup
	exit 1
}


usage() {
	echo "${PERSONNALITY} -M device [-m device] partition"
	echo "options: "
	echo "   -M <device> : writes a new Master Boot Record on device"
	echo "   -m <device> : writes a new Master Boot Record on device (alternate device)"
	echo "   <partition> : use <partition> as boot partition where extlinux is installed"
}


check_parameters () {
    [[ -b "${EXTLINUX_DEVICE}" ]] || error  "You must supply a valid boot block device."
    [[ -b "${MBR_DEVICE}" ]] || error "You must supply a valid block device to write the MBR on."
    [[ -z "${MBR_DEVICE_ALT}" || -b "${MBR_DEVICE_ALT}" ]] || error "You must supply a valid block device to write the MBR on."
    [[ ${FW} == "bios" || ${FW} == "efi32" || ${FW} == "efi64" ]] || error "You must supply a valid firmware"
}



write_mbr () {
    if [[ -z "${MBR_DEVICE_ALT}" ]]; then
	ebegin "Writing Master Boot Record"
	cat "$MASTERBOOTRECORD" > "${MBR_DEVICE}"
	eend
    else
	ebegin "Writing Master Boot Records"
	cat "$MASTERBOOTRECORD" > "${MBR_DEVICE}"
	cat "$MASTERBOOTRECORD" > "${MBR_DEVICE_ALT}"
	eend
    fi
}


call_extlinux () {
    ebegin "Setting up extlinux boot loader"
    mkdir "${TMP_CLIP_BOOT}"
    mount "${EXTLINUX_DEVICE}" "${TMP_CLIP_BOOT}" || error "Impossible to mount boot partition."
    BOOT_MOUNTED="yes"
    extlinux -i "${TMP_CLIP_BOOT}" &> /dev/null || error "extlinux failed"
    umount "${EXTLINUX_DEVICE}" || error "Error while unmounting boot partition."
    BOOT_MOUNTED=""
    rmdir "${TMP_CLIP_BOOT}"
    eend
}

copy_efi_binaries () {
    ebegin "Setting up syslinux (efi) boot loader"
    local arch=""
    if [[ ${FW} == "efi32" ]]; then
        arch=32
    else
        arch=64
    fi

    mkdir "${TMP_CLIP_BOOT}"
    mount "${EXTLINUX_DEVICE}" "${TMP_CLIP_BOOT}" || error "Impossible to mount boot partition."
    mkdir -p "${TMP_CLIP_BOOT}/EFI/boot"

    cp "${TMP_CLIP_BOOT}/syslinux/efi${arch}/*" "${TMP_CLIP_BOOT}/EFI/boot"
}

################## MAIN ####################


trap cleanup EXIT INT 

# Collect parameters and test if the options are coherent
while getopts M:m:f: arg ; do
    case $arg in
	m)
	    MBR_DEVICE_ALT="${OPTARG}"
	    ;;
	M)
	    MBR_DEVICE="${OPTARG}"
	    ;;
	f)
	    FW="${OPTARG}"
	    ;;
	*)
	    ewarn "Unsupported option: ${arg}"
	    usage
	    exit 1
	    ;;
    esac
done
shift `expr $OPTIND - 1`
EXTLINUX_DEVICE="$1"

check_parameters

if [[ ${FW} == "bios" ]]; then
    write_mbr
    call_extlinux
else
    copy_efi_binaries
fi
