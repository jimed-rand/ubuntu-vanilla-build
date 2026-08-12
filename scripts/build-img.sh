#!/bin/bash

# build-img.sh -- cloud disk image variant of build.sh.
#
# Instead of a live-installer ISO, this script produces a ready-to-deploy
# raw disk image (.img) for cloud VMs. cloud-init (+ growpart) is always
# installed, so provider metadata, SSH key injection, and root filesystem
# growth work out of the box.
#
#   * Firmware: UEFI-only (GPT + 512 MB EFI System Partition) or Hybrid
#     (BIOS + UEFI on one disk: 1 MiB BIOS boot partition + the same ESP,
#     GRUB installed for both targets), chosen at build time.
#   * Partition layout: ESP 512 MB, swap 4 GB, root = all remaining space
#     (a 32 GB image leaves ~27.5 GB for root). Image size: 32 / 64 / 128 GB
#     or a custom size.
#   * Profile: desktop-ready (pick any desktop the ISO builder offers) or
#     CLI/TTY-only (no desktop stack at all; network stack selectable:
#     netplan + systemd-networkd or NetworkManager).
#   * Allocation: the raw .img is created with truncate (sparse,
#     default), fallocate (preallocated), or dd (fully zero-written).
#   * Credentials: bake a username + password into the image during the
#     build, or leave user creation to cloud-init at deploy time (default).

set -e
set -o pipefail
set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# Set in resolve_workspace_paths() during host_main (WSL: avoid /mnt/c for debootstrap).
WORKSPACE_DIR=""
WORKSPACE_CHROOT=""
WORKSPACE_IMAGE=""
# Where the finished image + checksums land. Set in resolve_workspace_paths().
OUTPUT_DIR=""
# Basic-mode workspace parent: root-owned system path regular users cannot touch.
UVB_SYSTEM_WORKSPACE_PARENT="/var/cache/ubuntu-vanilla-build"
# Prevents duplicate teardown when both a signal handler and EXIT run.
HOST_ABORT_CLEANUP_DONE=0
DATE="$(TZ="UTC" date +"%y%m%d-%H%M%S")"
# Default hooks directory; overridden by --hooks-dir=PATH.
HOOKS_DIR=""
# Script filename (used when copying ourselves into the chroot).
SCRIPT_NAME="$(basename "$(readlink -f "$0")")"
# Image kind baked into this script: "cloud" produces a raw .img ready to
# deploy to a cloud VM; "vm" additionally exports the image to
# QCOW2/VDI/VMDK/VHDX for desktop hypervisors.
UVB_IMAGE_KIND="${UVB_IMAGE_KIND:-cloud}"
# Files produced by the build (image + checksums + exports); used to hand
# ownership back to the invoking user.
OUTPUT_FILES=()
# Loop device + mountpoint used while assembling the disk image; globals so
# the abort cleanup path can unwind them.
IMG_LOOP_DEV=""
IMG_MOUNT_DIR=""
# Advanced mode: set to 1 via --advanced (or the startup mode prompt) to enable
# config file loading, workspace preservation on failure/interrupt, package
# caching, and the --interactive/--no-interactive overrides.
# ADVANCED_MODE_EXPLICIT tracks whether the user chose a mode (env or CLI);
# when 0, host_main asks interactively on a TTY and defaults to basic otherwise.
if [[ -n "${ADVANCED_MODE+x}" ]]; then
    ADVANCED_MODE_EXPLICIT=1
else
    ADVANCED_MODE_EXPLICIT=0
fi
ADVANCED_MODE="${ADVANCED_MODE:-0}"

# ---------------------------------------------------------------------------
# UI helpers: consistent colored output, headings, step counters, prompts.
# Colors auto-disabled if stdout is not a TTY, TERM=dumb, or NO_COLOR is set.
# Set NO_CONFIRM=1 to skip the pre-build confirmation prompt.
# ---------------------------------------------------------------------------
UI_USE_COLOR=0
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]] && [[ -z "${NO_COLOR:-}" ]]; then
    UI_USE_COLOR=1
fi

function _ui_c() {
    if [[ "$UI_USE_COLOR" -eq 1 ]]; then
        printf '\033[%sm' "$1"
    fi
}

function _ui_r() {
    if [[ "$UI_USE_COLOR" -eq 1 ]]; then
        printf '\033[0m'
    fi
}

function ui_banner() {
    local title="$1"
    local bar="=================================================================="
    printf '\n'
    _ui_c '1;36'; printf '%s\n'     "$bar";   _ui_r
    _ui_c '1;36'; printf '  %s\n'   "$title"; _ui_r
    _ui_c '1;36'; printf '%s\n'     "$bar";   _ui_r
    printf '\n'
}

function ui_heading() {
    printf '\n'
    _ui_c '1;34'; printf -- '--- %s ---\n' "$1"; _ui_r
}

function ui_step() {
    local n="$1" total="$2" name="$3"
    printf '\n'
    _ui_c '1;33'; printf '[%d/%d] %s\n' "$n" "$total" "$name"; _ui_r
}

function ui_ok()   { _ui_c '32';   printf '  OK    %s\n' "$1"; _ui_r; }
# Color escapes and text must go to the same stream, or redirecting stderr
# leaves stray/unbalanced escape codes on stdout.
function ui_warn() { { _ui_c '33';   printf '  WARN  %s\n' "$1"; _ui_r; } >&2; }
function ui_err()  { { _ui_c '1;31'; printf '  ERROR %s\n' "$1"; _ui_r; } >&2; }
function ui_info() { _ui_c '36';   printf '  info  %s\n' "$1"; _ui_r; }

function ui_kv() {
    printf '    %-22s %s\n' "$1" "$2"
}

# ui_confirm "Prompt" [y|n]  -- default is "y" if omitted. Returns 0 for yes, 1 for no.
function ui_confirm() {
    local prompt="${1:-Proceed?}"
    local default="${2:-y}"
    local hint yn
    if [[ "$default" == "y" ]]; then
        hint="[Y/n]"
    else
        hint="[y/N]"
    fi
    while true; do
        read -r -p "  ${prompt} ${hint}: " yn
        yn="${yn,,}"
        [[ -z "$yn" ]] && yn="$default"
        case "$yn" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     echo "  Please answer y or n." ;;
        esac
    done
}

# Prompting policy: interactive prompts run when stdin is a TTY, or when forced
# via --interactive / INTERACTIVE=1 (config file). --no-interactive redirects
# stdin from /dev/null, which makes both conditions false.
FORCE_INTERACTIVE=0

function prompts_enabled() {
    [[ "$FORCE_INTERACTIVE" == "1" ]] || [[ -t 0 ]]
}

# assert_bool_var VAR_NAME [DEFAULT]  -- validate that $VAR_NAME is 0 or 1.
function assert_bool_var() {
    local name="$1" default="${2:-0}"
    local val="${!name:-$default}"
    case "$val" in
        0|1) ;;
        *)
            >&2 echo "${name} must be 0 or 1 (got: '${val}')."
            exit 1
            ;;
    esac
}

# cmd_find_index CMD ARRAY_NAME HELP_FN  -- set $index to the position of CMD in
# the named array, or call HELP_FN with an error message if not found.
function cmd_find_index() {
    local cmd="$1" arr_name="$2" help_fn="$3"
    local -n _arr="$arr_name"
    local i
    for ((i=0; i<${#_arr[*]}; i++)); do
        if [[ "${_arr[i]}" == "$cmd" ]]; then
            index=$i
            return
        fi
    done
    "$help_fn" "Command not found: $cmd"
}

# parse_cmd_range ARRAY_NAME HELP_FN ARGS...  -- compute start_index / end_index
# from the [start_cmd] [-] [end_cmd] syntax used by both host and chroot phases.
# Sets shell variables: start_index, end_index.
function parse_cmd_range() {
    local arr_name="$1" help_fn="$2"
    shift 2
    local -n _arr="$arr_name"

    if [[ $# == 0 ]]; then
        set -- "-"
    fi
    if [[ $# -gt 3 ]]; then
        "$help_fn"
    fi

    local dash_flag=false
    start_index=0
    end_index=${#_arr[*]}
    local ii
    for ii in "$@"; do
        if [[ $ii == "-" ]]; then
            dash_flag=true
            continue
        fi
        cmd_find_index "$ii" "$arr_name" "$help_fn"
        if [[ $dash_flag == false ]]; then
            start_index=$index
        else
            end_index=$((index + 1))
        fi
    done
    if [[ $dash_flag == false ]]; then
        end_index=$((start_index + 1))
    fi
    if [[ $end_index -le $start_index ]]; then
        "$help_fn" "Invalid range: end command '${_arr[end_index-1]}' comes before start command '${_arr[start_index]}'."
    fi
}

# Host (outside chroot): prepare tree, debootstrap, run chroot phase, assemble the disk image
HOST_CMD=(setup_host debootstrap run_chroot build_disk_image)

# Chroot phase: APT setup, packages, cleanup
CHROOT_CMD=(chroot_prepare install_pkg finish_up)

# Run host commands as root: sudo when invoked as a normal user, direct exec when already root.
function host_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ---------------------------------------------------------------------------
# Host (build-time, outside the chroot) package management abstraction --
# shared with every other build-*.sh script. See host-pkg.sh for details.
# Sourced here (after host_priv is defined) because the abstraction's
# install/refresh helpers wrap host_priv.
# ---------------------------------------------------------------------------
# shellcheck source=./host-pkg.sh
source "$SCRIPT_DIR/host-pkg.sh"

# ---------------------------------------------------------------------------
# Sudo keep-alive: long builds can outlast the default sudo timeout, which
# makes apt/chroot steps stall waiting for a password mid-build. Validate
# credentials once up front, then refresh them in the background. Skipped
# when running as root or when launched via start-here.sh (which already
# maintains its own keep-alive loop).
# ---------------------------------------------------------------------------
SUDO_KEEPALIVE_PID=""

function setup_sudo_keepalive() {
    if [[ "${LAUNCHED_FROM_START_HERE:-0}" -eq 1 ]] || [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    echo "=====> Requesting sudo credentials (will be kept alive for the entire build) ..."
    if ! sudo -v; then
        >&2 echo "ERROR: Failed to obtain sudo credentials. The build requires sudo access."
        exit 1
    fi
    # Background loop: refresh the sudo timestamp every 60 seconds.
    (while sudo -v -n 2>/dev/null; do sleep 60; done) &
    SUDO_KEEPALIVE_PID=$!
}

function cleanup_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    SUDO_KEEPALIVE_PID=""
}

# ---------------------------------------------------------------------------
# Hook loader: discover and execute *.sh scripts from a hooks subdirectory,
# sorted by filename (like a game modloader's load order). Non-executable
# files and files not ending in .sh are skipped.
# Usage: run_hooks <hooks_subdir>   e.g. run_hooks pre-chroot
# ---------------------------------------------------------------------------
function run_hooks() {
    local subdir="$1"
    local hooks_base="${HOOKS_DIR:-$SCRIPT_DIR/hooks}"
    local hooks_path="$hooks_base/$subdir"

    if [[ ! -d "$hooks_path" ]]; then
        return 0
    fi

    local hook_files=()
    local f
    while IFS= read -r -d '' f; do
        hook_files+=("$f")
    done < <(find "$hooks_path" -maxdepth 1 -name '*.sh' -print0 2>/dev/null | sort -z)

    if [[ ${#hook_files[@]} -eq 0 ]]; then
        return 0
    fi

    ui_heading "Loading hooks: $subdir (${#hook_files[@]} mod(s) found)"
    local i=0
    for f in "${hook_files[@]}"; do
        i=$((i + 1))
        local name
        name="$(basename "$f")"
        if [[ ! -x "$f" ]]; then
            ui_warn "[hook $i/${#hook_files[@]}] $name -- skipped (not executable)"
            continue
        fi
        ui_info "[hook $i/${#hook_files[@]}] Loading: $name"
        bash -e "$f"
        ui_ok "[hook $i/${#hook_files[@]}] $name"
    done
}

# run_chroot_hooks -- execute chroot hooks from /root/hooks/chroot/ inside the chroot.
# Called from the chroot phase (install_pkg) after customize_image.
function run_chroot_hooks() {
    local hooks_path="/root/hooks/chroot"

    if [[ ! -d "$hooks_path" ]]; then
        return 0
    fi

    local hook_files=()
    local f
    while IFS= read -r -d '' f; do
        hook_files+=("$f")
    done < <(find "$hooks_path" -maxdepth 1 -name '*.sh' -print0 2>/dev/null | sort -z)

    if [[ ${#hook_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo "=====> Loading chroot hooks (${#hook_files[@]} mod(s) found)"
    local i=0
    for f in "${hook_files[@]}"; do
        i=$((i + 1))
        local name
        name="$(basename "$f")"
        if [[ ! -x "$f" ]]; then
            echo "  WARN  [hook $i/${#hook_files[@]}] $name -- skipped (not executable)"
            continue
        fi
        echo "  info  [hook $i/${#hook_files[@]}] Loading: $name"
        bash -e "$f"
        echo "  OK    [hook $i/${#hook_files[@]}] $name"
    done
}

function set_defaults() {
    export TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION:-}"
    export TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR:-https://archive.ubuntu.com/ubuntu/}"
    export TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}"
    export TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}"
    export TARGET_DESKTOP="${TARGET_DESKTOP:-}"
    export TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-}"
    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-}"
    export TARGET_BROWSER="${TARGET_BROWSER:-}"
    export TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-}"
    # TARGET_LIBREWOLF, TARGET_FIREFOX, TARGET_FIREFOX_ESR, TARGET_THUNDERBIRD, TARGET_UBUNTU_STUDIO,
    # TARGET_PACSTALL, TARGET_FWUPD, TARGET_OPENSSH_SERVER, TARGET_COCKPIT:
    # intentionally left unset here so that resolve_browser_selection(),
    # resolve_ubuntu_studio_choice(), resolve_pacstall_choice(), and
    # resolve_optional_service_choices() can distinguish "user never specified"
    # (unset) from "user explicitly set to 0/1" via ${VAR+x}.
    # Only env/CLI paths should set these.
    export TARGET_NAME="${TARGET_NAME:-}"
    export TARGET_FIRMWARE="${TARGET_FIRMWARE:-}"
    export TARGET_DISK_SIZE_GB="${TARGET_DISK_SIZE_GB:-}"
    export TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE:-}"
    # TARGET_USER_MODE: "build" bakes TARGET_USERNAME/TARGET_USER_PASSWORD into
    # the image; "deploy" defers user creation to cloud-init (cloud images) or
    # the first-boot wizard (VM images).
    export TARGET_USER_MODE="${TARGET_USER_MODE:-}"
    export TARGET_USERNAME="${TARGET_USERNAME:-}"
    export TARGET_USER_PASSWORD="${TARGET_USER_PASSWORD:-}"
    export TARGET_USER_FULLNAME="${TARGET_USER_FULLNAME:-}"
    export TARGET_HOSTNAME="${TARGET_HOSTNAME:-}"
    # TARGET_NETWORK_STACK: network-manager or networkd (netplan backend).
    # Desktop images always use NetworkManager; CLI images default to
    # systemd-networkd but can opt into NetworkManager.
    export TARGET_NETWORK_STACK="${TARGET_NETWORK_STACK:-}"
    # TARGET_IMG_ALLOC: how the raw .img file is created -- truncate (sparse),
    # fallocate (preallocated), or dd (fully zero-written).
    export TARGET_IMG_ALLOC="${TARGET_IMG_ALLOC:-}"
    export TARGET_VM_FORMATS="${TARGET_VM_FORMATS:-}"
}

# Canonical release-codename-to-version map. Used for HWE suffix, ISO naming,
# and branding. Returns "" for unknown codenames.
function release_version() {
    case "$1" in
        jammy)    echo "22.04" ;;
        noble)    echo "24.04" ;;
        resolute) echo "26.04" ;;
        *)        echo "" ;;
    esac
}

function default_target_name() {
    local version flavor
    version="$(release_version "${TARGET_UBUNTU_VERSION:-}")"
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        flavor="cli"
    else
        flavor="${TARGET_DESKTOP:-gnome}"
    fi
    echo "ubuntu-${version}-${flavor}-${UVB_IMAGE_KIND}-amd64-${DATE}"
}

function normalize_desktop_variant() {
    local desktop="${TARGET_DESKTOP:-gnome}"
    desktop="${desktop,,}"
    case "$desktop" in
        kde)
            desktop="kde-plasma"
            ;;
    esac
    if [[ ! "$desktop" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        >&2 echo "TARGET_DESKTOP must be a slug like gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, or kde-plasma (got: '${TARGET_DESKTOP:-}')."
        exit 1
    fi
    export TARGET_DESKTOP="$desktop"
}

function assert_supported_release() {
    case "${TARGET_UBUNTU_VERSION:-}" in
        jammy|noble|resolute)
            return 0
            ;;
        *)
            >&2 echo "TARGET_UBUNTU_VERSION must be jammy, noble, or resolute (got: '${TARGET_UBUNTU_VERSION:-}')."
            return 1
            ;;
    esac
}

function set_target_kernel_package_from_flavor() {
    if [[ -n "${TARGET_KERNEL_PACKAGE:-}" ]]; then
        return 0
    fi

    assert_supported_release || exit 1

    case "${TARGET_KERNEL_FLAVOR:-}" in
        generic|lowlatency) ;;
        *)
            >&2 echo "TARGET_KERNEL_FLAVOR must be generic or lowlatency (got: '${TARGET_KERNEL_FLAVOR:-}')."
            exit 1
            ;;
    esac

    local hv
    hv="$(release_version "$TARGET_UBUNTU_VERSION")"
    if [[ -z "$hv" ]]; then
        >&2 echo "Internal error: no HWE suffix for TARGET_UBUNTU_VERSION='$TARGET_UBUNTU_VERSION'."
        exit 1
    fi

    case "$TARGET_KERNEL_FLAVOR" in
        generic)
            export TARGET_KERNEL_PACKAGE="linux-generic-hwe-${hv}"
            ;;
        lowlatency)
            export TARGET_KERNEL_PACKAGE="linux-lowlatency-hwe-${hv}"
            ;;
    esac
}

function block_snapd() {
    install -d /etc/apt/preferences.d
    # Also pin the Snap store backends: installing gnome-software-plugin-snap
    # or plasma-discover-backend-snap would drag snapd back in. Flatpak
    # backends (gnome-software-plugin-flatpak / plasma-discover-backend-flatpak)
    # are installed instead.
    cat <<'EOF' > /etc/apt/preferences.d/nosnap.pref
Package: snapd gnome-software-plugin-snap plasma-discover-backend-snap
Pin: release *
Pin-Priority: -1
EOF
}

# fwupd is banned while the image is being built: nothing may pull it in via
# Depends/Recommends. Unlike the permanent snapd pin, this one is build-time
# only -- finish_up() removes it (and the TARGET_FWUPD=1 path lifts it before
# pre-installing), so users can 'apt install fwupd' on the installed system.
function block_fwupd() {
    install -d /etc/apt/preferences.d
    cat <<'EOF' > /etc/apt/preferences.d/nofwupd-build.pref
# Build-time only: removed before the ISO is finalized.
Package: fwupd
Pin: release *
Pin-Priority: -1
EOF
}

function unblock_fwupd() {
    rm -f /etc/apt/preferences.d/nofwupd-build.pref
}

function apt_install_available() {
    local label="$1"
    shift

    local pkg candidate sim_out
    local -a installable=()
    local -a skipped=()
    local -a snapd_blocked=()
    local -a unresolved=()

    for pkg in "$@"; do
        candidate="$(apt-cache policy "$pkg" | awk '/Candidate:/ {print $2; exit}')"
        if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
            skipped+=("$pkg")
            continue
        fi

        # Validate installability under the current APT policy (including nosnap.pref).
        if ! sim_out="$(apt-get -s install -y "$pkg" 2>&1)"; then
            unresolved+=("$pkg")
            continue
        fi

        # Extra guard: skip if resolver still plans to install snapd.
        if [[ "$sim_out" == Inst\ snapd* || "$sim_out" == *$'\nInst snapd '* || "$sim_out" == *$'\nInst snapd:'* ]]; then
            snapd_blocked+=("$pkg")
            continue
        fi

        installable+=("$pkg")
    done

    if ((${#skipped[@]})); then
        echo "=====> ${label}: skipping unavailable packages: ${skipped[*]}"
    fi
    if ((${#unresolved[@]})); then
        echo "=====> ${label}: skipping packages with unsatisfied dependencies: ${unresolved[*]}"
    fi
    if ((${#snapd_blocked[@]})); then
        echo "=====> ${label}: skipping packages that would pull snapd: ${snapd_blocked[*]}"
    fi
    if ((${#installable[@]})); then
        echo "=====> ${label}: installing ${installable[*]}"
        apt-get install -y "${installable[@]}"
    else
        echo "=====> ${label}: no installable packages found"
    fi
}

# install_lightdm_desktop PKG...  -- install desktop packages with xorg + lightdm + slick-greeter.
function install_lightdm_desktop() {
    apt-get install -y "$@" xorg lightdm slick-greeter
}

function customize_image() {
    block_snapd
    block_fwupd

    case "${TARGET_DESKTOP:-gnome}" in
        cli)
            echo "=====> profile: CLI/TTY-only -- no desktop environment installed"
            ;;
        gnome)
            echo "=====> desktop flavor: gnome"
            if [[ "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" == "1" ]]; then
                echo "=====> gnome package recommends: enabled"
                apt-get install -y vanilla-gnome-desktop gnome-console
            else
                echo "=====> gnome package recommends: disabled (default lightweight mode)"
                apt-get install -y --no-install-recommends vanilla-gnome-desktop gnome-console
            fi
            ;;
        xfce)
            echo "=====> desktop flavor: xfce"
            # Xubuntu-equivalent package set, minus the xubuntu-* branding
            # (no xubuntu-default-settings, xubuntu-artwork, xubuntu-wallpapers*,
            # xubuntu-icon-theme, xubuntu-docs, xubuntu-community-*).
            # labwc provides a lightweight Wayland compositor for optional Wayland sessions.
            install_lightdm_desktop \
                xfce4 \
                xfce4-goodies \
                xfce4-terminal \
                xfce4-notifyd \
                xfce4-power-manager \
                xfce4-pulseaudio-plugin \
                xfce4-screensaver \
                xfce4-taskmanager \
                xfce4-indicator-plugin \
                xfce4-whiskermenu-plugin \
                thunar-archive-plugin \
                thunar-media-tags-plugin \
                thunar-volman \
                tumbler \
                gvfs \
                gvfs-backends \
                gvfs-fuse \
                catfish \
                menulibre \
                mugshot \
                gigolo \
                galculator \
                xarchiver \
                blueman \
                pulseaudio \
                pavucontrol \
                synaptic \
                xdg-user-dirs \
                xdg-user-dirs-gtk \
                fonts-ubuntu \
                fonts-noto-core \
                hunspell-en-us \
                onboard \
                labwc
            ;;
        lxde)
            echo "=====> desktop flavor: lxde"
            # Legacy LXDE stack (Openbox + PCManFM + lxpanel); lighter than XFCE for low-spec hardware.
            install_lightdm_desktop lxde
            ;;
        lxqt)
            echo "=====> desktop flavor: lxqt"
            # LXQt via upstream metapackage + SDDM (no lubuntu-desktop / lubuntu-* branding stack).
            apt-get install -y \
                lxqt \
                sddm \
                xorg
            ;;
        mate)
            echo "=====> desktop flavor: mate"
            echo "=====> MATE metapackage: ${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
            install_lightdm_desktop "${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
            if [[ "${TARGET_MATE_EXTRAS:-0}" == "1" ]]; then
                echo "=====> MATE extras: mate-desktop-environment-extras"
                apt-get install -y mate-desktop-environment-extras
            fi
            ;;
        cinnamon)
            echo "=====> desktop flavor: cinnamon"
            install_lightdm_desktop cinnamon-desktop-environment
            ;;
        budgie)
            echo "=====> desktop flavor: budgie"
            install_lightdm_desktop budgie-desktop-environment
            ;;
        kde-plasma)
            echo "=====> desktop flavor: kde-plasma"
            case "${TARGET_KDE_PACKAGE:-kde-standard}" in
                kde-full|kde-standard|kde-plasma-desktop)
                    echo "=====> KDE package: ${TARGET_KDE_PACKAGE:-kde-standard}"
                    apt-get install -y "${TARGET_KDE_PACKAGE:-kde-standard}"
                    ;;
                *)
                    >&2 echo "TARGET_KDE_PACKAGE must be kde-full, kde-standard, or kde-plasma-desktop (got: '${TARGET_KDE_PACKAGE:-}')."
                    exit 1
                    ;;
            esac
            # Keep the login screen on Plasma's own SDDM theme. Ubuntu's sddm
            # package satisfies its theme dependency with whatever alternative
            # the resolver picks first (e.g. sddm-theme-debian-maui), which
            # looks nothing like Plasma. Install Breeze explicitly and pin it
            # in sddm.conf.d so third-party themes cannot take over the greeter.
            echo "=====> SDDM: forcing Plasma's Breeze theme"
            apt-get install -y --no-install-recommends sddm sddm-theme-breeze
            install -d /etc/sddm.conf.d
            cat <<'EOF' > /etc/sddm.conf.d/10-ubuntu-vanilla-breeze.conf
[Theme]
Current=breeze
EOF
            # Exclude Slick SDDM (and friends) outright: pin every package
            # whose name combines "slick" with "sddm" so nothing can install
            # a third-party SDDM re-theme, during the build or afterwards.
            cat <<'EOF' > /etc/apt/preferences.d/no-slick-sddm.pref
# The login screen stays on Plasma's stock Breeze theme.
Package: *slick*sddm* *sddm*slick*
Pin: release *
Pin-Priority: -1
EOF
            # Safety net: purge any non-Breeze sddm-theme-* package that a
            # desktop metapackage may have pulled in (e.g. the resolver's
            # default sddm-theme-debian-maui). sddm-theme-breeze satisfies
            # sddm's theme dependency, so removing the others is safe.
            local _extra_sddm_themes
            _extra_sddm_themes="$(dpkg-query -W -f='${Package}\n' 'sddm-theme-*' 2>/dev/null | grep -vx 'sddm-theme-breeze' || true)"
            if [[ -n "$_extra_sddm_themes" ]]; then
                echo "=====> SDDM: removing non-Breeze theme packages: ${_extra_sddm_themes//$'\n'/ }"
                # shellcheck disable=SC2086
                apt-get purge -y $_extra_sddm_themes
            fi
            # Discover app store: Flatpak backend in, Snap backend pinned out
            # (see block_snapd). kde-plasma-desktop does not always pull
            # plasma-discover itself, so install it explicitly.
            echo "=====> Discover: plasma-discover + Flatpak backend (Snap backend blocked)"
            apt-get install -y plasma-discover plasma-discover-backend-flatpak
            ;;
        *)
            >&2 echo "Unsupported desktop variant '${TARGET_DESKTOP:-}'. Add install logic for this variant in customize_image()."
            exit 1
            ;;
    esac
    if [[ "${TARGET_DESKTOP:-gnome}" != "cli" ]]; then
        apt-get install -y plymouth plymouth-label plymouth-theme-ubuntu-text
    fi

    apt-get install -y curl wget apt-transport-https ca-certificates gnupg

    # Desktop-only software: web browsers and their vendor APT repositories.
    # Skipped entirely for the CLI/TTY-only profile so a CLI image never gets
    # browser repos or GUI browsers; the desktop-ready path is unchanged.
    if [[ "${TARGET_DESKTOP:-gnome}" != "cli" ]]; then
        install_desktop_browsers
    else
        echo "=====> profile: CLI/TTY-only -- skipping desktop browsers and their APT repositories"
    fi

    if [[ "${TARGET_PACSTALL:-1}" == "1" ]]; then
        echo "=====> Pacstall (official installer from https://pacstall.dev/q/install -- not Chaotic PPR / apt package)"
        # Subshell: restore DEBIAN_FRONTEND after upstream script. Pipe declines optional axel; GITHUB_ACTIONS quiets apt.
        local _pacstall_installer="/tmp/pacstall-install.sh"
        curl -fsSL https://pacstall.dev/q/install -o "$_pacstall_installer"
        (
            export DEBIAN_FRONTEND=noninteractive
            printf 'n\n' | env GITHUB_ACTIONS=true bash -e "$_pacstall_installer"
        )
        rm -f "$_pacstall_installer"
    else
        echo "=====> Pacstall: skipped (TARGET_PACSTALL=0)"
    fi

    # Ubuntu Studio is a GUI creative suite -- desktop-only. Never install it on
    # a CLI/TTY-only image even if the flag was set.
    if [[ "${TARGET_DESKTOP:-gnome}" != "cli" && "${TARGET_UBUNTU_STUDIO:-0}" == "1" ]]; then
        apt_install_available "Ubuntu Studio metapackages" \
            ubuntustudio-audio \
            ubuntustudio-graphics \
            ubuntustudio-photography \
            ubuntustudio-publishing \
            ubuntustudio-video \
            ubuntustudio-wallpapers \
            ubuntustudio-menu \
            ubuntu-edu-music
    fi

    # fwupd stays banned for the whole build (see block_fwupd). Pre-install it
    # only on explicit request; either way the installed system can add it
    # later because finish_up() drops the build-time pin.
    if [[ "${TARGET_FWUPD:-0}" == "1" ]]; then
        echo "=====> fwupd: pre-installing on request (lifting the build-time block)"
        unblock_fwupd
        apt-get install -y fwupd
    else
        echo "=====> fwupd: not pre-installed (blocked during build; 'sudo apt install fwupd' works on the installed system)"
    fi

    if [[ "${TARGET_OPENSSH_SERVER:-0}" == "1" ]]; then
        echo "=====> OpenSSH server: pre-installing"
        apt-get install -y openssh-server
        # The host keys generated by the package postinst are wiped in
        # finish_up() so every ISO/install does not share the same identity.
        # This oneshot unit regenerates them on first boot (ssh-keygen -A
        # only creates keys that are missing), ordered before ssh.service.
        cat <<'EOF' > /etc/systemd/system/ssh-host-keys-regen.service
[Unit]
Description=Regenerate missing SSH host keys
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl enable ssh-host-keys-regen.service
    else
        echo "=====> OpenSSH server: not pre-installed ('sudo apt install openssh-server' when needed)"
    fi

    # Cockpit upstream recommends the ${release}-backports build for the
    # latest version (https://cockpit-project.org/running.html#ubuntu);
    # chroot_prepare adds the backports pocket to sources.list. Fall back to
    # the main archive if the backports pocket has no cockpit yet.
    if [[ "${TARGET_COCKPIT:-0}" == "1" ]]; then
        echo "=====> Cockpit: pre-installing from ${TARGET_UBUNTU_VERSION}-backports"
        if ! apt-get install -y -t "${TARGET_UBUNTU_VERSION}-backports" cockpit; then
            echo "=====> Cockpit: no installable candidate in ${TARGET_UBUNTU_VERSION}-backports; installing from the main archive"
            apt-get install -y cockpit
        fi
    else
        echo "=====> Cockpit: not pre-installed ('sudo apt install -t ${TARGET_UBUNTU_VERSION}-backports cockpit' when needed)"
    fi

    apt-get install -y \
        git \
        vim \
        nano \
        less

    if [[ "${TARGET_DESKTOP:-gnome}" != "cli" ]]; then
        apt-get install -y flatpak
        flatpak remote-add --if-not-exists --system flathub \
            https://flathub.org/repo/flathub.flatpakrepo
    fi

    if [[ "${TARGET_DESKTOP:-gnome}" == "gnome" ]]; then
        apt-get install -y \
            gnome-software \
            gnome-software-plugin-flatpak
    fi

    apt-get purge -y --ignore-missing \
        transmission-gtk \
        transmission-common \
        aisleriot \
        hitori

    if [[ "${TARGET_DESKTOP:-gnome}" == "gnome" ]]; then
        apt-get purge -y --ignore-missing \
            gnome-mahjongg \
            gnome-mines \
            gnome-sudoku
    fi
}

# install_desktop_browsers -- vendor browser APT repositories (Brave, Librewolf,
# Mozilla) plus the optional browser pre-installs selected via
# TARGET_BRAVE_CHANNEL / TARGET_LIBREWOLF / TARGET_FIREFOX / TARGET_FIREFOX_ESR /
# TARGET_THUNDERBIRD. Desktop profiles only -- never called for the CLI/TTY-only
# image, so a CLI image never gets browser repos or GUI browsers.
function install_desktop_browsers() {
    # add-apt-repository (from software-properties-common) is only needed for the
    # Mozilla PPA below, which is a desktop-browser repository.
    apt-get install -y software-properties-common

    install -d /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d

    echo "=====> Browser APT sources: Brave release, Librewolf, Mozilla -- install packages only when selected"
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
    curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources

    curl -fsSL https://repo.librewolf.net/pubkey.gpg | gpg --dearmor -o /usr/share/keyrings/librewolf.gpg
    printf '%s\n' \
        "deb [arch=amd64 signed-by=/usr/share/keyrings/librewolf.gpg] https://repo.librewolf.net/ librewolf main" \
        > /etc/apt/sources.list.d/librewolf.list

    wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- \
        > /usr/share/keyrings/packages.mozilla.org.asc
    printf '%s\n' \
        "deb [signed-by=/usr/share/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list
    add-apt-repository ppa:mozillateam/ppa -y
    cat <<'EOF' > /etc/apt/preferences.d/mozilla
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox
Pin: release o=Ubuntu
Pin-Priority: -1

Package: firefox
Pin: origin ppa.launchpadcontent.net
Pin-Priority: -1

Package: firefox-esr
Pin: origin ppa.launchpadcontent.net
Pin-Priority: 1000

Package: thunderbird
Pin: origin ppa.launchpadcontent.net
Pin-Priority: 1000
EOF

    apt-get update

    echo "=====> Browser vendor APT: Brave (release), Librewolf, and Mozilla sources + keyrings are on disk"
    echo "       (optional installs below only; you can apt install later without re-adding repositories)."

    case "${TARGET_BRAVE_CHANNEL:-release}" in
        release)
            echo "=====> install: Brave stable"
            apt-get install -y brave-browser
            ;;
        origin)
            echo "=====> install: Brave Origin"
            apt-get install -y brave-origin
            ;;
        none)
            echo "=====> Brave: not pre-installed (Brave APT sources above remain; apt install brave-browser | brave-origin when ready)"
            ;;
        *)
            >&2 echo "TARGET_BRAVE_CHANNEL must be none, release, or origin (got: '${TARGET_BRAVE_CHANNEL:-}')."
            exit 1
            ;;
    esac

    if [[ "${TARGET_LIBREWOLF:-0}" == "1" ]]; then
        apt-get install -y librewolf
    else
        echo "=====> Librewolf: not pre-installed (Librewolf repo above remains; apt install librewolf when ready)"
    fi

    if [[ "${TARGET_FIREFOX:-0}" == "1" ]]; then
        # The desktop metapackage may already have pulled in Ubuntu's
        # epoch-versioned firefox stub (1:1snapX...) before the Mozilla pin
        # existed; moving to Mozilla's epoch-less build is then a downgrade,
        # and -y without --allow-downgrades aborts the build.
        apt-get install -y --allow-downgrades firefox
    else
        echo "=====> Firefox: not pre-installed (Mozilla repo + pin above remain; apt install firefox when ready)"
    fi

    if [[ "${TARGET_FIREFOX_ESR:-0}" == "1" ]]; then
        apt-get install -y firefox-esr
    else
        echo "=====> Firefox ESR: not pre-installed (Mozilla PPA + pin above remain; apt install firefox-esr when ready)"
    fi

    if [[ "${TARGET_THUNDERBIRD:-0}" == "1" ]]; then
        apt-get install -y thunderbird
    else
        echo "=====> Thunderbird: not pre-installed (Mozilla PPA + pin above remain; apt install thunderbird when ready)"
    fi
}

function check_settings() {
    assert_supported_release || exit 1
    normalize_desktop_variant
    if [[ ! "${TARGET_UBUNTU_MIRROR:-}" =~ ^https?://[^[:space:]]+$ ]]; then
        >&2 echo "TARGET_UBUNTU_MIRROR must be a valid http:// or https:// URL (got: '${TARGET_UBUNTU_MIRROR:-}')."
        exit 1
    fi
    assert_bool_var TARGET_GNOME_INSTALL_RECOMMENDS
    case "${TARGET_KDE_PACKAGE:-kde-standard}" in
        kde-full|kde-standard|kde-plasma-desktop)
            ;;
        *)
            >&2 echo "TARGET_KDE_PACKAGE must be kde-full, kde-standard, or kde-plasma-desktop (got: '${TARGET_KDE_PACKAGE:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_BROWSER:-}" in
        ""|release|origin)
            ;;
        *)
            >&2 echo "TARGET_BROWSER legacy env must be empty, release, or origin (got: '${TARGET_BROWSER:-}'). Use TARGET_BRAVE_CHANNEL."
            exit 1
            ;;
    esac
    case "${TARGET_BRAVE_CHANNEL:-release}" in
        none|release|origin)
            ;;
        *)
            >&2 echo "TARGET_BRAVE_CHANNEL must be none, release, or origin (got: '${TARGET_BRAVE_CHANNEL:-}')."
            exit 1
            ;;
    esac
    assert_bool_var TARGET_LIBREWOLF
    assert_bool_var TARGET_FIREFOX
    assert_bool_var TARGET_FIREFOX_ESR
    assert_bool_var TARGET_THUNDERBIRD
    assert_bool_var TARGET_UBUNTU_STUDIO
    assert_bool_var TARGET_PACSTALL 1
    assert_bool_var TARGET_FWUPD
    assert_bool_var TARGET_OPENSSH_SERVER
    assert_bool_var TARGET_COCKPIT
    if [[ "${TARGET_DESKTOP:-}" == "mate" ]]; then
        case "${TARGET_MATE_PACKAGE:-mate-desktop-environment}" in
            full)
                export TARGET_MATE_PACKAGE="mate-desktop-environment"
                ;;
            core)
                export TARGET_MATE_PACKAGE="mate-desktop-environment-core"
                ;;
        esac
        case "${TARGET_MATE_PACKAGE:-mate-desktop-environment}" in
            mate-desktop-environment|mate-desktop-environment-core)
                ;;
            *)
                >&2 echo "TARGET_MATE_PACKAGE must be mate-desktop-environment or mate-desktop-environment-core (got: '${TARGET_MATE_PACKAGE:-}'). Use --mate=full|core or full APT names."
                exit 1
                ;;
        esac
        assert_bool_var TARGET_MATE_EXTRAS
    fi
    case "${TARGET_FIRMWARE:-uefi}" in
        uefi|hybrid)
            ;;
        *)
            >&2 echo "TARGET_FIRMWARE must be uefi (UEFI-only) or hybrid (BIOS + UEFI; got: '${TARGET_FIRMWARE:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_NETWORK_STACK:-networkd}" in
        networkd|network-manager)
            ;;
        *)
            >&2 echo "TARGET_NETWORK_STACK must be networkd or network-manager (got: '${TARGET_NETWORK_STACK:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_IMG_ALLOC:-truncate}" in
        truncate|fallocate|dd)
            ;;
        *)
            >&2 echo "TARGET_IMG_ALLOC must be truncate, fallocate, or dd (got: '${TARGET_IMG_ALLOC:-}')."
            exit 1
            ;;
    esac
    if [[ ! "${TARGET_DISK_SIZE_GB:-32}" =~ ^[0-9]+$ ]] || [[ "${TARGET_DISK_SIZE_GB:-32}" -lt 10 ]]; then
        >&2 echo "TARGET_DISK_SIZE_GB must be a whole number of GB, at least 10 (got: '${TARGET_DISK_SIZE_GB:-}')."
        exit 1
    fi
    case "${TARGET_IMAGE_PROFILE:-desktop}" in
        desktop|cli)
            ;;
        *)
            >&2 echo "TARGET_IMAGE_PROFILE must be desktop or cli (got: '${TARGET_IMAGE_PROFILE:-}')."
            exit 1
            ;;
    esac
    case "${TARGET_USER_MODE:-deploy}" in
        build|deploy)
            ;;
        *)
            >&2 echo "TARGET_USER_MODE must be build or deploy (got: '${TARGET_USER_MODE:-}')."
            exit 1
            ;;
    esac
    if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]] && [[ -n "${TARGET_USERNAME:-}" ]] && \
       [[ ! "${TARGET_USERNAME}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        >&2 echo "TARGET_USERNAME must be a valid Linux username (got: '${TARGET_USERNAME}')."
        exit 1
    fi
}

# shellcheck disable=SC2120  # called indirectly with an error message via parse_cmd_range/cmd_find_index
function host_help() {
    if [ -z "${1+x}" ]; then
        echo "This script builds a ready-to-deploy Ubuntu cloud disk image (.img)."
        echo
    else
        echo "$1"
        echo
    fi

    echo "Supported commands: ${HOST_CMD[*]}"
    echo
    echo "Options:"
    echo "  --release=jammy|noble|resolute          Target Ubuntu release (omit to be prompted on a TTY)"
    echo "  --mirror=URL                            Ubuntu package mirror"
    echo "  UBUNTU_VANILLA_WORKSPACE=DIR             Parent directory for build workspace (optional; overrides mode defaults:"
    echo "                                           basic = /var/cache/ubuntu-vanilla-build, advanced = ~/uvb-workspace)"
    echo "  UVB_OUTPUT_DIR=DIR                       Directory for the finished image + checksums (optional; default: your home directory)"
    echo "  TARGET_DESKTOP=<desktop>                  Desktop variant slug (optional; default gnome)"
    echo "  TARGET_KDE_PACKAGE=kde-full|kde-standard|kde-plasma-desktop  KDE package when desktop is kde-plasma (optional; default kde-standard)"
    echo "  TARGET_MATE_PACKAGE=mate-desktop-environment|mate-desktop-environment-core  MATE metapackage when desktop is mate (optional; full|core aliases OK)"
    echo "  TARGET_MATE_EXTRAS=0|1            Also install mate-desktop-environment-extras when desktop is mate (optional; default 0)"
    echo "  TARGET_BRAVE_CHANNEL=none|release|origin   Pre-install Brave build (both Brave APT repos always added)"
    echo "  TARGET_BROWSER=release|origin               Legacy alias for Brave channel if TARGET_BRAVE_CHANNEL unset"
    echo "  TARGET_LIBREWOLF=0|1                    Pre-install Librewolf (optional; default 0; repo always added)"
    echo "  TARGET_FIREFOX=0|1                       Pre-install Firefox from Mozilla APT (optional; default 0; repo always added)"
    echo "  TARGET_FIREFOX_ESR=0|1                   Pre-install Firefox ESR from Mozilla PPA (optional; default 0; PPA always added)"
    echo "  TARGET_THUNDERBIRD=0|1                   Pre-install Thunderbird from Mozilla PPA (optional; default 0; PPA always added)"
    echo "  TARGET_UBUNTU_STUDIO=0|1                 Ubuntu Studio metapackages (optional; default 0)"
    echo "  TARGET_FWUPD=0|1                         Pre-install fwupd (optional; default 0; fwupd is blocked during the build either way)"
    echo "  TARGET_OPENSSH_SERVER=0|1                Pre-install openssh-server (optional; default 0)"
    echo "  TARGET_COCKPIT=0|1                       Pre-install Cockpit from the backports pocket (optional; default 0)"
    echo "  TARGET_GNOME_INSTALL_RECOMMENDS=0|1       GNOME install with recommends (optional; default 0)"
    echo "  --kernel=generic|lowlatency             Kernel type to install"
    echo "  --desktop=<desktop>                      Desktop variant (gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, kde-plasma)"
    echo "  --kde=kde-full|kde-standard|kde-plasma-desktop  KDE package tier (used with --desktop=kde-plasma)"
    echo "  --mate=full|core|mate-desktop-environment|mate-desktop-environment-core  MATE tier (used with --desktop=mate; default full)"
    echo "  --mate-extras / --no-mate-extras        Pre-install mate-desktop-environment-extras (with --desktop=mate)"
    echo "  --brave=none|release|origin       Brave channel (default release; none skips Brave)"
    echo "  --browser=release|origin            Same as --brave for the two Brave archives (legacy)"
    echo "  --librewolf / --no-librewolf             Pre-install Librewolf (APT repo always configured)"
    echo "  --firefox / --no-firefox               Pre-install Firefox (Mozilla APT always configured)"
    echo "  --firefox-esr / --no-firefox-esr       Pre-install Firefox ESR (Mozilla PPA always configured)"
    echo "  --thunderbird / --no-thunderbird       Pre-install Thunderbird (Mozilla PPA always configured)"
    echo "  --ubuntu-studio / --no-ubuntu-studio     Ubuntu Studio metapackage set (heavy)"
    echo "  --pacstall / --no-pacstall               Install Pacstall package manager (default: yes)"
    echo "  --fwupd / --no-fwupd                     Pre-install fwupd (default: no; blocked during the build either way)"
    echo "  --openssh-server / --no-openssh-server   Pre-install openssh-server (default: no)"
    echo "  --cockpit / --no-cockpit                 Pre-install Cockpit from backports (default: no)"
    echo "  --firmware=uefi|hybrid                   uefi = UEFI-only; hybrid = BIOS + UEFI on one disk (default uefi)"
    echo "  --network=networkd|network-manager       Network stack for CLI images (default networkd; desktop images always use NetworkManager)"
    echo "  --alloc-tool=truncate|fallocate|dd       How the raw .img is created: sparse, preallocated, or dd zero-written (default truncate)"
    echo "  --disk-size=32|64|128|<GB>               Disk image size in GB (default 32; minimum 10)"
    echo "  --profile=desktop|cli                    Desktop-ready or CLI/TTY-only image (default desktop)"
    echo "  --user-mode=build|deploy                 build = bake credentials now; deploy = create the user after deployment"
    echo "  --username=NAME / --password=PASS        Credentials for --user-mode=build (prompted on a TTY if omitted)"
    echo "  --fullname=NAME                          Full name (GECOS) for the baked user (optional)"
    echo "  --hostname=NAME                          Hostname baked into the image (optional)"
    echo "  --locale=LOCALE                          System locale (e.g. en_US.UTF-8) for unattended builds"
    echo "  --keyboard-layout=LAYOUT                 Keyboard layout code (e.g. us, de, fr) for unattended builds"
    echo "  --keyboard-variant=VARIANT               Keyboard variant (e.g. intl, nodeadkeys; optional)"
    echo
    echo "Advanced mode (--advanced; also offered by the startup mode prompt):"
    echo "  --advanced                               Enable advanced mode (config file, workspace preservation, package cache)"
    echo "  --interactive                            Force interactive prompts even if stdin is not a TTY (advanced only)"
    echo "  --no-interactive                         Disable all interactive prompts, use defaults or fail (advanced only)"
    echo "  --config=FILE                            Load build options from a .cfg file (KEY=VALUE format; advanced mode only)"
    echo "  --generate-config                        Launch config wizard to generate a build-img.cfg file"
    echo "  --hooks-dir=PATH                         Custom hooks directory (default: scripts/hooks/)"
    echo
    echo "Syntax: $0 [options] [start_cmd] [-] [end_cmd]"
    echo "  Run from start_cmd to end_cmd"
    echo "  If no start_cmd/end_cmd are given, all host steps run (same as '-')"
    echo "  If start_cmd is given without '-', only that command runs"
    echo "  If end_cmd is omitted (with a start_cmd), stop after the selected start_cmd"
    echo "  Use '-' by itself to run all commands explicitly"
    echo
    echo "Build stages (HOST_CMD -- run in order; run one alone or a range with '-'):"
    echo "  setup_host         Install host tools (debootstrap, parted, dosfstools,"
    echo "                     e2fsprogs, rsync) and prepare a fresh workspace."
    echo "  debootstrap        Bootstrap the minimal Ubuntu base (--variant=minbase) from the"
    echo "                     mirror into <workspace>/chroot. Advanced mode reuses it."
    echo "  run_chroot         Bind-mount /dev /run /proc /sys, copy this script into the"
    echo "                     chroot, and run the chroot phase inside it (sub-stages below)."
    echo "  build_disk_image   Create the raw .img (truncate/fallocate/dd), partition it GPT,"
    echo "                     make filesystems, rsync the chroot in, install GRUB for the"
    echo "                     chosen firmware, then bake the user in or defer it."
    echo "                     Writes SHA-1/SHA-256 checksums."
    echo
    echo "Chroot phase sub-stages (CHROOT_CMD -- run automatically inside run_chroot):"
    echo "  chroot_prepare   APT sources (release/-security/-updates/-backports), hostname,"
    echo "                   machine-id, snapd + build-time fwupd APT pins."
    echo "  install_pkg      Upgrade the base; install kernel + GRUB, cloud-init, the chosen"
    echo "                   desktop unless --profile=cli, browsers, optional extras,"
    echo "                   and locale/keyboard settings."
    echo "  finish_up        Cleanup: remove SSH host keys, truncate machine-id, drop the"
    echo "                   build-time fwupd pin, clear /tmp."
    echo
    echo "Configuration precedence (highest wins):"
    echo "  CLI flags  >  config file (--config, advanced mode)  >  environment variables"
    echo "  >  interactive prompts (on a TTY)  >  the built-in defaults shown above."
    echo
    echo "Disk image layout & options:"
    echo "  Firmware  --firmware=uefi|hybrid. uefi = UEFI-only (GPT + 512 MB ESP). hybrid ="
    echo "            BIOS + UEFI on one disk: adds a 1 MiB BIOS-boot partition and installs"
    echo "            GRUB for both the i386-pc and x86_64-efi targets."
    echo "  Size      --disk-size=32|64|128|<GB> (minimum 10). Fixed layout: ESP 512 MB +"
    echo "            swap 4 GB + root = the rest (a 32 GB image leaves ~27.5 GB for root)."
    echo "  Alloc     --alloc-tool=truncate|fallocate|dd. How the .img file is created:"
    echo "            sparse (default), preallocated, or fully zero-written with dd."
    echo "  Profile   --profile=desktop|cli. Desktop-ready, or CLI/TTY-only (no desktop)."
    echo "  Network   --network=networkd|network-manager (CLI images; desktop always uses NM)."
    echo "  User      --user-mode=build|deploy. build bakes --username/--password (and optional"
    echo "            --fullname/--hostname) in now; deploy leaves the user to cloud-init."
    echo
    echo "Output:  <output-dir>/<name>.img  plus  <name>.img.sha1  and  <name>.img.sha256"
    echo "  Default <name>: ubuntu-<version>-<desktop|cli>-cloud-amd64-<UTC-timestamp>."
    echo "  Default output dir: your home directory (UVB_OUTPUT_DIR overrides). Workspace:"
    echo "  <parent>/workspace-img (basic parent /var/cache/ubuntu-vanilla-build,"
    echo "  advanced ~/uvb-workspace) -- separate from the other builders so nothing collides."
    echo
    echo "Examples:"
    echo "  $0                                     Guided interactive build (all stages)"
    echo "  $0 --release=noble --kernel=generic --profile=cli --firmware=uefi -"
    echo "  $0 --profile=desktop --desktop=gnome --disk-size=64 --alloc-tool=dd \\"
    echo "       --user-mode=build --username=alice --password=secret --hostname=vm01 -"
    echo "  $0 --advanced --config=build-img.cfg --no-interactive -    Unattended from a config"
    echo "  $0 --advanced run_chroot               Re-run only the chroot phase (advanced)"
    echo "  $0 debootstrap - build_disk_image      Run debootstrap through image assembly"
    echo
    exit 0
}

function check_host_user() {
    # Detect the host's package family (deb / rpm / arch). This populates
    # HOST_PKG_FAMILY etc. and errors out on truly unsupported hosts.
    host_pkg_detect

    # On a Debian host (not Ubuntu or an Ubuntu derivative) we still need
    # the Ubuntu archive keyring so debootstrap can verify Ubuntu release
    # signatures. The other families don't have this requirement.
    if [[ "${HOST_PKG_FAMILY}" == "deb" ]] && \
       { [[ "${ID:-}" == "debian" ]] || [[ "${ID_LIKE:-}" == *debian* ]]; } && \
       { [[ "${ID:-}" != "ubuntu" ]] && [[ "${ID_LIKE:-}" != *ubuntu* ]]; }; then
        if ! dpkg -s ubuntu-archive-keyring &>/dev/null; then
            >&2 echo "ERROR: On Debian, install the Ubuntu archive keyring before building (required for debootstrap from Ubuntu mirrors):"
            >&2 echo "  sudo apt install ubuntu-archive-keyring"
            exit 1
        fi
    fi
}

# Package cache: persistent directory bind-mounted into the chroot's APT cache.
# Only used in advanced mode. Survives across builds to save bandwidth.
PKG_CACHE_MOUNTED=0

function resolve_package_cache_dir() {
    local _cache="${XDG_CACHE_HOME:-${HOME:-/root}/.cache}"
    echo "$_cache/ubuntu-vanilla-build/apt-cache"
}

function mount_package_cache() {
    if [[ "${ADVANCED_MODE:-0}" != "1" ]]; then
        return 0
    fi
    local cache_dir
    cache_dir="$(resolve_package_cache_dir)"
    local chroot_apt_cache="$WORKSPACE_CHROOT/var/cache/apt/archives"

    host_priv mkdir -p "$cache_dir"
    host_priv mkdir -p "$chroot_apt_cache"

    if mountpoint -q "$chroot_apt_cache" 2>/dev/null; then
        PKG_CACHE_MOUNTED=1
        return 0
    fi

    echo "=====> [advanced] Mounting package cache: $cache_dir"
    host_priv mount --bind "$cache_dir" "$chroot_apt_cache"
    PKG_CACHE_MOUNTED=1
}

function unmount_package_cache() {
    if [[ "$PKG_CACHE_MOUNTED" -eq 0 ]]; then
        return 0
    fi
    local chroot_apt_cache="$WORKSPACE_CHROOT/var/cache/apt/archives"
    if mountpoint -q "$chroot_apt_cache" 2>/dev/null; then
        echo "=====> [advanced] Unmounting package cache"
        host_priv umount -l "$chroot_apt_cache" 2>/dev/null || true
    fi
    PKG_CACHE_MOUNTED=0
}

function ensure_workspace_root() {
    host_priv mkdir -p "$WORKSPACE_DIR"
}

function clean_workspace() {
    if [[ -e "$WORKSPACE_DIR" ]]; then
        echo "=====> removing workspace ..."
        host_priv rm -rf "$WORKSPACE_DIR"
    fi
}

function chroot_enter_setup() {
    host_priv mount --bind /dev "$WORKSPACE_CHROOT/dev"
    host_priv mount --bind /run "$WORKSPACE_CHROOT/run"
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t proc /proc
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t sysfs /sys
    host_priv chroot "$WORKSPACE_CHROOT" mount none -t devpts /dev/pts
}

function chroot_exit_teardown() {
    [[ -z "${WORKSPACE_CHROOT:-}" ]] && return 0
    # Unmount from the host so we still unwind if chroot is unusable; order: inner mounts, then bind mounts.
    local _mp _rc
    for _mp in "$WORKSPACE_CHROOT/dev/pts" "$WORKSPACE_CHROOT/proc" "$WORKSPACE_CHROOT/sys" "$WORKSPACE_CHROOT/run" "$WORKSPACE_CHROOT/dev"; do
        if mountpoint -q "$_mp" 2>/dev/null; then
            _rc=0
            host_priv umount -l "$_mp" 2>/dev/null || _rc=$?
            if [[ $_rc -ne 0 ]]; then
                echo "  WARN  umount -l '$_mp' failed (exit $_rc); mount may be stale" >&2
            fi
        fi
    done
}

# On failed or interrupted host build: drop chroot mounts (if any).
# In default mode: also remove the workspace tree so leftover mounts do not require a reboot to clear.
# In advanced mode: only unmount, preserve workspace for faster re-runs.
function host_abort_cleanup() {
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        return 0
    fi
    HOST_ABORT_CLEANUP_DONE=1
    detach_image_loop || true
    chroot_exit_teardown || true
    unmount_package_cache || true
    if [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        echo "=====> [advanced] Workspace preserved at: ${WORKSPACE_DIR:-unknown}" >&2
        echo "=====> [advanced] Re-run individual stages (e.g. run_chroot) to continue." >&2
    else
        echo "=====> unmounting chroot bind mounts and removing workspace ..." >&2
        if [[ -n "${WORKSPACE_DIR:-}" ]]; then
            clean_workspace || true
        fi
    fi
}

function host_build_exit_trap() {
    local _st=$?
    cleanup_sudo_keepalive || true
    if [[ "$_st" -ne 0 ]] && [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 0 ]]; then
        host_abort_cleanup
    fi
    exit "$_st"
}

# host_build_signal_trap EXIT_CODE  -- shared handler for INT (130) and TERM (143).
function host_build_signal_trap() {
    local code="$1"
    if [[ "${HOST_ABORT_CLEANUP_DONE:-0}" -eq 1 ]]; then
        exit "$code"
    fi
    host_abort_cleanup
    exit "$code"
}

function setup_host() {
    echo "=====> running setup_host ..."

    # Canonical (Debian-style) host dependency names. The host-package
    # abstraction (see host-pkg.sh) translates these to the host family's
    # own package names (squashfs-tools -> squashfs on openSUSE,
    # xorriso -> libisoburn on Arch, etc.).
    local -a _host_deps=(debootstrap parted dosfstools e2fsprogs rsync)
    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        _host_deps+=(qemu-utils)
    fi
    # On Arch-based hosts, also pull the keyrings debootstrap needs to
    # verify Ubuntu/Debian release signatures. Arch has no built-in trust
    # for the Ubuntu or Debian archives, so these have to be installed
    # explicitly (they live in [extra] / AUR on Arch and are pulled via
    # pacman here).
    if [[ "${HOST_PKG_FAMILY}" == "arch" ]]; then
        _host_deps+=(ubuntu-keyring debian-archive-keyring debian-ports-archive-keyring)
    fi

    local skip_install=0
    if [[ "${LAUNCHED_FROM_START_HERE:-0}" -eq 1 ]]; then
        if [[ "${HOST_PKG_FAMILY}" == "deb" ]]; then
            if host_pkg_is_installed "${_host_deps[@]}" \
               && { ! host_pkg_is_installed ubuntu-archive-keyring || \
                    { [[ "${ID:-}" == "ubuntu" ]] || [[ "${ID_LIKE:-}" == *ubuntu* ]]; }; }; then
                skip_install=1
            fi
        elif [[ -n "${HOST_PKG_FAMILY}" ]]; then
            if host_pkg_is_installed "${_host_deps[@]}"; then
                skip_install=1
            fi
        fi
    fi

    if [[ "$skip_install" -eq 1 ]]; then
        echo "=====> Host dependencies already installed. Skipping ${HOST_PKG_MANAGER} update and installation."
    else
        host_pkg_refresh
        host_pkg_install "${_host_deps[@]}"
    fi

    if [[ "${ADVANCED_MODE:-0}" == "1" ]] && [[ -d "$WORKSPACE_CHROOT" ]]; then
        echo "=====> [advanced] Reusing existing workspace: $WORKSPACE_DIR"
    else
        clean_workspace
        ensure_workspace_root
        host_priv mkdir -p "$WORKSPACE_CHROOT"
    fi
}

function debootstrap() {
    # Advanced mode preserves the workspace across runs; re-running debootstrap
    # into an already-bootstrapped chroot fails midway and corrupts it.
    if [[ "${ADVANCED_MODE:-0}" == "1" ]] && [[ -f "$WORKSPACE_CHROOT/etc/os-release" ]]; then
        echo "=====> [advanced] Chroot already bootstrapped at $WORKSPACE_CHROOT -- skipping debootstrap."
        echo "=====> [advanced] Delete the workspace to force a fresh bootstrap."
        return 0
    fi
    echo "=====> running debootstrap ... this will take a few minutes ..."
    # On openSUSE, debootstrap is not packaged with the Ubuntu/Debian
    # archive keyrings -- ensure the Ubuntu archive keyring is on the host
    # and hand it to debootstrap explicitly via --keyring so it can verify
    # the Ubuntu Release signature.
    local -a _debootstrap_extra=()
    if [[ "${HOST_PKG_FAMILY}" == "rpm" ]]; then
        ensure_ubuntu_keyring_for_opensuse
        _debootstrap_extra=(--keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg)
    fi
    local _debootstrap_path="${PATH}" _debootstrap_shim=""
    if [[ "${HOST_PKG_FAMILY}" == "arch" ]] && command -v pacman-conf >/dev/null 2>&1 && [[ "$(pacman-conf Architecture 2>/dev/null)" == *[[:space:]]* ]]; then
        _debootstrap_shim="$(mktemp -d "${TMPDIR:-/tmp}/debootstrap-path.XXXXXX")"
        printf "%s\n" "#!/bin/sh" "exec /usr/bin/pacman-conf \"\$@\" | /usr/bin/head -n 1" >"${_debootstrap_shim}/pacman-conf"
        chmod 0755 "${_debootstrap_shim}/pacman-conf"
        export PATH="${_debootstrap_shim}:${PATH}"
    fi
    host_priv env "PATH=${PATH}" debootstrap --arch=amd64 --variant=minbase \
        "${_debootstrap_extra[@]}" \
        "$TARGET_UBUNTU_VERSION" "$WORKSPACE_CHROOT" "$TARGET_UBUNTU_MIRROR"
    PATH="${_debootstrap_path}"
    [[ -n "${_debootstrap_shim}" ]] && rm -rf "${_debootstrap_shim}"
}

function run_chroot() {
    echo "=====> running run_chroot ..."

    # Run pre-chroot hooks on the host (modloader: pre-chroot stage).
    WORKSPACE_CHROOT="$WORKSPACE_CHROOT" run_hooks pre-chroot

    chroot_enter_setup
    mount_package_cache

    host_priv cp "$SCRIPT_DIR/$SCRIPT_NAME" "$WORKSPACE_CHROOT/root/build.sh"

    # Copy hooks into chroot so chroot-phase hooks can run inside.
    host_priv rm -rf "$WORKSPACE_CHROOT/root/hooks"
    local _hooks_base="${HOOKS_DIR:-$SCRIPT_DIR/hooks}"
    if [[ -d "$_hooks_base/chroot" ]]; then
        host_priv mkdir -p "$WORKSPACE_CHROOT/root/hooks"
        host_priv cp -a "$_hooks_base/chroot" "$WORKSPACE_CHROOT/root/hooks/chroot"
    fi

    host_priv chroot "$WORKSPACE_CHROOT" /usr/bin/env \
        DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-readline}" \
        TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION}" \
        TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR}" \
        TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}" \
        TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}" \
        TARGET_DESKTOP="${TARGET_DESKTOP:-gnome}" \
        TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-kde-standard}" \
        TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}" \
        TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}" \
        TARGET_BROWSER="${TARGET_BROWSER:-}" \
        TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-release}" \
        TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}" \
        TARGET_FIREFOX="${TARGET_FIREFOX:-0}" \
        TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}" \
        TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}" \
        TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}" \
        TARGET_PACSTALL="${TARGET_PACSTALL:-1}" \
        TARGET_FWUPD="${TARGET_FWUPD:-0}" \
        TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}" \
        TARGET_COCKPIT="${TARGET_COCKPIT:-0}" \
        TARGET_LOCALE="${TARGET_LOCALE:-}" \
        TARGET_KEYBOARD_LAYOUT="${TARGET_KEYBOARD_LAYOUT:-}" \
        TARGET_KEYBOARD_VARIANT="${TARGET_KEYBOARD_VARIANT:-}" \
        TARGET_GNOME_INSTALL_RECOMMENDS="${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" \
        TARGET_NAME="${TARGET_NAME}" \
        TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE:-desktop}" \
        TARGET_NETWORK_STACK="${TARGET_NETWORK_STACK:-}" \
        UVB_IMAGE_KIND="${UVB_IMAGE_KIND}" \
        /root/build.sh --chroot-internal -

    host_priv rm -f "$WORKSPACE_CHROOT/root/build.sh"
    host_priv rm -rf "$WORKSPACE_CHROOT/root/hooks"

    unmount_package_cache
    chroot_exit_teardown
}

function write_output_hashes() {
    local file="$1"
    echo "=====> writing SHA-1 and SHA-256 for ${file##*/} ..."
    (
        cd "$OUTPUT_DIR"
        # tee via host_priv: the output directory may be root-owned.
        sha1sum "${file##*/}" | host_priv tee "${file##*/}.sha1" >/dev/null
        sha256sum "${file##*/}" | host_priv tee "${file##*/}.sha256" >/dev/null
    )
    OUTPUT_FILES+=("$file" "$file.sha1" "$file.sha256")
}

# The image and checksums are produced by privileged commands, so they come
# out root-owned. Hand them back to the human who launched the build.
function fix_output_ownership() {
    local owner=""
    if [[ "$(id -u)" -eq 0 ]]; then
        [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && owner="$SUDO_USER"
    else
        owner="$(id -un)"
    fi
    [[ -z "$owner" ]] && return 0
    local f
    for f in "${OUTPUT_FILES[@]}"; do
        [[ -e "$f" ]] && host_priv chown "$owner" "$f" 2>/dev/null || true
    done
}

function ensure_output_dir() {
    if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
        host_priv mkdir -p "$OUTPUT_DIR"
    fi
}

# Unwind the disk image mounts and the loop device. Also called from the
# abort path, so everything is best-effort and re-entrant.
function detach_image_loop() {
    if [[ -n "${IMG_MOUNT_DIR:-}" ]]; then
        local _mp
        for _mp in "$IMG_MOUNT_DIR/dev/pts" "$IMG_MOUNT_DIR/dev" "$IMG_MOUNT_DIR/proc" \
                   "$IMG_MOUNT_DIR/sys" "$IMG_MOUNT_DIR/run" "$IMG_MOUNT_DIR/boot/efi" \
                   "$IMG_MOUNT_DIR"; do
            if mountpoint -q "$_mp" 2>/dev/null; then
                host_priv umount -l "$_mp" 2>/dev/null || true
            fi
        done
    fi
    if [[ -n "${IMG_LOOP_DEV:-}" ]]; then
        host_priv losetup -d "$IMG_LOOP_DEV" 2>/dev/null || true
    fi
    IMG_LOOP_DEV=""
    IMG_MOUNT_DIR=""
}

# in_target CMD...  -- run a command inside the mounted disk image.
function in_target() {
    host_priv chroot "$IMG_MOUNT_DIR" /usr/bin/env \
        DEBIAN_FRONTEND=noninteractive LC_ALL=C HOME=/root "$@"
}

function create_baked_user() {
    echo "=====> creating user '${TARGET_USERNAME}' inside the image (build-time credentials) ..."
    in_target useradd -m -s /bin/bash -c "${TARGET_USER_FULLNAME:-$TARGET_USERNAME}" "$TARGET_USERNAME"
    local grp
    for grp in adm cdrom dip plugdev sudo lxd; do
        if in_target getent group "$grp" >/dev/null 2>&1; then
            in_target usermod -aG "$grp" "$TARGET_USERNAME"
        fi
    done
    printf '%s:%s
' "$TARGET_USERNAME" "$TARGET_USER_PASSWORD" | in_target chpasswd
}

# Cloud images with baked credentials: point cloud-init's default user at the
# baked account so provider-injected SSH keys and user-data land there
# (instead of a separate 'ubuntu' user), and allow password login.
function configure_cloud_init_user() {
    if [[ "$UVB_IMAGE_KIND" != "cloud" ]] || [[ "${TARGET_USER_MODE:-deploy}" != "build" ]]; then
        return 0
    fi
    host_priv mkdir -p "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d"
    host_priv tee "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d/90-uvb-default-user.cfg" >/dev/null <<EOF
# Written by $SCRIPT_NAME: the default user is the account baked in at build time.
system_info:
  default_user:
    name: ${TARGET_USERNAME}
    lock_passwd: false
    gecos: ${TARGET_USER_FULLNAME:-$TARGET_USERNAME}
    groups: [adm, cdrom, dip, plugdev, sudo]
    shell: /bin/bash
ssh_pwauth: true
EOF
}

# VM images without baked credentials: a first-boot wizard on the VM console
# asks for username/password/hostname, creates the account, then disables
# itself (flag file /var/lib/uvb-firstboot-pending).
function install_firstboot_user_wizard() {
    echo "=====> installing the first-boot user wizard (runs on the VM console at first boot) ..."
    host_priv tee "$IMG_MOUNT_DIR/usr/local/sbin/uvb-firstboot-setup" >/dev/null <<'WIZARD_EOF'
#!/bin/bash
# First-boot account wizard: asks for a username/password/hostname on the
# console, creates the account, then disables itself. Installed by the
# Ubuntu Vanilla image builder.
set -u
echo
echo "=================================================================="
echo "  Welcome! Let's create your user account for this system."
echo "=================================================================="
echo
username=""
while true; do
    read -r -p "Username: " username
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "Invalid username (lowercase letters, digits, '-' and '_')."
        continue
    fi
    if id "$username" &>/dev/null; then
        echo "User '$username' already exists -- pick another name."
        continue
    fi
    break
done
read -r -p "Full name (optional): " fullname
while true; do
    read -r -s -p "Password: " pw1; echo
    read -r -s -p "Confirm password: " pw2; echo
    [[ -n "$pw1" && "$pw1" == "$pw2" ]] && break
    echo "Passwords are empty or do not match -- try again."
done
read -r -p "Hostname [$(cat /etc/hostname)]: " newhost
useradd -m -s /bin/bash -c "${fullname:-$username}" "$username"
for grp in adm cdrom dip plugdev sudo lxd; do
    getent group "$grp" >/dev/null && usermod -aG "$grp" "$username"
done
printf '%s:%s
' "$username" "$pw1" | chpasswd
if [[ -n "$newhost" ]]; then
    echo "$newhost" > /etc/hostname
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${newhost}/" /etc/hosts || true
    hostname "$newhost" 2>/dev/null || true
fi
rm -f /var/lib/uvb-firstboot-pending
echo
echo "User '$username' created. Continuing boot ..."
sleep 1
exit 0
WIZARD_EOF
    host_priv chmod 0755 "$IMG_MOUNT_DIR/usr/local/sbin/uvb-firstboot-setup"

    host_priv tee "$IMG_MOUNT_DIR/etc/systemd/system/uvb-firstboot-setup.service" >/dev/null <<'UNIT_EOF'
[Unit]
Description=First-boot user account wizard
ConditionPathExists=/var/lib/uvb-firstboot-pending
After=systemd-user-sessions.service
Before=getty@tty1.service display-manager.service

[Service]
Type=oneshot
RemainAfterExit=yes
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
ExecStart=/usr/local/sbin/uvb-firstboot-setup

[Install]
WantedBy=multi-user.target
UNIT_EOF
    host_priv touch "$IMG_MOUNT_DIR/var/lib/uvb-firstboot-pending"
    in_target systemctl enable uvb-firstboot-setup.service
}

# export_vm_images RAW_IMG -- convert the raw image to the formats selected in
# TARGET_VM_FORMATS with qemu-img (vm kind only).
function export_vm_images() {
    local raw="$1"
    local formats="${TARGET_VM_FORMATS:-qcow2}"
    if [[ "$formats" == "none" ]]; then
        echo "=====> VM exports: none requested (raw .img only)"
        return 0
    fi
    local fmt out
    for fmt in ${formats//,/ }; do
        case "$fmt" in
            qcow2)
                out="${raw%.img}.qcow2"
                echo "=====> exporting QCOW2 (QEMU/KVM, Proxmox, virt-manager): ${out##*/}"
                host_priv qemu-img convert -f raw -O qcow2 -c "$raw" "$out"
                ;;
            vdi)
                out="${raw%.img}.vdi"
                echo "=====> exporting VDI (VirtualBox): ${out##*/}"
                host_priv qemu-img convert -f raw -O vdi "$raw" "$out"
                ;;
            vmdk)
                out="${raw%.img}.vmdk"
                echo "=====> exporting VMDK (VMware): ${out##*/}"
                host_priv qemu-img convert -f raw -O vmdk "$raw" "$out"
                ;;
            vhdx)
                out="${raw%.img}.vhdx"
                echo "=====> exporting VHDX (Hyper-V): ${out##*/}"
                host_priv qemu-img convert -f raw -O vhdx "$raw" "$out"
                ;;
            *)
                ui_warn "Unknown VM export format '$fmt' -- skipping."
                continue
                ;;
        esac
        write_output_hashes "$out"
    done
}

function build_disk_image() {
    echo "=====> running build_disk_image ..."

    local size_gb="${TARGET_DISK_SIZE_GB:-32}"
    local firmware="${TARGET_FIRMWARE:-uefi}"
    local esp_mib=512
    local swap_mib=4096
    local img_path="$WORKSPACE_DIR/$TARGET_NAME.img"
    IMG_MOUNT_DIR="$WORKSPACE_DIR/imgroot"

    ensure_workspace_root
    host_priv rm -f "$img_path"
    local alloc="${TARGET_IMG_ALLOC:-truncate}"
    echo "=====> allocating ${size_gb} GB image (tool: ${alloc}): $img_path"
    case "$alloc" in
        truncate)
            # Sparse file: instant, occupies only the data actually written.
            host_priv truncate -s "${size_gb}G" "$img_path"
            ;;
        fallocate)
            # Preallocated extents: the full size is reserved up front.
            host_priv fallocate -l "${size_gb}G" "$img_path"
            ;;
        dd)
            # Fully zero-written: slowest, maximum compatibility.
            host_priv dd if=/dev/zero of="$img_path" bs=1M count="$((size_gb * 1024))" status=progress
            ;;
        *)
            >&2 echo "Internal error: TARGET_IMG_ALLOC='${alloc}' (expected truncate, fallocate, or dd)."
            exit 1
            ;;
    esac

    IMG_LOOP_DEV="$(host_priv losetup --show -f -P "$img_path")"
    echo "=====> loop device: $IMG_LOOP_DEV"

    # GPT partition table.
    #   UEFI-only: 1 = ESP 512 MB, 2 = swap 4 GB, 3 = root (rest)
    #   Hybrid:    1 = BIOS boot 1 MiB (GRUB core.img), 2 = ESP 512 MB,
    #              3 = swap 4 GB, 4 = root -- GRUB is installed for BOTH the
    #              i386-pc (BIOS) and x86_64-efi targets, so the same disk
    #              boots on legacy BIOS and UEFI firmware alike
    local p_esp p_swap p_root
    if [[ "$firmware" == "uefi" ]]; then
        host_priv parted -s "$IMG_LOOP_DEV" \
            mklabel gpt \
            mkpart ESP fat32 1MiB "$((1 + esp_mib))MiB" \
            set 1 esp on \
            mkpart swap linux-swap "$((1 + esp_mib))MiB" "$((1 + esp_mib + swap_mib))MiB" \
            mkpart root ext4 "$((1 + esp_mib + swap_mib))MiB" 100%
        p_esp="${IMG_LOOP_DEV}p1"
        p_swap="${IMG_LOOP_DEV}p2"
        p_root="${IMG_LOOP_DEV}p3"
    else
        host_priv parted -s "$IMG_LOOP_DEV" \
            mklabel gpt \
            mkpart biosboot 1MiB 2MiB \
            set 1 bios_grub on \
            mkpart ESP fat32 2MiB "$((2 + esp_mib))MiB" \
            set 2 esp on \
            mkpart swap linux-swap "$((2 + esp_mib))MiB" "$((2 + esp_mib + swap_mib))MiB" \
            mkpart root ext4 "$((2 + esp_mib + swap_mib))MiB" 100%
        p_esp="${IMG_LOOP_DEV}p2"
        p_swap="${IMG_LOOP_DEV}p3"
        p_root="${IMG_LOOP_DEV}p4"
    fi
    host_priv partprobe "$IMG_LOOP_DEV" 2>/dev/null || true
    if command -v udevadm &>/dev/null; then
        host_priv udevadm settle 2>/dev/null || true
    fi

    echo "=====> creating filesystems (ESP ${esp_mib} MB, swap $((swap_mib / 1024)) GB, root = rest) ..."
    host_priv mkfs.vfat -F 32 -n ESP "$p_esp"
    host_priv mkswap -L swap "$p_swap"
    host_priv mkfs.ext4 -q -L root "$p_root"

    host_priv mkdir -p "$IMG_MOUNT_DIR"
    host_priv mount "$p_root" "$IMG_MOUNT_DIR"
    host_priv mkdir -p "$IMG_MOUNT_DIR/boot/efi"
    host_priv mount "$p_esp" "$IMG_MOUNT_DIR/boot/efi"

    echo "=====> copying the root filesystem into the image ..."
    host_priv rsync -aHAX \
        --exclude=/root/build.sh \
        --exclude=/root/hooks \
        --exclude='/var/cache/apt/archives/*.deb' \
        --exclude=/swapfile \
        "$WORKSPACE_CHROOT/" "$IMG_MOUNT_DIR/"

    local uuid_esp uuid_swap uuid_root
    uuid_esp="$(host_priv blkid -s UUID -o value "$p_esp")"
    uuid_swap="$(host_priv blkid -s UUID -o value "$p_swap")"
    uuid_root="$(host_priv blkid -s UUID -o value "$p_root")"

    host_priv tee "$IMG_MOUNT_DIR/etc/fstab" >/dev/null <<EOF
# /etc/fstab -- generated by $SCRIPT_NAME
UUID=${uuid_root}  /          ext4  defaults,errors=remount-ro  0 1
UUID=${uuid_esp}  /boot/efi  vfat  umask=0077  0 1
UUID=${uuid_swap}  none       swap  sw  0 0
EOF

    # Hostname: TARGET_HOSTNAME, or a short distro default instead of the
    # long build target name written during the chroot phase.
    local img_hostname="${TARGET_HOSTNAME:-ubuntu}"
    echo "$img_hostname" | host_priv tee "$IMG_MOUNT_DIR/etc/hostname" >/dev/null
    host_priv tee "$IMG_MOUNT_DIR/etc/hosts" >/dev/null <<EOF
127.0.0.1 localhost
127.0.1.1 ${img_hostname}

::1 ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # Standard Ubuntu resolver symlink (systemd-resolved).
    host_priv ln -sf ../run/systemd/resolve/stub-resolv.conf "$IMG_MOUNT_DIR/etc/resolv.conf"

    # Network defaults. Cloud images: cloud-init writes its own netplan at
    # deploy time. VM images: static netplan defaults baked in here.
    if [[ "$UVB_IMAGE_KIND" != "cloud" ]]; then
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/netplan"
        if [[ "${TARGET_NETWORK_STACK:-network-manager}" == "network-manager" ]]; then
            host_priv tee "$IMG_MOUNT_DIR/etc/netplan/01-network-manager-all.yaml" >/dev/null <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
            host_priv chmod 0600 "$IMG_MOUNT_DIR/etc/netplan/01-network-manager-all.yaml"
        else
            host_priv tee "$IMG_MOUNT_DIR/etc/netplan/01-dhcp-all.yaml" >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    all-ethernet:
      match:
        name: "en*"
      dhcp4: true
      dhcp6: true
EOF
            host_priv chmod 0600 "$IMG_MOUNT_DIR/etc/netplan/01-dhcp-all.yaml"
        fi
    fi

    # Bind mounts so grub-install / update-grub / update-initramfs can run
    # inside the image.
    host_priv mount --bind /dev "$IMG_MOUNT_DIR/dev"
    host_priv mount --bind /dev/pts "$IMG_MOUNT_DIR/dev/pts"
    host_priv mount -t proc proc "$IMG_MOUNT_DIR/proc"
    host_priv mount -t sysfs sysfs "$IMG_MOUNT_DIR/sys"
    host_priv mount --bind /run "$IMG_MOUNT_DIR/run"

    # netplan backend: enable systemd-networkd when it is the renderer.
    if [[ "${TARGET_NETWORK_STACK:-networkd}" == "networkd" ]]; then
        in_target systemctl enable systemd-networkd.service || true
    fi

    # Cloud images with NetworkManager: tell cloud-init to render its network
    # config for NetworkManager instead of the systemd-networkd default.
    if [[ "$UVB_IMAGE_KIND" == "cloud" ]] && [[ "${TARGET_NETWORK_STACK:-networkd}" == "network-manager" ]]; then
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d"
        host_priv tee "$IMG_MOUNT_DIR/etc/cloud/cloud.cfg.d/91-uvb-network-renderer.cfg" >/dev/null <<'EOF'
# Written by the Ubuntu Vanilla image builder: this image uses NetworkManager.
system_info:
  network:
    renderers: ['network-manager', 'netplan', 'networkd']
    activators: ['network-manager', 'netplan', 'networkd']
EOF
    fi

    # Serial console for cloud images: most providers expose the VM console
    # on ttyS0.
    if [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
        host_priv mkdir -p "$IMG_MOUNT_DIR/etc/default/grub.d"
        host_priv tee "$IMG_MOUNT_DIR/etc/default/grub.d/50-cloudimg.cfg" >/dev/null <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 console=ttyS0,115200"
GRUB_TIMEOUT=0
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200"
EOF
    fi

    # No hibernation into the swap partition of a generic image: keep the
    # initramfs free of a baked-in resume UUID.
    host_priv mkdir -p "$IMG_MOUNT_DIR/etc/initramfs-tools/conf.d"
    echo "RESUME=none" | host_priv tee "$IMG_MOUNT_DIR/etc/initramfs-tools/conf.d/resume" >/dev/null

    echo "=====> installing GRUB (${firmware}) ..."
    # UEFI: --no-nvram because NVRAM boot entries of the build machine do not
    # travel with the image; --removable adds the EFI/BOOT/BOOTX64.EFI
    # fallback path every firmware finds without NVRAM entries.
    if [[ "$firmware" == "hybrid" ]]; then
        # Hybrid: BIOS GRUB into the bios_grub partition, ...
        in_target grub-install --target=i386-pc --recheck "$IMG_LOOP_DEV"
    fi
    # ... and UEFI GRUB onto the ESP (both firmware modes have one).
    in_target grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=ubuntu --uefi-secure-boot --recheck --no-nvram
    in_target grub-install --target=x86_64-efi --efi-directory=/boot/efi \
        --bootloader-id=ubuntu --uefi-secure-boot --removable --recheck --no-nvram
    in_target update-initramfs -u
    in_target update-grub

    # User account: baked in now, or deferred to cloud-init / the first-boot
    # wizard depending on the image kind.
    if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
        create_baked_user
    elif [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        install_firstboot_user_wizard
    else
        echo "=====> user account: created at deploy time by cloud-init (provider metadata)"
    fi
    configure_cloud_init_user

    detach_image_loop

    ensure_output_dir
    echo "=====> moving image to $OUTPUT_DIR/$TARGET_NAME.img"
    host_priv mv "$img_path" "$OUTPUT_DIR/$TARGET_NAME.img"
    write_output_hashes "$OUTPUT_DIR/$TARGET_NAME.img"

    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        export_vm_images "$OUTPUT_DIR/$TARGET_NAME.img"
    fi

    fix_output_ownership
    clean_workspace
}

# Startup mode selection: alternative to passing --advanced. Only asked when
# the user did not choose a mode via --advanced or the ADVANCED_MODE env var.
# Uses a plain TTY check (not prompts_enabled): the --interactive override is
# itself advanced-only, so it cannot apply before the mode is known.
function interactive_mode_pick() {
    if [[ ! -t 0 ]]; then
        # Non-interactive invocation without an explicit mode: default to basic.
        return 0
    fi

    ui_heading "Build mode"
    echo "    1) Basic     Guided build with sensible defaults  [default]"
    echo "                 (workspace in a system directory, image saved to your home)"
    echo "    2) Advanced  Adds config file loading (build-img.cfg / --config),"
    echo "                 workspace preservation on failure, package caching,"
    echo "                 custom workspace/output paths (asked interactively),"
    echo "                 and the --interactive / --no-interactive overrides"

    local choice
    while true; do
        read -r -p "  Mode [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|b|basic)    export ADVANCED_MODE=0; break ;;
            2|a|adv|advanced) export ADVANCED_MODE=1; break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "ADVANCED_MODE=$ADVANCED_MODE"
}

function interactive_release_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --release=jammy|noble|resolute."
        exit 1
    fi

    ui_heading "Ubuntu release"
    cat <<'EOF'
    1) jammy     Ubuntu 22.04 LTS
    2) noble     Ubuntu 24.04 LTS
    3) resolute  Ubuntu 26.04 LTS
EOF

    local choice
    while true; do
        read -r -p "  Release [1/2/3]: " choice
        case "${choice,,}" in
            1|jammy)    export TARGET_UBUNTU_VERSION="jammy";    break ;;
            2|noble)    export TARGET_UBUNTU_VERSION="noble";    break ;;
            3|resolute) export TARGET_UBUNTU_VERSION="resolute"; break ;;
            "")  ui_warn "Please choose 1, 2, or 3." ;;
            *)   ui_warn "Invalid selection: '$choice'. Please choose 1, 2, or 3." ;;
        esac
    done
    ui_ok "TARGET_UBUNTU_VERSION=$TARGET_UBUNTU_VERSION"
}

function resolve_release_choice() {
    if [[ -n "${TARGET_UBUNTU_VERSION:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_release_pick
        return 0
    fi

    >&2 echo "TARGET_UBUNTU_VERSION is not set. Use --release=jammy|noble|resolute for non-interactive runs."
    exit 1
}

function interactive_kernel_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --kernel=generic|lowlatency."
        exit 1
    fi

    local hv=""
    hv="$(release_version "${TARGET_UBUNTU_VERSION:-}")"

    ui_heading "Kernel flavor${hv:+ (HWE stream for Ubuntu ${hv})}"
    printf '    1) generic     Recommended for most systems%s\n' \
        "${hv:+  (linux-generic-hwe-${hv})}"
    printf '    2) lowlatency  Better for audio / low-latency workloads%s\n' \
        "${hv:+  (linux-lowlatency-hwe-${hv})}"

    local choice
    while true; do
        read -r -p "  Kernel [1/2]: " choice
        case "${choice,,}" in
            1|g|generic)    export TARGET_KERNEL_FLAVOR="generic";    break ;;
            2|l|lowlatency) export TARGET_KERNEL_FLAVOR="lowlatency"; break ;;
            "")  ui_warn "Please choose 1 or 2." ;;
            *)   ui_warn "Invalid selection: '$choice'. Please choose 1 or 2." ;;
        esac
    done
    ui_ok "TARGET_KERNEL_FLAVOR=$TARGET_KERNEL_FLAVOR"
}

function resolve_kernel_choice() {
    if [[ -n "${TARGET_KERNEL_FLAVOR:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_kernel_pick
        return 0
    fi

    >&2 echo "TARGET_KERNEL_FLAVOR is not set. Use --kernel=generic|lowlatency for non-interactive runs."
    exit 1
}

function interactive_desktop_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --desktop=<desktop> (e.g. gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, or kde-plasma)."
        exit 1
    fi

    ui_heading "Desktop environment"
    echo "    (Ordered A-Z by desktop name.)"
    echo "    1) Budgie         Modern GTK desktop with Raven applets/sidebar. budgie-desktop-environment; lightdm + slick-greeter."
    echo "    2) Cinnamon       Familiar bottom panel and menu layout. cinnamon-desktop-environment; lightdm + slick-greeter."
    echo "    3) GNOME          Modern, full-featured desktop (similar to stock Ubuntu). Installs vanilla-gnome-desktop; next prompt offers optional extra apps (APT recommends)."
    echo "    4) KDE            KDE Plasma - flexible and customizable. Next you choose package set: kde-full, kde-standard, or kde-plasma-desktop."
    echo "    5) LXDE           Very light; best for low-spec or older PCs. lxde metapackage; lightdm + slick-greeter (classic LXDE stack)."
    echo "    6) LXQt           Lightweight Qt desktop. lxqt + sddm + xorg (no Lubuntu branding metapackages)."
    echo "    7) MATE           Traditional two-panel layout (GNOME 2 style). You choose full vs core MATE metapackage next, then optional extras."
    echo "    8) XFCE           Lighter weight, classic taskbar layout. xfce4 + add-ons; display manager lightdm + slick-greeter; includes labwc for an optional Wayland session."

    local choice
    while true; do
        read -r -p "  Desktop [1-8, A-Z by name; Enter=GNOME]: " choice
        case "${choice,,}" in
            ""|3|g|gnome)               export TARGET_DESKTOP="gnome";   break ;;
            1|b|budgie)                export TARGET_DESKTOP="budgie";   break ;;
            2|c|cinnamon)             export TARGET_DESKTOP="cinnamon"; break ;;
            4|k|kde|kde-plasma)        export TARGET_DESKTOP="kde-plasma"; break ;;
            5|l|lxde)                  export TARGET_DESKTOP="lxde";    break ;;
            6|q|lxqt)                  export TARGET_DESKTOP="lxqt";    break ;;
            7|m|mate)                  export TARGET_DESKTOP="mate";    break ;;
            8|x|xfce)                  export TARGET_DESKTOP="xfce";    break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_DESKTOP=$TARGET_DESKTOP"
}

function resolve_desktop_choice() {
    if [[ -n "${TARGET_DESKTOP:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_desktop_pick
        return 0
    fi

    export TARGET_DESKTOP=gnome
}

function interactive_kde_package_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --kde=kde-full|kde-standard|kde-plasma-desktop."
        exit 1
    fi

    ui_heading "KDE package selection"
    echo "    1) kde-standard        Balanced KDE software set  [default]"
    echo "    2) kde-plasma-desktop  Minimal KDE Plasma desktop"
    echo "    3) kde-full            Full KDE software collection"

    local choice
    while true; do
        read -r -p "  KDE package [1/2/3, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|kde-standard|standard) export TARGET_KDE_PACKAGE="kde-standard"; break ;;
            2|kde-plasma-desktop|plasma|minimal) export TARGET_KDE_PACKAGE="kde-plasma-desktop"; break ;;
            3|kde-full|full) export TARGET_KDE_PACKAGE="kde-full"; break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_KDE_PACKAGE=$TARGET_KDE_PACKAGE"
}

function resolve_kde_package_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "kde-plasma" ]]; then
        export TARGET_KDE_PACKAGE="kde-standard"
        return 0
    fi

    if [[ -n "${TARGET_KDE_PACKAGE:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_kde_package_pick
        return 0
    fi

    export TARGET_KDE_PACKAGE="kde-standard"
}

function resolve_mate_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "mate" ]]; then
        export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
        export TARGET_MATE_EXTRAS=0
        return 0
    fi

    case "${TARGET_MATE_PACKAGE:-}" in
        full)
            export TARGET_MATE_PACKAGE="mate-desktop-environment"
            ;;
        core)
            export TARGET_MATE_PACKAGE="mate-desktop-environment-core"
            ;;
    esac

    if [[ -n "${TARGET_MATE_PACKAGE:-}" ]] && [[ -v TARGET_MATE_EXTRAS ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_mate_options_pick
        return 0
    fi

    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
    export TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}"
}

function interactive_mate_options_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --mate=full|core, --mate-extras / --no-mate-extras, or set TARGET_MATE_PACKAGE and TARGET_MATE_EXTRAS=0|1."
        exit 1
    fi

    if [[ -z "${TARGET_MATE_PACKAGE:-}" ]]; then
        ui_heading "MATE desktop metapackage"
        echo "    1) mate-desktop-environment       Full MATE desktop  [default]"
        echo "    2) mate-desktop-environment-core  Core only (smaller install)"

        local choice
        while true; do
            read -r -p "  MATE metapackage [1/2, Enter=1]: " choice
            case "${choice,,}" in
                ""|1|full|mate-desktop-environment)
                    export TARGET_MATE_PACKAGE="mate-desktop-environment"
                    break
                    ;;
                2|core|mate-desktop-environment-core)
                    export TARGET_MATE_PACKAGE="mate-desktop-environment-core"
                    break
                    ;;
                *) ui_warn "Invalid selection: '$choice'." ;;
            esac
        done
        ui_ok "TARGET_MATE_PACKAGE=$TARGET_MATE_PACKAGE"
    fi

    if [[ ! -v TARGET_MATE_EXTRAS ]]; then
        ui_heading "MATE extras"
        echo "    y) Also install mate-desktop-environment-extras (extra MATE apps and utilities)"
        echo "    n) Skip extras  [default]"
        if ui_confirm "Install mate-desktop-environment-extras?" n; then
            export TARGET_MATE_EXTRAS=1
        else
            export TARGET_MATE_EXTRAS=0
        fi
        ui_ok "TARGET_MATE_EXTRAS=$TARGET_MATE_EXTRAS"
    fi
}

function interactive_gnome_recommends_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use TARGET_GNOME_INSTALL_RECOMMENDS=0|1."
        exit 1
    fi

    ui_heading "GNOME extra recommends"
    echo "    y) apt install vanilla-gnome-desktop     (fuller GNOME experience)"
    echo "    n) apt install --no-install-recommends   (lighter; default)"
    if ui_confirm "Include recommended packages?" n; then
        export TARGET_GNOME_INSTALL_RECOMMENDS="1"
    else
        export TARGET_GNOME_INSTALL_RECOMMENDS="0"
    fi
    ui_ok "TARGET_GNOME_INSTALL_RECOMMENDS=$TARGET_GNOME_INSTALL_RECOMMENDS"
}

function resolve_gnome_recommends_choice() {
    if [[ "${TARGET_DESKTOP:-gnome}" != "gnome" ]]; then
        export TARGET_GNOME_INSTALL_RECOMMENDS=0
        return 0
    fi

    if [[ -n "${TARGET_GNOME_INSTALL_RECOMMENDS:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_gnome_recommends_pick
        return 0
    fi

    export TARGET_GNOME_INSTALL_RECOMMENDS=0
}

function interactive_brave_channel_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Set TARGET_BRAVE_CHANNEL=none|release|origin (or legacy TARGET_BROWSER=release|origin)."
        exit 1
    fi

    ui_heading "Brave Browser"
    echo "    1) Brave Stable [default]"
    echo "       Official release from Brave's repository (brave-browser package)"
    echo "       This is the standard Brave browser with all features enabled by default"
    echo "       Includes Leo AI, News, Playlist, Rewards, Wallet, VPN, and other integrated features"
    echo "       Completely free to use on all platforms with regular security updates"
    echo ""
    echo "    2) Brave Origin"
    echo "       Origin build (brave-origin package) - a minimalist version of Brave"
    echo "       Streamlined to the core of Brave's ad blocking and privacy protections"
    echo "       Lets you manage or completely remove features you don't want"
    echo "       Removes daily usage pings, crash logs, and product analytics"
    echo "       FREE for Linux users (paid on other platforms)"
    echo "       Ideal for users who want a clean, privacy-focused browser without extra features"
    echo ""
    echo "    3) Skip Brave"
    echo "       Do not install Brave browser"
    echo "       Choose this if you prefer another browser or don't need Brave"
    echo ""

    local choice
    while true; do
        read -r -p "  Brave [1/2/3, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|r|release|stable)
                export TARGET_BRAVE_CHANNEL="release"
                break
                ;;
            2|o|origin)
                export TARGET_BRAVE_CHANNEL="origin"
                break
                ;;
            3|n|none|skip)
                export TARGET_BRAVE_CHANNEL="none"
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_BRAVE_CHANNEL=$TARGET_BRAVE_CHANNEL"
}

# interactive_toggle_pick VAR_NAME HEADING INSTALL_LABEL SKIP_LABEL PROMPT_LABEL
#   Generic yes/no pre-install toggle. Default answer is "skip" (0).
function interactive_toggle_pick() {
    local var_name="$1" heading="$2" install_label="$3" skip_label="$4" prompt_label="$5"

    if ! prompts_enabled; then
        ui_err "No terminal is available. Set ${var_name}=0|1."
        exit 1
    fi

    ui_heading "$heading"
    echo "    1) ${install_label}"
    echo "    2) ${skip_label}  [default]"

    local choice
    while true; do
        read -r -p "  ${prompt_label} [1/2, Enter=2]: " choice
        case "${choice,,}" in
            ""|2|n|no|off|skip|s|none)
                export "$var_name"="0"
                break
                ;;
            1|y|yes|install|pre|on)
                export "$var_name"="1"
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "${var_name}=${!var_name}"
}

function interactive_librewolf_pick() {
    interactive_toggle_pick TARGET_LIBREWOLF \
        "Librewolf" \
        "Pre-install librewolf (repo is configured either way)" \
        "Skip Librewolf" \
        "Librewolf"
}

function interactive_firefox_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Set TARGET_FIREFOX=0|1 and TARGET_FIREFOX_ESR=0|1."
        exit 1
    fi

    ui_heading "Firefox Browser"
    echo "    1) Firefox Release"
    echo "       Official release from Mozilla's repository (firefox package)"
    echo "       This is the standard Firefox browser with the latest features"
    echo "       Includes the newest web standards, performance improvements, and UI updates"
    echo "       Rapid release cycle with major updates every 4 weeks"
    echo "       Ideal for users who want cutting-edge features and the latest security patches"
    echo ""
    echo "    2) Firefox ESR"
    echo "       Extended Support Release (firefox-esr package) from Mozilla PPA"
    echo "       A slower-moving release designed for enterprise and institutional use"
    echo "       Receives security updates but fewer feature changes over time"
    echo "       Major updates only once per year, with maintenance updates for 54 weeks"
    echo "       Ideal for users who prefer stability and consistency over new features"
    echo "       Recommended for organizations that need standardized browser environments"
    echo ""
    echo "    3) Skip Firefox [default]"
    echo "       Do not install Firefox browser"
    echo "       Choose this if you prefer another browser or don't need Firefox"
    echo ""

    local choice
    while true; do
        read -r -p "  Firefox [1/2/3, Enter=3]: " choice
        case "${choice,,}" in
            1|r|release)
                export TARGET_FIREFOX="1"
                export TARGET_FIREFOX_ESR="0"
                break
                ;;
            2|e|esr)
                export TARGET_FIREFOX="0"
                export TARGET_FIREFOX_ESR="1"
                break
                ;;
            ""|3|n|none|skip)
                export TARGET_FIREFOX="0"
                export TARGET_FIREFOX_ESR="0"
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_FIREFOX=$TARGET_FIREFOX  TARGET_FIREFOX_ESR=$TARGET_FIREFOX_ESR"
}

function interactive_thunderbird_pick() {
    interactive_toggle_pick TARGET_THUNDERBIRD \
        "Thunderbird (Mozilla PPA)" \
        "Pre-install thunderbird (Mozilla PPA + pin are configured either way)" \
        "Skip Thunderbird" \
        "Thunderbird"
}

function resolve_browser_selection() {
    # CLI/TTY-only images get no GUI browsers unless explicitly requested.
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
        export TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-none}"
        export TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}"
        export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
        export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
        export TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
        return 0
    fi

    if [[ -n "${TARGET_BROWSER:-}" && -z "${TARGET_BRAVE_CHANNEL:-}" ]]; then
        export TARGET_BRAVE_CHANNEL="$TARGET_BROWSER"
    fi

    if [[ -z "${TARGET_BRAVE_CHANNEL:-}" ]]; then
        if prompts_enabled; then
            interactive_brave_channel_pick
        else
            export TARGET_BRAVE_CHANNEL="release"
        fi
    fi

    if [[ -z "${TARGET_LIBREWOLF+x}" ]]; then
        if prompts_enabled; then
            interactive_librewolf_pick
        else
            export TARGET_LIBREWOLF="0"
        fi
    fi

    if [[ -z "${TARGET_FIREFOX+x}" || -z "${TARGET_FIREFOX_ESR+x}" ]]; then
        if prompts_enabled; then
            interactive_firefox_pick
        else
            export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
            export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
        fi
    fi

    if [[ -z "${TARGET_THUNDERBIRD+x}" ]]; then
        if prompts_enabled; then
            interactive_thunderbird_pick
        else
            export TARGET_THUNDERBIRD="0"
        fi
    fi

    export TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}"
    export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
    export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
    export TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
}

function resolve_ubuntu_studio_choice() {
    if [[ -n "${TARGET_UBUNTU_STUDIO+x}" ]]; then
        export TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}"
        return 0
    fi

    if prompts_enabled; then
        ui_heading "Ubuntu Studio"
        echo "    Large bundle: ubuntustudio-audio/graphics/photography/publishing/video,"
        echo "    ubuntustudio-wallpapers, ubuntustudio-menu, ubuntu-edu-music."
        local yn
        while true; do
            read -r -p "  Do you want to install Ubuntu Studio packages? (y/N) " yn
            yn="${yn,,}"
            [[ -z "$yn" ]] && yn="n"
            case "$yn" in
                y|yes)
                    export TARGET_UBUNTU_STUDIO="1"
                    break
                    ;;
                n|no)
                    export TARGET_UBUNTU_STUDIO="0"
                    break
                    ;;
                *)
                    echo "  Please answer y or n."
                    ;;
            esac
        done
        ui_ok "TARGET_UBUNTU_STUDIO=$TARGET_UBUNTU_STUDIO"
    else
        export TARGET_UBUNTU_STUDIO=0
    fi
}

function resolve_pacstall_choice() {
    if [[ -n "${TARGET_PACSTALL+x}" ]]; then
        export TARGET_PACSTALL="${TARGET_PACSTALL:-1}"
        return 0
    fi

    if prompts_enabled; then
        ui_heading "Pacstall"
        echo "    AUR-like package manager for Ubuntu (installed from https://pacstall.dev)."
        local yn
        while true; do
            read -r -p "  Install Pacstall? (Y/n) " yn
            yn="${yn,,}"
            [[ -z "$yn" ]] && yn="y"
            case "$yn" in
                y|yes)
                    export TARGET_PACSTALL="1"
                    break
                    ;;
                n|no)
                    export TARGET_PACSTALL="0"
                    break
                    ;;
                *)
                    echo "  Please answer y or n."
                    ;;
            esac
        done
        ui_ok "TARGET_PACSTALL=$TARGET_PACSTALL"
    else
        export TARGET_PACSTALL=1
    fi
}

# Optional service/tool pre-installs: fwupd, OpenSSH server, Cockpit.
# All default to "no" -- the point is a lean image where the user opts in.
function resolve_optional_service_choices() {
    if [[ -z "${TARGET_FWUPD+x}" ]]; then
        if prompts_enabled; then
            ui_heading "fwupd (firmware updater)"
            echo "    fwupd is banned while the ISO is built, so no package can drag it in."
            echo "    You can still pre-install it here as the very last build step, or add it"
            echo "    yourself later on the installed system with 'sudo apt install fwupd'."
            if ui_confirm "Pre-install fwupd?" n; then
                export TARGET_FWUPD=1
            else
                export TARGET_FWUPD=0
            fi
            ui_ok "TARGET_FWUPD=$TARGET_FWUPD"
        else
            export TARGET_FWUPD=0
        fi
    fi

    # Cloud images are managed over SSH, so openssh-server defaults to yes there.
    if [[ -z "${TARGET_OPENSSH_SERVER+x}" ]] && [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
        if prompts_enabled; then
            ui_heading "OpenSSH server"
            echo "    Cloud images are normally reached over SSH, so this defaults to yes."
            if ui_confirm "Pre-install openssh-server?" y; then
                export TARGET_OPENSSH_SERVER=1
            else
                export TARGET_OPENSSH_SERVER=0
            fi
            ui_ok "TARGET_OPENSSH_SERVER=$TARGET_OPENSSH_SERVER"
        else
            export TARGET_OPENSSH_SERVER=1
        fi
    fi

    if [[ -z "${TARGET_OPENSSH_SERVER+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_OPENSSH_SERVER \
                "OpenSSH server" \
                "Pre-install openssh-server (remote SSH access enabled on the installed system)" \
                "Skip OpenSSH server" \
                "OpenSSH server"
        else
            export TARGET_OPENSSH_SERVER=0
        fi
    fi

    if [[ -z "${TARGET_COCKPIT+x}" ]]; then
        if prompts_enabled; then
            interactive_toggle_pick TARGET_COCKPIT \
                "Cockpit (web admin console, from ${TARGET_UBUNTU_VERSION:-release}-backports for the latest version)" \
                "Pre-install cockpit from the backports pocket" \
                "Skip Cockpit" \
                "Cockpit"
        else
            export TARGET_COCKPIT=0
        fi
    fi

    export TARGET_FWUPD="${TARGET_FWUPD:-0}"
    export TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}"
    export TARGET_COCKPIT="${TARGET_COCKPIT:-0}"
}

function interactive_firmware_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --firmware=uefi|hybrid."
        exit 1
    fi

    ui_heading "Firmware / boot mode"
    echo "    1) UEFI-only  GPT with a 512 MB EFI System Partition; boots on UEFI"
    echo "                  firmware only (modern clouds and hypervisors: OVMF,"
    echo "                  Hyper-V Gen2, ...)  [default]"
    echo "    2) Hybrid     BIOS + UEFI on one disk: GPT with a 1 MiB BIOS boot"
    echo "                  partition plus the same 512 MB ESP; GRUB is installed"
    echo "                  for both targets (SeaBIOS, Hyper-V Gen1, older clouds"
    echo "                  -- and still bootable on UEFI)"

    local choice
    while true; do
        read -r -p "  Firmware [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|u|uefi|efi|uefi-only) export TARGET_FIRMWARE="uefi";   break ;;
            2|h|hybrid|b|bios|legacy)  export TARGET_FIRMWARE="hybrid"; break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_FIRMWARE=$TARGET_FIRMWARE"
}

function resolve_firmware_choice() {
    if [[ -n "${TARGET_FIRMWARE:-}" ]]; then
        export TARGET_FIRMWARE="${TARGET_FIRMWARE,,}"
        # Legacy aliases from before the hybrid rename.
        case "$TARGET_FIRMWARE" in
            bios|legacy) export TARGET_FIRMWARE="hybrid" ;;
            uefi-only)   export TARGET_FIRMWARE="uefi" ;;
        esac
        return 0
    fi

    if prompts_enabled; then
        interactive_firmware_pick
        return 0
    fi

    export TARGET_FIRMWARE="uefi"
}

function interactive_network_stack_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --network=networkd|network-manager."
        exit 1
    fi

    ui_heading "Network stack (CLI/TTY-only profile)"
    echo "    1) networkd         netplan + systemd-networkd -- lean, server-style  [default]"
    echo "    2) network-manager  NetworkManager -- nmcli/nmtui, the same stack the"
    echo "                        desktop images use"

    local choice
    while true; do
        read -r -p "  Network stack [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|networkd|systemd-networkd|netplan)   export TARGET_NETWORK_STACK="networkd";       break ;;
            2|nm|networkmanager|network-manager)      export TARGET_NETWORK_STACK="network-manager"; break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_NETWORK_STACK=$TARGET_NETWORK_STACK"
}

function resolve_network_stack_choice() {
    # Normalize aliases first.
    if [[ -n "${TARGET_NETWORK_STACK:-}" ]]; then
        case "${TARGET_NETWORK_STACK,,}" in
            networkd|systemd-networkd|netplan)   export TARGET_NETWORK_STACK="networkd" ;;
            nm|networkmanager|network-manager)   export TARGET_NETWORK_STACK="network-manager" ;;
            *)
                >&2 echo "TARGET_NETWORK_STACK must be networkd or network-manager (got: '${TARGET_NETWORK_STACK}')."
                exit 1
                ;;
        esac
    fi

    # Desktop images always use NetworkManager -- the desktop stacks depend on it.
    if [[ "${TARGET_IMAGE_PROFILE:-desktop}" != "cli" ]]; then
        if [[ "${TARGET_NETWORK_STACK:-}" == "networkd" ]]; then
            ui_warn "Desktop profile always uses NetworkManager -- ignoring network stack 'networkd'."
        fi
        export TARGET_NETWORK_STACK="network-manager"
        return 0
    fi

    if [[ -n "${TARGET_NETWORK_STACK:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_network_stack_pick
        return 0
    fi

    export TARGET_NETWORK_STACK="networkd"
}

function interactive_alloc_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --alloc-tool=truncate|fallocate|dd."
        exit 1
    fi

    ui_heading "Image allocation tool"
    echo "    How the raw .img file is created on the build host:"
    echo "    1) truncate   Sparse file -- instant; occupies only the data actually"
    echo "                  written (recommended)  [default]"
    echo "    2) fallocate  Preallocated -- reserves the full size up front, no holes"
    echo "    3) dd         Fully zero-written with dd -- slowest, uses the full size"
    echo "                  on disk, maximum compatibility with picky tooling"

    local choice
    while true; do
        read -r -p "  Allocation [1/2/3, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|t|truncate|sparse)        export TARGET_IMG_ALLOC="truncate";  break ;;
            2|f|fallocate|prealloc|preallocate) export TARGET_IMG_ALLOC="fallocate"; break ;;
            3|d|dd)                        export TARGET_IMG_ALLOC="dd";        break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_IMG_ALLOC=$TARGET_IMG_ALLOC"
}

function resolve_alloc_choice() {
    if [[ -n "${TARGET_IMG_ALLOC:-}" ]]; then
        export TARGET_IMG_ALLOC="${TARGET_IMG_ALLOC,,}"
        case "$TARGET_IMG_ALLOC" in
            sparse)                 export TARGET_IMG_ALLOC="truncate" ;;
            prealloc|preallocate)   export TARGET_IMG_ALLOC="fallocate" ;;
        esac
        return 0
    fi

    if prompts_enabled; then
        interactive_alloc_pick
        return 0
    fi

    export TARGET_IMG_ALLOC="truncate"
}

function interactive_disk_size_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --disk-size=32|64|128|<GB>."
        exit 1
    fi

    ui_heading "Disk image size"
    echo "    Fixed layout: 512 MB ESP + 4 GB swap + root gets everything else."
    echo "    1) 32 GB     root gets ~27.5 GB  [default]"
    echo "    2) 64 GB     root gets ~59.5 GB"
    echo "    3) 128 GB    root gets ~123.5 GB"
    echo "    4) Custom    any whole number of GB (minimum 10)"

    local choice custom
    while true; do
        read -r -p "  Size [1/2/3/4, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|32)  export TARGET_DISK_SIZE_GB=32;  break ;;
            2|64)     export TARGET_DISK_SIZE_GB=64;  break ;;
            3|128)    export TARGET_DISK_SIZE_GB=128; break ;;
            4|c|custom)
                while true; do
                    read -r -p "  Custom size in GB (minimum 10): " custom
                    if [[ "$custom" =~ ^[0-9]+$ ]] && [[ "$custom" -ge 10 ]]; then
                        export TARGET_DISK_SIZE_GB="$custom"
                        break
                    fi
                    ui_warn "Enter a whole number of GB, at least 10."
                done
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_DISK_SIZE_GB=$TARGET_DISK_SIZE_GB"
}

function resolve_disk_size_choice() {
    if [[ -n "${TARGET_DISK_SIZE_GB:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_disk_size_pick
        return 0
    fi

    export TARGET_DISK_SIZE_GB=32
}

function interactive_profile_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --profile=desktop|cli."
        exit 1
    fi

    ui_heading "Image profile"
    echo "    1) Desktop ready   Full graphical desktop, ready to log in  [default]"
    echo "                       (you pick the desktop environment next)"
    echo "    2) CLI / TTY only  No desktop at all -- text console, server-style image"

    local choice
    while true; do
        read -r -p "  Profile [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|d|desktop)     export TARGET_IMAGE_PROFILE="desktop"; break ;;
            2|c|cli|tty|server) export TARGET_IMAGE_PROFILE="cli";     break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_IMAGE_PROFILE=$TARGET_IMAGE_PROFILE"
}

function resolve_profile_choice() {
    if [[ -z "${TARGET_IMAGE_PROFILE:-}" ]]; then
        if prompts_enabled; then
            interactive_profile_pick
        else
            export TARGET_IMAGE_PROFILE="desktop"
        fi
    fi
    export TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE,,}"

    # CLI/TTY-only images have no desktop; the pseudo-desktop slug "cli"
    # short-circuits every desktop-related prompt and install step.
    if [[ "$TARGET_IMAGE_PROFILE" == "cli" ]]; then
        if [[ -n "${TARGET_DESKTOP:-}" && "${TARGET_DESKTOP,,}" != "cli" ]]; then
            ui_warn "CLI/TTY-only profile selected -- ignoring desktop '${TARGET_DESKTOP}'."
        fi
        export TARGET_DESKTOP="cli"
    fi
}

function interactive_user_mode_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --user-mode=build|deploy."
        exit 1
    fi

    ui_heading "User account"
    local choice
    if [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
        echo "    1) Deploy-time   cloud-init creates the user when the image is deployed"
        echo "                     (username, SSH keys, and password from provider metadata)  [default]"
        echo "    2) Build-time    bake a username + password into the image now"
        while true; do
            read -r -p "  User account [1/2, Enter=1]: " choice
            case "${choice,,}" in
                ""|1|d|deploy|cloud-init) export TARGET_USER_MODE="deploy"; break ;;
                2|b|build|bake)           export TARGET_USER_MODE="build";  break ;;
                *) ui_warn "Invalid selection: '$choice'." ;;
            esac
        done
    else
        echo "    1) Build-time    bake a username + password into the image now  [default]"
        echo "    2) First boot    the VM asks for username/password/hostname on its own"
        echo "                     console the first time it starts (no credentials baked in)"
        while true; do
            read -r -p "  User account [1/2, Enter=1]: " choice
            case "${choice,,}" in
                ""|1|b|build|bake)               export TARGET_USER_MODE="build";  break ;;
                2|f|firstboot|first-boot|deploy) export TARGET_USER_MODE="deploy"; break ;;
                *) ui_warn "Invalid selection: '$choice'." ;;
            esac
        done
    fi
    ui_ok "TARGET_USER_MODE=$TARGET_USER_MODE"
}

function interactive_credentials_pick() {
    local u
    while true; do
        read -r -p "  Username: " u
        if [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            export TARGET_USERNAME="$u"
            break
        fi
        ui_warn "Invalid username (lowercase letters, digits, '-' and '_'; must not start with a digit)."
    done
    if [[ -z "${TARGET_USER_FULLNAME:-}" ]]; then
        read -r -p "  Full name (optional): " TARGET_USER_FULLNAME
        export TARGET_USER_FULLNAME
    fi
    local p1 p2
    while true; do
        read -r -s -p "  Password: " p1; echo
        read -r -s -p "  Confirm password: " p2; echo
        if [[ -n "$p1" && "$p1" == "$p2" ]]; then
            export TARGET_USER_PASSWORD="$p1"
            break
        fi
        ui_warn "Passwords are empty or do not match -- try again."
    done
    if [[ -z "${TARGET_HOSTNAME:-}" ]]; then
        read -r -p "  Hostname [ubuntu]: " TARGET_HOSTNAME
        export TARGET_HOSTNAME="${TARGET_HOSTNAME:-ubuntu}"
    fi
}

function resolve_user_setup_choice() {
    if [[ -z "${TARGET_USER_MODE:-}" ]]; then
        if prompts_enabled; then
            interactive_user_mode_pick
        else
            export TARGET_USER_MODE="deploy"
        fi
    fi
    export TARGET_USER_MODE="${TARGET_USER_MODE,,}"

    if [[ "$TARGET_USER_MODE" != "build" ]]; then
        return 0
    fi

    if [[ -z "${TARGET_USERNAME:-}" || -z "${TARGET_USER_PASSWORD:-}" ]]; then
        if prompts_enabled; then
            ui_heading "Build-time credentials"
            interactive_credentials_pick
        else
            ui_err "TARGET_USER_MODE=build requires TARGET_USERNAME and TARGET_USER_PASSWORD (or --username/--password) for non-interactive runs."
            exit 1
        fi
    fi
    ui_ok "TARGET_USERNAME=$TARGET_USERNAME"
}

# validate_vm_formats LIST -- 0 when LIST is 'none' or a comma-separated list
# of qcow2/vdi/vmdk/vhdx.
function validate_vm_formats() {
    local fmt list="${1:-}"
    [[ "$list" == "none" ]] && return 0
    [[ -z "$list" ]] && return 1
    for fmt in ${list//,/ }; do
        case "$fmt" in
            qcow2|vdi|vmdk|vhdx) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

function interactive_vm_formats_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --formats=qcow2,vdi,vmdk,vhdx|all|none."
        exit 1
    fi

    ui_heading "VM export formats"
    echo "    The raw .img is always produced. Pick extra formats to export with qemu-img:"
    echo "      qcow2   QEMU/KVM, Proxmox, virt-manager   [default]"
    echo "      vdi     VirtualBox"
    echo "      vmdk    VMware Workstation / ESXi"
    echo "      vhdx    Microsoft Hyper-V"
    echo "    Enter a comma-separated list (e.g. qcow2,vdi), 'all', or 'none'."

    local raw
    while true; do
        read -r -p "  Formats [Enter=qcow2]: " raw
        raw="${raw,,}"
        [[ -z "$raw" ]] && raw="qcow2"
        [[ "$raw" == "all" ]] && raw="qcow2,vdi,vmdk,vhdx"
        if validate_vm_formats "$raw"; then
            export TARGET_VM_FORMATS="$raw"
            break
        fi
        ui_warn "Invalid format list: '$raw' (allowed: qcow2, vdi, vmdk, vhdx, all, none)."
    done
    ui_ok "TARGET_VM_FORMATS=$TARGET_VM_FORMATS"
}

function resolve_vm_formats_choice() {
    if [[ "$UVB_IMAGE_KIND" != "vm" ]]; then
        return 0
    fi

    if [[ -n "${TARGET_VM_FORMATS:-}" ]]; then
        export TARGET_VM_FORMATS="${TARGET_VM_FORMATS,,}"
        [[ "$TARGET_VM_FORMATS" == "all" ]] && export TARGET_VM_FORMATS="qcow2,vdi,vmdk,vhdx"
        if ! validate_vm_formats "$TARGET_VM_FORMATS"; then
            >&2 echo "TARGET_VM_FORMATS must be 'all', 'none', or a comma-separated list of qcow2, vdi, vmdk, vhdx (got: '${TARGET_VM_FORMATS}')."
            exit 1
        fi
        return 0
    fi

    if prompts_enabled; then
        interactive_vm_formats_pick
        return 0
    fi

    export TARGET_VM_FORMATS="qcow2"
}

# Home directory of the human who launched the build (even under sudo).
function invoking_user_home() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        local h
        h="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6)"
        if [[ -n "$h" ]]; then
            echo "$h"
            return 0
        fi
    fi
    echo "${HOME:-/root}"
}

# debootstrap extracts .deb archives with tar; DrvFs/9p under WSL (/mnt/c, etc.)
# breaks that. Returns success when PATH lives on a Windows-backed mount.
function path_on_windows_mount() {
    local path="$1" probe="$1" fs_type
    while [[ -n "$probe" && "$probe" != "/" && ! -e "$probe" ]]; do
        probe="$(dirname "$probe")"
    done
    [[ -z "$probe" ]] && probe="/"
    fs_type="$(df -T "$probe" 2>/dev/null | awk 'NR==2 {print tolower($2)}')"
    [[ "$path" == /mnt/* ]] || [[ "$path" == /media/* ]] || \
        [[ "$fs_type" == "9p" ]] || [[ "$fs_type" == "drvfs" ]]
}

# Workspace and output locations:
#   * Basic mode: the workspace lives in a root-owned system directory
#     ($UVB_SYSTEM_WORKSPACE_PARENT) that regular users cannot touch -- the
#     same idea as the old WSL relocation -- and the finished image lands in
#     the invoking user's home directory.
#   * Advanced mode: prompts for both paths (workspace default:
#     ~/uvb-workspace, output default: ~); non-interactive runs use those
#     defaults silently.
#   * UBUNTU_VANILLA_WORKSPACE / UVB_OUTPUT_DIR override either path and
#     skip the prompts (any mode).
function resolve_workspace_paths() {
    local user_home
    user_home="$(invoking_user_home)"

    local interactive_advanced=0
    if [[ "${ADVANCED_MODE:-0}" == "1" ]] && prompts_enabled; then
        interactive_advanced=1
    fi

    # -- Workspace parent directory ----------------------------------
    local ws_parent=""
    if [[ -n "${UBUNTU_VANILLA_WORKSPACE:-}" ]]; then
        ws_parent="${UBUNTU_VANILLA_WORKSPACE%/}"
        echo "=====> Workspace parent (UBUNTU_VANILLA_WORKSPACE): $ws_parent" >&2
    elif [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        local ws_default="$user_home/uvb-workspace"
        if [[ "$interactive_advanced" -eq 1 ]]; then
            local _ws
            read -r -p "  Workspace directory [${ws_default}]: " _ws
            ws_parent="${_ws:-$ws_default}"
        else
            ws_parent="$ws_default"
        fi
        ws_parent="${ws_parent%/}"
    else
        # Basic mode: root-owned system path, out of the user's reach (and
        # always on a Linux-native filesystem, so WSL /mnt/c is a non-issue).
        ws_parent="$UVB_SYSTEM_WORKSPACE_PARENT"
    fi
    [[ -z "$ws_parent" ]] && ws_parent="/"

    if path_on_windows_mount "$ws_parent"; then
        echo "=====> $ws_parent is on a Windows/WSL mount -- debootstrap cannot unpack reliably there." >&2
        ws_parent="$UVB_SYSTEM_WORKSPACE_PARENT"
        echo "=====> Using Linux-native workspace parent instead: $ws_parent" >&2
    fi

    WORKSPACE_DIR="${ws_parent%/}/workspace-img"
    WORKSPACE_CHROOT="$WORKSPACE_DIR/chroot"
    WORKSPACE_IMAGE="$WORKSPACE_DIR/image"

    # -- Output directory (final image + checksums) --------------------
    if [[ -n "${UVB_OUTPUT_DIR:-}" ]]; then
        OUTPUT_DIR="${UVB_OUTPUT_DIR%/}"
        echo "=====> Output directory (UVB_OUTPUT_DIR): $OUTPUT_DIR" >&2
    elif [[ "$interactive_advanced" -eq 1 ]]; then
        local _out
        read -r -p "  Output directory for the image [${user_home}]: " _out
        OUTPUT_DIR="${_out:-$user_home}"
        OUTPUT_DIR="${OUTPUT_DIR%/}"
    else
        OUTPUT_DIR="$user_home"
    fi
    [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="/"

    if [[ "${TMPDIR:-}" == /mnt/* ]] || [[ "${TMPDIR:-}" == /media/* ]]; then
        echo "=====> TMPDIR is on a Windows mount (${TMPDIR:-}); using /tmp for extraction." >&2
        export TMPDIR=/tmp
    fi
}

function print_build_summary() {
    local hv=""
    hv="$(release_version "${TARGET_UBUNTU_VERSION:-}")"

    ui_heading "Build configuration"
    ui_kv "Ubuntu release"  "${TARGET_UBUNTU_VERSION:-?}${hv:+  (Ubuntu ${hv} LTS)}"
    ui_kv "Kernel"          "${TARGET_KERNEL_FLAVOR:-?}${TARGET_KERNEL_PACKAGE:+  [${TARGET_KERNEL_PACKAGE}]}"
    ui_kv "Desktop"         "${TARGET_DESKTOP:-?}"
    case "${TARGET_DESKTOP:-}" in
        gnome)  ui_kv "  with Recommends" "${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" ;;
        kde-plasma) ui_kv "  KDE package" "${TARGET_KDE_PACKAGE:-kde-standard}" ;;
        mate)
            ui_kv "  MATE metapackage" "${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
            ui_kv "  MATE extras" "${TARGET_MATE_EXTRAS:-0}"
            ;;
    esac
    ui_kv "Profile"         "${TARGET_IMAGE_PROFILE:-desktop}"
    local _fw="${TARGET_FIRMWARE:-uefi}"
    [[ "$_fw" == "uefi" ]] && _fw="uefi  (UEFI-only)"
    [[ "$_fw" == "hybrid" ]] && _fw="hybrid  (BIOS + UEFI)"
    ui_kv "Firmware"        "$_fw"
    ui_kv "Network stack"   "${TARGET_NETWORK_STACK:-network-manager}"
    ui_kv "Image allocation" "${TARGET_IMG_ALLOC:-truncate}"
    ui_kv "Disk size"       "${TARGET_DISK_SIZE_GB:-32} GB  (ESP 512 MB + swap 4 GB + root = rest)"
    local _user_line=""
    if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
        _user_line="baked at build time (user: ${TARGET_USERNAME:-?})"
    elif [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
        _user_line="created at deploy time (cloud-init)"
    else
        _user_line="first-boot wizard on the VM console"
    fi
    ui_kv "User account"    "$_user_line"
    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        if [[ "${TARGET_VM_FORMATS:-qcow2}" == "none" ]]; then
            ui_kv "VM formats"      "raw .img only"
        else
            ui_kv "VM formats"      "raw + ${TARGET_VM_FORMATS:-qcow2}"
        fi
    fi
    local _bs=""
    case "${TARGET_BRAVE_CHANNEL:-release}" in
        none)              _bs="Brave: none" ;;
        release)           _bs="Brave: stable" ;;
        origin)            _bs="Brave: origin" ;;
    esac
    [[ "${TARGET_LIBREWOLF:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Librewolf"
    [[ "${TARGET_FIREFOX:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox"
    [[ "${TARGET_FIREFOX_ESR:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox ESR"
    [[ "${TARGET_THUNDERBIRD:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Thunderbird"
    ui_kv "Browsers"       "${_bs}"
    ui_kv "Ubuntu Studio"  "${TARGET_UBUNTU_STUDIO:-0}"
    ui_kv "Pacstall"        "${TARGET_PACSTALL:-1}"
    ui_kv "fwupd"           "${TARGET_FWUPD:-0}  (blocked during build either way)"
    ui_kv "OpenSSH server"  "${TARGET_OPENSSH_SERVER:-0}"
    local _cockpit="${TARGET_COCKPIT:-0}"
    [[ "$_cockpit" == "1" ]] && _cockpit="1  (from ${TARGET_UBUNTU_VERSION:-release}-backports)"
    ui_kv "Cockpit"         "$_cockpit"
    if [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        ui_kv "Advanced mode"   "enabled (workspace preserved, package cache active)"
    fi
    ui_kv "Target name"     "${TARGET_NAME:-?}"
    ui_kv "Mirror"          "${TARGET_UBUNTU_MIRROR:-?}"
    ui_kv "Workspace"       "${WORKSPACE_DIR:-?}"
    ui_kv "Output image"    "${OUTPUT_DIR:-?}/${TARGET_NAME:-ubuntu}.img"
    echo
}

function print_build_result() {
    local img_path="${OUTPUT_DIR:-?}/${TARGET_NAME:-ubuntu}.img"
    if [[ ! -f "$img_path" ]]; then
        ui_heading "Build finished"
        ui_info "No image produced at $img_path (this is expected for partial runs)."
        return 0
    fi
    local size=""
    size="$(du -h --apparent-size "$img_path" 2>/dev/null | awk '{print $1}')"

    ui_heading "Build complete"
    ui_kv "Image"  "$img_path"
    ui_kv "Size"   "${size:-unknown}"
    if [[ -f "$img_path.sha1" ]]; then
        ui_kv "SHA1"   "$(awk '{print $1}' "$img_path.sha1")"
    fi
    if [[ -f "$img_path.sha256" ]]; then
        ui_kv "SHA256" "$(awk '{print $1}' "$img_path.sha256")"
    fi
    if [[ "$UVB_IMAGE_KIND" == "vm" ]]; then
        local fmt out
        for fmt in ${TARGET_VM_FORMATS//,/ }; do
            [[ "$fmt" == "none" ]] && continue
            out="${img_path%.img}.${fmt}"
            [[ -f "$out" ]] && ui_kv "Export ($fmt)" "$out"
        done
    fi
    echo
    echo "  Next steps:"
    if [[ "$UVB_IMAGE_KIND" == "cloud" ]]; then
        echo "    Upload the raw .img to your cloud provider (most accept raw directly;"
        echo "    convert with qemu-img if yours wants qcow2/vhd). When deployed to a"
        echo "    larger disk, cloud-init/growpart grows the root filesystem on first"
        echo "    boot."
        if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
            echo "    Log in with the account baked in at build time: ${TARGET_USERNAME:-?}."
        else
            echo "    User accounts and SSH keys are created at deploy time by cloud-init"
            echo "    from your provider's settings."
        fi
    else
        echo "    Attach the exported disk to a new VM (QCOW2 for QEMU/KVM/Proxmox,"
        echo "    VDI for VirtualBox, VMDK for VMware, VHDX for Hyper-V) or use the"
        if [[ "${TARGET_FIRMWARE:-uefi}" == "hybrid" ]]; then
            echo "    raw .img directly. The hybrid image boots on both BIOS and UEFI VMs."
        else
            echo "    raw .img directly. Create the VM with UEFI firmware (UEFI-only image)."
        fi
        if [[ "${TARGET_USER_MODE:-deploy}" == "build" ]]; then
            echo "    Log in with the account baked in at build time: ${TARGET_USERNAME:-?}."
        else
            echo "    On first boot the VM console asks you to create your user account."
        fi
    fi
    echo
}

# generate_config_wizard -- interactive wizard that generates a build-img.cfg file.
# Walks the user through each setting and writes the result.
function generate_config_wizard() {
    if ! prompts_enabled; then
        ui_err "Config wizard requires an interactive terminal."
        exit 1
    fi

    local out_path="$SCRIPT_DIR/build-img.cfg"

    ui_banner "Build Configuration Wizard"
    echo "  This wizard will generate a build-img.cfg file with your settings."
    echo "  Press Enter to accept the [default] value shown in brackets."
    echo

    if [[ -f "$out_path" ]]; then
        if ! ui_confirm "  $out_path already exists. Overwrite?" n; then
            ui_info "Wizard cancelled."
            exit 0
        fi
    fi

    local _release _kernel _desktop _mirror
    local _firmware _network _alloc _disk_size _profile _user_mode _vm_formats
    local _brave _librewolf _firefox _firefox_esr _thunderbird
    local _pacstall _ubuntu_studio _fwupd _openssh _cockpit
    local _locale _keyboard_layout _keyboard_variant
    local _advanced _name _workspace _output

    # Release
    echo "  Supported releases: jammy (22.04), noble (24.04), resolute (26.04)"
    read -r -p "  Release [noble]: " _release
    _release="${_release:-noble}"

    # Kernel
    read -r -p "  Kernel flavor (generic / lowlatency) [generic]: " _kernel
    _kernel="${_kernel:-generic}"

    # Desktop
    echo "  Desktops: gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, kde-plasma"
    read -r -p "  Desktop [gnome]: " _desktop
    _desktop="${_desktop:-gnome}"

    # Firmware / boot mode (uefi = UEFI-only, hybrid = BIOS + UEFI)
    read -r -p "  Firmware (uefi / hybrid) [uefi]: " _firmware
    _firmware="${_firmware:-uefi}"

    # Network stack (CLI images; desktop images always use NetworkManager)
    read -r -p "  Network stack (networkd / network-manager) [networkd]: " _network
    _network="${_network:-networkd}"

    # Image allocation tool
    read -r -p "  Image allocation tool (truncate / fallocate / dd) [truncate]: " _alloc
    _alloc="${_alloc:-truncate}"

    # Disk image size
    read -r -p "  Disk image size in GB (32 / 64 / 128 / any number >= 10) [32]: " _disk_size
    _disk_size="${_disk_size:-32}"

    # Image profile
    read -r -p "  Image profile (desktop / cli) [desktop]: " _profile
    _profile="${_profile:-desktop}"

    # User account creation
    read -r -p "  User account (build = bake credentials / deploy = create after deployment) [deploy]: " _user_mode
    _user_mode="${_user_mode:-deploy}"

    _vm_formats=""

    # Mirror
    read -r -p "  Mirror [https://archive.ubuntu.com/ubuntu/]: " _mirror
    _mirror="${_mirror:-https://archive.ubuntu.com/ubuntu/}"

    # Brave
    echo "  Brave browser channel: none, release, origin"
    read -r -p "  Brave channel [release]: " _brave
    _brave="${_brave:-release}"

    # LibreWolf
    read -r -p "  Pre-install LibreWolf? (0/1) [0]: " _librewolf
    _librewolf="${_librewolf:-0}"

    # Firefox
    read -r -p "  Pre-install Firefox? (0/1) [0]: " _firefox
    _firefox="${_firefox:-0}"

    # Firefox ESR
    read -r -p "  Pre-install Firefox ESR? (0/1) [0]: " _firefox_esr
    _firefox_esr="${_firefox_esr:-0}"

    # Thunderbird
    read -r -p "  Pre-install Thunderbird? (0/1) [0]: " _thunderbird
    _thunderbird="${_thunderbird:-0}"

    # Pacstall
    read -r -p "  Install Pacstall? (0/1) [1]: " _pacstall
    _pacstall="${_pacstall:-1}"

    # Ubuntu Studio
    read -r -p "  Install Ubuntu Studio packages? (0/1) [0]: " _ubuntu_studio
    _ubuntu_studio="${_ubuntu_studio:-0}"

    # fwupd
    read -r -p "  Pre-install fwupd? (0/1, blocked during build either way) [0]: " _fwupd
    _fwupd="${_fwupd:-0}"

    # OpenSSH server
    read -r -p "  Pre-install openssh-server? (0/1) [0]: " _openssh
    _openssh="${_openssh:-0}"

    # Cockpit
    read -r -p "  Pre-install Cockpit from backports? (0/1) [0]: " _cockpit
    _cockpit="${_cockpit:-0}"

    # Locale
    read -r -p "  System locale (blank to skip, e.g. en_US.UTF-8): " _locale

    # Keyboard layout
    read -r -p "  Keyboard layout (blank to skip, e.g. us): " _keyboard_layout

    # Keyboard variant
    if [[ -n "$_keyboard_layout" ]]; then
        read -r -p "  Keyboard variant (blank for default, e.g. intl): " _keyboard_variant
    else
        _keyboard_variant=""
    fi

    # Advanced mode
    read -r -p "  Enable advanced mode? (0/1) [0]: " _advanced
    _advanced="${_advanced:-0}"

    # Workspace / output paths (advanced only; blank keeps the runtime defaults:
    # workspace ~/uvb-workspace, output = your home directory)
    _workspace=""
    _output=""
    if [[ "$_advanced" == "1" ]]; then
        read -r -p "  Workspace directory (blank for ~/uvb-workspace): " _workspace
        read -r -p "  Output directory for the image (blank for your home directory): " _output
    fi

    # Custom name
    read -r -p "  Custom image name (blank for auto): " _name

    # Write the config file
    cat > "$out_path" <<WIZARD_EOF
# Ubuntu Vanilla Cloud Image Builder -- generated by config wizard
# $(date '+%Y-%m-%d %H:%M:%S %Z')

# --- Core ---
TARGET_UBUNTU_VERSION=${_release}
TARGET_KERNEL_FLAVOR=${_kernel}
TARGET_DESKTOP=${_desktop}
TARGET_FIRMWARE=${_firmware}
TARGET_NETWORK_STACK=${_network}
TARGET_IMG_ALLOC=${_alloc}
TARGET_DISK_SIZE_GB=${_disk_size}
TARGET_IMAGE_PROFILE=${_profile}
TARGET_USER_MODE=${_user_mode}
TARGET_UBUNTU_MIRROR=${_mirror}

# --- Browsers ---
TARGET_BRAVE_CHANNEL=${_brave}
TARGET_LIBREWOLF=${_librewolf}
TARGET_FIREFOX=${_firefox}
TARGET_FIREFOX_ESR=${_firefox_esr}
TARGET_THUNDERBIRD=${_thunderbird}

# --- Package Managers ---
TARGET_PACSTALL=${_pacstall}

# --- Extras ---
TARGET_UBUNTU_STUDIO=${_ubuntu_studio}

# --- Optional services/tools (all default 0) ---
TARGET_FWUPD=${_fwupd}
TARGET_OPENSSH_SERVER=${_openssh}
TARGET_COCKPIT=${_cockpit}
WIZARD_EOF

    {
        if [[ -n "$_locale" || -n "$_keyboard_layout" ]]; then
            echo ""
            echo "# --- Locale & Keyboard ---"
            [[ -n "$_locale" ]] && echo "TARGET_LOCALE=${_locale}"
            if [[ -n "$_keyboard_layout" ]]; then
                echo "TARGET_KEYBOARD_LAYOUT=${_keyboard_layout}"
                [[ -n "$_keyboard_variant" ]] && echo "TARGET_KEYBOARD_VARIANT=${_keyboard_variant}"
            fi
        fi

        if [[ "$_advanced" == "1" ]]; then
            echo ""
            echo "# --- Advanced ---"
            echo "ADVANCED_MODE=1"
            [[ -n "$_workspace" ]] && echo "UBUNTU_VANILLA_WORKSPACE=${_workspace}"
            [[ -n "$_output" ]] && echo "UVB_OUTPUT_DIR=${_output}"
        fi

        if [[ -n "$_name" ]]; then
            echo ""
            echo "# --- Output ---"
            echo "TARGET_NAME=${_name}"
        fi
    } >> "$out_path"

    echo
    ui_ok "Config written to: $out_path"
    ui_info "Run './build-img.sh -' to start a build with these settings."
    exit 0
}

# load_config_file FILE -- source a config file (key=value lines, # comments, blank lines).
# Only recognized TARGET_* variables are exported.
# Unknown keys are ignored; the config cannot run arbitrary commands.
function load_config_file() {
    local config_path="$1"
    if [[ ! -f "$config_path" ]]; then
        ui_err "Config file not found: $config_path"
        exit 1
    fi
    ui_info "Loading config from: $config_path"
    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank lines and comments.
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Strip inline comments: only "#" preceded by whitespace starts a
        # comment, so values containing "#" (e.g. GRUB labels) survive.
        line="${line%%[[:space:]]\#*}"
        # Match KEY=VALUE (with optional quotes).
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            # Strip surrounding quotes.
            val="${val#\"}" ; val="${val%\"}"
            val="${val#\'}" ; val="${val%\'}"
            val="${val## }" ; val="${val%% }"
            case "$key" in
                TARGET_UBUNTU_VERSION|TARGET_UBUNTU_MIRROR|TARGET_KERNEL_FLAVOR|\
                TARGET_KERNEL_PACKAGE|TARGET_DESKTOP|TARGET_KDE_PACKAGE|\
                TARGET_MATE_PACKAGE|TARGET_MATE_EXTRAS|TARGET_BROWSER|\
                TARGET_BRAVE_CHANNEL|TARGET_LIBREWOLF|TARGET_FIREFOX|\
                TARGET_FIREFOX_ESR|TARGET_THUNDERBIRD|TARGET_UBUNTU_STUDIO|\
                TARGET_PACSTALL|TARGET_FWUPD|TARGET_OPENSSH_SERVER|TARGET_COCKPIT|\
                TARGET_GNOME_INSTALL_RECOMMENDS|TARGET_NAME|\
                TARGET_LOCALE|TARGET_KEYBOARD_LAYOUT|TARGET_KEYBOARD_VARIANT|\
                TARGET_FIRMWARE|TARGET_DISK_SIZE_GB|TARGET_IMAGE_PROFILE|\
                TARGET_NETWORK_STACK|TARGET_IMG_ALLOC|\
                TARGET_USER_MODE|TARGET_USERNAME|TARGET_USER_PASSWORD|\
                TARGET_USER_FULLNAME|TARGET_HOSTNAME|TARGET_VM_FORMATS|\
                UBUNTU_VANILLA_WORKSPACE|UVB_OUTPUT_DIR|NO_CONFIRM|\
                INTERACTIVE|ADVANCED_MODE|HOOKS_DIR)
                    export "$key=$val"
                    ;;
                *)
                    ui_warn "Config: ignoring unknown key '$key'"
                    ;;
            esac
        fi
    done < "$config_path"
}

function host_main() {
    local cli_kernel=""
    local cli_release=""
    local cli_mirror=""
    local cli_network=""
    local cli_alloc=""
    local cli_firmware=""
    local cli_disk_size=""
    local cli_profile=""
    local cli_user_mode=""
    local cli_username=""
    local cli_password=""
    local cli_fullname=""
    local cli_hostname=""
    local cli_formats=""
    local cli_desktop=""
    local cli_kde=""
    local cli_mate=""
    local cli_mate_extras_set=0
    local cli_mate_extras=0
    local cli_browser=""
    local cli_brave=""
    local cli_librewolf_set=0
    local cli_librewolf=0
    local cli_firefox_set=0
    local cli_firefox=0
    local cli_firefox_esr_set=0
    local cli_firefox_esr=0
    local cli_thunderbird_set=0
    local cli_thunderbird=0
    local cli_ubuntustudio_set=0
    local cli_ubuntustudio=0
    local cli_pacstall_set=0
    local cli_pacstall=0
    local cli_fwupd_set=0
    local cli_fwupd=0
    local cli_openssh_set=0
    local cli_openssh=0
    local cli_cockpit_set=0
    local cli_cockpit=0
    local cli_locale=""
    local cli_keyboard_layout=""
    local cli_keyboard_variant=""
    local cli_config=""
    local cli_interactive=""
    local args=()

    set_defaults

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kernel=generic|--kernel=lowlatency)
                cli_kernel="${1#--kernel=}"
                shift
                ;;
            --kernel)
                cli_kernel="$2"
                shift 2
                ;;
            --release=jammy|--release=noble|--release=resolute)
                cli_release="${1#--release=}"
                shift
                ;;
            --release)
                cli_release="$2"
                shift 2
                ;;
            --mirror=*)
                cli_mirror="${1#--mirror=}"
                shift
                ;;
            --mirror)
                cli_mirror="$2"
                shift 2
                ;;
            --network=*)
                cli_network="${1#--network=}"
                shift
                ;;
            --network)
                cli_network="$2"
                shift 2
                ;;
            --alloc-tool=*)
                cli_alloc="${1#--alloc-tool=}"
                shift
                ;;
            --alloc-tool)
                cli_alloc="$2"
                shift 2
                ;;
            --firmware=*)
                cli_firmware="${1#--firmware=}"
                shift
                ;;
            --firmware)
                cli_firmware="$2"
                shift 2
                ;;
            --disk-size=*)
                cli_disk_size="${1#--disk-size=}"
                shift
                ;;
            --disk-size)
                cli_disk_size="$2"
                shift 2
                ;;
            --profile=*)
                cli_profile="${1#--profile=}"
                shift
                ;;
            --profile)
                cli_profile="$2"
                shift 2
                ;;
            --user-mode=*)
                cli_user_mode="${1#--user-mode=}"
                shift
                ;;
            --user-mode)
                cli_user_mode="$2"
                shift 2
                ;;
            --username=*)
                cli_username="${1#--username=}"
                shift
                ;;
            --username)
                cli_username="$2"
                shift 2
                ;;
            --password=*)
                cli_password="${1#--password=}"
                shift
                ;;
            --password)
                cli_password="$2"
                shift 2
                ;;
            --fullname=*)
                cli_fullname="${1#--fullname=}"
                shift
                ;;
            --fullname)
                cli_fullname="$2"
                shift 2
                ;;
            --hostname=*)
                cli_hostname="${1#--hostname=}"
                shift
                ;;
            --hostname)
                cli_hostname="$2"
                shift 2
                ;;
            --desktop=*)
                cli_desktop="${1#--desktop=}"
                shift
                ;;
            --desktop)
                cli_desktop="$2"
                shift 2
                ;;
            --kde=kde-full|--kde=kde-standard|--kde=kde-plasma-desktop)
                cli_kde="${1#--kde=}"
                shift
                ;;
            --kde)
                cli_kde="$2"
                shift 2
                ;;
            --mate=*)
                cli_mate="${1#--mate=}"
                shift
                ;;
            --mate)
                cli_mate="$2"
                shift 2
                ;;
            --mate-extras)
                cli_mate_extras_set=1
                cli_mate_extras=1
                shift
                ;;
            --no-mate-extras)
                cli_mate_extras_set=1
                cli_mate_extras=0
                shift
                ;;
            --browser=release|--browser=origin)
                cli_browser="${1#--browser=}"
                shift
                ;;
            --browser)
                cli_browser="$2"
                shift 2
                ;;
            --brave=none|--brave=release|--brave=origin)
                cli_brave="${1#--brave=}"
                shift
                ;;
            --brave)
                cli_brave="$2"
                shift 2
                ;;
            --librewolf)
                cli_librewolf_set=1
                cli_librewolf=1
                shift
                ;;
            --no-librewolf)
                cli_librewolf_set=1
                cli_librewolf=0
                shift
                ;;
            --firefox)
                cli_firefox_set=1
                cli_firefox=1
                shift
                ;;
            --no-firefox)
                cli_firefox_set=1
                cli_firefox=0
                shift
                ;;
            --firefox-esr)
                cli_firefox_esr_set=1
                cli_firefox_esr=1
                shift
                ;;
            --no-firefox-esr)
                cli_firefox_esr_set=1
                cli_firefox_esr=0
                shift
                ;;
            --thunderbird)
                cli_thunderbird_set=1
                cli_thunderbird=1
                shift
                ;;
            --no-thunderbird)
                cli_thunderbird_set=1
                cli_thunderbird=0
                shift
                ;;
            --ubuntu-studio)
                cli_ubuntustudio_set=1
                cli_ubuntustudio=1
                shift
                ;;
            --no-ubuntu-studio)
                cli_ubuntustudio_set=1
                cli_ubuntustudio=0
                shift
                ;;
            --pacstall)
                cli_pacstall_set=1
                cli_pacstall=1
                shift
                ;;
            --no-pacstall)
                cli_pacstall_set=1
                cli_pacstall=0
                shift
                ;;
            --fwupd)
                cli_fwupd_set=1
                cli_fwupd=1
                shift
                ;;
            --no-fwupd)
                cli_fwupd_set=1
                cli_fwupd=0
                shift
                ;;
            --openssh-server)
                cli_openssh_set=1
                cli_openssh=1
                shift
                ;;
            --no-openssh-server)
                cli_openssh_set=1
                cli_openssh=0
                shift
                ;;
            --cockpit)
                cli_cockpit_set=1
                cli_cockpit=1
                shift
                ;;
            --no-cockpit)
                cli_cockpit_set=1
                cli_cockpit=0
                shift
                ;;
            --locale=*)
                cli_locale="${1#--locale=}"
                shift
                ;;
            --locale)
                cli_locale="$2"
                shift 2
                ;;
            --keyboard-layout=*)
                cli_keyboard_layout="${1#--keyboard-layout=}"
                shift
                ;;
            --keyboard-layout)
                cli_keyboard_layout="$2"
                shift 2
                ;;
            --keyboard-variant=*)
                cli_keyboard_variant="${1#--keyboard-variant=}"
                shift
                ;;
            --keyboard-variant)
                cli_keyboard_variant="$2"
                shift 2
                ;;
            --config=*)
                cli_config="${1#--config=}"
                shift
                ;;
            --config)
                cli_config="$2"
                shift 2
                ;;
            --interactive)
                cli_interactive="1"
                shift
                ;;
            --no-interactive)
                cli_interactive="0"
                shift
                ;;
            --hooks-dir=*)
                HOOKS_DIR="${1#--hooks-dir=}"
                shift
                ;;
            --hooks-dir)
                HOOKS_DIR="$2"
                shift 2
                ;;
            --advanced)
                export ADVANCED_MODE=1
                ADVANCED_MODE_EXPLICIT=1
                shift
                ;;
            --generate-config)
                export ADVANCED_MODE=1
                # The wizard runs during argument parsing, before the
                # --interactive handling below; honor an earlier --interactive.
                [[ "$cli_interactive" == "1" ]] && FORCE_INTERACTIVE=1
                generate_config_wizard
                ;;
            -h|--help)
                host_help
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    set -- "${args[@]}"

    # Resolve build mode first: everything below (config loading, interactive
    # overrides) is gated on it. Asked only when no explicit mode was given.
    if [[ "$ADVANCED_MODE_EXPLICIT" -eq 0 ]]; then
        interactive_mode_pick
    fi

    # Load config file (advanced mode only). Config values act as defaults; CLI flags override them below.
    if [[ "${ADVANCED_MODE:-0}" == "1" ]]; then
        if [[ -n "$cli_config" ]]; then
            load_config_file "$cli_config"
        elif [[ -f "$SCRIPT_DIR/build-img.cfg" ]]; then
            load_config_file "$SCRIPT_DIR/build-img.cfg"
        fi
    elif [[ -n "$cli_config" ]]; then
        ui_warn "--config requires --advanced mode. Ignoring config file."
    fi

    # Handle --interactive / --no-interactive (advanced mode only, like --config).
    # The INTERACTIVE variable can also come from the config file.
    # --no-interactive: redirect stdin from /dev/null so prompts_enabled() returns false,
    # making the build fully non-interactive (all missing values use defaults or fail with an error).
    # --interactive: force prompts_enabled() true even when stdin is not a TTY (e.g. piped).
    # Basic mode keeps the default behavior: prompts whenever stdin is a TTY.
    if [[ "${ADVANCED_MODE:-0}" != "1" ]]; then
        if [[ -n "$cli_interactive" ]] || [[ -n "${INTERACTIVE:-}" ]]; then
            ui_warn "--interactive / --no-interactive / INTERACTIVE require --advanced mode. Ignoring."
        fi
    elif [[ "$cli_interactive" == "0" ]] || [[ "${INTERACTIVE:-}" == "0" && -z "$cli_interactive" ]]; then
        exec 0</dev/null
        export NO_CONFIRM=1
    elif [[ "$cli_interactive" == "1" ]] || [[ "${INTERACTIVE:-}" == "1" ]]; then
        FORCE_INTERACTIVE=1
    fi

    cd "$SCRIPT_DIR"
    resolve_workspace_paths

    ui_banner "Ubuntu Vanilla Cloud Image Builder"
    ui_kv "Script"     "$0"
    ui_kv "Workspace"  "$WORKSPACE_DIR"
    ui_kv "Output dir" "$OUTPUT_DIR"
    ui_kv "Started at" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    HOST_ABORT_CLEANUP_DONE=0
    trap host_build_exit_trap EXIT
    trap 'host_build_signal_trap 130' INT
    trap 'host_build_signal_trap 143' TERM

    setup_sudo_keepalive

    if [[ -n "$cli_release" ]]; then
        export TARGET_UBUNTU_VERSION="$cli_release"
    fi
    if [[ -n "$cli_mirror" ]]; then
        export TARGET_UBUNTU_MIRROR="$cli_mirror"
    fi
    if [[ -n "$cli_kernel" ]]; then
        export TARGET_KERNEL_FLAVOR="$cli_kernel"
    fi
    if [[ -n "$cli_network" ]]; then
        export TARGET_NETWORK_STACK="$cli_network"
    fi
    if [[ -n "$cli_alloc" ]]; then
        export TARGET_IMG_ALLOC="$cli_alloc"
    fi
    if [[ -n "$cli_firmware" ]]; then
        export TARGET_FIRMWARE="$cli_firmware"
    fi
    if [[ -n "$cli_disk_size" ]]; then
        export TARGET_DISK_SIZE_GB="$cli_disk_size"
    fi
    if [[ -n "$cli_profile" ]]; then
        export TARGET_IMAGE_PROFILE="$cli_profile"
    fi
    if [[ -n "$cli_user_mode" ]]; then
        export TARGET_USER_MODE="$cli_user_mode"
    fi
    if [[ -n "$cli_username" ]]; then
        export TARGET_USERNAME="$cli_username"
    fi
    if [[ -n "$cli_password" ]]; then
        export TARGET_USER_PASSWORD="$cli_password"
    fi
    if [[ -n "$cli_fullname" ]]; then
        export TARGET_USER_FULLNAME="$cli_fullname"
    fi
    if [[ -n "$cli_hostname" ]]; then
        export TARGET_HOSTNAME="$cli_hostname"
    fi
    if [[ -n "$cli_desktop" ]]; then
        export TARGET_DESKTOP="$cli_desktop"
    fi
    if [[ -n "$cli_kde" ]]; then
        export TARGET_KDE_PACKAGE="$cli_kde"
    fi
    if [[ -n "$cli_mate" ]]; then
        export TARGET_MATE_PACKAGE="$cli_mate"
    fi
    if [[ "$cli_mate_extras_set" -eq 1 ]]; then
        export TARGET_MATE_EXTRAS="$cli_mate_extras"
    fi
    if [[ -n "$cli_browser" ]]; then
        export TARGET_BROWSER="$cli_browser"
    fi
    if [[ -n "$cli_brave" ]]; then
        export TARGET_BRAVE_CHANNEL="$cli_brave"
    fi
    if [[ "$cli_librewolf_set" -eq 1 ]]; then
        export TARGET_LIBREWOLF="$cli_librewolf"
    fi
    if [[ "$cli_firefox_set" -eq 1 ]]; then
        export TARGET_FIREFOX="$cli_firefox"
    fi
    if [[ "$cli_firefox_esr_set" -eq 1 ]]; then
        export TARGET_FIREFOX_ESR="$cli_firefox_esr"
    fi
    if [[ "$cli_thunderbird_set" -eq 1 ]]; then
        export TARGET_THUNDERBIRD="$cli_thunderbird"
    fi
    if [[ "$cli_ubuntustudio_set" -eq 1 ]]; then
        export TARGET_UBUNTU_STUDIO="$cli_ubuntustudio"
    fi
    if [[ "$cli_pacstall_set" -eq 1 ]]; then
        export TARGET_PACSTALL="$cli_pacstall"
    fi
    if [[ "$cli_fwupd_set" -eq 1 ]]; then
        export TARGET_FWUPD="$cli_fwupd"
    fi
    if [[ "$cli_openssh_set" -eq 1 ]]; then
        export TARGET_OPENSSH_SERVER="$cli_openssh"
    fi
    if [[ "$cli_cockpit_set" -eq 1 ]]; then
        export TARGET_COCKPIT="$cli_cockpit"
    fi
    if [[ -n "$cli_locale" ]]; then
        export TARGET_LOCALE="$cli_locale"
    fi
    if [[ -n "$cli_keyboard_layout" ]]; then
        export TARGET_KEYBOARD_LAYOUT="$cli_keyboard_layout"
    fi
    if [[ -n "$cli_keyboard_variant" ]]; then
        export TARGET_KEYBOARD_VARIANT="$cli_keyboard_variant"
    fi

    if [[ -z "${TARGET_UBUNTU_VERSION:-}" ]]; then
        resolve_release_choice
    fi

    resolve_profile_choice
    resolve_network_stack_choice
    resolve_firmware_choice
    resolve_disk_size_choice
    resolve_alloc_choice

    if [[ -z "${TARGET_KERNEL_FLAVOR:-}" ]]; then
        resolve_kernel_choice
    fi
    if [[ -z "${TARGET_DESKTOP:-}" ]]; then
        resolve_desktop_choice
    fi
    normalize_desktop_variant
    if [[ -z "${TARGET_NAME:-}" ]]; then
        export TARGET_NAME
        TARGET_NAME="$(default_target_name)"
    fi
    if [[ -z "${TARGET_GNOME_INSTALL_RECOMMENDS:-}" ]]; then
        resolve_gnome_recommends_choice
    fi
    resolve_kde_package_choice
    resolve_mate_choice
    resolve_browser_selection
    resolve_ubuntu_studio_choice
    resolve_pacstall_choice
    resolve_optional_service_choices
    resolve_user_setup_choice
    resolve_vm_formats_choice

    check_settings
    set_target_kernel_package_from_flavor
    check_host_user

    local start_index end_index
    parse_cmd_range HOST_CMD host_help "$@"

    print_build_summary
    ui_info "Phases to run: ${HOST_CMD[*]:$start_index:$((end_index - start_index))}"
    echo
    if prompts_enabled && [[ "${NO_CONFIRM:-0}" != "1" ]]; then
        if ! ui_confirm "Start build now?" y; then
            echo
            ui_info "Build cancelled by user. No changes were made."
            exit 0
        fi
    fi

    local total=$((end_index - start_index))
    local i
    for ((i=start_index; i<end_index; i++)); do
        ui_step "$((i - start_index + 1))" "$total" "${HOST_CMD[i]}"
        "${HOST_CMD[i]}"
    done

    print_build_result
}

function chroot_help() {
    if [ -z "${1+x}" ]; then
        echo "Chroot phase: build the root filesystem that is later assembled into the disk image."
        echo
    else
        echo "$1"
        echo
    fi
    echo "Supported commands: ${CHROOT_CMD[*]}"
    echo
    echo "Syntax: $0 --chroot-internal [start_cmd] [-] [end_cmd]"
    echo
    exit 0
}

function check_chroot_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "The chroot phase must run as root."
        exit 1
    fi

    export HOME=/root
    export LC_ALL=C
}

function chroot_prepare() {
    echo "=====> running chroot_prepare ..."

    cat <<EOF > /etc/apt/sources.list
deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-security main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-security main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-updates main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-updates main restricted universe multiverse

deb $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-backports main restricted universe multiverse
deb-src $TARGET_UBUNTU_MIRROR $TARGET_UBUNTU_VERSION-backports main restricted universe multiverse
EOF

    echo "$TARGET_NAME" > /etc/hostname

    apt-get update

    block_snapd
    block_fwupd

    apt-get install -y libterm-readline-gnu-perl systemd-sysv

    dbus-uuidgen > /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id

    dpkg-divert --local --rename --add /sbin/initctl
    # -f: advanced-mode re-runs enter this stage with the symlink already in
    # place; plain ln -s would fail under set -e.
    ln -sf /bin/true /sbin/initctl
}

function install_pkg() {
    echo "=====> running install_pkg ... this will take a while ..."
    echo "=====> kernel metapackage: $TARGET_KERNEL_PACKAGE"
    apt-get -y upgrade

    apt-get install -y \
        sudo \
        ubuntu-standard \
        net-tools \
        locales \
        netplan.io \
        grub-common \
        grub-gfxpayload-lists \
        grub-pc \
        grub-pc-bin \
        grub2-common \
        grub-efi-amd64-bin \
        grub-efi-amd64-signed \
        shim-signed \
        dosfstools \
        e2fsprogs \
        parted

    if [[ "${TARGET_NETWORK_STACK:-network-manager}" == "network-manager" ]]; then
        echo "=====> networking: NetworkManager"
        apt-get install -y network-manager
    else
        echo "=====> networking: netplan + systemd-networkd (NetworkManager not installed)"
    fi

    echo "=====> installing kernel metapackage (with Recommends): $TARGET_KERNEL_PACKAGE"
    apt-get install -y "$TARGET_KERNEL_PACKAGE"

    if [[ "${UVB_IMAGE_KIND:-cloud}" == "cloud" ]]; then
        echo "=====> cloud-init: installing (deploy-time provisioning: users, SSH keys, growroot)"
        apt-get install -y cloud-init cloud-guest-utils
    else
        echo "=====> VM image: cloud-init skipped (credentials are baked in or created by the first-boot wizard)"
    fi

    customize_image

    # Run chroot hooks (modloader: chroot stage).
    run_chroot_hooks

    apt-get autoremove -y

    # Locale configuration: if TARGET_LOCALE is set, pre-seed debconf for unattended operation.
    if [[ -n "${TARGET_LOCALE:-}" ]]; then
        echo "=====> Configuring locale: ${TARGET_LOCALE}"
        sed -i "s/^# *${TARGET_LOCALE}/${TARGET_LOCALE}/" /etc/locale.gen 2>/dev/null || true
        echo "${TARGET_LOCALE}" >> /etc/locale.gen
        sort -u -o /etc/locale.gen /etc/locale.gen
        echo "locales locales/default_environment_locale select ${TARGET_LOCALE}" | debconf-set-selections
        echo "locales locales/locales_to_be_generated multiselect ${TARGET_LOCALE}" | debconf-set-selections
        dpkg-reconfigure --frontend=noninteractive locales
    else
        dpkg-reconfigure locales
    fi

    # Keyboard configuration: if TARGET_KEYBOARD_LAYOUT is set, pre-seed for unattended operation.
    if [[ -n "${TARGET_KEYBOARD_LAYOUT:-}" ]]; then
        local _kb_variant="${TARGET_KEYBOARD_VARIANT:-}"
        echo "=====> Configuring keyboard: layout=${TARGET_KEYBOARD_LAYOUT}${_kb_variant:+, variant=${_kb_variant}}"
        apt-get install -y keyboard-configuration console-setup 2>/dev/null || true
        echo "keyboard-configuration keyboard-configuration/layoutcode select ${TARGET_KEYBOARD_LAYOUT}" | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/variant select ${_kb_variant}" | debconf-set-selections
        echo "keyboard-configuration keyboard-configuration/model select pc105" | debconf-set-selections
        echo "console-setup console-setup/charmap47 select UTF-8" | debconf-set-selections
        dpkg-reconfigure --frontend=noninteractive keyboard-configuration
        dpkg-reconfigure --frontend=noninteractive console-setup
    fi

    if [[ "${TARGET_NETWORK_STACK:-network-manager}" == "network-manager" ]]; then
        cat <<EOF > /etc/NetworkManager/NetworkManager.conf
[main]
rc-manager=none
plugins=ifupdown,keyfile
dns=systemd-resolved

[ifupdown]
managed=false
EOF

        dpkg-reconfigure network-manager
    fi

    apt-get clean -y
}

function finish_up() {
    echo "=====> finish_up"

    # The fwupd ban is build-time only: drop it here so users of the shipped
    # system can install fwupd normally. (The snapd pin stays by design.)
    unblock_fwupd

    # Never ship SSH host keys in the image: openssh-server's postinst
    # generates them at install time, and baking them into the ISO would make
    # every installation share the same host identity. Unconditional (rm -f
    # is a no-op when openssh-server was not selected); the
    # ssh-host-keys-regen oneshot unit recreates them on first boot.
    rm -f /etc/ssh/ssh_host_*

    truncate -s 0 /etc/machine-id

    # -f: keep this stage re-runnable (advanced mode) after the symlink was
    # already removed by a previous pass.
    rm -f /sbin/initctl
    dpkg-divert --rename --remove /sbin/initctl

    rm -rf /tmp/* ~/.bash_history
}

function chroot_main() {
    shift
    set_defaults
    export TARGET_IMAGE_PROFILE="${TARGET_IMAGE_PROFILE:-desktop}"
    export TARGET_FIRMWARE="${TARGET_FIRMWARE:-uefi}"
    export TARGET_DISK_SIZE_GB="${TARGET_DISK_SIZE_GB:-32}"
    export TARGET_USER_MODE="${TARGET_USER_MODE:-deploy}"
    export TARGET_IMG_ALLOC="${TARGET_IMG_ALLOC:-truncate}"
    if [[ -z "${TARGET_NETWORK_STACK:-}" ]]; then
        if [[ "${TARGET_IMAGE_PROFILE:-desktop}" == "cli" ]]; then
            export TARGET_NETWORK_STACK="networkd"
        else
            export TARGET_NETWORK_STACK="network-manager"
        fi
    fi
    export TARGET_DESKTOP="${TARGET_DESKTOP:-gnome}"
    export TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-kde-standard}"
    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-mate-desktop-environment}"
    export TARGET_MATE_EXTRAS="${TARGET_MATE_EXTRAS:-0}"
    normalize_desktop_variant
    if [[ -n "${TARGET_BROWSER:-}" && -z "${TARGET_BRAVE_CHANNEL:-}" ]]; then
        export TARGET_BRAVE_CHANNEL="$TARGET_BROWSER"
    fi
    export TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-release}"
    export TARGET_LIBREWOLF="${TARGET_LIBREWOLF:-0}"
    export TARGET_FIREFOX="${TARGET_FIREFOX:-0}"
    export TARGET_FIREFOX_ESR="${TARGET_FIREFOX_ESR:-0}"
    export TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
    export TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}"
    export TARGET_FWUPD="${TARGET_FWUPD:-0}"
    export TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}"
    export TARGET_COCKPIT="${TARGET_COCKPIT:-0}"
    check_settings
    set_target_kernel_package_from_flavor
    check_chroot_root

    local start_index end_index
    parse_cmd_range CHROOT_CMD chroot_help "$@"

    local i
    for ((i=start_index; i<end_index; i++)); do
        "${CHROOT_CMD[i]}"
    done

    echo "$0 --chroot-internal - Chroot phase done."
}

if [[ "${1:-}" == "--chroot-internal" ]]; then
    chroot_main "$@"
else
    host_main "$@"
fi
