#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright Â© 2008-2018 ANSSI. All Rights Reserved.
# Copyright (C) 2011-2012 SGDSN/ANSSI
# Authors:
#   Vincent Strubel <clipos@ssi.gouv.fr>
#   Mickaël Salaün <clipos@ssi.gouv.fr>
# All rights reserved

DEV_NAME="clip-livecd"
DORMDIR=0
MOUNTED=0

# Don't add "config" here
BUILD_FILES="
boot.msg
helpers
image.squashfs
initrd.img
isolinux
isolinux.cfg
kernels.msg
linux
livecd
memtest86
mirrors
config
postinst_chroot_scripts
syslinux.cfg
System.map-clip
user_scripts
vmlinuz-clip
"

usage() {
	echo "Usage: prepare-key.sh -b <build-dir> { -d <device> [ -n <dev-name> ] | -m <mount-dir> | -f <file-image> [-s <size>]} [ -t <fstype> ]" >&2
	echo "" >&2
	echo "<fstype> can be \"FAT\" or \"EXT\" (default value is FAT)" >&2
	echo "" >&2
	echo "<file-image> is a raw image that can be burn to a USB stick"
	echo "" >&2
	echo "  example of use: prepare-key.sh -b /mnt/cdrom -d /dev/sdb -t EXT" >&2
	exit 1
}

if [[ ! -f /usr/sbin/parted ]]; then
	echo "* gparted is needed, please run \"emerge sys-block/parted\" to install it"
	exit 1
fi

while getopts d:b:f:n:m:s:t: arg ; do
    case $arg in
	d)
	    DEV="${OPTARG}"
	    ;;
	b)
	    BUILD_DIR="${OPTARG}"
	    ;;
	n)
	    DEV_NAME="${OPTARG}"
	    ;;
	m)
	    MOUNT="${OPTARG}"
	    ;;
	t)
	    TYPE="${OPTARG}"
	    ;;
	s)
	    IMAGESIZE="${OPTARG}"
	    ;;
	f)
	    if [[ -n ${OPTARG} ]]; then
		    FILEIMAGE="${OPTARG}"
	    fi
	    ;;
	*)
	    echo "Unsupported option: ${arg}" >&2
	    usage
	    exit 1
	    ;;
    esac
done

error() {
	echo "${1}" >&2
	exit 1
}

cleanup() {
	trap - INT TERM EXIT
	if [ "${MOUNTED}" -eq 1 ]; then
		umount -l "${MOUNT}" || error "Failed to unmount key from ${MOUNT}"
		MOUNTED=0
	fi
	if [ "${DORMDIR}" -eq 1 ]; then
		rmdir "${MOUNT}"
		DORMDIR=0
	fi

	if [[ -n ${FILEIMAGE} ]]; then
		losetup -d "${DEV}"
		losetup -d "${DEVP}"
		rm -f "${DEV}1"
	fi
}
trap cleanup INT TERM EXIT

[ -z "${DEV}" -a -z "${MOUNT}" -a -z "${FILEIMAGE}" ] && usage
[ -n "${DEV}" -a -n "${FILEIMAGE}" ] && usage
[ -z "${MOUNT}" ] && MOUNT="$(mktemp -u /tmp/prepare-key_XXXXXX)"
[ -n "${DEV}" -a ! -b "${DEV}" ] && error "${DEV} is not a block device"
[[ -z "${BUILD_DIR}" ]] && usage
[[ -f "${BUILD_DIR}/livecd" ]] || error "${BUILD_DIR} is not a valid build directory"
TYPE=${TYPE:-"FAT"}

if [[ "${LANG}" == "fr_FR" ]]; then
	MSG_INIT=" * Formattage du support ..."
	MSG_COPY=" * Copie des fichiers du DVD en cours, veuillez patienter ..."
	MSG_BOOT=" * Installation du chargeur de démarrage ..."
	MSG_DONE=" * Le nouvel installeur CLIP a été correctement créé"
else
	MSG_INIT=" * Creating filesystem ..."
	MSG_COPY=" * Copying files from the original media, please wait ..."
	MSG_BOOT=" * Installing bootloader ..."
	MSG_DONE=" * CLIP installer successfully created"
fi

if [[ -n ${FILEIMAGE} ]]; then
	dd if=/dev/zero of="${FILEIMAGE}" bs=1M seek="${IMAGESIZE:-2048}" count=0 >/dev/null 2>/dev/null \
		|| error "dd failed on ${FILEIMAGE}"
	DEV=$(losetup --show --find ${FILEIMAGE})
	# 2048 sectors * 512 (block size) = 1048576
	DEVP=$(losetup --show --find -o 1048576  ${FILEIMAGE})
	cp -dpR ${DEVP} ${DEV}1
fi

if [[ -b "${DEV}" ]]; then
	echo -n "${MSG_INIT}"
	#echo ',,c,*' | sfdisk "${DEV}" >/dev/null 2>/dev/null \
	#	|| error "sfdisk failed on ${DEV}"
	dd if=/dev/zero of="${DEV}" bs=512 count=4 >/dev/null 2>/dev/null
	parted "${DEV}" -s -a optimal mktable msdos \
		|| error "parted failed on ${DEV}"
	parted "${DEV}" -s -a optimal mkpart primary fat32 2048s 100% \
		|| error "parted failed on ${DEV}"
	parted "${DEV}" -s set 1 boot on \
		|| error "parted failed on ${DEV}"
	while ! blockdev --getsz "${DEV}1" 1>/dev/null 2>/dev/null ; do
		echo -n '.'
		sleep 1
	done

	case "${TYPE}" in
	"FAT"|"fat")
		mkfs.vfat -n "${DEV_NAME}" "${DEV}1" 1>/dev/null 2>/dev/null || error "mkfs failed on ${DEV}1"
		;;
	"EXT"|"ext")
		mke2fs -t ext4 -O ^has_journal -L "${DEV_NAME}" "${DEV}1" 1>/dev/null 2>/dev/null || error "mkfs failed on ${DEV}1"
		;;
	#"UDF")
	#	mkudffs -b 512 --media-type=hd --utf8 --lvid="${DEV_NAME}" --vid="${DEV_NAME}" --fsid="${DEV_NAME}" "${DEV}"
	#	;;
	"*")
		echo "Unsupported filesystem: ${TYPE}" >&2
		usage
		exit 1
		;;
	esac

	echo '[ok]'

	[ -d "${MOUNT}" ] || DORMDIR=1
	mkdir -p "${MOUNT}" || error "Failed to create ${MOUNT}"

	case "${TYPE}" in
	"FAT"|"fat")
		mount -t vfat "${DEV}1" "${MOUNT}" || error "Failed to mount"
		;;
	"EXT"|"ext")
		mount -t ext4 "${DEV}1" "${MOUNT}" || error "Failed to mount"
		;;
	#"UDF")
	#	mount -t udf "${DEV}1" "${MOUNT}" || error "Failed to mount"
	#	;;
	*)
		echo "Unsuppored filesystem: ${TYPE}" >&2
		usage
		exit 1
		;;
	esac

	MOUNTED=1
fi

echo -n "${MSG_COPY}"
rsync -a --inplace --modify-window=1 --chmod=ugo=rwX --files-from=<(echo "${BUILD_FILES}") -r -- "${BUILD_DIR}" "${MOUNT}/" || error "Failed to copy files"
chmod 777 "${MOUNT}" || error "Failed to change permissions on ${MOUNT}"

for f in syslinux.cfg vmlinuz-clip initrd.img; do
	[[ -f "${MOUNT}/isolinux/${f}" ]] && mv "${MOUNT}/isolinux/${f}" "${MOUNT}/${f}"
	[[ -f "${MOUNT}/${f}" ]] || error "Failed to copy ${f}"
done
cp "/usr/share/syslinux/menu.c32" "${MOUNT}/menu.c32" || error "Failed to copy menu.c32"
echo '[ok]'

if [[ -b "${DEV}" || ( -n "${FILEIMAGE}" && -f "${DEV}" ) ]]; then
	echo -n "${MSG_BOOT}"
	dd bs=440 count=1 if="/usr/share/syslinux/mbr.bin" of="${DEV}" conv=notrunc >/dev/null 2>/dev/null \
	|| error "Failed to write MBR"
	sync
	case "${TYPE}" in
	"FAT"|"fat")
		syslinux -i -f "${DEV}1" || error "Failed to install bootloader"
		echo -n '[ok (step 1/2)]'

		syslinux -i -f "${DEV}1" || error "Failed to install bootloader"
		echo ' [ok (step 2/2)]'

		cleanup
		;;
	"EXT"|"ext")
		# note: extlinux also works on FAT filesystems, but it does not work well 
		# within the SDK (probably due to some capabilities being droppped)
		extlinux --install "${MOUNT}" >/dev/null 2>/dev/null || error "Failed to install bootloader"
		echo '[ok]'
		cleanup
		;;
	*)
		echo "Unsuppored filesystem: ${TYPE}" >&2
		usage
		exit 1
		;;
	esac

	sync

	echo "${MSG_DONE}"
else
	cleanup
fi
