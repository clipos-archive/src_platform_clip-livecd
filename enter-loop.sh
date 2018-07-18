#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.
# Copyright (C) 2008 SGDN/DCSSI
# Copyright (C) 2010-2012 ANSSI
# Authors: Olivier Levillain <clipos@ssi.gouv.fr>
#          Mickaël Salaün <clipos@ssi.gouv.fr>
# All rights reserved

set -e

usage() {
	echo "Usage: $0 [-n] [-s] <chroot-path> [exec-cmd]" > /dev/stderr
	echo "  Set ROOT environment to change the clip-sdk root directory" > /dev/stderr
	echo "  Set '-n' to not mount anything (e.g. multiple invocations)" > /dev/stderr
	echo "  Set '-s' to run in SDK mode (less mount)" > /dev/stderr
	exit 1
}

if [ "$1" == "-n" ]; then
	NO_MOUNT=1
	alias mount="true"
	alias umount="true"
	shift
elif [ "$1" == "-s" ]; then
	SDK=1
	shift
fi

LOOP_CONTENT="${1}"

if [ -z "${LOOP_CONTENT}" -o ! -d "${LOOP_CONTENT}" ] ; then
	usage
fi

source "${ROOT}/etc/clip-build.conf" || usage

if [[ -z "${CLIP_BASE}" ]] ; then
  echo "CLIP_BASE must be defined and contain the path to the portage trees." > /dev/stderr
  exit 1
fi

if [[ -z "$SDK" && ! -e "${LOOP_CONTENT}/usr/src" ]]; then
	mkdir -p "${LOOP_CONTENT}/usr/src"
	touch "${LOOP_CONTENT}/usr/src/.keep"
fi

if [[ "$SDK" == 1 ]]; then
	mkdir -p "${LOOP_CONTENT}/var/tmp/portage"
fi

cleanup() {
	trap - KILL INT TERM EXIT
	set +e
	exec 2> /dev/null
	umount "${LOOP_CONTENT}/opt/clip-int"
	umount "${LOOP_CONTENT}/proc"
	if [ -z "$SDK" ]; then
		umount -l "${LOOP_CONTENT}/dev"
		umount "${LOOP_CONTENT}/usr/src"
	else
		umount -l "${LOOP_CONTENT}/dev/shm"
	fi
	if [[ "$SDK" == 1 ]]; then
		# hardcoded for now
		umount "${LOOP_CONTENT}/var/tmp/portage"
	fi
}
trap cleanup KILL INT TERM EXIT

mount --bind "${ROOT}${CLIP_BASE}/" "${LOOP_CONTENT}/opt/clip-int"
mount --bind "${ROOT}/proc" "${LOOP_CONTENT}/proc"
if [ -z "$SDK" ]; then
	mount --bind "${ROOT}/usr/src" "${LOOP_CONTENT}/usr/src"
	mount --rbind "${ROOT}/dev" "${LOOP_CONTENT}/dev"
else
	mount --bind "${ROOT}/dev/shm" "${LOOP_CONTENT}/dev/shm"
fi
if [[ "$SDK" == 1 ]]; then
	# hardcoded for now
	mount --bind "${ROOT}/var/tmp/portage" "${LOOP_CONTENT}/var/tmp/portage"
fi
chroot "${LOOP_CONTENT}" ${2:-/bin/bash -l}
