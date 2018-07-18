#!/bin/sh
# SPDX-License-Identifier: LGPL-2.1-or-later
# Copyright © 2008-2018 ANSSI. All Rights Reserved.

# Copyright (C) 2008 SGDN/DCSSI
# Copyright (C) 2010-2011 SGDSN/ANSSI
# Authors: Olivier Levillain <clipos@ssi.gouv.fr>
#          Vincent Strubel <clipos@ssi.gouv.fr>
#          Mickaël Salaün <clipos@ssi.gouv.fr>
# All rights reserved


if [[ -e "/lib/rc/sh/functions.sh" ]]; then
	source "/lib/rc/sh/functions.sh" # openRC
else
	source "/sbin/functions.sh"
fi

. /etc/clip-build.conf

usage() {
  echo "Usage: $0 [ -r <repository> -s <subrepository> | -p <pkgdir> ] -R <repodir> -d <debname> -D <distrib> [-t <tag>] [-e <extra>] [-c <cache>] ... [-C <confname>] [-a]" > /dev/stderr
  echo > /dev/stderr
  echo "For example, repository=https://svn.clip:20443/svn" > /dev/stderr
  echo "             subrepository=clip4-rm-dpkg" > /dev/stderr
  echo "             pkgdir=/home/user/clip-pkg" > /dev/stderr
  echo "             repodir=/opt/clip-livecd/mirrors/clip4-rm-dpkg" > /dev/stderr
  echo "             debname=rm-apps-conf_3.0.7_i386.deb" > /dev/stderr
  echo "             distrib=clip" > /dev/stderr
  echo "             tag=CLIP_V04.00.12" > /dev/stderr
  echo "             extra=./extra-pkg-list.txt" > /dev/stderr
  echo "             cache=/opt/clip-livecd/cache" > /dev/stderr
  echo "             confname=rm-apps-conf" > /dev/stderr
  echo "             -a : to recompile missing deb packages" > /dev/stderr
  exit 1
}

CACHE=""
DO_COMPILE="0"
while getopts r:s:p:R:d:D:t:e:c:C:a arg; do
	case "${arg}" in
		r)
			REPOSITORY="${OPTARG}"
			;;
		s)
			SUBREPOSITORY="${OPTARG}"
			;;
		p)
			PKGDIR="${OPTARG}"
			;;
		R)
			REPODIR="${OPTARG}"
			;;
		d)
			DEBNAME="${OPTARG}"
			;;
		D)
			DISTRIB="${OPTARG}"
			;;
		t)
			TAG="${OPTARG}"
			;;
		e)
			EXTRA="${OPTARG}"
			;;
		c)
			CACHE="${CACHE} ${OPTARG}"
			;;
		C)
			CONFNAME="${OPTARG}"
			;;
		a)	DO_COMPILE="1"
			;;
		*)
			usage
			;;
	esac
done

[[ -n "${REPODIR}" ]] || usage
[[ -n "${DEBNAME}" ]] || usage
ARCH="${DEBNAME/#*_/}"
ARCH="${ARCH/%.deb}"
VERSION="${DEBNAME/%_${ARCH}.deb/}"
VERSION="${VERSION/#*_/}"
[[ -n "${DISTRIB}" ]] || usage
for d in ${CACHE}; do
	[[ -d "$d" ]] || usage
done
[[ -n "${CONFNAME}" ]] || CONFNAME="${DEBNAME/_*_*.deb/}"
[[ -n "${VERSION}" ]] || usage
MISSING=""

if [[ -n "${PKGDIR}" ]]; then
	if [[ -n "${TAG}" ]]; then
		eerror "Cannot use pkgdir with a tag"
		exit 1
	elif [[ -n "${REPOSITORY}" ]] || [[ -n "${SUBREPOSITORY}" ]]; then
		eerror "Cannot use pkgdir with a repository"
		exit 1
	fi
	IMPORTDIR="${PKGDIR}"
else
	[[ -n "${REPOSITORY}" ]] || usage
	[[ -n "${SUBREPOSITORY}" ]] || usage
	if [[ -n "${TAG}" ]]; then
		IMPORTDIR="${REPOSITORY}/${SUBREPOSITORY}/tags/${TAG}/${DISTRIB}"
	else
		IMPORTDIR="${REPOSITORY}/${SUBREPOSITORY}/pkg/${DISTRIB}"
	fi
fi

deb2ebuild() {
        local deb="$(basename "$1")"
        local name="${deb/_*_*.deb/}"
        find "${CLIP_BASE}/"portage* -maxdepth 2 -mindepth 2 -type d -name "${name}" | while read dir; do
                echo -n "$(echo "${dir}" | sed -r 's,^.*/(.+/.+)$,\1,') "
        done
}

cp_repo() {
	local name="$1"
	local src="${IMPORTDIR}/${name}"
	local dst="$2"
	ewarn "repo: ${name}"
	if [[ -z "${src/#http*/}" ]]; then
		svn export "${src}" ${dst} >/dev/null
	else
		rsync --times -- "${src}" "${dst}" 2>/dev/null
	fi
	return $?
}

in_cache() {
	local pattern="$1"
	for d in ${CACHE}; do
		[[ "$(find -L "${d}" -maxdepth 1 -type f -name "${pattern}" | wc -l)" -gt 0 ]] && return 0
	done
	return 1
}

cp_cache() {
	local fname="$1"
	local dst="$2"
	for d in ${CACHE}; do
		if [[ -f "${d}/${fname}" ]]; then
			einfo "cache: ${fname}"
			rsync --times -- "${d}/${fname}" "${dst}"
			return $?
		fi
	done
	return 1
}

rm_local() {
	local pattern="$1"
	find -L "${REPODIR}/${DISTRIB}/${CONFNAME}" -type f -name "${pattern}" -exec rm -f {} \;
}

einfo "Building mirror for ${HILITE}${DEBNAME}${NORMAL} ${VERSION}"
eindent
mkdir -p "${REPODIR}/${DISTRIB}/${CONFNAME}/pool"
mkdir -p "${REPODIR}/${DISTRIB}/${CONFNAME}/dists/${DISTRIB}/main/binary-${ARCH}"

DEBNAME_FOR_MISSING="${DEBNAME}"
MISSING_DEBS=""

ROOTS="${DEBNAME}"
if [[ -n "${EXTRA}" && -f "${EXTRA}" ]]; then
	ROOTS="${ROOTS} $(cat "${EXTRA}")"
fi

for DEBNAME in ${ROOTS} ; do
	DEBCONF="$(basename "${DEBNAME/%_*_*.deb/}")"
	rm_local "${DEBCONF}_*_*.deb"

	if in_cache "${DEBNAME}"; then
		cp_cache "${DEBNAME}" . > /dev/null
	else
		cp_repo "${DEBNAME}" .
		if [[ $? -ne 0 ]]; then
			eend 1
			exit 1
		fi
	fi

	dpackages=`dpkg-deb -f ${DEBNAME} depends | tr "," "\n" | sed "s|\([^ ]*\) (= \(.*\))|\1_\2_${ARCH}.deb|"`
	dsuggests=`dpkg-deb -f ${DEBNAME} suggests | tr "," "\n" | sed "s|\([^ ]*\) (= \(.*\))|\1_\2_${ARCH}.deb|"`
	packages="${packages} ${DEBNAME} ${dpackages} ${dsuggests}"
	mv "${DEBNAME}" "${REPODIR}/${DISTRIB}/${CONFNAME}/pool/"
done


for pkgname in ${packages}; do
	pkgtmpl="$(basename "${pkgname/%_*_*.deb/}")_*_*.deb"
	if ! in_cache "${pkgname}" && in_cache "${pkgtmpl}"; then
		eerror "diff: ${pkgname/%_*_*.deb/} -> looking for ${pkgname}"
	fi
	if in_cache "${pkgname}"; then
		rm_local "${pkgtmpl}"
		cp_cache "${pkgname}" "${REPODIR}/${DISTRIB}/${CONFNAME}/pool/${pkgname}"
	elif [[ ! -e "${REPODIR}/${DISTRIB}/${CONFNAME}/pool/${pkgname}" ]]; then
		rm_local "${pkgtmpl}"
		cp_repo "${pkgname}" "${REPODIR}/${DISTRIB}/${CONFNAME}/pool/${pkgname}"
		if [[ $? -ne 0 ]]; then
			MISSING_DEBS="${MISSING_DEBS} ${pkgname}"
			MISSING="${MISSING} $(deb2ebuild "${pkgname}")"
			eerror "missing: ${pkgname}"
		fi
	fi
done


# missing packages recompilation
if [[ ( ${DO_COMPILE} = "1" ) && ( ! -z ${MISSING} ) ]]; then
	einfo "Compile missing packages :"
	for pkgname in ${MISSING_DEBS}; do
		einfo "$pkgname"
	done

	clip-compile-from-debname  ${IMPORTDIR}/${DEBNAME_FOR_MISSING} "log_missing_build_$(date +%F-%T).txt" ${MISSING_DEBS}
	MISSING_DEBS_BACK=${MISSING_DEBS}
	MISSING=
	MISSING_DEBS=
	for pkgname in ${MISSING_DEBS_BACK}; do
		ls -al "${DEBS_BASE}/${DISTRIB}/$pkgname"
		rsync --times -- "${DEBS_BASE}/${DISTRIB}/$pkgname" "${REPODIR}/${DISTRIB}/${CONFNAME}/pool/${pkgname}"  2>/dev/null
		if [[ $? -ne 0 ]]; then
			MISSING_DEBS="${MISSING_DEBS} ${pkgname}"
			MISSING="${MISSING} $(deb2ebuild "${pkgname}")"
			eerror "missing: ${pkgname}"
		fi
	done
fi

if [[ -z "${MISSING}" ]]; then
	pushd "${REPODIR}/${DISTRIB}/${CONFNAME}" > /dev/null
	ebegin "Packages.gz construction"
	apt-ftparchive packages pool | gzip > "dists/${DISTRIB}/main/binary-${ARCH}/Packages.gz"
	RET=$?
	eend "${RET}"
	popd > /dev/null
else
	eerror "Missing packages:"
	eindent
	eerror "${MISSING_DEBS}"
	eoutdent
	RET=1
fi
eoutdent
exit "${RET}"
