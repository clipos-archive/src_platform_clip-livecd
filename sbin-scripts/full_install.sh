#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

# Copyright (C) 2008 SGDN/DCSSI
# Copyright (C) 2011-2012 SGDSN/ANSSI
# Authors:
#   Olivier Levillain <clipos@ssi.gouv.fr>
#   Vincent Strubel <clipos@ssi.gouv.fr>
#   Mickaël Salaün <clipos@ssi.gouv.fr>
# All rights reserved

BIN_PATH=${0%/*}
[[ -z "${CONF_PATH}" ]] && CONF_PATH="/opt/clip-installer"
export CONF_PATH
PERSONNALITY="${0}"

source "/lib/rc/sh/functions.sh"
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

# error <message> [command [args]...]
error() {
	echo
	ewarn "error: ${1}"
	shift
	[[ "$#" -gt 0 ]] && "$@"
	exit 1
}

usage() {
    echo "${PERSONNALITY} -t [rm|gtw|bare] [-c <dir>] [-e <dir>] -H <hardware type> <device(s)>"
    echo "options: "
    echo "   -v : list available configurations and supported hardware types"
    echo "   -t : define the CLIP distribution to install"
    echo "   -k : keep user data from a previous install"
    echo "   -c <dir> : use <dir> as configuration directory"
    echo "           (default /opt/clip-installer)"
    echo "   -C <type> : full-disk encryption with <type> (crypt0|crypt1|crypt2) scheme" 
    echo "   -P <pass> : use <pass> as master password for crypt0 full-disk encryption" 
    echo "   -H <hardware type> : install on <hardware type> hardware "
    echo "   <device(s)> : use <device(s)> to install CLIP"
    echo "                 (if two are given, install will use RAID)"
    echo "   -e <dir> : generate an escrow key and save it in <dir>, only for"
    echo "              crypt0 and crypt2 encryption scheme"
}

init_parts () {
    # Do we have to install in EFI mode or in Legacy mode ?
    local efi=""
    [[ ${FW} != "bios" ]] && efi="-U"

    local disk1="${1}"
    [[ -b "${disk1}" ]] || error "${disk1} is not a valid block device." usage

    local disk2="${2}"
    local args=""
    [[ -n "${KEEP_DATA}" ]] && args="-k"

    if [[ -n "${disk2}" ]]; then
        [[ -b "${disk2}" ]] || error "${disk2} is not a valid block device." usage
        args="${args} -R ${disk1} ${disk2}"
        INSTALL_DISK="/dev/md"
    else
        args="${args} ${disk1}"
        INSTALL_DISK="${disk1}"
    fi
    [[ -n "${QUIET}" ]] && args="-q ${args}"

    if [[ ! -z "${ESCROW_FILE}" ]]; then
        args="-E ${ESCROW_FILE} ${args}"
    fi

    if [[ ! -z "${PASSWORD2}" ]]; then
        args="-T ${PASSWORD2} ${args}"
    fi

    local diskconf="${CONF_PATH}/params/disk_layout"
    [[ -f "${diskconf}" ]] && args="-c ${diskconf} ${args}"

    if [[ -n "${PASSWORD}" ]]; then
        if ! ${BIN_PATH}/init_partitions.sh ${efi} -P "${PASSWORD}" ${args}; then
		ewarn "init_partitions failed, retrying"
		${BIN_PATH}/init_partitions.sh ${efi} -P "${PASSWORD}" ${args} \
			|| error "init_partitions failed"
	fi
    else
        if ! ${BIN_PATH}/init_partitions.sh ${efi} ${args}; then
		ewarn "init_partitions failed, retrying"
		${BIN_PATH}/init_partitions.sh ${efi} ${args} || error "init_partitions failed"
	fi
    fi

    if [[ "${ENCRYPT}" == "crypt1" ]]; then
        mount -t ext4,vfat "${INSTALL_DISK}1" /clip1 || error "Failed to mount
				boot partition"
        echo -n "${PASSWORD}" > "/clip1/master_key" || error "Failed to write master key"
        umount /clip1 || error "Failed to unmount boot partition"
    elif [[ "${ENCRYPT}" == "crypt2" ]]; then
        mount -t ext4,vfat "${INSTALL_DISK}1" /clip1 || error "Failed to mount
				boot partition"
        echo -n "${PASSWORD}" > "/clip1/master_key.1.unseal" || error "Failed to write master key"
        echo -n "${PASSWORD2}" > "/clip1/master_key.2.unseal" || error "Failed to write master key"

        tpm_cmd seal "/clip1/master_key.1.unseal" "/clip1/master_key.1.seal" || error "fail to seal first primary key"
        tpm_cmd seal "/clip1/master_key.2.unseal" "/clip1/master_key.2.seal" || error "fail to seal snd primary key"

        touch /clip1/.reseal
        rm -f "/clip1/master_key.1.unseal"
        rm -f "/clip1/master_key.2.unseal"

        umount /clip1 || error "Failed to unmount boot partition"
    fi
}

inst_bootloader () {
    local disk1="${1}"
    local disk2="${2}"
    if [[ -n "${disk2}" ]]; then
        ${BIN_PATH}/bootloader.sh -f ${FW} -M "${disk1}" -m "${disk2}" "/dev/md1" || error "installation of the bootloader failed"
    else
        ${BIN_PATH}/bootloader.sh -f ${FW} -M "${disk1}" "${disk1}1" || error "installation of the bootloader failed"
    fi
}

get_dmin() {
	awk "\$4~/^${1#/dev/}\$/ { print \$2 }" /proc/partitions
}

# When a disk is detected at boot time, but disappear at install...
get_real_boot() {
	# Quick and dirty workaround for Foo - where we don't actually
	# install on the internal disk
	if [[ "${HW_TYPE}" == "Foo" ]]; then
		echo "/dev/sda"
		return 0
	fi
	if [[ "${HW_TYPE%-usb}" != "${HW_TYPE}" ]]; then
		echo "/dev/sda"
		return 0
	fi
	# Get the boot disk
	local disk_boot="${1}"
	local dmin_boot="$(get_dmin "${disk_boot}")"
	[[ -n "${dmin_boot}" ]] || error "Invalid boot disk: ${disk_boot}"

	# Get the first disk
	# sd* or vd*?
	# try sd* first, if not it's sd*
	local x="s"
	local disk_first="$(awk '$4~/^sd[a-z]+$/ { print $4 }' /proc/partitions | head -n 1)"

	if [[ -z $disk_first ]]; then
		# it's not sd*, so it has to be vd*
		x="v"
	fi

	disk_first="/dev/$(awk '$4~/^'${x}'d[a-z]+$/ { print $4 }' /proc/partitions | head -n 1)"
	local dmin_first="$(get_dmin "${disk_first}")"
	[[ -n "${dmin_first}" ]] || error "Invalid first disk: ${disk_first}"

	# Get the live partition
	local part_live="$(awk '$2 == "/mnt/cdrom" {print $1}' /proc/mounts)"
	# Do not care about liveCD
	local dmin_live="256"
	if [[ "${part_live#/dev/sd}" != "${part_live}" ]]; then
		dmin_live="$(get_dmin "${part_live//[0-9]}")"
		[[ -n "${dmin_live}" ]] || error "Invalid live partition: ${part_live}"
	fi

	local dmin_good="${dmin_boot}"
	if [[ "${dmin_live}" -lt "${dmin_boot}" ]]; then
		let "dmin_good -= 16"
	fi
	let "dmin_good -= dmin_first"
	local disk_good="/dev/${x}d$(echo -en "\x$((dmin_good / 16 + 61))")"
	[[ -b "${disk_good}" ]] || error "Humm... Can't find ${disk_good}. Is there a ghost drive with us?"
	echo "${disk_good}"
}

fixup_disks() {
	local disk1="${1}"
	local disk2="${2}"
	if [[ -n "${disk2}" ]]; then
		echo "Boot disk is fine with RAID."
		return 0
	fi
	local boot="$(get_real_boot "${disk1}")"
	[[ -n "${boot}" ]] || error "Failed to get the real boot disk."
	if [[ "${disk1}" = "${boot}" ]]; then
		echo "Boot disk ${disk1} is fine."
		return 0
	fi
	einfo "Fixing install disks from ${disk1} to ${boot}"
	eindent
	for f in /clip1/boot/extlinux_{5,10}.conf /clip{1,2}/etc/fstab; do
		ebegin "$f"
		sed -i -e "s,${disk1#/dev},${boot#/dev},g" "${f}" || error "Failed to fixup ${f}"
		eend $?
	done
	eoutdent
}

show_hw () {
    echo "This installer supports the following hardware"
    for f in $(ls -1 /opt/clip-installer/hw_conf/); do
        printf "\t%s\n" "$(basename ${f})"
    done
}

VERBOSE_OPT=""
ENCRYPT=""
PASSWORD=""
PASSWORD2=""
QUIET=""
KEEP_DATA=""
FW=""
ESCROW_DIRECTORY=""
ESCROW_FILE=""
while getopts vVt:c:C:H:P:qke: arg ; do
    case $arg in
    v)
        version_rm=$(ls /mirrors/clip*-rm-dpkg/clip/clip-core-conf/pool/clip-core-conf*deb 2>/dev/null | sed "s/.*clip-core-conf_\([0-9\.]\+\)\(-r[0-9]\+\)\?_[^\.]\*[\.]deb/\1\2/")
        version_gtw=$(ls /mirrors/clip*-gtw-dpkg/clip/clip-core-conf/pool/clip-core-conf*deb 2>/dev/null | sed "s/.*clip-core-conf_\([0-9\.]\+\)\(-r[0-9]\+\)\?_[^\.]\*[\.]deb/\1\2/")
        version_bare=$(ls /mirrors/clip*-bare-dpkg/clip/clip-core-conf/pool/clip-core-conf*deb 2>/dev/null | sed "s/.*clip-core-conf_\([0-9\.]\+\)\(-r[0-9]\+\)\?_[^\.]\*[\.]deb/\1\2/")
        echo "This installer contains the following versions:"
        [[ -n "${version_rm}" ]] && echo "  CLIP-RM (client) version ${version_rm}"
        [[ -n "${version_gtw}" ]] && echo "  CLIP-GTW (gateway) version ${version_gtw}"
        [[ -n "${version_bare}" ]] && echo "  CLIP-BARE (bare) version ${version_bare}"
        show_hw
    exit 0
        ;;
    k)
    	KEEP_DATA="yes"
	;;
    t)
        CLIP_TYPE="${OPTARG}"
        ;;
    c)
        CONF_PATH="${OPTARG}"
        ;;
    C)
        ENCRYPT="${OPTARG}"
        ;;
    P)
        PASSWORD="${OPTARG}"
        ;;
    q)
        QUIET="yes"
        ;;
    H)
        HW_TYPE="${OPTARG}"
        if [[ ! -e "/opt/clip-installer/hw_conf/${HW_TYPE}" ]]; then
            error "Hardware type ${HW_TYPE} is not supported by this installer" show_hw
        fi
        ;;
    V)
        VERBOSE_OPT="-V"
        ;;
    e)
        ESCROW_DIRECTORY="${OPTARG}"
	;;
    *)
        error "Unsupported option: ${arg}" usage
        ;;
    esac
done
shift `expr $OPTIND - 1`

FW=$(cat "/opt/clip-installer/hw_conf/${HW_TYPE}/fw")
echo "Firmware: ${FW}"

case "${ENCRYPT}" in
    crypt0)
        if [[ -z "${PASSWORD}" ]]; then
            error "Missing password for full disk encryption" usage
        fi
        ;;
    crypt1)
         ebegin "Generating master password for disk encryption"
	       einfo "(Move the mouse around if this seems to block)"
         PASSWORD="$(generate_key 48)"
         if [[ -z "${PASSWORD}" ]]; then
             eend 1 "Failed to generate password"
             exit 1
         fi
         eend 0
         ;;
    crypt2)
         # check for tpm support in hw profile
         if [[ -z "$(grep tpm "/opt/clip-installer/hw_conf/${HW_TYPE}/modules")" ]]; then
           eend 1 "${HW_TYPE} lacks TPM support"
           exit 1
         fi
         # provision the tpm
         tpm.sh || error "fail to provision tpm, you need to clear it"
         ebegin "Generating tpm-protected passwords for disk encryption"
	       einfo "(Move the mouse around if this seems to block)"
         PASSWORD="$(generate_key 48)"
         if [[ -z "${PASSWORD}" ]]; then
             eend 1 "Failed to generate password"
             exit 1
         fi
         PASSWORD2="$(generate_key 48)"
         if [[ -z "${PASSWORD2}" ]]; then
             eend 1 "Failed to generate password"
             exit 1
         fi
         eend 0
         ;;
    "")
         ;;
    *)
         error "Unsupported encryption scheme: ${ENCRYPT}"
         ;;
esac

# We generate an escrow key to be stored in a secure location (the escrow
# directory given by the user as an argument of this script).
ESCROW_FILE=""
if [[ ! -z "${ESCROW_DIRECTORY}" ]]; then
    ebegin "Generating escrow key for disk encryption"
    einfo "(Move the mouse around if this seems to block)"
    ESCROW_KEY="$(generate_key 48)"
    if [[ -z "${ESCROW_KEY}" ]]; then
        eend 1 "Failed to generate escrow key"
        exit 1
    fi
    # We find out a filename to store the escrow key using the conf path.
    ESCROW_FILE="$(generate_escrow_name "${ESCROW_DIRECTORY}" "$(basename ${CONF_PATH})" "escrow_key")"

    printf "${ESCROW_KEY}" > ${ESCROW_FILE} || (eend 1 "Failed to store escrow key"; exit 1)
    eend 0
fi


if [[ -z "${CLIP_TYPE}" ]]; then
    usage
    exit 1
fi
[[ -n "${SCREEN_GEOM}" ]] && SCREEN_OPT="-s ${SCREEN_GEOM}"

CLIP_CONF_FILE="${CONF_PATH}/params/conf.d/clip"

if [[ ! -f "${CLIP_CONF_FILE}" ]]; then
    CLIP_JAILS=""
    [[ "${CLIP_TYPE}" == "rm" ]] && CLIP_JAILS="rm_h rm_"
    ewarn "${CLIP_CONF_FILE} is missing, creating one for compatibility"
    touch "${CLIP_CONF_FILE}" || error "Cannot write to ${CLIP_CONF_FILE}"
    cat > "${CLIP_CONF_FILE}" <<EOF
CLIP_JAILS="${CLIP_JAILS}"

SERVER_ROOT="/vservers"

SERVER_CONF="/etc/jails"

VIEWER_ROOT="/user/viewers"

VIEWER_CONF="/etc/viewers"

EOF

fi

source "${CLIP_CONF_FILE}"
export CLIP_JAILS

INST_OPTS=""
[[ -n "${ENCRYPT}" ]] && INST_OPTS="-C ${ENCRYPT}"
NOCONF_OPT=""
[[ -n "${KEEP_DATA}" ]] && NOCONF_OPT="-z"

case "$CLIP_TYPE" in
    rm|gtw|bare)
        ;;
    *)
    error "Not a valid clip distribution : ${OPTARG}" usage
    ;;
esac
export CLIP_TYPE

if [[ -n "${KEEP_DATA}" ]]; then
	/opt/clip-installer/save.sh || error "Failed to save configuration"
fi

init_parts "${1}" "${2}"

"/opt/clip-installer/install_clip_${CLIP_TYPE}.sh" -H "${HW_TYPE}" \
    -d "${INSTALL_DISK}" ${SCREEN_OPT} -u "file:///mirrors" \
    ${INST_OPTS} ${NOCONF_OPT} \
    -c "${CONF_PATH}" ${VERBOSE_OPT} -b clip1 || error "installation of clip1 failed"

"/opt/clip-installer/install_clip_${CLIP_TYPE}.sh" -H "${HW_TYPE}" \
    -d "${INSTALL_DISK}" ${SCREEN_OPT} -u "file:///mirrors" \
    ${INST_OPTS} \
    -c "${CONF_PATH}" ${VERBOSE_OPT} -b -z clip2 || error "installation of clip2 failed"

#if @DO_INSTALL_BOOTLOADER@ ; then
	#inst_bootloader "${1}" "${2}"
#fi

clip-disk mount all
fixup_disks "$1" "$2"
clip-disk umount all

echo -e "\nCLIP was correctly installed!"
