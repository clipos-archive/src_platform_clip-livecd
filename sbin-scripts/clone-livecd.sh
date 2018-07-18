#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

# Create a new installation USB stick from the current clip-livecd.
# Copyright (C) 2012 ANSSI
# Author: Mickaël Salaün <clipos@ssi.gouv.fr>
# All rights reserved

ROOTDISK="$(mount | awk '$3 == "/mnt/cdrom" {print $1}')"
ROOTDISK="${ROOTDISK%?}"

block_info() {
	local block="$1"
	shift
	for type in "$@"; do
		sed -e 's/^ *//' -e 's/ *$//' -- "/sys/block/${name}/device/${type}"
	done | tr '\n' ' ' | sed -e 's/ $//'
}

list_usbblock() {
	local name
	for block in /sys/block/sd*; do
		name="$(basename "${block}")"
		[[ "${name}" == "${ROOTDISK#/dev/}" ]] && continue
		if readlink "${block}" | grep -qE '/usb[0-9]+/'; then
			echo -e "/dev/${name}\n$(block_info "${name}" vendor model)\noff"
		fi
	done
}

TITLE="Clonage du media d'installation"
if [ ! -b "${ROOTDISK}" ]; then
	Xdialog --title "${TITLE}" --icon /usr/share/icons/dialog-error.png --msgbox "Impossible de trouver le média d'installation." 0 0
	exit 1
fi

LIST="$(list_usbblock)"
if [ -z "${LIST}" ]; then
	Xdialog --title "${TITLE}" --icon /usr/share/icons/dialog-error.png --msgbox "Aucun nouveau média USB trouvé." 0 0
	exit 1
fi

DISK="$(echo "${LIST}" | xargs -d '\n' Xdialog --title "${TITLE}" --stdout --radiolist "Choix du média à effacer pour la copie :" 12 80 0)"
[ $? -ne 0 ] && exit 0

if [ ! -b "${DISK}" ]; then
	Xdialog --title "${TITLE}" --icon /usr/share/icons/dialog-error.png --msgbox "Le périphérique ${DISK} n'est pas correct." 0 0
	exit 1
fi
# TODO: check disk size?
Xdialog --title "${TITLE}" --icon /usr/share/icons/dialog-warning.png --yesno "Êtes-vous sûr de vouloir effacer le disque ${DISK} ?" 0 0
[ $? -ne 0 ] && exit 0

DISKNAME="$(blkid -o udev "${ROOTDISK}1" 2>/dev/null | sed -n -r 's/^ID_FS_LABEL=(.*)/\1/p')"
if [ -z "${DISKNAME}" ]; then
	SETNAME=""
else
	SETNAME="-n ${DISKNAME}"
fi
# TODO: take care of spaces
xterm -T "${TITLE}..." -e "prepare-key.sh -d ${DISK} -b /mnt/cdrom ${SETNAME}; read"
