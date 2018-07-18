#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

error() {
  local ret="${1}"
  local msg="${2}"

  echo "${msg}"
  exit "${ret}"
}

success() {
  local msg="${1}"
  echo "[*] ${msg}"
}
verbose() {
  local msg="${1}"
  echo "    ${msg}"
}
error() {
  local msg="${1}"
  echo "[!] ${msg}"
}

usage() {
  echo "${PERSONNALITY} <command>"
}

tpm_init() {
  if [[ ! -f /etc/init.d/tcsd ]];
  then
    error "tcsd not found: you need to install tcsd"
    return 1
  fi

  if ! /etc/init.d/tcsd start; then
    error "tcsd start failed: you probably lack a TPM"
    return 1
  fi

  success "tcsd started: ready to go"
}

tpm_provision() {
  tpm_takeownership -yz
}

verbose "trying to start tcsd daemon"
if ! tpm_init; then
  error "tcsd daemon cannot be started: you cannot use CLIP-TPM"
  exit 1
fi

tpm_provision

verbose "releasing tpm"
/etc/init.d/tcsd stop || error "cannot release tpm"
