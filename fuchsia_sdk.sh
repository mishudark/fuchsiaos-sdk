#!/usr/bin/env bash
# Copyright 2019 Mishel Vera @mishudark <mishu.drk@gmail.com>

set -eo pipefail; [[ "${TRACE}" ]] && set -x

BAZEL_VERSION=0.22.0
SDK_DIR=${HOME}/sdk/fuchsia-bazel
ZSH_RC=$HOME/.zshrc

declare HOST_PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${HOST_PLATFORM}" in
	linux)
		OS=linux
		OS_CIPD=linux
		BASH_RC=$HOME/.bashrc
		;;
	darwin)
		OS=darwin
		OS_CIPD=mac
		BASH_RC=$HOME/.bash_profile
		;;
	*)
    echo "Unknown operating system." >&2
		exit 1
		;;
esac

function install_bazel() {
	echo "Checking Bazel version"
	if command -v bazel; then
		v=$(bazel version |grep label|awk '{ print $3 }')
		if [[ $v == $BAZEL_VERSION ]]; then
			return
		fi
	fi

	URL="https://releases.bazel.build/${BAZEL_VERSION}/release/bazel-${BAZEL_VERSION}-installer-${OS}-x86_64.sh"
	echo "Downloading Bazel ..."

	curl -SLo install.sh $URL
	chmod +x install.sh
	./install.sh --user
}

function export_bin(){
	# by default, add $HOME/bin to bash conf file
	grep -q "${HOME}/bin" $BASH_RC
	if [[ $? != 0 ]]; then
		echo "export PATH=\$PATH:${HOME}/bin" >> $BASH_RC
	fi

	# additional add $HOME/bin to zsh conf if it is present
	if [[ -f $ZSH_RC ]]; then
		grep -q "${HOME}/bin" $ZSH_RC
		if [[ $? != 0 ]]; then
			echo "export PATH=\$PATH:${HOME}/bin" >> $ZSH_RC
		fi
	fi
}

function create_cipd(){
	if [ -f cipd ]; then
		return
	fi

	echo "Creating cipd"

	cat << 'EOF' >> cipd
#!/usr/bin/env bash
# Copyright 2017 The Fuchsia Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -eo pipefail; [[ "${TRACE}" ]] && set -x

readonly SCRIPT_DIR="$(pwd)"

readonly VERSION_FILE="${SCRIPT_DIR}/.cipd_version"
readonly CIPD_BACKEND="https://chrome-infra-packages.appspot.com"

declare HOST_PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${HOST_PLATFORM}" in
	linux)
		readonly HOST_PLATFORM="linux"
		;;
	darwin)
		readonly HOST_PLATFORM="mac"
		;;
	*)
		echo "Unknown operating system." >&2
		exit 1
esac

HOST_ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"
case "${HOST_ARCH}" in
	x86_64|amd64)
		readonly HOST_ARCH="amd64"
		;;
	arm*)
		readonly HOST_ARCH="${HOST_ARCH}"
		;;
	aarch64)
		readonly HOST_ARCH="arm64"
		;;
	*86)
		readonly HOST_ARCH=386
		;;
	*)
		echo "Unknown machine architecture." >&2
		exit 1
esac

readonly PLATFORM="${HOST_PLATFORM}-${HOST_ARCH}"
readonly VERSION="$(cat ${VERSION_FILE})"
readonly URL="${CIPD_BACKEND}/client?platform=${PLATFORM}&version=${VERSION}"
readonly CLIENT="${SCRIPT_DIR}/.cipd_client"

readonly USER_AGENT="Mozilla/5.0 (iPhone; U; CPU iPhone OS 4_3_3 like Mac OS X; en-us) AppleWebKit/533.17.9 (KHTML, like Gecko) Version/5.0.2 Mobile/8J2 Safari/6533.18.5"

function actual_sha256() {
	if type shasum >/dev/null ; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		echo "The `shasum` command is missing. Please use your package manager to install it." >&2
		return 1
	fi
}

function expected_sha256() {
	local line
	while read -r line; do
		if [[ "${line}" =~ ^([0-9a-z\-]+)[[:blank:]]+sha256[[:blank:]]+([0-9a-f]+)$ ]] ; then
			local platform="${BASH_REMATCH[1]}"
			local hash="${BASH_REMATCH[2]}"
			if [[ "${platform}" ==  "$1" ]]; then
				echo "${hash}"
				return 0
			fi
		fi
	done < "${VERSION_FILE}.digests"

	echo "Platform $1 is not supported by the CIPD client bootstrap. There's no pinned hash for it in the *.digests file." >&2

	return 1
}

# bootstraps the client from scratch using 'curl'.
function bootstrap() {
	local expected_hash="$(expected_sha256 "${PLATFORM}")"
	if [[ -z "${expected_hash}" ]] ; then
		exit 1
	fi

	echo "Bootstrapping cipd client for ${HOST_PLATFORM}-${HOST_ARCH}..."
	local CLIENT_TMP="$(mktemp -p "${SCRIPT_DIR}" 2>/dev/null || mktemp "${SCRIPT_DIR}/.cipd_client.XXXXXXX")"
	if type curl >/dev/null ; then
		echo $URL
		curl -f --progress-bar "${URL}" -A "${USER_AGENT}"  -L -o "${CLIENT_TMP}"
	else
		echo "The `curl` command is missing. Please use your package manager to install it." >&2
		exit 1
	fi
	trap "rm -f '${CLIENT_TMP}'" EXIT ERR HUP INT TERM

	local actual_hash="$(actual_sha256 "${CLIENT_TMP}")"
	if [[ -z "${actual_hash}" ]] ; then
		exit 1
	fi

	if [[ "${actual_hash}" != "${expected_hash}" ]]; then
		echo "SHA256 digest of the downloaded CIPD client is incorrect. Check that *.digests file is up-to-date." >&2
		exit 1
	fi

	chmod +x "${CLIENT_TMP}"
	mv -f "${CLIENT_TMP}" "${CLIENT}"
	trap - EXIT
}

# self_update asks the existing client to update itself, if necessary.
function self_update() {
	"${CLIENT}" selfupdate -version-file "${VERSION_FILE}" -service-url "${CIPD_BACKEND}"
}

if [[ ! -x "${CLIENT}" ]]; then
	bootstrap
fi

export CIPD_HTTP_USER_AGENT_PREFIX="${USER_AGENT}"
if ! self_update ; then
	echo "CIPD selfupdate failed. Trying to bootstrap the CIPD client from scratch..." >&2
	bootstrap
	if ! self_update ; then  # we need to run it again to setup .cipd_version file
		echo "Bootstrap from scratch failed. Run `CIPD_HTTP_USER_AGENT_PREFIX=${USER_AGENT}/manual ${CLIENT} selfupdate -version-file '${VERSION_FILE}'` to diagnose if this is repeating." >&2
	fi
fi

exec "${CLIENT}" "${@}"
#!/usr/bin/env bash
# Copyright 2017 The Fuchsia Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -eo pipefail; [[ "${TRACE}" ]] && set -x

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly VERSION_FILE="${SCRIPT_DIR}/.cipd_version"
readonly CIPD_BACKEND="https://chrome-infra-packages.appspot.com"

declare HOST_PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${HOST_PLATFORM}" in
	linux)
		readonly HOST_PLATFORM="linux"
		;;
	darwin)
		readonly HOST_PLATFORM="mac"
		;;
	*)
		echo "Unknown operating system." >&2
		exit 1
esac

HOST_ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"
case "${HOST_ARCH}" in
	x86_64|amd64)
		readonly HOST_ARCH="amd64"
		;;
	arm*)
		readonly HOST_ARCH="${HOST_ARCH}"
		;;
	aarch64)
		readonly HOST_ARCH="arm64"
		;;
	*86)
		readonly HOST_ARCH=386
		;;
	*)
		echo "Unknown machine architecture." >&2
		exit 1
esac

readonly PLATFORM="${HOST_PLATFORM}-${HOST_ARCH}"
readonly VERSION="$(cat ${VERSION_FILE})"
readonly URL="${CIPD_BACKEND}/client?platform=${PLATFORM}&version=${VERSION}"
readonly CLIENT="${SCRIPT_DIR}/.cipd_client"

readonly USER_AGENT="buildtools/$(git -C ${SCRIPT_DIR} rev-parse HEAD 2>/dev/null || echo "???")"

function actual_sha256() {
	if type shasum >/dev/null ; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		echo "The `shasum` command is missing. Please use your package manager to install it." >&2
		return 1
	fi
}

function expected_sha256() {
	local line
	while read -r line; do
		if [[ "${line}" =~ ^([0-9a-z\-]+)[[:blank:]]+sha256[[:blank:]]+([0-9a-f]+)$ ]] ; then
			local platform="${BASH_REMATCH[1]}"
			local hash="${BASH_REMATCH[2]}"
			if [[ "${platform}" ==  "$1" ]]; then
				echo "${hash}"
				return 0
			fi
		fi
	done < "${VERSION_FILE}.digests"

	echo "Platform $1 is not supported by the CIPD client bootstrap. There's no pinned hash for it in the *.digests file." >&2

	return 1
}

# bootstraps the client from scratch using 'curl'.
function bootstrap() {
	local expected_hash="$(expected_sha256 "${PLATFORM}")"
	if [[ -z "${expected_hash}" ]] ; then
		exit 1
	fi

	echo "Bootstrapping cipd client for ${HOST_PLATFORM}-${HOST_ARCH}..."
	local CLIENT_TMP="$(mktemp -p "${SCRIPT_DIR}" 2>/dev/null || mktemp "${SCRIPT_DIR}/.cipd_client.XXXXXXX")"
	if type curl >/dev/null ; then
		curl -f --progress-bar "${URL}" -A "${USER_AGENT}"  -L -o "${CLIENT_TMP}"
	else
		echo "The `curl` command is missing. Please use your package manager to install it." >&2
		exit 1
	fi
	trap "rm -f '${CLIENT_TMP}'" EXIT ERR HUP INT TERM

	local actual_hash="$(actual_sha256 "${CLIENT_TMP}")"
	if [[ -z "${actual_hash}" ]] ; then
		exit 1
	fi

	if [[ "${actual_hash}" != "${expected_hash}" ]]; then
		echo "SHA256 digest of the downloaded CIPD client is incorrect. Check that *.digests file is up-to-date." >&2
		exit 1
	fi

	chmod +x "${CLIENT_TMP}"
	mv -f "${CLIENT_TMP}" "${CLIENT}"
	trap - EXIT
}

# self_update asks the existing client to update itself, if necessary.
function self_update() {
	"${CLIENT}" selfupdate -version-file "${VERSION_FILE}" -service-url "${CIPD_BACKEND}"
}

if [[ ! -x "${CLIENT}" ]]; then
	bootstrap
fi

export CIPD_HTTP_USER_AGENT_PREFIX="${USER_AGENT}"
if ! self_update ; then
	echo "CIPD selfupdate failed. Trying to bootstrap the CIPD client from scratch..." >&2
	bootstrap
	if ! self_update ; then  # we need to run it again to setup .cipd_version file
		echo "Bootstrap from scratch failed. Run `CIPD_HTTP_USER_AGENT_PREFIX=${USER_AGENT}/manual ${CLIENT} selfupdate -version-file '${VERSION_FILE}'` to diagnose if this is repeating." >&2
	fi
fi

exec "${CLIENT}" "${@}"
#!/usr/bin/env bash
# Copyright 2017 The Fuchsia Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -eo pipefail; [[ "${TRACE}" ]] && set -x

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly VERSION_FILE="${SCRIPT_DIR}/.cipd_version"
readonly CIPD_BACKEND="https://chrome-infra-packages.appspot.com"

declare HOST_PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${HOST_PLATFORM}" in
	linux)
		readonly HOST_PLATFORM="linux"
		;;
	darwin)
		readonly HOST_PLATFORM="mac"
		;;
	*)
		echo "Unknown operating system." >&2
		exit 1
esac

HOST_ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"
case "${HOST_ARCH}" in
	x86_64|amd64)
		readonly HOST_ARCH="amd64"
		;;
	arm*)
		readonly HOST_ARCH="${HOST_ARCH}"
		;;
	aarch64)
		readonly HOST_ARCH="arm64"
		;;
	*86)
		readonly HOST_ARCH=386
		;;
	*)
		echo "Unknown machine architecture." >&2
		exit 1
esac

readonly PLATFORM="${HOST_PLATFORM}-${HOST_ARCH}"
readonly VERSION="$(cat ${VERSION_FILE})"
readonly URL="${CIPD_BACKEND}/client?platform=${PLATFORM}&version=${VERSION}"
readonly CLIENT="${SCRIPT_DIR}/.cipd_client"

readonly USER_AGENT="buildtools/$(git -C ${SCRIPT_DIR} rev-parse HEAD 2>/dev/null || echo "???")"

function actual_sha256() {
	if type shasum >/dev/null ; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		echo "The `shasum` command is missing. Please use your package manager to install it." >&2
		return 1
	fi
}

function expected_sha256() {
	local line
	while read -r line; do
		if [[ "${line}" =~ ^([0-9a-z\-]+)[[:blank:]]+sha256[[:blank:]]+([0-9a-f]+)$ ]] ; then
			local platform="${BASH_REMATCH[1]}"
			local hash="${BASH_REMATCH[2]}"
			if [[ "${platform}" ==  "$1" ]]; then
				echo "${hash}"
				return 0
			fi
		fi
	done < "${VERSION_FILE}.digests"

	echo "Platform $1 is not supported by the CIPD client bootstrap. There's no pinned hash for it in the *.digests file." >&2

	return 1
}

# bootstraps the client from scratch using 'curl'.
function bootstrap() {
	local expected_hash="$(expected_sha256 "${PLATFORM}")"
	if [[ -z "${expected_hash}" ]] ; then
		exit 1
	fi

	echo "Bootstrapping cipd client for ${HOST_PLATFORM}-${HOST_ARCH}..."
	local CLIENT_TMP="$(mktemp -p "${SCRIPT_DIR}" 2>/dev/null || mktemp "${SCRIPT_DIR}/.cipd_client.XXXXXXX")"
	if type curl >/dev/null ; then
		curl -f --progress-bar "${URL}" -A "${USER_AGENT}"  -L -o "${CLIENT_TMP}"
	else
		echo "The `curl` command is missing. Please use your package manager to install it." >&2
		exit 1
	fi
	trap "rm -f '${CLIENT_TMP}'" EXIT ERR HUP INT TERM

	local actual_hash="$(actual_sha256 "${CLIENT_TMP}")"
	if [[ -z "${actual_hash}" ]] ; then
		exit 1
	fi

	if [[ "${actual_hash}" != "${expected_hash}" ]]; then
		echo "SHA256 digest of the downloaded CIPD client is incorrect. Check that *.digests file is up-to-date." >&2
		exit 1
	fi

	chmod +x "${CLIENT_TMP}"
	mv -f "${CLIENT_TMP}" "${CLIENT}"
	trap - EXIT
}

# self_update asks the existing client to update itself, if necessary.
function self_update() {
	"${CLIENT}" selfupdate -version-file "${VERSION_FILE}" -service-url "${CIPD_BACKEND}"
}

if [[ ! -x "${CLIENT}" ]]; then
	bootstrap
fi

export CIPD_HTTP_USER_AGENT_PREFIX="${USER_AGENT}"
if ! self_update ; then
	echo "CIPD selfupdate failed. Trying to bootstrap the CIPD client from scratch..." >&2
	bootstrap
	if ! self_update ; then  # we need to run it again to setup .cipd_version file
		echo "Bootstrap from scratch failed. Run `CIPD_HTTP_USER_AGENT_PREFIX=${USER_AGENT}/manual ${CLIENT} selfupdate -version-file '${VERSION_FILE}'` to diagnose if this is repeating." >&2
	fi
fi

exec "${CLIENT}" "${@}"
#!/usr/bin/env bash
# Copyright 2017 The Fuchsia Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -eo pipefail; [[ "${TRACE}" ]] && set -x

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly VERSION_FILE="${SCRIPT_DIR}/.cipd_version"
readonly CIPD_BACKEND="https://chrome-infra-packages.appspot.com"

declare HOST_PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${HOST_PLATFORM}" in
	linux)
		readonly HOST_PLATFORM="linux"
		;;
	darwin)
		readonly HOST_PLATFORM="mac"
		;;
	*)
		echo "Unknown operating system." >&2
		exit 1
esac

HOST_ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"
case "${HOST_ARCH}" in
	x86_64|amd64)
		readonly HOST_ARCH="amd64"
		;;
	arm*)
		readonly HOST_ARCH="${HOST_ARCH}"
		;;
	aarch64)
		readonly HOST_ARCH="arm64"
		;;
	*86)
		readonly HOST_ARCH=386
		;;
	*)
		echo "Unknown machine architecture." >&2
		exit 1
esac

readonly PLATFORM="${HOST_PLATFORM}-${HOST_ARCH}"
readonly VERSION="$(cat ${VERSION_FILE})"
readonly URL="${CIPD_BACKEND}/client?platform=${PLATFORM}&version=${VERSION}"
readonly CLIENT="${SCRIPT_DIR}/.cipd_client"

readonly USER_AGENT="buildtools/$(git -C ${SCRIPT_DIR} rev-parse HEAD 2>/dev/null || echo "???")"

function actual_sha256() {
	if type shasum >/dev/null ; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		echo "The `shasum` command is missing. Please use your package manager to install it." >&2
		return 1
	fi
}

function expected_sha256() {
	local line
	while read -r line; do
		if [[ "${line}" =~ ^([0-9a-z\-]+)[[:blank:]]+sha256[[:blank:]]+([0-9a-f]+)$ ]] ; then
			local platform="${BASH_REMATCH[1]}"
			local hash="${BASH_REMATCH[2]}"
			if [[ "${platform}" ==  "$1" ]]; then
				echo "${hash}"
				return 0
			fi
		fi
	done < "${VERSION_FILE}.digests"

	echo "Platform $1 is not supported by the CIPD client bootstrap. There's no pinned hash for it in the *.digests file." >&2

	return 1
}

# bootstraps the client from scratch using 'curl'.
function bootstrap() {
	local expected_hash="$(expected_sha256 "${PLATFORM}")"
	if [[ -z "${expected_hash}" ]] ; then
		exit 1
	fi

	echo "Bootstrapping cipd client for ${HOST_PLATFORM}-${HOST_ARCH}..."
	local CLIENT_TMP="$(mktemp -p "${SCRIPT_DIR}" 2>/dev/null || mktemp "${SCRIPT_DIR}/.cipd_client.XXXXXXX")"
	if type curl >/dev/null ; then
		curl -f --progress-bar "${URL}" -A "${USER_AGENT}"  -L -o "${CLIENT_TMP}"
	else
		echo "The `curl` command is missing. Please use your package manager to install it." >&2
		exit 1
	fi
	trap "rm -f '${CLIENT_TMP}'" EXIT ERR HUP INT TERM

	local actual_hash="$(actual_sha256 "${CLIENT_TMP}")"
	if [[ -z "${actual_hash}" ]] ; then
		exit 1
	fi

	if [[ "${actual_hash}" != "${expected_hash}" ]]; then
		echo "SHA256 digest of the downloaded CIPD client is incorrect. Check that *.digests file is up-to-date." >&2
		exit 1
	fi

	chmod +x "${CLIENT_TMP}"
	mv -f "${CLIENT_TMP}" "${CLIENT}"
	trap - EXIT
}

# self_update asks the existing client to update itself, if necessary.
function self_update() {
	"${CLIENT}" selfupdate -version-file "${VERSION_FILE}" -service-url "${CIPD_BACKEND}"
}

if [[ ! -x "${CLIENT}" ]]; then
	bootstrap
fi

export CIPD_HTTP_USER_AGENT_PREFIX="${USER_AGENT}"
if ! self_update ; then
	echo "CIPD selfupdate failed. Trying to bootstrap the CIPD client from scratch..." >&2
	bootstrap
	if ! self_update ; then  # we need to run it again to setup .cipd_version file
		echo "Bootstrap from scratch failed. Run `CIPD_HTTP_USER_AGENT_PREFIX=${USER_AGENT}/manual ${CLIENT} selfupdate -version-file '${VERSION_FILE}'` to diagnose if this is repeating." >&2
	fi
fi

exec "${CLIENT}" "${@}"
#!/usr/bin/env bash
# Copyright 2017 The Fuchsia Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

set -eo pipefail; [[ "${TRACE}" ]] && set -x

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly VERSION_FILE="${SCRIPT_DIR}/.cipd_version"
readonly CIPD_BACKEND="https://chrome-infra-packages.appspot.com"

declare HOST_PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${HOST_PLATFORM}" in
	linux)
		readonly HOST_PLATFORM="linux"
		;;
	darwin)
		readonly HOST_PLATFORM="mac"
		;;
	*)
		echo "Unknown operating system." >&2
		exit 1
esac

HOST_ARCH="$(uname -m | tr '[:upper:]' '[:lower:]')"
case "${HOST_ARCH}" in
	x86_64|amd64)
		readonly HOST_ARCH="amd64"
		;;
	arm*)
		readonly HOST_ARCH="${HOST_ARCH}"
		;;
	aarch64)
		readonly HOST_ARCH="arm64"
		;;
	*86)
		readonly HOST_ARCH=386
		;;
	*)
		echo "Unknown machine architecture." >&2
		exit 1
esac

readonly PLATFORM="${HOST_PLATFORM}-${HOST_ARCH}"
readonly VERSION="$(cat ${VERSION_FILE})"
readonly URL="${CIPD_BACKEND}/client?platform=${PLATFORM}&version=${VERSION}"
readonly CLIENT="${SCRIPT_DIR}/.cipd_client"

readonly USER_AGENT="buildtools/$(git -C ${SCRIPT_DIR} rev-parse HEAD 2>/dev/null || echo "???")"

function actual_sha256() {
	if type shasum >/dev/null ; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		echo "The `shasum` command is missing. Please use your package manager to install it." >&2
		return 1
	fi
}

function expected_sha256() {
	local line
	while read -r line; do
		if [[ "${line}" =~ ^([0-9a-z\-]+)[[:blank:]]+sha256[[:blank:]]+([0-9a-f]+)$ ]] ; then
			local platform="${BASH_REMATCH[1]}"
			local hash="${BASH_REMATCH[2]}"
			if [[ "${platform}" ==  "$1" ]]; then
				echo "${hash}"
				return 0
			fi
		fi
	done < "${VERSION_FILE}.digests"

	echo "Platform $1 is not supported by the CIPD client bootstrap. There's no pinned hash for it in the *.digests file." >&2

	return 1
}

# bootstraps the client from scratch using 'curl'.
function bootstrap() {
	local expected_hash="$(expected_sha256 "${PLATFORM}")"
	if [[ -z "${expected_hash}" ]] ; then
		exit 1
	fi

	echo "Bootstrapping cipd client for ${HOST_PLATFORM}-${HOST_ARCH}..."
	local CLIENT_TMP="$(mktemp -p "${SCRIPT_DIR}" 2>/dev/null || mktemp "${SCRIPT_DIR}/.cipd_client.XXXXXXX")"
	if type curl >/dev/null ; then
		curl -f --progress-bar "${URL}" -A "${USER_AGENT}"  -L -o "${CLIENT_TMP}"
	else
		echo "The `curl` command is missing. Please use your package manager to install it." >&2
		exit 1
	fi
	trap "rm -f '${CLIENT_TMP}'" EXIT ERR HUP INT TERM

	local actual_hash="$(actual_sha256 "${CLIENT_TMP}")"
	if [[ -z "${actual_hash}" ]] ; then
		exit 1
	fi

	if [[ "${actual_hash}" != "${expected_hash}" ]]; then
		echo "SHA256 digest of the downloaded CIPD client is incorrect. Check that *.digests file is up-to-date." >&2
		exit 1
	fi

	chmod +x "${CLIENT_TMP}"
	mv -f "${CLIENT_TMP}" "${CLIENT}"
	trap - EXIT
}

# self_update asks the existing client to update itself, if necessary.
function self_update() {
	"${CLIENT}" selfupdate -version-file "${VERSION_FILE}" -service-url "${CIPD_BACKEND}"
}

if [[ ! -x "${CLIENT}" ]]; then
	bootstrap
fi

export CIPD_HTTP_USER_AGENT_PREFIX="${USER_AGENT}"
if ! self_update ; then
	echo "CIPD selfupdate failed. Trying to bootstrap the CIPD client from scratch..." >&2
	bootstrap
	if ! self_update ; then  # we need to run it again to setup .cipd_version file
		echo "Bootstrap from scratch failed. Run `CIPD_HTTP_USER_AGENT_PREFIX=${USER_AGENT}/manual ${CLIENT} selfupdate -version-file '${VERSION_FILE}'` to diagnose if this is repeating." >&2
	fi
fi

exec "${CLIENT}" "${@}"
EOF
}

function setup_cipd(){
	if [ -f .cipd_version ]; then
		return
	fi

	cat << EOF >> .cipd_version
git_revision:03c4e813e09a23cd7004aca03aba32ad546d9202
EOF


	cat << EOF >> .cipd_version.digests
# This file was generated by
#
#  cipd selfupdate-roll -version-file .cipd_version \
#      -version git_revision:03c4e813e09a23cd7004aca03aba32ad546d9202
#
# Do not modify manually. All changes will be overwritten.
# Use 'cipd selfupdate-roll ...' to modify.

linux-386       sha256  714bea642415e1c175eddce505e019a704a4f2acc1a21afa140d6318fb8d0401
linux-amd64     sha256  8b2ce92994355c61e3693ccfd4f598b3cca685a1fa309051b871557d30d98da1
linux-arm64     sha256  51ad96a8a31d6817a1fe9cfaaef39aa17ac50b426c9df5dc59138e9a8d571566
linux-armv6l    sha256  fb7a3cd208f934b7d155db81ea54f3ea66512aafd6bc76d8930eb8750d1b8c52
linux-mips64    sha256  ef5bb7d096822059b0f93dfb1d27156f44f201e5c96b577f8768e86dd71432b6
linux-mips64le  sha256  6a7e8dd559db2e3c5e816874051f5c7191711f2d795eee7f832a721ae0db8315
linux-mipsle    sha256  8a33ca853ce7ce9da0e9e2884e1ed3c8cea22c315a5c2ef53c8b40309e1cc5ab
linux-ppc64     sha256  95213f2c5ed6048bd3cef026356f2eec13dfb1a26823b945bfef1c5bd6ece855
linux-ppc64le   sha256  96548353376c97885ac6de2761dd9c9b4aee0a7b2a34ea056ba0a0f509be65be
linux-s390x     sha256  0fc9d2f9324338122a22c7085e93bfee9a242d64fe95a0bd36a01818f39126b5
mac-amd64       sha256  17671867253317f33af6363440a2cb0d881fe12ed6d24956d56322a38cfbdaae
windows-386     sha256  2261420498cf0bf71a9f8e03a54f0e08033151d6f5f81d779aa78e553b586234
windows-amd64   sha256  f7a3269f4d18c902f8a9b0954f4090d46f5c4f271381c3e563c5109043d552bb
EOF

chmod +x cipd
}

function install_sdk(){
	echo "Installing SDK..."
	./cipd install fuchsia/sdk/bazel/${OS_CIPD}-amd64 latest -root ${SDK_DIR}
}

function workspace() {
	chmod +w $SDK_DIR/WORKSPACE
	cat << EOF > $SDK_DIR/WORKSPACE
# Copyright 2018 The Fuchsia Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.
load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")

local_repository(
  name = "fuchsia_sdk",
  path = "./",
)


load("@fuchsia_sdk//build_defs:fuchsia_setup.bzl", "fuchsia_setup")
fuchsia_setup(with_toolchain = True)

http_archive(
    name = "io_bazel_rules_dart",
    url = "https://github.com/dart-lang/rules_dart/archive/master.zip",
    strip_prefix = "rules_dart-master",
)

load("@io_bazel_rules_dart//dart/build_rules:repositories.bzl", "dart_repositories")
dart_repositories()

load("@fuchsia_sdk//build_defs:setup_dart.bzl", "setup_dart")
setup_dart()

load("@fuchsia_sdk//build_defs:setup_flutter.bzl", "setup_flutter")
setup_flutter()
EOF
}

function bazelrc(){
	cat << EOF > $SDK_DIR/.bazelrc
build:fuchsia --crosstool_top=@fuchsia_crosstool//:toolchain
build:fuchsia --cpu=x86_64
build:fuchsia --host_crosstool_top=@bazel_tools//tools/cpp:toolchain
EOF
}

function flutter_app(){
	if [[ -f ${SDK_DIR}/flutter ]]; then
		return
	fi

	echo "Creating demo flutter app ..."
	curl -SLo ${SDK_DIR}/flutter_app.tar.gz	https://github.com/mishudark/fuchsiaos-sdk/releases/download/0.1.0/flutter_app.tar.gz
	cd $SDK_DIR
	tar -xzvf flutter_app.tar.gz
	rm flutter_app.tar.gz
}

install_bazel
export_bin
clear
create_cipd
setup_cipd
install_sdk
workspace
bazelrc
flutter_app
clear

echo "FuchsiaOS SDK has been installed"
echo "cd $SDK_DIR"
echo ""
echo "Try to compile an app"
echo "    bazel build //flutter:package --config=fuchsia"
