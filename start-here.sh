#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -euo pipefail

# -- Help -------------------------------------------------------------
# start-here.sh is a thin dispatcher: it picks a distro (Ubuntu / Pop!_OS)
# and an output type (ISO / cloud image / VM image), then runs the matching
# builder in scripts/ with every other argument passed straight through.
# --help is handled here (before any sudo/dependency work) and explains the
# dispatcher; per-builder options are shown by each builder's own --help.
show_start_help() {
    local self="$0"
    cat <<EOF
start-here.sh -- guided launcher for the Ubuntu / Pop!_OS image builders.

It asks two things (or takes them as flags), then hands off to the matching
script in scripts/ with all remaining arguments passed through unchanged.

Usage:
  ${self} [--distro=ubuntu|popos] [--output=iso|img|vm|removable] [builder options...]
  ${self} --create-config [--distro=...] [--output=...]
  ${self} --help

Dispatcher options:
  --distro=ubuntu|popos     Which distribution to build (default: asked on a TTY,
                            else ubuntu). Env: BUILD_DISTRO.
  --output=iso|img|vm|removable  What to produce (default: asked on a TTY, else iso).
                            Env: BUILD_OUTPUT.
                              iso       Live-installer ISO (USB / DVD / PXE / VM boot)
                              img       Cloud disk image: raw .img for cloud VMs (cloud-init)
                              vm        VM disk image: raw .img + QCOW2/VDI/VMDK/VHDX exports
                              removable Removable-media disk image: raw .img to flash onto USB / SD / CF
  --create-config           Only run the selected builder's config wizard
    (--generate-config)     (no sudo, no host dependencies installed). The
                            builder's --generate-config is forwarded as-is.
  --advanced                Forwarded to the builder: enables config file loading,
                            workspace preservation, package caching, and the
                            --interactive/--no-interactive overrides. Without
                            this flag the launcher runs in basic mode (the
                            builder's own startup-mode prompt is suppressed
                            by the launcher because basic is always assumed).
                            Env: ADVANCED_MODE.
  -h, --help                Show this help and exit.

Environment contract:
  BUILD_DISTRO, BUILD_OUTPUT  Resolved by the launcher only -- not exported to
                              the builder. Use --distro=... and --output=... if
                              you also need the builder to see the choice.
  LAUNCHED_FROM_START_HERE=1  Set on the builder's environment so it knows to
                              skip its own host-setup (sudo + dependency
                              installation). The launcher handles both.

distro + output map to these builders (run one directly if you prefer):
  ubuntu iso       ->  scripts/build.sh                popos iso       ->  scripts/build-popos.sh
  ubuntu img       ->  scripts/build-img.sh            popos img       ->  scripts/build-popos-img.sh
  ubuntu vm        ->  scripts/build-vm.sh             popos vm        ->  scripts/build-popos-vm.sh
  ubuntu removable ->  scripts/build-removable.sh      popos removable ->  scripts/build-popos-removable.sh

All other options (--release, --kernel, --desktop, browsers, and for images
--firmware, --disk-size, --profile, --network, --alloc-tool, --user-mode,
--formats, ...) belong to the builders and are forwarded verbatim. For the full,
output-specific list run the matching builder's own help, e.g.:
  scripts/build.sh --help                  (ISO options + stages)
  scripts/build-img.sh --help              (cloud image options + stages)
  scripts/build-vm.sh --help               (VM image options + stages)
  scripts/build-removable.sh --help        (removable-media options + stages)

Examples:
  ${self}                                     Fully guided (asks distro + output)
  ${self} --distro=popos --output=vm          Pop!_OS VM image, then guided prompts
  ${self} --output=img --release=noble --profile=cli -
  ${self} --create-config --distro=ubuntu --output=vm
  ${self} --advanced --distro=ubuntu --config=build.cfg --no-interactive -
EOF
}

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_start_help
            exit 0
            ;;
    esac
done

# Clear the terminal screen (if stdout is a TTY)
if [[ -t 1 ]]; then
    clear || true
fi

# -- Pre-scan: detect dispatcher-only flags before the arg loop ---------
# --create-config and --generate-config both set the same flag, and the
# wizard is launched as <builder> --generate-config below. --advanced is
# forwarded to the builder as-is (and additionally exported as ADVANCED_MODE=1
# so the builder skips its interactive mode-pick prompt).
GENERATE_CONFIG=0
ADVANCE_REQUESTED=0
for arg in "$@"; do
    case "$arg" in
        --create-config|--generate-config) GENERATE_CONFIG=1 ;;
        --advanced)                        ADVANCE_REQUESTED=1 ;;
    esac
done

# -- Distro selection -------------------------------------------------
# Choose which image to build: Ubuntu (scripts/build.sh) or Pop!_OS
# (scripts/build-popos.sh). Selectable via --distro=ubuntu|popos, the
# BUILD_DISTRO env var, or an interactive prompt on a TTY (default: ubuntu).
# The output type -- live-installer ISO, cloud disk image (.img), VM disk
# image (raw + QCOW2/VDI/VMDK/VHDX), or removable-media disk image (raw .img
# to flash onto USB / SD / CF) -- is selectable via --output=iso|img|vm|removable,
# the BUILD_OUTPUT env var, or an interactive prompt (default: iso).
BUILD_DISTRO="${BUILD_DISTRO:-}"
BUILD_OUTPUT="${BUILD_OUTPUT:-}"
PASS_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --distro=*)       BUILD_DISTRO="${arg#--distro=}" ;;
        --output=*)       BUILD_OUTPUT="${arg#--output=}" ;;
        # --create-config / --generate-config are translated to the builders'
        # --generate-config below; keep both spellings out of PASS_ARGS so they
        # are not forwarded twice. --advanced is also exported as ADVANCED_MODE=1
        # so the builder skips its interactive mode-pick prompt, but the flag
        # is forwarded so the builder can set ADVANCED_MODE_EXPLICIT=1 itself.
        --create-config|--generate-config) ;;
        --advanced)                        ADVANCE_REQUESTED=1; PASS_ARGS+=("$arg") ;;
        *)                                 PASS_ARGS+=("$arg") ;;
    esac
done
if [[ "$GENERATE_CONFIG" -eq 1 ]]; then
    PASS_ARGS+=("--generate-config")
fi

case "${BUILD_DISTRO,,}" in
    pop|pop-os|pop_os|popos) BUILD_DISTRO="popos" ;;
    ubuntu)                  BUILD_DISTRO="ubuntu" ;;
    "")
        if [[ -t 0 ]]; then
            echo ""
            echo "--- Distribution ---"
            if [[ "$GENERATE_CONFIG" -eq 1 ]]; then
                echo "    (config wizard: choose which builder to generate a config for)"
            fi
            echo "    1) Ubuntu   Vanilla Ubuntu (scripts/build*.sh)  [default]"
            echo "    2) Pop!_OS  Pop!_OS from apt.pop-os.org repos (scripts/build-popos*.sh)"
            while true; do
                read -r -p "  Distro [1/2, Enter=1]: " _choice
                case "${_choice,,}" in
                    ""|1|u|ubuntu)           BUILD_DISTRO="ubuntu"; break ;;
                    2|p|pop|pop-os|popos)    BUILD_DISTRO="popos";  break ;;
                    *) echo "  Invalid selection: '${_choice}'." ;;
                esac
            done
        else
            echo "  info  No TTY and no --distro given: defaulting to 'ubuntu'. Pass --distro=ubuntu|popos to override." >&2
            BUILD_DISTRO="ubuntu"
        fi
        ;;
    *)
        echo "ERROR: BUILD_DISTRO/--distro must be 'ubuntu' or 'popos' (got: '${BUILD_DISTRO}')." >&2
        exit 1
        ;;
esac

# -- Output type selection --------------------------------------------
case "${BUILD_OUTPUT,,}" in
    iso)          BUILD_OUTPUT="iso" ;;
    img|image|cloud|cloud-img) BUILD_OUTPUT="img" ;;
    vm)           BUILD_OUTPUT="vm" ;;
    removable|removable-media|usb|sd) BUILD_OUTPUT="removable" ;;
    "")
        if [[ -t 0 ]]; then
            echo ""
            echo "--- Output type ---"
            echo "    1) ISO           Live-installer ISO (USB/DVD/PXE/VM boot)  [default]"
            echo "    2) Cloud image   Ready-to-deploy raw .img for cloud VMs (cloud-init)"
            echo "    3) VM image      Raw .img + QCOW2/VDI/VMDK/VHDX exports for hypervisors"
            echo "    4) Removable     Ready-to-flash raw .img for USB sticks, SD cards, CF cards"
            while true; do
                read -r -p "  Output [1/2/3/4, Enter=1]: " _choice
                case "${_choice,,}" in
                    ""|1|iso)                              BUILD_OUTPUT="iso";       break ;;
                    2|img|image|cloud|cloud-img)           BUILD_OUTPUT="img";       break ;;
                    3|vm)                                  BUILD_OUTPUT="vm";        break ;;
                    4|removable|removable-media|usb|sd)    BUILD_OUTPUT="removable"; break ;;
                    *) echo "  Invalid selection: '${_choice}'." ;;
                esac
            done
        else
            echo "  info  No TTY and no --output given: defaulting to 'iso'. Pass --output=iso|img|vm|removable to override." >&2
            BUILD_OUTPUT="iso"
        fi
        ;;
    *)
        echo "ERROR: BUILD_OUTPUT/--output must be 'iso', 'img', 'vm', or 'removable' (got: '${BUILD_OUTPUT}')." >&2
        exit 1
        ;;
esac

case "${BUILD_DISTRO}-${BUILD_OUTPUT}" in
    ubuntu-iso)       BUILD_SCRIPT="build.sh" ;;
    ubuntu-img)       BUILD_SCRIPT="build-img.sh" ;;
    ubuntu-vm)        BUILD_SCRIPT="build-vm.sh" ;;
    ubuntu-removable) BUILD_SCRIPT="build-removable.sh" ;;
    popos-iso)        BUILD_SCRIPT="build-popos.sh" ;;
    popos-img)        BUILD_SCRIPT="build-popos-img.sh" ;;
    popos-vm)         BUILD_SCRIPT="build-popos-vm.sh" ;;
    popos-removable)  BUILD_SCRIPT="build-popos-removable.sh" ;;
esac
echo "=====> Selected: ${BUILD_DISTRO} / ${BUILD_OUTPUT} (scripts/${BUILD_SCRIPT})"

# -- Host detection + dependency install ------------------------------
# Single source of truth for host packages: the launcher always installs
# them, then sets LAUNCHED_FROM_START_HERE=1 so the builder's own host-setup
# (which would otherwise re-install them) is a no-op. The dep list is
# computed from BUILD_OUTPUT so the ISO-only tools (squashfs-tools, xorriso)
# are not pulled in for img/vm runs and vice versa.
#
# Three host families are supported here:
#   deb   - Ubuntu / Debian and derivatives (apt + dpkg)
#   rpm   - openSUSE / SUSE (zypper + rpm)
#   arch  - Arch Linux and derivatives (pacman)
# Any other host is left to the user to install dependencies for.
HOST_PKG_FAMILY=""
HOST_PKG_MANAGER=""
# Per-family overrides for the host's package name. The key is
# 'canonical:family' (e.g. 'xorriso:arch'); the value is the host's
# package name on that family. Anything not listed here uses the
# canonical (Debian-style) name as-is, which is the right answer for
# most tools (debootstrap, parted, dosfstools, e2fsprogs, rsync, etc.).
# Keep in sync with scripts/build.sh (same table for its own host-side
# install path).
declare -gA HOST_PKG_NAME=(
    [squashfs-tools:rpm]=squashfs        # openSUSE: 'squashfs'
    [xorriso:arch]=libisoburn            # Arch: xorriso binary ships in libisoburn
    [qemu-utils:rpm]=qemu-tools          # openSUSE: 'qemu-tools'
    [qemu-utils:arch]=qemu-img           # Arch: 'qemu-img'
)

IS_DEBIAN=0
if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}" in
        ubuntu)
            HOST_PKG_FAMILY="deb"; HOST_PKG_MANAGER="apt" ;;
        debian)
            HOST_PKG_FAMILY="deb"; HOST_PKG_MANAGER="apt"
            # Exclude Ubuntu-based distros (e.g. Linux Mint based on Ubuntu)
            if [[ "${ID_LIKE:-}" != *ubuntu* ]]; then
                IS_DEBIAN=1
            fi
            ;;
        opensuse-tumbleweed|opensuse-slowroll)
            # openSUSE Tumbleweed and openSUSE Slowroll are the supported
            # openSUSE targets. openSUSE Leap is NOT currently planned --
            # if you would like to add Leap support, contributions are
            # welcome (open an issue or PR).
            HOST_PKG_FAMILY="rpm"; HOST_PKG_MANAGER="zypper" ;;
        arch)
            HOST_PKG_FAMILY="arch"; HOST_PKG_MANAGER="pacman" ;;
    esac
    # ID_LIKE fallback for derivatives (Mint, Manjaro, Endeavour, ...).
    if [[ -z "$HOST_PKG_FAMILY" ]]; then
        case "${ID_LIKE:-}" in
            *ubuntu*|*debian*)
                HOST_PKG_FAMILY="deb"; HOST_PKG_MANAGER="apt" ;;
            *suse*|*opensuse*)
                HOST_PKG_FAMILY="rpm"; HOST_PKG_MANAGER="zypper" ;;
            *arch*)
                HOST_PKG_FAMILY="arch"; HOST_PKG_MANAGER="pacman" ;;
        esac
    fi
fi

# Translate a canonical (Debian-style) package name to the host's name.
shim_host_pkg_name() {
    local canonical="$1"
    local key="${canonical}:${HOST_PKG_FAMILY}"
    if [[ -n "${HOST_PKG_NAME[$key]:-}" ]]; then
        echo "${HOST_PKG_NAME[$key]}"
        return
    fi
    echo "$canonical"
}

# Compute the dep list for the chosen output. debootstrap is always required;
# ISO output needs squashfs-tools + xorriso; img + removable need
# parted/dosfstools/e2fsprogs/rsync; vm is img + qemu-utils.
DEPS=(debootstrap)
case "${BUILD_OUTPUT}" in
    iso)       DEPS+=(squashfs-tools xorriso) ;;
    img)       DEPS+=(parted dosfstools e2fsprogs rsync) ;;
    vm)        DEPS+=(parted dosfstools e2fsprogs rsync qemu-utils) ;;
    removable) DEPS+=(parted dosfstools e2fsprogs rsync) ;;
esac
# On non-Ubuntu Debian, also pull the Ubuntu archive keyring so debootstrap
# can verify Ubuntu release signatures. No-op on non-deb hosts.
if [[ "$IS_DEBIAN" -eq 1 ]]; then
    DEPS+=("ubuntu-archive-keyring")
fi
# On Arch-based hosts, also pull the keyrings debootstrap needs to verify
# the Ubuntu/Debian release signatures. These are required because pacman
# hosts have no built-in trust for the Ubuntu or Debian archives.
if [[ "${HOST_PKG_FAMILY}" == "arch" ]]; then
    DEPS+=("ubuntu-keyring" "debian-archive-keyring" "debian-ports-archive-keyring")
fi

if [[ "$GENERATE_CONFIG" -eq 0 ]]; then
    if [[ -n "$HOST_PKG_FAMILY" ]]; then
        # Translate the canonical dep list to the host's package names,
        # then filter out the ones that are already installed.
        MISSING_DEPS=()
        for dep in "${DEPS[@]}"; do
            host_name="$(shim_host_pkg_name "$dep")"
            case "$HOST_PKG_FAMILY" in
                deb)  dpkg -s "$host_name" &>/dev/null || MISSING_DEPS+=("$host_name") ;;
                rpm)  rpm  -q "$host_name" &>/dev/null || MISSING_DEPS+=("$host_name") ;;
                arch) pacman -Q "$host_name" &>/dev/null || MISSING_DEPS+=("$host_name") ;;
            esac
        done

        if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
            echo "=====> Installing missing host dependencies: ${MISSING_DEPS[*]}"
            case "$HOST_PKG_FAMILY" in
                deb)
                    if [ "$(id -u)" -eq 0 ]; then
                        apt-get update
                        apt-get install -y "${MISSING_DEPS[@]}"
                    else
                        sudo apt-get update
                        sudo apt-get install -y "${MISSING_DEPS[@]}"
                    fi
                    ;;
                rpm)
                    if [ "$(id -u)" -eq 0 ]; then
                        zypper --non-interactive refresh
                        zypper --non-interactive install "${MISSING_DEPS[@]}"
                    else
                        sudo zypper --non-interactive refresh
                        sudo zypper --non-interactive install "${MISSING_DEPS[@]}"
                    fi
                    ;;
                arch)
                    if [ "$(id -u)" -eq 0 ]; then
                        # -Sy, not -Syu: only refresh the package DB; never
                        # run a full system upgrade from a build script.
                        pacman -Sy
                        pacman -S --noconfirm --needed "${MISSING_DEPS[@]}"
                    else
                        sudo pacman -Sy
                        sudo pacman -S --noconfirm --needed "${MISSING_DEPS[@]}"
                    fi
                    ;;
            esac
        fi
    else
        echo "=====> WARNING: host is not detected as Ubuntu, Debian, openSUSE (Tumbleweed / Slowroll), or Arch" >&2
        echo "=====>          ($(lsb_release -id 2>/dev/null || echo unknown))." >&2
        echo "=====>          Skipping automatic dependency install. Make sure these are present:" >&2
        printf '=====>            %s\n' "${DEPS[@]}" >&2
        echo "=====>          The build will fail mid-run if any are missing." >&2
    fi
fi

# -- Sudo keep-alive --------------------------------------------------
# Long builds (especially on WSL2) can outlast the default sudo timeout.
# We validate credentials once up front, then refresh them in the
# background so privileged steps never stall waiting for a password.
# Skipped when the user only wants the config wizard.
SUDO_KEEPALIVE_PID=""

cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
}

if [[ "$GENERATE_CONFIG" -eq 0 ]] && [[ "$(id -u)" -ne 0 ]]; then
    echo "=====> Requesting sudo credentials (will be kept alive for the entire build) ..."
    if ! sudo -v 2>/dev/null; then
        echo "=====> ERROR: Failed to obtain sudo credentials. The build requires sudo access." >&2
        exit 1
    fi

    # Background loop: refresh sudo timestamp every 60 seconds
    (while sudo -v -n 2>/dev/null; do sleep 60; done) &
    SUDO_KEEPALIVE_PID=$!

    trap cleanup_sudo_keepalive EXIT
fi

# Set the toggle indicating launched from start-here.sh
export LAUNCHED_FROM_START_HERE=1

# Forward --advanced explicitly so the builder skips its interactive
# mode-pick prompt. (The flag is also passed through PASS_ARGS.)
if [[ "$ADVANCE_REQUESTED" -eq 1 ]]; then
    export ADVANCED_MODE=1
fi

# Call the selected build script with all remaining arguments passed through.
# Use a regular invocation (not exec) so the EXIT trap can clean up the
# sudo keep-alive background process when the build finishes.
"$(dirname "$0")/scripts/${BUILD_SCRIPT}" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}
