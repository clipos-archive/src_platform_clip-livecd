#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright Â© 2008-2018 ANSSI. All Rights Reserved.

# Copyright (C) 2008 SGDN/DCSSI
# Copyright (C) 2011 SGDSN/ANSSI
# Author: Olivier Levillain <clipos@ssi.gouv.fr>
# Author: Vincent Strubel <clipos@ssi.gouv.fr>
# All rights reserved

# compute_sizes.sh propose a way to partition a client or a gateway.
#
# It awaits CLIP_TYPE and CLIP_JAILS in its environment, and takes one
# or two arguments (the second case corresponds to the RAID case)

export LC_ALL="C"

##################
# Error handling #
##################

source "/lib/rc/sh/functions.sh"

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
    ewarn "error: ${1}"
    exit 1
}

######################
#   Global int vars  #
######################

declare -i NUM_PART

declare -i SECS_PER_CYL
declare -i BYTES_PER_CYL

declare -i BOOT_CYLS
declare -i ROOT_CYLS
declare -i MOUNTS_CYLS
declare -i SWAP_CYLS
declare -i RM_CYLS
declare -i EMPTY_CYLS

declare -i RM_HOME_MINCYLS
declare -i RM_LOGS_CYLS

declare -i GW_HOME_CYLS
declare -i GW_LOGS_MINCYLS

declare -i SIZE
declare -i START

declare -i SECS_PER_TRACK
declare -i HEADS
declare -i N_CYLINDERS

declare -i RM_NUM
declare -i EMPTY_RM_NUM
###############################
# General computing functions #
###############################

# MB_to_cyls <size in MB> returns 
function MB_to_cyls () {
    local -i bytes=$(($1 * 1024 * 1024))
    local -i cyls=$(($bytes / $BYTES_PER_CYL))
    if [[ $(($bytes % $BYTES_PER_CYL)) != 0 ]]; then
	cyls=cyls+1
    fi
    echo $cyls
}

# adjust partition start and end to a 4K boundary
function fourkadj () {
    # start and end partition on a 4K boundary
    if [ $FOURKALIG == "yes" ]; then
	ADJ=0
	if [ $(($START % 8)) ]; then
		ADJ=$((8 - $START % 8))
		START=$(($START + $ADJ))
	fi
	SIZE=$(($SIZE - $ADJ))
    fi
}



################################
# General displaying functions #
################################

#echo_line uses $NUM_PART $START $SIZE $ID $BOOTABLE
function echo_line () {
    if [[ $NUM_PART -lt 10 ]]; then
	echo -n "${device}${NUM_PART} : "
    else
	echo -n "${device}${NUM_PART}: "
    fi
    NUM_PART=NUM_PART+1

    echo -n "start=${START}, "
    echo -n "size=${SIZE}, "
    echo -n "Id=${ID}"
    if [[ -n ${BOOTABLE} ]]; then
	echo ", bootable"
	unset BOOTABLE
    else
	echo ""
    fi

    local -i mb=$(( $SIZE / 2048 ))    # n_sectors -> MB
    echo "# Partition ${NAME} de taille ${mb} Mo"
}


# echo_primary_line $N_CYLS $NAME
function echo_primary_line () {
    START=$(($START + $SIZE))
    SIZE=$(($1 * $SECS_PER_CYL))
    NAME=$2

    if [ -z $3 ]; then
        fourkadj
    fi
    echo_line
}

# echo_secondary_line $N_CYLS $NAME
function echo_secondary_line () {
    START=$(($START + $SIZE + $SECS_PER_TRACK))
    SIZE=$(($1 * $SECS_PER_CYL - $SECS_PER_TRACK))
    NAME=$2

    fourkadj
    echo_line
}

# echo_table
function echo_table () {
    local id_ext id_swap

    if [ -n "$RAID_ENABLED" ]; then
	id_ext="fd"
	id_swap="fd"
    else
	id_ext="83"
	id_swap="82"
    fi

    echo "   # partition table of ${DISK1}"
    echo "unit: sectors"

    NUM_PART=1
    ID="$id_ext"
    BOOTABLE="bootable"

    if [ $FOURKALIG == "yes" ]; then
	START=2048 # start at the first Megabyte of the drive
	ADJ=$(($START - $SECS_PER_TRACK))
    else
	START=$SECS_PER_TRACK
	ADJ=0
    fi

    SIZE=$(( $BOOT_CYLS * $SECS_PER_CYL - $SECS_PER_TRACK - $ADJ ))
    NAME="/boot"
    echo_line

    echo_primary_line $HOME_CYLS "/home"
    echo_primary_line $LOGS_CYLS "/log"
    ID=5
    local -i extended_cyls=$(( 2*$ROOT_CYLS + 2*$MOUNTS_CYLS + $RM_NUM*$RM_CYLS + $SWAP_CYLS + $EMPTY_RM_NUM*$EMPTY_CYLS ))
    echo_primary_line $extended_cyls "étendue" "no4kaligning"
    ID="$id_ext"

    START=$(( $START + $SECS_PER_TRACK ))
    SIZE=$(( $ROOT_CYLS * $SECS_PER_CYL - $SECS_PER_TRACK ))
    NAME="/clip1"
    fourkadj
    echo_line

    echo_secondary_line $MOUNTS_CYLS "/clip1/mounts"
    if echo "${CLIP_JAILS}" | grep -q rm_h; then
        echo_secondary_line $RM_CYLS "rm_h"
    else
        echo_secondary_line $EMPTY_CYLS "dummy_rm_h"
    fi
    if echo "${CLIP_JAILS}" | grep -q rm_b; then
        echo_secondary_line $RM_CYLS "rm_b"
    else
        echo_secondary_line $EMPTY_CYLS "dummy_rm_b"
    fi

    ID="$id_swap"
    echo_secondary_line $SWAP_CYLS "swap"
    ID="$id_ext"

    echo_secondary_line $ROOT_CYLS "/clip2"
    echo_secondary_line $MOUNTS_CYLS "/clip2/mounts"
}






#####################################
# Retrieval of the disk(s) geometry #
#####################################

DISK1=$1
[ -b "$DISK1" ] || error "$DISK1 is not a valid block device"
DISK_GEOMETRY=$(sfdisk -g ${DISK1})
SECS_PER_TRACK=$(echo $DISK_GEOMETRY | sed 's/^.*[^0-9]\([0-9]\+\) sectors\/track.*$/\1/')
HEADS=$(echo $DISK_GEOMETRY | sed 's/^.*[^0-9]\([0-9]\+\) heads.*$/\1/')
N_CYLINDERS=$(echo $DISK_GEOMETRY | sed 's/^.*[^0-9]\([0-9]\+\) cylinders.*$/\1/')
RAID_ENABLED=""

# test if the 4kB sector alignment is required
if [[ $(cat /sys/block/${1##*/}/queue/physical_block_size 2> /dev/null) == "4096" ]]; then
    FOURKALIG=yes
else
    FOURKALIG=no
fi

DISK2=$2
if [[ -n "$DISK2" ]]; then
	[ -b "$DISK2" ] || error "$DISK2 is not a valid block device"
	DISK_GEOMETRY_2=$(sfdisk -g ${DISK2})
	SECS_PER_TRACK_2=$(echo $DISK_GEOMETRY_2 | sed 's/^.*[^0-9]\([0-9]\+\) sectors\/track.*$/\1/')
	HEADS_2=$(echo $DISK_GEOMETRY_2 | sed 's/^.*[^0-9]\([0-9]\+\) heads.*$/\1/')
	N_CYLINDERS_2=$(echo $DISK_GEOMETRY_2 | sed 's/^.*[^0-9]\([0-9]\+\) cylinders.*$/\1/')

	if [[ $SECS_PER_TRACK -ne $SECS_PER_TRACK_2 || $HEADS -ne $HEADS_2 || $N_CYLINDERS -ne $N_CYLINDERS_2 ]]; then
 		error "The two block devices do not have the same geometry."
	fi
	RAID_ENABLED=yes
fi

SECS_PER_CYL=$(( $HEADS * $SECS_PER_TRACK ))
BYTES_PER_CYL=$(( $SECS_PER_CYL * 512))

#############################################################
# Actual computing, using CLIP_TYPE / CLIP_JAILS parameters #
#############################################################

# compute_sizes_rm.sh for rm/gateway distributions
#   1            /boot              128 Mo
#   2            /home              10+ Go / 1 Go
#   3            /log               2 Go   / 4+ Go
#   4            <extended>     
#   5/10         /                  2 Go
#   6/11         /mounts            4 Go
#   7/8          /rmX              12 Go   
#   9            <swap>             2 Go
#
# rm >= 51 Go
# gateway >= 20 Go

BOOT_CYLS=$(MB_to_cyls 128)
ROOT_CYLS=$(MB_to_cyls 2048)
MOUNTS_CYLS=$(MB_to_cyls 4096)
SWAP_CYLS=$(MB_to_cyls 2048)
RM_CYLS=$(MB_to_cyls 12292)
EMPTY_CYLS=$(MB_to_cyls 16)

RM_HOME_MINCYLS=$(MB_to_cyls 10240)
RM_LOGS_CYLS=$(MB_to_cyls 2048)

GW_HOME_CYLS=$(MB_to_cyls 1024)
GW_LOGS_MINCYLS=$(MB_to_cyls 4096)

BARE_HOME_CYLS=$(MB_to_cyls 1024)
BARE_LOGS_MINCYLS=$(MB_to_cyls 4096)



# Compat
[[ -z "${CLIP_TYPE}" ]] && CLIP_TYPE="rm"


case "$CLIP_TYPE" in
    rm)
	if [[ -n "${CLIP_JAILS}" ]]; then
	    RM_NUM=$(echo "${CLIP_JAILS}" | wc -w)
	    EMPTY_RM_NUM=$(( 2 - ${RM_NUM} ))
	else 
            # Compat 
	    RM_NUM=2
	    EMPTY_RM_NUM=0
	    CLIP_JAILS="rm_b rm_h"
	fi

	LOGS_CYLS=$RM_LOGS_CYLS
	NEEDED_CYLS=$(( $BOOT_CYLS + $LOGS_CYLS + $SWAP_CYLS + 2*$ROOT_CYLS + 2*$MOUNTS_CYLS + $RM_NUM*$RM_CYLS + $EMPTY_RM_NUM*$EMPTY_CYLS ))
	HOME_CYLS=$(( $N_CYLINDERS - $NEEDED_CYLS ))
	if [[ $HOME_CYLS -ge $RM_HOME_MINCYLS ]]; then
	    echo_table
	else
	    error "The disk is too small to fit a CLIP-RM system"
	fi
	;;

    gtw)
	CLIP_JAILS=""
	RM_NUM=0
	EMPTY_RM_NUM=2
	HOME_CYLS=$GW_HOME_CYLS
        NEEDED_CYLS=$(( $BOOT_CYLS + $HOME_CYLS + $SWAP_CYLS + 2*$ROOT_CYLS + 2*$MOUNTS_CYLS + 4*$EMPTY_CYLS ))
	LOGS_CYLS=$(( $N_CYLINDERS - $NEEDED_CYLS ))

	if [[ $LOGS_CYLS -ge $GW_LOGS_MINCYLS ]]; then
	    echo_table
	else
	    error "The disk is too small to fit a CLIP-GTW system"
	fi
	;;

    bare)
	CLIP_JAILS=""
	RM_NUM=0
	EMPTY_RM_NUM=2
	HOME_CYLS=$BARE_HOME_CYLS
        NEEDED_CYLS=$(( $BOOT_CYLS + $HOME_CYLS + $SWAP_CYLS + 2*$ROOT_CYLS + 2*$MOUNTS_CYLS + 4*$EMPTY_CYLS ))
	LOGS_CYLS=$(( $N_CYLINDERS - $NEEDED_CYLS ))

	if [[ $LOGS_CYLS -ge $BARE_LOGS_MINCYLS ]]; then
	    echo_table
	else
	    error "The disk is too small to fit a CLIP-BARE system"
	fi
	;;

    *)
	error "Not a valid clip distribution : ${CLIP_TYPE}"
	;;
   
esac
