#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright Â© 2008-2018 ANSSI. All Rights Reserved.

# Copyright (C) 2008 SGDN/DCSSI
# Copyright (C) 2011 SGDSN/ANSSI
# Authors: Olivier Levillain <clipos@ssi.gouv.fr>
#          Vincent Strubel <clipos@ssi.gouv.fr>
#          Mickaël Salaün <clipos@ssi.gouv.fr>
# All rights reserved

NAME="$(basename -- "$0")"
WORKDIR="$(dirname -- "$(readlink -f -- "$0")")"

# Default config
[[ -z "${BUILD_LOOP}" ]] && BUILD_LOOP="yes"
[[ -z "${FORCE_SKIP}" ]] && FORCE_SKIP=""
[[ -z "${BUILD_DIR}" ]] && BUILD_DIR=""
[[ -z "${OUTPUT_ISO}" ]] && OUTPUT_ISO="livecd.iso"
[[ -z "${MAKE_ISO}" ]] && MAKE_ISO="no"


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
		/bin/true
	}
	eindent() {
		/bin/true
	}
	eoutdent() {
		/bin/true
	}
fi



cleanup() {
	trap - EXIT

	local ret=0
	ebegin "Cleaning up"

	if [ -n "${BOOT_BINDMOUNTED}" ]; then
	    umount "${BUILD_DIR}"/isolinux 2> /dev/null || let "ret+=1"
	fi

	eend $ret

	exit 0
}

error() {
	trap - EXIT
	ewarn "error: ${1}"
	cleanup
	usage
	exit 1
}

usage() {
	echo "${NAME} [-Vlmf] [-M mirrors-dir] -B build-dir [-o image] loop-dir"
	echo "options: "
	echo "   -a <extra> : recursively copy files from <extra> to the install media"
	echo "   -l : skip image.squashfs generation if possible"
	echo "   -f : force the above generation to be skipped, even if the squashfs files"
	echo "           are missing (this may create broken live CDs)"
	echo "   -i : make ISO image (not USB boot)"
	echo "   -o <image> : use <image> as output name of the ISO image"
	echo "           (default livecd.iso)"
	echo "   -B <build-dir> : specify the directory where the image is build"
	echo "   -V : be more verbose"
	echo "   <loop-dir> : use <loop-dir> as source to build the main image.squashfs"
}


check_parameters () {
    [[ -n "${LOOP_DIR}" ]] || error "You have to provide a loop directory."
    [[ -d "${LOOP_DIR}" ]] || error "${LOOP_DIR} is not a valid loop directory."

    [[ -n "${BUILD_DIR}" ]] || error "You have to provide a build directory"
    [[ -d "${BUILD_DIR}" ]] || error "${BUILD_DIR} is not a valid build directory"
    [[ -d "${BUILD_DIR}"/isolinux ]] || mkdir "${BUILD_DIR}"/isolinux || error "mkdir ${BUILD_DIR}/isolinux failed"

    [[ -f "${BUILD_DIR}/image.squashfs" ]] || [[ -n "${FORCE_SKIP}" ]] || BUILD_LOOP="yes"
}

vorq() {
	if [ -z "${VERBOSE}" ]; then
		exec 1> /dev/null
		exec 2> /dev/null
	fi
	"$@"
	local ret=$?
	if [ -z "${VERBOSE}" ]; then
		exec 1>&0
		exec 2>&0
	fi
	return ${ret}
}

build_loop () {
	ebegin "Updating boot initrd"
	/opt/clip-livecd/enter-loop.sh "${LOOP_DIR}" /sbin/livecd-mkinitrd.sh
	local ret=$?
	eend $ret
	[[ $ret -eq 0 ]] || exit 1
	ebegin "Generating squashfs root image"
	#find "${LOOP_DIR}" -iname libgcc_s.so.1 | xargs chmod +x
	cp "${LOOP_DIR}"/boot/vmlinuz-clip "${LOOP_DIR}"/boot/linux
	vorq mksquashfs "${LOOP_DIR}" "${BUILD_DIR}/image.squashfs" -noappend \
		-ef "${WORKDIR}/prepare-media_exclude.txt" \
		-pf "${WORKDIR}/prepare-media_create.txt"
	eend $?
}

genere_iso () {
	ebegin "Generating livecd ISO image"
	vorq genisoimage -J -r -l -v -V "CD d'installation de CLIP" \
		-o ${OUTPUT_ISO} \
		-b isolinux/isolinux.bin \
		-c isolinux/boot.cat \
		-no-emul-boot \
		-boot-load-size 4 \
		-boot-info-table ${BUILD_DIR}
	eend $?
}



################## MAIN ####################

trap cleanup EXIT INT 

# Collect parameters and test if the options are coherent
while getopts a:mlVfM:o:B:i arg ; do
    case $arg in
	a)
	    EXTRA_TREE="${OPTARG}"
		;;
	V) 
	    VERBOSE="yes"
	    ;;
	l)
	    BUILD_LOOP="no"
	    ;;
	f)
	    FORCE_SKIP="yes"
	    ;;
	B)
	    BUILD_DIR="${OPTARG}"
	    ;;
	o)
	    OUTPUT_ISO="${OPTARG}"
	    ;;
	i)
	    MAKE_ISO="yes"
	    ;;
	*)
	    ewarn "Unsupported option: ${arg}"
	    usage
	    exit 1
	    ;;
    esac
done
shift `expr $OPTIND - 1`
LOOP_DIR="$1"
[[ "${MAKE_ISO}" == "yes" ]] &&  BOOT_DIR="${BUILD_DIR}"/isolinux
[[ -z "${BOOT_DIR}" ]] && BOOT_DIR="${BUILD_DIR}"

check_parameters

# Let's build the livecd image
[[ "${BUILD_LOOP}" == "no" ]] || build_loop

for tomk in config mirrors user_scripts postinst_chroot_scripts; do
	mkdir -p "${BUILD_DIR}/${tomk}"
done

cp -r "/opt/clip-livecd/helpers/" "${BUILD_DIR}/"

#mount --bind "${LOOP_DIR}"/boot "${BUILD_DIR}"/isolinux || error "Impossible to bind boot to isolinux"
#BOOT_BINDMOUNTED="yes"
for i in "${LOOP_DIR}"/boot/*; do
	if [ -f "$i" ]; then
		cp "$i" "${BOOT_DIR}"/
	fi
done || error "Impossible to copy boot directory to isolinux"

if [[ -e "${LOOP_DIR}"/usr/share/syslinux/menu.c32 ]] ; then
	cp "${LOOP_DIR}"/usr/share/syslinux/menu.c32 "${BOOT_DIR}" || error "Impossible to copy menu.c32"
else
	ewarn "Not copying syslinux/menu.c32 since it does not exist"
fi

echo "Support d'installation CLIP" > "${BOOT_DIR}"/boot.msg
date "+Genere le %Y-%m-%d a %H:%M" >> "${BOOT_DIR}"/boot.msg
echo "Appuyez sur Entree pour demarrer." >> "${BOOT_DIR}"/boot.msg

if [[ -n "${EXTRA_TREE}" ]]; then
	einfo "Copying extra files from ${EXTRA_TREE}"
    cp -r "${EXTRA_TREE}"/* "${BUILD_DIR}/"
fi

touch "${BUILD_DIR}"/livecd
if [[ "${MAKE_ISO}" == "yes" ]]; then
	cp "${BOOT_DIR}/vmlinuz-clip" "${BOOT_DIR}/vmlinuz"
	sed -i -r 's/\<vmlinuz-clip\>/vmlinuz/g' "${BOOT_DIR}/isolinux.cfg"
	genere_iso
else
	rm "${BOOT_DIR}/isolinux.bin"
fi
