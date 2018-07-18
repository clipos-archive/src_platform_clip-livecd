#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

# generate_key <key_size>
generate_key() {
    local size=${1}

    head -c ${size} /dev/random | sha256sum | awk '{print $1}'
}

# derive_key <primary_key> <iteration>
# /!\ this is a deterministic derivation process, so two successive
# identical calls give the same result. Therefore, be sure to give
# a different <iteration> argument to get two different keys.
derive_key() {
    local seed="${1}"
    local nth="${2}"

    echo "${seed}${nth}" | sha512sum | awk '{print $1}'
}

generate_escrow_name() {
    local dir="${1}"
    local base="${2}"
    local file="${3}"
    local escrow_file="${base}.${file}"
    local escrow_occ="$(find "${dir}" -name "${escrow_file}*" | wc -l)"

    printf "${dir}/${escrow_file}.${escrow_occ}"
}
