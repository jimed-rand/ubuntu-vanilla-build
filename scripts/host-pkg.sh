#!/bin/bash
# host-pkg.sh -- host (build-time, outside the chroot) package-management
# abstraction shared by every build-*.sh script.
#
# This file is meant to be sourced, never executed. It depends on `host_priv`
# (a tiny "sudo when not root, direct exec when root" wrapper) being defined
# in the caller. The caller is also expected to invoke `host_pkg_detect`
# before any code path that touches host-side package management
# (typically right at the top of host_main()).
#
# The chroot is always Ubuntu/Debian, so every apt-get call inside the
# chroot pipeline stays as-is. This abstraction only covers commands that
# run on the host *before* the chroot exists (setup_host's install of
# debootstrap / squashfs-tools / xorriso / parted / etc., plus the
# skip-if-installed check that guards it).
#
# Three host families are supported:
#   deb   - Ubuntu / Debian and derivatives (uses apt + dpkg)
#   rpm   - openSUSE (Tumbleweed / Slowroll) and SUSE derivatives (uses zypper + rpm)
#   arch  - Arch Linux and derivatives (uses pacman)
#
# Everything else calls host_pkg_install() / host_pkg_is_installed() with
# the *canonical* (Debian-style) name; this layer translates it to the
# host's package name and runs the host's package manager.
# ---------------------------------------------------------------------------
HOST_PKG_FAMILY=""
HOST_PKG_MANAGER=""   # user-facing tool name: apt / zypper / pacman
HOST_INSTALL_CMD=()   # array form of the install command (without pkgs)
HOST_REFRESH_CMD=()   # array form of the DB-refresh command

# Per-family overrides for the host's package name. The key is
# 'canonical:family' (e.g. 'xorriso:arch'); the value is the host's
# package name on that family. Anything not listed here uses the
# canonical (Debian-style) name as-is, which is the right answer for
# most tools (debootstrap, parted, dosfstools, e2fsprogs, rsync, etc.).
declare -gA HOST_PKG_NAME=(
    [squashfs-tools:rpm]=squashfs        # openSUSE: 'squashfs'
    [xorriso:arch]=libisoburn            # Arch: xorriso binary ships in libisoburn
    [qemu-utils:rpm]=qemu-tools          # openSUSE: 'qemu-tools'
    [qemu-utils:arch]=qemu-img           # Arch: 'qemu-img'
)

# Lookup the host package name for a canonical (Debian) name on the current
# host family. Falls back to the canonical name if no override is set.
function host_pkg_name() {
    local canonical="$1"
    local key="${canonical}:${HOST_PKG_FAMILY}"
    if [[ -n "${HOST_PKG_NAME[$key]:-}" ]]; then
        echo "${HOST_PKG_NAME[$key]}"
        return
    fi
    echo "$canonical"
}

# Detect the host's package family. Sets HOST_PKG_FAMILY / HOST_PKG_MANAGER
# and HOST_INSTALL_CMD / HOST_REFRESH_CMD. Errors out on unsupported hosts.
function host_pkg_detect() {
    if [[ ! -r /etc/os-release ]]; then
        >&2 echo "ERROR: /etc/os-release is missing or unreadable; cannot determine host package manager."
        exit 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release

    local id="${ID:-}" id_like="${ID_LIKE:-}"

    if [[ "$id" == "ubuntu" ]] || [[ "$id_like" == *ubuntu* ]] || \
       [[ "$id" == "debian" ]] || [[ "$id_like" == *debian* ]]; then
        HOST_PKG_FAMILY="deb"
        HOST_PKG_MANAGER="apt"
        HOST_INSTALL_CMD=(apt install -y)
        HOST_REFRESH_CMD=(apt update)
        return 0
    fi

    if [[ "$id" == "opensuse-tumbleweed" || "$id" == "opensuse-slowroll" || \
          "$id_like" == *suse* || "$id_like" == *opensuse* ]]; then
        # Supported openSUSE targets: Tumbleweed and Slowroll.
        # openSUSE Leap / SLES are NOT currently planned -- contributions
        # to add them are welcome.
        HOST_PKG_FAMILY="rpm"
        HOST_PKG_MANAGER="zypper"
        HOST_INSTALL_CMD=(zypper --non-interactive install)
        HOST_REFRESH_CMD=(zypper --non-interactive refresh)
        return 0
    fi

    if [[ "$id" == "arch" || "$id_like" == *arch* ]]; then
        HOST_PKG_FAMILY="arch"
        HOST_PKG_MANAGER="pacman"
        HOST_INSTALL_CMD=(pacman -S --noconfirm --needed)
        # -Sy, not -Syu: only refresh the package DB; never run a full
        # system upgrade from a build script -- that is the host owner's
        # responsibility.
        HOST_REFRESH_CMD=(pacman -Sy)
        return 0
    fi

    >&2 echo "ERROR: Unsupported host OS (ID='${id}', ID_LIKE='${id_like}')."
    >&2 echo "Supported host families: Ubuntu/Debian, openSUSE (Tumbleweed / Slowroll), Arch."
    exit 1
}

# host_pkg_refresh -- refresh the host's package database.
# Wraps apt update / zypper refresh / pacman -Sy. No-op if the family
# cannot be detected (caller will have already errored out by then).
function host_pkg_refresh() {
    if [[ ${#HOST_REFRESH_CMD[@]} -eq 0 ]]; then
        return 0
    fi
    host_priv "${HOST_REFRESH_CMD[@]}"
}

# host_pkg_install PKG... -- install the given *canonical* (Debian-style)
# package names on the host, translating to the host's name where needed.
function host_pkg_install() {
    if [[ ${#HOST_INSTALL_CMD[@]} -eq 0 ]]; then
        return 0
    fi
    local -a host_pkgs=()
    local p
    for p in "$@"; do
        host_pkgs+=("$(host_pkg_name "$p")")
    done
    host_priv "${HOST_INSTALL_CMD[@]}" "${host_pkgs[@]}"
}

# host_pkg_is_installed PKG... -- returns 0 iff every named canonical
# package is installed on the host. Translates names per the host family.
function host_pkg_is_installed() {
    local p translated
    case "$HOST_PKG_FAMILY" in
        deb)
            for p in "$@"; do
                dpkg -s "$(host_pkg_name "$p")" &>/dev/null || return 1
            done
            ;;
        rpm)
            for p in "$@"; do
                rpm -q "$(host_pkg_name "$p")" &>/dev/null || return 1
            done
            ;;
        arch)
            for p in "$@"; do
                pacman -Q "$(host_pkg_name "$p")" &>/dev/null || return 1
            done
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

# On openSUSE hosts the Ubuntu/Debian archive keyrings are not packaged,
# so debootstrap would fail to verify the Ubuntu Release.gpg signature.
# Workaround: fetch the Ubuntu archive signing key from a public keyserver
# with gpg and drop the resulting keyring into /usr/share/keyrings/ where
# debootstrap can pick it up via --keyring. This runs once on the host
# before debootstrap and is a no-op on every other family.
function ensure_ubuntu_keyring_for_opensuse() {
    if [[ "${HOST_PKG_FAMILY}" != "rpm" ]]; then
        return 0
    fi
    local keyring="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
    if [[ -s "$keyring" ]]; then
        echo "=====> Ubuntu archive keyring already present at $keyring -- skipping fetch."
        return 0
    fi
    echo "=====> Fetching Ubuntu archive signing key into $keyring ..."
    host_priv mkdir -p /usr/share/keyrings
    host_priv gpg --homedir /tmp --no-default-keyring \
        --keyring "$keyring" \
        --keyserver hkp://keyserver.ubuntu.com:80 \
        --recv-keys 871920D1991BC93C
}
