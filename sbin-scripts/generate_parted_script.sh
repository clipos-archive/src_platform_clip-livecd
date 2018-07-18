#!/bin/bash -e
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

# Copyright (C) 2015 SGDSN/ANSSI
#
# generate_parted_script.sh propose a way to partition a clip distribution
# by generating a script that uses parted
#
# CLIP_TYPE and CLIP_JAILS have to be set in its environment
#
# It uses some functions from compute_size.sh original script, but intend to
# replace it

export LC_ALL="C"

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

get_secs_per_track() {
  local geometry=${1}

  echo $(echo $geometry1 | sed 's/^.*[^0-9]\([0-9]\+\) sectors\/track.*$/\1/')
}

get_heads() {
  local geometry=${1}

  echo bonjour
}


check_geometry() {
  # TODO :)
  echo "yet to implement"
  #local disk1=${1}
  #local disk2=${2}

  #local geometry1=$(sfdisk -V -q -g ${disk1})
  #local geometry2=$(sfdisk -V -q -g ${disk2})

  #local secs_per_track1=$(get_secs_per_track ${geometry1})
  #local secs_per_track2=$(get_secs_per_track ${geometry2})
}

ext_line() {
  local disk=${1}
  echo "parted -a optimal --script ${disk} -- mkpart extended ${START}MiB 100%"
}

part_gpt_line() {
  local size=${1}
  local id=${2}
  local name=${3}
  local disk=${4}

  local -i end=$(( ${START} + ${size} ))

  echo "parted -a optimal --script ${disk} -- mkpart ${name}  ${id} ${START}MiB ${end}MiB"

  START=${end}
}

part_primary_mbr_line() {
  local size=${1}
  local id=${2}
  local disk=${3}

  local -i end=$(( ${START} + ${size} ))

  echo "parted -a optimal --script ${disk} -- mkpart primary ${id} ${START}MiB ${end}MiB"

  START=${end}
}

part_extended_mbr_line() {
  local size=${1}
  local id=${2}
  local disk=${3}

  local -i end=$(( ${START} + ${size} ))

  # TODO: ok, this +1 thing just looks like cheating. However, I do not know
  # how to make this work without it
  echo "parted -a optimal --script ${disk} -- mkpart logical ${id} $(( 1 + ${START} ))MiB ${end}MiB"

  START=${end}
}

declare DISK1=${1}
declare DISK2=${2}
declare RAIDE_ENABLED="no"

if [[ ! -z ${DISK2} ]]
then
  # TODO check geometry
  RAID_ENABLED="yes"

  check_geometry ${DISK1} ${DISK2}
fi

declare -i START=1
declare -i AVAILABLE_SPACE=$(( $(parted ${DISK1} unit MiB print \
  | grep "Disk ${DISK1}" | sed 's/^.*: \([0-9]\+\)MiB.*/\1/') - 1))
declare -i MIN_SPACE
declare -i NEEDED_SPACE=0
declare -i MAX_LEVEL=2
declare -i USED_LEVEL=0
declare -i UNUSED_LEVEL=$(( ${MAX_LEVEL}-${USED_LEVEL} ))
declare DEFAULT_JAILS="rm_b rm_h"
declare DEFAULT_TYPE="rm"

declare -A BOOT_PARTITION
declare -A HOME_PARTITION
declare -A LOG_PARTITION
declare -A CLIP_PARTITION
declare -A CLIP_MOUNTS_PARTITION
declare -A RM_PARTITION
declare -A DUMMY_PARTITION
declare -A SWAP_PARTITION

declare ID_BOOT
declare ID_LINUX
declare ID_SWAP

if [[ ${RAID_ENABLED} = "yes" ]]
then
  echo RAID
fi

# init PARTITION variable (no condition)
BOOT_PARTITION=( ["size"]=128 \
                 ["mbr_type"]="ext3" \
                 ["gpt_type"]="fat32" )

CLIP_PARTITION=( ["size"]=2000 \
                 ["mbr_type"]="ext4" \
                 ["gpt_type"]="ext4" )

CLIP_MOUNTS_PARTITION=( ["size"]=4000 \
                        ["mbr_type"]="ext4" \
                        ["gpt_type"]="ext4" )

SWAP_PARTITION=( ["size"]=2000 \
                 ["mbr_type"]="linux-swap" \
                 ["gpt_type"]="linux-swap" )

RM_PARTITION=( ["size"]=12000 \
               ["mbr_type"]="ext4" \
               ["gpt_type"]="ext4" )

DUMMY_PARTITION=( ["size"]=16 \
                  ["mbr_type"]="ext4" \
                  ["gpt_type"]="ext4" )
                                       
LOG_PARTITION["mbr_type"]="ext4"
HOME_PARTITION["mbr_type"]="ext4"

LOG_PARTITION["gpt_type"]="ext4"
HOME_PARTITION["gpt_type"]="ext4"

[[ -z ${CLIP_TYPE} ]]  && CLIP_TYPE=${DEFAULT_TYPE}

case ${CLIP_TYPE} in
  rm)
    LOG_PARTITION["size"]=2000
    HOME_PARTITION["size"]=10000

    [[ -z ${CLIP_JAILS} ]] && CLIP_JAILS=${DEFAULT_JAILS}

    USED_LEVEL=$(echo "${CLIP_JAILS}" | wc -w)
    UNUSED_LEVEL=$(( ${MAX_LEVEL} - ${USED_LEVEL} ))
    ;;
  gtw)
    LOG_PARTITION["size"]=4000
    HOME_PARTITION["size"]=1000

    CLIP_JAILS=""
    ;;
  bare)
    LOG_PARTITION["size"]=2000
    HOME_PARTITION["size"]=100
    SWAP_PARTITION["size"]=1000 
    CLIP_MOUNTS_PARTITION["size"]=400
    CLIP_JAILS=""
    ;;
esac

if [[ ! -z ${KEEP_DATA} ]]; then
	# change sizes according to existing home
	home_partition=$(parted -s -m ${DISK1} unit MiB print | grep '^2')
	tmp=$(echo $home_partition | cut -d ':' -f 4)
	HOME_PARTITION["size"]=${tmp%MiB}
	tmp=$(echo $home_partition | cut -d ':' -f 3)
	HOME_PARTITION["end"]=${tmp%MiB}
	tmp=$(echo $home_partition | cut -d ':' -f 2)
	BOOT_PARTITION["size"]="$(( ${tmp%MiB} - 2 ))"
fi

# check size
USED_SPACE=$(( 1 + ${BOOT_PARTITION["size"]} + ${HOME_PARTITION["size"]} \
            + ${LOG_PARTITION["size"]} + 2*${CLIP_PARTITION["size"]} \
            + 2*${CLIP_MOUNTS_PARTITION["size"]} \
            + ${USED_LEVEL}*${RM_PARTITION["size"]} \
            + ${SWAP_PARTITION["size"]} \
            + ${UNUSED_LEVEL}*${DUMMY_PARTITION["size"]}))

if [[ ! -z ${UEFI} ]]; then
  # dummy partition in order to align mbr and gpt tables
  USED_SPACE=$(( ${USED_SPACE} + ${DUMMY_PARTITION["size"]} )) 
fi

[[ ${AVAILABLE_SPACE} -le ${USED_SPACE} ]] && error "Not enough space in ${DISK1} for clip ${CLIP_TYPE}"

FREE_SPACE=$(( ${AVAILABLE_SPACE} - ${USED_SPACE} ))

# expands
case ${CLIP_TYPE} in
  rm)
    # expands home
    HOME_PARTITION["size"]=$(( ${HOME_PARTITION["size"]} + ${FREE_SPACE} ))
    ;;
  *)
    # expands log
    LOG_PARTITION["size"]=$(( ${LOG_PARTITION["size"]} + ${FREE_SPACE} ))
    ;;
esac

START=1

clean_partitions() {
	local disk=${1}
	local old_partitions=$(ls ${disk}?)
	echo "Delete old partitions"
	for part in $old_partitions; do
		[ ${part#${disk}} -eq 2 ] || echo "parted --script ${disk} -- rm ${part#${disk}}"
	done
}

parted_gpt() {
  local disk=${1}

  local jails=(${CLIP_JAILS// / })
  if [ -z "${KEEP_DATA}" ]; then
	  echo "# Table"
	  echo "parted --script ${disk} -- mktable gpt"
  else
	  clean_partitions ${disk}
  fi

  echo "# /boot"
  part_gpt_line "${BOOT_PARTITION["size"]}" \
                "${BOOT_PARTITION["gpt_type"]}"   \
                "/boot" \
                "${disk}"

  echo "parted --script ${disk} -- set 1 esp on"

  if [ -z "${KEEP_DATA}" ]; then
	  echo "# /home"
	  part_gpt_line "${HOME_PARTITION["size"]}" \
				"${HOME_PARTITION["gpt_type"]}"   \
				"/home" \
				"${disk}"
  else
	  START=$(( ${HOME_PARTITION["end"]} + 1 ))
  fi

  echo "# /log"
  part_gpt_line "${LOG_PARTITION["size"]}" \
            "${LOG_PARTITION["gpt_type"]}"   \
            "/log" \
            "${disk}"

  echo "#Dummy partition for alignment issue"
  part_gpt_line "${DUMMY_PARTITION["size"]}" \
            "${DUMMY_PARTITION["gpt_type"]}"   \
            "Dummy" \
            "${disk}"


  echo "# /clip1"
  part_gpt_line "${CLIP_PARTITION["size"]}" \
            "${CLIP_PARTITION["gpt_type"]}"   \
            "/clip1" \
            "${disk}"

  echo "# /clip1/mounts"
  part_gpt_line "${CLIP_MOUNTS_PARTITION["size"]}" \
            "${CLIP_MOUNTS_PARTITION["gpt_type"]}"   \
            "/clip1/mounts" \
            "${disk}"

  echo "# Jails partition"

  echo "# rm_h"
  jail_gpt_line "rm_h"

  echo "# rm_b"
  jail_gpt_line "rm_b"

  echo "# swap"
  part_gpt_line "${SWAP_PARTITION["size"]}" \
            "${SWAP_PARTITION["gpt_type"]}"   \
            "swap" \
            "${disk}"

  echo "# /clip2"
  part_gpt_line "${CLIP_PARTITION["size"]}" \
            "${CLIP_PARTITION["gpt_type"]}"   \
            "/clip2" \
            "${disk}"

  echo "# /clip2/mounts"
  part_gpt_line "${CLIP_MOUNTS_PARTITION["size"]}" \
            "${CLIP_MOUNTS_PARTITION["gpt_type"]}"   \
            "/clip2/mounts" \
            "${disk}"
}

jail_gpt_line () {
  local jail=${1}

  if echo "${CLIP_JAILS}" | grep -q ${jail}; then
    part_gpt_line "${RM_PARTITION["size"]}" \
              "${RM_PARTITION["gpt_type"]}"   \
              "${jails[$(( ${jail} - 1 ))]}" \
              "${disk}"
  else
    part_gpt_line "${DUMMY_PARTITION["size"]}" \
              "${DUMMY_PARTITION["gpt_type"]}"   \
              "Dummy" \
              "${disk}"
  fi
}

jail_mbr_line () {
  local jail=${1}

  if echo "${CLIP_JAILS}" | grep -q ${jail}; then
    part_extended_mbr_line "${RM_PARTITION["size"]}" \
                      "${RM_PARTITION["mbr_type"]}"   \
                      "${disk}"
  else
    part_extended_mbr_line "${DUMMY_PARTITION["size"]}" \
                      "${DUMMY_PARTITION["mbr_type"]}"   \
                      "${disk}"
  fi
}

parted_mbr() {
  local disk=${1}

  local jails=(${CLIP_JAILS// / })
  if [ -z "${KEEP_DATA}" ]; then
	  echo "# Table"
	  echo "parted --script ${disk} -- mktable msdos"
  else
	  clean_partitions ${disk}
  fi

  echo "# /boot"
  part_primary_mbr_line "${BOOT_PARTITION["size"]}" \
            "${BOOT_PARTITION["mbr_type"]}"   \
            "${disk}"

  echo "parted --script ${disk} -- set 1 boot on"

  if [ -z "${KEEP_DATA}" ]; then
	  echo "# /home"
	  part_primary_mbr_line "${HOME_PARTITION["size"]}" \
				"${HOME_PARTITION["mbr_type"]}"   \
				"${disk}"
  else
	  START=${HOME_PARTITION["end"]}
  fi

  echo "# /log"
  part_primary_mbr_line "${LOG_PARTITION["size"]}" \
            "${LOG_PARTITION["mbr_type"]}"   \
            "${disk}"

  echo "# Extended partition"
  ext_line ${disk}


  echo "# /clip1"
  part_extended_mbr_line "${CLIP_PARTITION["size"]}" \
            "${CLIP_PARTITION["mbr_type"]}"   \
            "${disk}"

  echo "# /clip1/mounts"
  part_extended_mbr_line "${CLIP_MOUNTS_PARTITION["size"]}" \
                    "${CLIP_MOUNTS_PARTITION["mbr_type"]}"   \
                    "${disk}"

  echo "# Jails"

  echo "# rm_h"
  jail_mbr_line "rm_h"

  echo "# rm_b"
  jail_mbr_line "rm_b"

  echo "# swap"
  part_extended_mbr_line "${SWAP_PARTITION["size"]}" \
                    "${SWAP_PARTITION["mbr_type"]}"   \
                    "${disk}"

  echo "# /clip2"
  part_extended_mbr_line "${CLIP_PARTITION["size"]}" \
                    "${CLIP_PARTITION["mbr_type"]}"   \
                    "${disk}"

  echo "# /clip2/mounts"
  part_extended_mbr_line "${CLIP_MOUNTS_PARTITION["size"]}" \
                    "${CLIP_MOUNTS_PARTITION["mbr_type"]}"   \
                    "${disk}"
}

if [[ ! -z ${UEFI} ]]; then
  parted_gpt ${DISK1}
else
  parted_mbr ${DISK1}
fi

echo "sync"
echo "partprobe"
