#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

LOOPFILE="$(mktemp /tmp/initrd.XXXXXX)"
LOOPMNT="/tmp/initrd-mounted"
INITRD_BASE="/usr/share/clip-livecd/initrd-files"

cleanup() {
	umount "${LOOPMNT}" 2>/dev/null
	rm -fr "${BASEDIR}" "${LOOPMNT}"
	[[ -n "${LOOPFILE}" ]] && rm -f "${LOOPFILE}"
}

error() {
	echo "${1}" >&2
	cleanup
	exit 1;
}

create_dirs() {
	for d in bin dev etc lib proc sbin tmp sys usr/bin usr/sbin usr/share var; do
		mkdir -p "${LOOPMNT}/${d}" \
			|| error "Failed to create ${LOOPMNT}/${d}"
	done
}

populate_dev() {
	echo "Creating device nodes..."

	mknod "${LOOPMNT}/dev/mem" c 1 1 || error "mknod mem failed"
	mknod "${LOOPMNT}/dev/null" c 1 3 || error "mknod null failed"
	mknod "${LOOPMNT}/dev/zero" c 1 5 || error "mknod zero failed"
	mknod "${LOOPMNT}/dev/tty1" c 4 1 || error "mknod tty1 failed"
	mknod "${LOOPMNT}/dev/console" c 5 1 || error "mknod console failed"
}

copy_modules() {
	local kern="$(ls -rt "/lib/modules" | tail -n 1)"

	[[ -n "${kern}" ]] || error "Could not find kernel modules"

	echo "Copying modules for ${kern}..."

	local kernpath="/lib/modules/${kern}"
	local ret=0

	mkdir -p "${LOOPMNT}${kernpath}" || ret=1
	for f in "${kernpath}/"*; do 
		[[ -f "${f}" ]] || continue 
		cp "${f}" "${LOOPMNT}/${kernpath}/" || ret=2
	done
	if [[ -d "${kernpath}/kernel" ]]; then
		cp -r "${kernpath}/kernel" "${LOOPMNT}${kernpath}/kernel" || ret=3
	fi

	[[ $ret != 0 ]] && error "Failed to copy all module files ($ret)"
}


copy_base_files() {
	echo "Copying base files..."

	[[ -d "${INITRD_BASE}" ]] || error "Missing ${INITRD_BASE}" 

	cp -a "${INITRD_BASE}/etc"/* "${LOOPMNT}/etc/"
	cp -a "${INITRD_BASE}/usr"/* "${LOOPMNT}/usr/"

	chmod +x "${LOOPMNT}/usr/share/udhcpc/default.script"

	cp "${INITRD_BASE}/modprobe" "${LOOPMNT}/sbin/modprobe" \
		|| error "Failed to copy modprobe"

	cp "${INITRD_BASE}/init" "${LOOPMNT}/init" \
		|| error "Failed to copy init"

	chmod +x "${LOOPMNT}/sbin/modprobe" "${LOOPMNT}/init"

	ln -sf "init" "${LOOPMNT}/linuxrc" || error "Failed to link init"
	ln -sf "../init" "${LOOPMNT}/sbin/init" || error "Failed to link init"

	echo "/dev/ram0     /           ext2    defaults	0 0" \
		> "${LOOPMNT}"/etc/fstab
	echo "proc          /proc       proc    defaults    0 0" \
		>> "${LOOPMNT}"/etc/fstab
}

check_binary() {
	local bin="${1}"

	[[ -f "${bin}" ]] || error "${bin} binary missing"

	file "${bin}" | grep -q "statically linked" \
		|| error "${bin} is not a statically linked binary"
}
copy_busybox() {
	echo "Copying and linking busybox..."
	
	check_binary "/bin/busybox-livecd"
	
	cp -a "/bin/busybox-livecd" "${LOOPMNT}/bin/busybox" \
		|| error "Failed to copy busybox"

	for l in "[" "[[" cat cut echo mount sh umount uname; do
		ln -sf "busybox" "${LOOPMNT}/bin/${l}" \
			|| error "Failed to create ${l} busybox symlink"
	done
}

copy_lvm() {
	echo "Copying lvm..."

	check_binary "/sbin/lvm.static"

	cp -a "/sbin/lvm.static" "${LOOPMNT}/bin/lvm" \
		|| error "Failed to copy lvm"
}

copy_dmraid() {
	echo "Copying dmraid..."
	
	check_binary "/usr/sbin/dmraid" 

	cp -a "/usr/sbin/dmraid" "${LOOPMNT}/sbin/dmraid" \
		|| error "Failed to copy dmraid"
}

copy_binaries() {
	copy_busybox
	copy_lvm
	copy_dmraid
}

[[ -z "${LOOPFILE}" ]] && error "Failed to create loop file"
mkdir "${LOOPMNT}" || error "Failed to create ${LOOPMNT}" 

echo "Creating filesystem..."
dd if=/dev/zero of="${LOOPFILE}" bs=1M count=64 2>/dev/null \
	|| error "Failed to initialize ${LOOPFILE}" 

mke2fs -m0 -F "${LOOPFILE}" 1>/dev/null 2>/dev/null || error "mke2fs failed"

mount -o loop "${LOOPFILE}" "${LOOPMNT}" || error "mount failed"

create_dirs

populate_dev

copy_base_files

copy_binaries

copy_modules

umount "${LOOPMNT}" || error "umount failed"
gzip -S .img "${LOOPFILE}" || die "gzip failed"
mv "${LOOPFILE}.img" "/boot/initrd.img" || die "mv failed"

if @DO_UBOOT_IMAGE@ ; then
	echo "Creating U-Boot image"
        mkimage -A @ARCH@ -O linux -T ramdisk -a @LOADADDR_RAMDISK@ -n "CLIP LiveCD @VERSION@ initrd" -d "/boot/initrd.img" "/boot/initrd.uimg" || error "Failed to generate initrd uImage"
        mv "/boot/initrd.uimg" "/boot/initrd.img"

	echo "Creating U-Boot script (${i})"
	mkimage -A @ARCH@ -O linux -T script -a 0 -n "CLIP LiveCD loader" -d "/boot/uboot_livecd_@PLATFORM@.scr" "/boot/uboot_livecd_@PLATFORM@"
fi



echo " * New LiveCD initrd generated in /boot/initrd.img *"

cleanup
