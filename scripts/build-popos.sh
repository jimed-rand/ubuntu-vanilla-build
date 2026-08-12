#!/bin/bash

# build-popos.sh -- Pop!_OS variant of build.sh.
#
# Repositories: everything comes from the CDN-backed https://apt.pop-os.org/
# -- the ubuntu mirror plus the release, proprietary, and release-ubuntu
# suites (staging suites are intentionally excluded). The origin server
# (apt-origin.pop-os.org) is only used as a per-suite fallback when the CDN
# does not publish a suite: fetching bulk package traffic straight from the
# origin makes it drop TLS connections mid-transfer (OpenSSL "unexpected
# eof while reading"), aborting the chroot phase.
# Calamares configuration comes from scripts/calamares-popos.
# Supported releases: jammy (22.04), noble (24.04), resolute (26.04) -- LTS only.
#
# Deliberate differences from official Pop!_OS media:
#   * Bootloader: official Pop!_OS ISOs use systemd-boot, which wants a large
#     (>= 1 GiB) EFI System Partition. This build keeps GRUB (BIOS + UEFI
#     hybrid) so no oversized ESP is required.
#   * Desktop: Pop's own desktops (pop-desktop, and COSMIC on noble/resolute)
#     are NOT offered -- COSMIC still has too many bugs when installed through
#     Calamares. Users can install COSMIC after installation; see the note
#     printed at the end of the build (print_build_result).
#   * Kernel: choose the System76 kernel (linux-system76, tracking the stable
#     Linux branch, from the Pop!_OS repos) or stock Ubuntu HWE kernels
#     (generic / lowlatency).

set -e
set -o pipefail
set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# Pop!_OS APT archive. Suites: ubuntu (mirror, via TARGET_UBUNTU_MIRROR),
# release, proprietary, and release-ubuntu. Staging suites are excluded.
# POP_APT_URL is the CDN endpoint packages must be fetched from;
# POP_APT_ORIGIN_URL is the origin server, used only as a per-suite fallback
# -- bulk downloads from the origin get their TLS connections cut
# mid-transfer ("SSL routines::unexpected eof while reading").
POP_APT_URL="https://apt.pop-os.org"
POP_APT_ORIGIN_URL="https://apt-origin.pop-os.org"
# Pop!_OS archive signing key (pop-keyring).
POP_KEY_FINGERPRINT="63C46DF0140D738961429F4E204DD8AEC33A7AFF"
# Set in resolve_workspace_paths() during host_main (WSL: avoid /mnt/c for debootstrap).
WORKSPACE_DIR=""
WORKSPACE_CHROOT=""
WORKSPACE_IMAGE=""
# Where the finished ISO + checksums land. Set in resolve_workspace_paths().
OUTPUT_DIR=""
# Basic-mode workspace parent: root-owned system path regular users cannot touch.
UVB_SYSTEM_WORKSPACE_PARENT="/var/cache/ubuntu-vanilla-build"
# Prevents duplicate teardown when both a signal handler and EXIT run.
HOST_ABORT_CLEANUP_DONE=0
DATE="$(TZ="UTC" date +"%y%m%d-%H%M%S")"
# Default hooks directory; overridden by --hooks-dir=PATH.
HOOKS_DIR=""
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

# Host (outside chroot): prepare tree, debootstrap, run chroot phase, squashfs + ISO
HOST_CMD=(setup_host debootstrap run_chroot build_iso)

# Chroot phase: APT setup, packages, /image layout, cleanup
CHROOT_CMD=(chroot_prepare install_pkg build_image finish_up)

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

function default_target_package_remove() {
    case "${TARGET_INSTALLER:-calamares}" in
        calamares)
            echo "calamares casper discover laptop-detect os-prober ubiquity-slideshow-ubuntu"
            ;;
        ubiquity)
            echo "ubiquity ubiquity-frontend-gtk ubiquity-ubuntu-artwork ubiquity-slideshow-ubuntu casper discover laptop-detect os-prober"
            ;;
        *)
            >&2 echo "Internal error: default_target_package_remove with TARGET_INSTALLER='${TARGET_INSTALLER:-}'."
            exit 1
            ;;
    esac
}

function set_defaults() {
    export TARGET_UBUNTU_VERSION="${TARGET_UBUNTU_VERSION:-}"
    export TARGET_UBUNTU_MIRROR="${TARGET_UBUNTU_MIRROR:-https://apt.pop-os.org/ubuntu}"
    export TARGET_KERNEL_FLAVOR="${TARGET_KERNEL_FLAVOR:-}"
    export TARGET_KERNEL_PACKAGE="${TARGET_KERNEL_PACKAGE:-}"
    export TARGET_DESKTOP="${TARGET_DESKTOP:-}"
    export TARGET_KDE_PACKAGE="${TARGET_KDE_PACKAGE:-}"
    export TARGET_MATE_PACKAGE="${TARGET_MATE_PACKAGE:-}"
    export TARGET_BROWSER="${TARGET_BROWSER:-}"
    export TARGET_BRAVE_CHANNEL="${TARGET_BRAVE_CHANNEL:-}"
    # TARGET_LIBREWOLF, TARGET_FIREFOX, TARGET_FIREFOX_ESR, TARGET_FIREFOX_POPOS, TARGET_THUNDERBIRD, TARGET_UBUNTU_STUDIO,
    # TARGET_PACSTALL: intentionally left unset here so that resolve_browser_selection(),
    # resolve_ubuntu_studio_choice(), and resolve_pacstall_choice() can distinguish
    # "user never specified" (unset) from "user explicitly set to 0/1" via ${VAR+x}.
    # Only env/CLI paths should set these.
    # TARGET_SYSTEM76_DRIVER: left unset here so resolve_system76_driver_choice()
    # can distinguish "user never specified" (unset) from an explicit 0/1.
    # TARGET_FWUPD, TARGET_OPENSSH_SERVER, TARGET_COCKPIT: left unset so
    # resolve_optional_service_choices() can prompt (all default 0).
    export TARGET_NAME="${TARGET_NAME:-}"
    export GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL:-Try Pop!_OS without installing}"
}

# TARGET_INSTALLER / TARGET_PACKAGE_REMOVE (after CLI and interactive resolution on the host).
function set_installer_and_manifest_defaults() {
    export TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}"
    case "${TARGET_INSTALLER}" in
        calamares|ubiquity) ;;
        *)
            >&2 echo "TARGET_INSTALLER must be calamares or ubiquity (got: '${TARGET_INSTALLER}')."
            exit 1
            ;;
    esac
    export TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE:-$(default_target_package_remove)}"
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
    local version desktop
    version="$(release_version "${TARGET_UBUNTU_VERSION:-}")"
    desktop="${TARGET_DESKTOP:-gnome}"
    echo "popos-${version}-${desktop}-amd64-${DATE}"
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
        system76|generic|lowlatency) ;;
        *)
            >&2 echo "TARGET_KERNEL_FLAVOR must be system76, generic, or lowlatency (got: '${TARGET_KERNEL_FLAVOR:-}')."
            exit 1
            ;;
    esac

    # System76 kernel: shipped in the Pop!_OS repos, tracks the stable Linux
    # branch. No HWE suffix applies.
    if [[ "$TARGET_KERNEL_FLAVOR" == "system76" ]]; then
        export TARGET_KERNEL_PACKAGE="linux-system76"
        return 0
    fi

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
# Pop!_OS publishes firefox as a real native deb built from Mozilla source
# (github.com/pop-os/packaging-firefox, versions like 1:152.0.4), unlike
# Ubuntu's archive "firefox", which is a ~70 kB transitional stub that only
# installs the snap. Trust but verify before installing: the candidate must
# download from the Pop!_OS repos, must not depend on snapd, and its .deb
# must be larger than 10 MB.
function install_firefox_from_popos() {
    echo "=====> Firefox: installing the native build from the Pop!_OS repository"

    # The always-on Mozilla APT pin (origin packages.mozilla.org, 1000) would
    # otherwise make Mozilla's build the candidate. Pop's native build also
    # carries an epoch (1:...), so it must stay the candidate on later
    # upgrades too, or apt would treat a move back to Mozilla's epoch-less
    # version as the upgrade path.
    cat <<'EOF' > /etc/apt/preferences.d/firefox-popos
Package: firefox firefox-locale-*
Pin: release o=pop-os-release
Pin-Priority: 1001
EOF

    local candidate uri size depends
    candidate="$(apt-cache policy firefox | awk '/Candidate:/ {print $2; exit}')"
    if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
        >&2 echo "ERROR: the Pop!_OS repositories provide no firefox candidate for '${TARGET_UBUNTU_VERSION}'."
        >&2 echo "       Re-run with TARGET_FIREFOX=1 to use Mozilla's APT build instead."
        exit 1
    fi
    uri="$(apt-get install --reinstall --print-uris -y --allow-downgrades firefox 2>/dev/null \
        | awk -F"'" '$2 ~ /\/firefox_/ {print $2; exit}')"
    size="$(apt-cache show "firefox=${candidate}" 2>/dev/null | awk '/^Size:/ {print $2; exit}')"
    depends="$(apt-cache show "firefox=${candidate}" 2>/dev/null | awk -F': ' '/^(Pre-)?Depends:/ {print $2}')"

    if [[ "$uri" != "${POP_APT_URL}/"* && "$uri" != "${POP_APT_ORIGIN_URL}/"* ]]; then
        >&2 echo "ERROR: firefox candidate '${candidate}' does not come from the Pop!_OS repos (URI: ${uri:-unknown})."
        >&2 echo "       Refusing to install it as the Pop!_OS firefox."
        exit 1
    fi
    if [[ "$depends" == *snap* ]]; then
        >&2 echo "ERROR: firefox candidate '${candidate}' depends on snapd -- a snap-transition stub, not the real browser."
        exit 1
    fi
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size <= 10485760 )); then
        >&2 echo "ERROR: firefox candidate '${candidate}' .deb is ${size:-unknown} bytes (<= 10 MB) -- too small to be the real browser."
        exit 1
    fi
    echo "=====> Firefox ${candidate}: $(( size / 1024 / 1024 )) MB deb from ${uri%%/pool/*}, no snapd dependency -- genuine native build."
    # --allow-downgrades: harmless when firefox is absent or already Pop's,
    # and required if something earlier pinned in a higher-versioned build.
    apt-get install -y --allow-downgrades firefox
}

function install_lightdm_desktop() {
    apt-get install -y "$@" xorg lightdm slick-greeter
}

function customize_image() {
    block_snapd
    block_fwupd

    case "${TARGET_DESKTOP:-gnome}" in
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
    apt-get install -y plymouth plymouth-label plymouth-theme-ubuntu-text

    # software-properties-common provides add-apt-repository, used below for the
    # Mozilla PPA; install it explicitly rather than relying on the desktop
    # stack to pull it in transitively.
    apt-get install -y curl wget apt-transport-https ca-certificates squashfs-tools gnupg software-properties-common

    install -d /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d

    echo "=====> Browser APT sources (always): Brave release, Librewolf, Mozilla -- install packages only when selected"
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

    echo "=====> Browser vendor APT: Brave (release), Librewolf, and Mozilla sources + keyrings are always on disk"
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

    if [[ "${TARGET_FIREFOX_POPOS:-0}" == "1" ]]; then
        install_firefox_from_popos
    elif [[ "${TARGET_FIREFOX:-0}" == "1" ]]; then
        # The desktop metapackage may already have pulled in Pop!_OS's native
        # firefox (epoch 1:...), which versions higher than Mozilla's
        # epoch-less APT build; switching to the pinned Mozilla origin is
        # then a downgrade, and -y without --allow-downgrades aborts the
        # build ("Packages were downgraded and -y was used without
        # --allow-downgrades").
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

    if [[ "${TARGET_UBUNTU_STUDIO:-0}" == "1" ]]; then
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

    if [[ "${TARGET_SYSTEM76_DRIVER:-0}" == "1" ]]; then
        echo "=====> System76 hardware driver: system76-driver (from the Pop!_OS repos)"
        apt-get install -y system76-driver
        # system76-driver depends on pop-default-settings, which ships a
        # blanket "Package: *" pin at priority 1001 in
        # /etc/apt/preferences.d/pop-default-settings. That pin forces Pop's
        # release-ubuntu rebuilds as the only candidates and breaks the
        # Ubuntu desktop metapackages this builder installs (see the scoped
        # pin in setup_pop_apt_repos). Replace it with a comment; the scoped
        # pin in /etc/apt/preferences.d/pop-os-release already covers every
        # package this build takes from Pop.
        if [[ -f /etc/apt/preferences.d/pop-default-settings ]]; then
            cat <<'EOF' > /etc/apt/preferences.d/pop-default-settings
# Blanket "Package: *" pin removed by build-popos.sh: this image installs
# standard Ubuntu desktops, and a repo-wide 1001 pin on o=pop-os-release
# makes their strictly versioned dependencies unsatisfiable. The scoped
# replacement lives in /etc/apt/preferences.d/pop-os-release.
EOF
        fi
    else
        echo "=====> System76 driver: skipped (repos remain configured; apt install system76-driver on System76 hardware)"
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

    apt-get install -y flatpak
    flatpak remote-add --if-not-exists --system flathub \
        https://flathub.org/repo/flathub.flatpakrepo

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

    # These slideshow packages may not exist in the target release's repos at all
    # (not just "not installed"). Filter to only packages dpkg knows about to avoid
    # "Unable to locate package" errors that would obscure real failures.
    local _purge_slideshow=()
    local _pkg
    for _pkg in ubiquity-slideshow-ubuntu calamares-slideshow-ubuntu; do
        if dpkg -s "$_pkg" &>/dev/null; then
            _purge_slideshow+=("$_pkg")
        fi
    done
    if [[ ${#_purge_slideshow[@]} -gt 0 ]]; then
        apt-get purge -y "${_purge_slideshow[@]}"
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
    assert_bool_var TARGET_FIREFOX_POPOS
    if [[ "${TARGET_FIREFOX:-0}" == "1" && "${TARGET_FIREFOX_POPOS:-0}" == "1" ]]; then
        >&2 echo "TARGET_FIREFOX and TARGET_FIREFOX_POPOS are both 1 -- they install the same 'firefox' package from competing sources; pick one (Mozilla APT or Pop!_OS repo)."
        exit 1
    fi
    assert_bool_var TARGET_THUNDERBIRD
    assert_bool_var TARGET_UBUNTU_STUDIO
    assert_bool_var TARGET_PACSTALL 1
    assert_bool_var TARGET_SYSTEM76_DRIVER
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
}

# shellcheck disable=SC2120  # called indirectly with an error message via parse_cmd_range/cmd_find_index
function host_help() {
    if [ -z "${1+x}" ]; then
        echo "This script builds a bootable Pop!_OS ISO image (repos from https://apt.pop-os.org/, staging excluded)."
        echo
    else
        echo "$1"
        echo
    fi

    echo "Supported commands: ${HOST_CMD[*]}"
    echo
    echo "Options:"
    echo "  --release=jammy|noble|resolute          Target Pop!_OS release / Ubuntu base codename (omit to be prompted on a TTY)"
    echo "  --mirror=URL                            Ubuntu package mirror"
    echo "  UBUNTU_VANILLA_WORKSPACE=DIR             Parent directory for build workspace (optional; overrides mode defaults:"
    echo "                                           basic = /var/cache/ubuntu-vanilla-build, advanced = ~/uvb-workspace)"
    echo "  UVB_OUTPUT_DIR=DIR                       Directory for the finished ISO + checksums (optional; default: your home directory)"
    echo "  TARGET_INSTALLER=calamares|ubiquity       Live installer (optional; default calamares)"
    echo "  TARGET_DESKTOP=<desktop>                  Desktop variant slug (optional; default gnome)"
    echo "  TARGET_KDE_PACKAGE=kde-full|kde-standard|kde-plasma-desktop  KDE package when desktop is kde-plasma (optional; default kde-standard)"
    echo "  TARGET_MATE_PACKAGE=mate-desktop-environment|mate-desktop-environment-core  MATE metapackage when desktop is mate (optional; full|core aliases OK)"
    echo "  TARGET_MATE_EXTRAS=0|1            Also install mate-desktop-environment-extras when desktop is mate (optional; default 0)"
    echo "  TARGET_BRAVE_CHANNEL=none|release|origin   Pre-install Brave build (both Brave APT repos always added)"
    echo "  TARGET_BROWSER=release|origin               Legacy alias for Brave channel if TARGET_BRAVE_CHANNEL unset"
    echo "  TARGET_LIBREWOLF=0|1                    Pre-install Librewolf (optional; default 0; repo always added)"
    echo "  TARGET_FIREFOX=0|1                       Pre-install Firefox from Mozilla APT (optional; default 0; repo always added)"
    echo "  TARGET_FIREFOX_ESR=0|1                   Pre-install Firefox ESR from Mozilla PPA (optional; default 0; PPA always added)"
    echo "  TARGET_FIREFOX_POPOS=0|1                 Pre-install Firefox as Pop!_OS's native deb (optional; default 0; verified real browser, not a snap stub)"
    echo "  TARGET_THUNDERBIRD=0|1                   Pre-install Thunderbird from Mozilla PPA (optional; default 0; PPA always added)"
    echo "  TARGET_UBUNTU_STUDIO=0|1                 Ubuntu Studio metapackages (optional; default 0)"
    echo "  TARGET_FWUPD=0|1                         Pre-install fwupd (optional; default 0; fwupd is blocked during the build either way)"
    echo "  TARGET_OPENSSH_SERVER=0|1                Pre-install openssh-server (optional; default 0)"
    echo "  TARGET_COCKPIT=0|1                       Pre-install Cockpit from the backports pocket (optional; default 0)"
    echo "  TARGET_SYSTEM76_DRIVER=0|1               Pre-install system76-driver for System76 hardware (optional; default 0)"
    echo "  TARGET_GNOME_INSTALL_RECOMMENDS=0|1       GNOME install with recommends (optional; default 0)"
    echo "  --kernel=system76|generic|lowlatency    Kernel: System76 (stable branch, Pop!_OS repos) or Ubuntu HWE"
    echo "  --installer=calamares|ubiquity           Calamares (default), or Ubiquity (jammy/22.04 only)"
    echo "  --desktop=<desktop>                      Desktop variant (gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, kde-plasma)"
    echo "  --kde=kde-full|kde-standard|kde-plasma-desktop  KDE package tier (used with --desktop=kde-plasma)"
    echo "  --mate=full|core|mate-desktop-environment|mate-desktop-environment-core  MATE tier (used with --desktop=mate; default full)"
    echo "  --mate-extras / --no-mate-extras        Pre-install mate-desktop-environment-extras (with --desktop=mate)"
    echo "  --brave=none|release|origin       Brave channel (default release; none skips Brave)"
    echo "  --browser=release|origin            Same as --brave for the two Brave archives (legacy)"
    echo "  --librewolf / --no-librewolf             Pre-install Librewolf (APT repo always configured)"
    echo "  --firefox / --no-firefox               Pre-install Firefox (Mozilla APT always configured)"
    echo "  --firefox-esr / --no-firefox-esr       Pre-install Firefox ESR (Mozilla PPA always configured)"
    echo "  --firefox-popos / --no-firefox-popos   Pre-install Firefox from the Pop!_OS repository (native deb, not a snap stub)"
    echo "  --thunderbird / --no-thunderbird       Pre-install Thunderbird (Mozilla PPA always configured)"
    echo "  --ubuntu-studio / --no-ubuntu-studio     Ubuntu Studio metapackage set (heavy)"
    echo "  --pacstall / --no-pacstall               Install Pacstall package manager (default: yes)"
    echo "  --system76-driver / --no-system76-driver  Pre-install system76-driver for System76 hardware (default: no)"
    echo "  --fwupd / --no-fwupd                     Pre-install fwupd (default: no; blocked during the build either way)"
    echo "  --openssh-server / --no-openssh-server   Pre-install openssh-server (default: no)"
    echo "  --cockpit / --no-cockpit                 Pre-install Cockpit from backports (default: no)"
    echo "  --locale=LOCALE                          System locale (e.g. en_US.UTF-8) for unattended builds"
    echo "  --keyboard-layout=LAYOUT                 Keyboard layout code (e.g. us, de, fr) for unattended builds"
    echo "  --keyboard-variant=VARIANT               Keyboard variant (e.g. intl, nodeadkeys; optional)"
    echo
    echo "Advanced mode (--advanced; also offered by the startup mode prompt):"
    echo "  --advanced                               Enable advanced mode (config file, workspace preservation, package cache)"
    echo "  --interactive                            Force interactive prompts even if stdin is not a TTY (advanced only)"
    echo "  --no-interactive                         Disable all interactive prompts, use defaults or fail (advanced only)"
    echo "  --config=FILE                            Load build options from a .cfg file (KEY=VALUE format; advanced mode only)"
    echo "  --generate-config                        Launch config wizard to generate a build-popos.cfg file"
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
    echo "  setup_host       Install host build tools (debootstrap, squashfs-tools,"
    echo "                   xorriso) and prepare a fresh workspace directory."
    echo "  debootstrap      Bootstrap the minimal base (--variant=minbase) from the"
    echo "                   Ubuntu mirror into <workspace>/chroot. Advanced mode reuses"
    echo "                   an existing chroot instead of re-bootstrapping."
    echo "  run_chroot       Bind-mount /dev /run /proc /sys, copy this script + the"
    echo "                   Calamares config into the chroot, and run the chroot phase"
    echo "                   inside it (sub-stages below)."
    echo "  build_iso        Compress the chroot into casper/filesystem.squashfs and build"
    echo "                   the hybrid BIOS+UEFI ISO with xorriso; write SHA-1/SHA-256"
    echo "                   checksums and clean the workspace."
    echo
    echo "Chroot phase sub-stages (CHROOT_CMD -- run automatically inside run_chroot):"
    echo "  chroot_prepare   Ubuntu APT sources + the Pop!_OS repos (release, proprietary,"
    echo "                   release-ubuntu; staging excluded) with the Pop!_OS keyring and"
    echo "                   scoped pin; switch to Pop!_OS base-files; snapd/fwupd pins."
    echo "  install_pkg      Upgrade the base; install the kernel (System76 or Ubuntu HWE),"
    echo "                   GRUB, the live installer (Calamares or Ubiquity), the chosen"
    echo "                   desktop, browsers, optional System76 driver, locale/keyboard."
    echo "  build_image      Assemble the live /image tree: kernel + initrd, GRUB configs,"
    echo "                   signed EFI binaries, Memtest86+, package manifests, md5sums."
    echo "  finish_up        Cleanup: remove SSH host keys, truncate machine-id, drop the"
    echo "                   build-time fwupd pin, clear /tmp."
    echo
    echo "Configuration precedence (highest wins):"
    echo "  CLI flags  >  config file (--config, advanced mode)  >  environment variables"
    echo "  >  interactive prompts (on a TTY)  >  the built-in defaults shown above."
    echo
    echo "Hooks (modloader): executable *.sh files in scripts/hooks/pre-chroot/ run on the"
    echo "  host before entering the chroot; scripts/hooks/chroot/ run inside the chroot."
    echo "  Both run in sorted-filename order. Override the directory with --hooks-dir=PATH."
    echo
    echo "Output:  <output-dir>/<name>.iso  plus  <name>.iso.sha1  and  <name>.iso.sha256"
    echo "  Default <name>: popos-<version>-<desktop>-amd64-<UTC-timestamp>."
    echo "  Default output dir: your home directory (UVB_OUTPUT_DIR overrides)."
    echo "  Workspace: <parent>/workspace-popos (basic parent /var/cache/ubuntu-vanilla-build,"
    echo "  advanced ~/uvb-workspace); separate from Ubuntu builds so they never collide."
    echo
    echo "Examples:"
    echo "  $0                                     Guided interactive build (all stages)"
    echo "  $0 --release=noble --kernel=system76 --desktop=gnome -"
    echo "  $0 --release=noble --kernel=generic --system76-driver --firefox-popos -"
    echo "  $0 --advanced --config=build-popos.cfg --no-interactive -   Unattended config"
    echo "  $0 --advanced run_chroot               Re-run only the chroot phase (advanced)"
    echo "  $0 debootstrap - build_iso             Run debootstrap through the ISO build"
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
    echo "$_cache/popos-vanilla-build/apt-cache"
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
    local -a _host_deps=(debootstrap squashfs-tools xorriso)
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

    host_priv cp "$SCRIPT_DIR/build-popos.sh" "$WORKSPACE_CHROOT/root/build.sh"
    host_priv rm -rf "$WORKSPACE_CHROOT/root/calamares-config"
    if [[ -d "$SCRIPT_DIR/calamares-popos" ]]; then
        host_priv cp -a "$SCRIPT_DIR/calamares-popos" "$WORKSPACE_CHROOT/root/calamares-config"
    fi

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
        TARGET_FIREFOX_POPOS="${TARGET_FIREFOX_POPOS:-0}" \
        TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}" \
        TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}" \
        TARGET_PACSTALL="${TARGET_PACSTALL:-1}" \
        TARGET_SYSTEM76_DRIVER="${TARGET_SYSTEM76_DRIVER:-0}" \
        TARGET_FWUPD="${TARGET_FWUPD:-0}" \
        TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}" \
        TARGET_COCKPIT="${TARGET_COCKPIT:-0}" \
        TARGET_LOCALE="${TARGET_LOCALE:-}" \
        TARGET_KEYBOARD_LAYOUT="${TARGET_KEYBOARD_LAYOUT:-}" \
        TARGET_KEYBOARD_VARIANT="${TARGET_KEYBOARD_VARIANT:-}" \
        TARGET_GNOME_INSTALL_RECOMMENDS="${TARGET_GNOME_INSTALL_RECOMMENDS:-0}" \
        TARGET_NAME="${TARGET_NAME}" \
        GRUB_LIVEBOOT_LABEL="${GRUB_LIVEBOOT_LABEL}" \
        TARGET_INSTALLER="${TARGET_INSTALLER:-calamares}" \
        TARGET_PACKAGE_REMOVE="${TARGET_PACKAGE_REMOVE}" \
        /root/build.sh --chroot-internal -

    host_priv rm -f "$WORKSPACE_CHROOT/root/build.sh"
    host_priv rm -rf "$WORKSPACE_CHROOT/root/calamares-config"
    host_priv rm -rf "$WORKSPACE_CHROOT/root/hooks"

    unmount_package_cache
    chroot_exit_teardown
}

function write_iso_hashes() {
    echo "=====> writing SHA-1 and SHA-256 ..."
    (
        cd "$OUTPUT_DIR"
        # tee via host_priv: the output directory may be root-owned.
        sha1sum "$TARGET_NAME.iso" | host_priv tee "$TARGET_NAME.iso.sha1" >/dev/null
        sha256sum "$TARGET_NAME.iso" | host_priv tee "$TARGET_NAME.iso.sha256" >/dev/null
    )
}

# The ISO and checksums are produced by privileged commands, so they come out
# root-owned. Hand them back to the human who launched the build.
function fix_output_ownership() {
    local owner=""
    if [[ "$(id -u)" -eq 0 ]]; then
        [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && owner="$SUDO_USER"
    else
        owner="$(id -un)"
    fi
    [[ -z "$owner" ]] && return 0
    local f
    for f in "$OUTPUT_DIR/$TARGET_NAME.iso" \
             "$OUTPUT_DIR/$TARGET_NAME.iso.sha1" \
             "$OUTPUT_DIR/$TARGET_NAME.iso.sha256"; do
        [[ -e "$f" ]] && host_priv chown "$owner" "$f" 2>/dev/null || true
    done
}

function ensure_output_dir() {
    if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
        host_priv mkdir -p "$OUTPUT_DIR"
    fi
}

function build_iso() {
    echo "=====> running build_iso ..."

    ensure_workspace_root
    host_priv rm -rf "$WORKSPACE_IMAGE"
    host_priv mv "$WORKSPACE_CHROOT/image" "$WORKSPACE_IMAGE"

    host_priv mksquashfs "$WORKSPACE_CHROOT" "$WORKSPACE_IMAGE/casper/filesystem.squashfs" \
        -noappend -no-duplicates -no-recovery \
        -wildcards \
        -comp xz -b 1M -Xdict-size 100% \
        -e "var/cache/apt/archives/*" \
        -e "root/*" \
        -e "root/.*" \
        -e "tmp/*" \
        -e "tmp/.*" \
        -e "swapfile" \
        -e "image"

    # Mirror the mksquashfs excludes above so the size casper reports matches
    # what actually ships in the squashfs (instead of overcounting /root, /tmp,
    # and the APT package cache).
    printf "%s" "$(host_priv du -sx --block-size=1 \
        --exclude="$WORKSPACE_CHROOT/root" \
        --exclude="$WORKSPACE_CHROOT/tmp" \
        --exclude="$WORKSPACE_CHROOT/var/cache/apt/archives" \
        --exclude="$WORKSPACE_CHROOT/swapfile" \
        "$WORKSPACE_CHROOT" | cut -f1)" | host_priv tee "$WORKSPACE_IMAGE/casper/filesystem.size" >/dev/null

    local boot_hybrid_img="$WORKSPACE_CHROOT/usr/lib/grub/i386-pc/boot_hybrid.img"
    if [[ ! -f "$boot_hybrid_img" ]]; then
        >&2 echo "Missing $boot_hybrid_img (grub-pc-bin not installed in chroot?). Cannot build hybrid BIOS/UEFI ISO."
        exit 1
    fi
    if [[ ! -f "$WORKSPACE_IMAGE/boot/grub/bios.img" ]]; then
        >&2 echo "Missing $WORKSPACE_IMAGE/boot/grub/bios.img (build_image step did not produce it). Aborting."
        exit 1
    fi
    if [[ ! -f "$WORKSPACE_IMAGE/boot/grub/efiboot.img" ]]; then
        >&2 echo "Missing $WORKSPACE_IMAGE/boot/grub/efiboot.img (build_image step did not produce it). Aborting."
        exit 1
    fi

    # ISO 9660 volume id: A-Z 0-9 _ only, max 32 chars. Normalize so xorriso doesn't warn.
    local iso_volid
    iso_volid="$(printf '%s' "$TARGET_NAME" \
        | tr '[:lower:]' '[:upper:]' \
        | tr -c 'A-Z0-9_' '_' \
        | cut -c1-32)"

    ensure_output_dir

    pushd "$WORKSPACE_IMAGE" >/dev/null

    # Hybrid BIOS + UEFI El Torito layout (matches what Ubuntu/Debian ship today):
    #   * Legacy/BIOS boot:  -b boot/grub/bios.img   (must exist inside the ISO tree)
    #     - bios.img is "cdboot.img + core.img" produced by build_image()
    #     - --grub2-boot-info patches GRUB's offsets so it finds its core inside the ISO
    #     - --grub2-mbr embeds boot_hybrid.img as the protective MBR (BIOS hybrid boot)
    #   * UEFI boot:         efiboot.img is appended as GPT partition 2 (EFI System
    #     Partition GUID, mixed-endian = 28732ac11ff8d211ba4b00a0c93ec93b), and the
    #     UEFI alt-boot entry points at that appended partition via the
    #     `--interval:appended_partition_2:all::` pseudo-path. UEFI firmware mounts the
    #     ESP partition directly, so the file does NOT also need to live in the ISO9660
    #     tree (we keep it there too for tooling that still looks for /boot/grub/efiboot.img).
    # EFI System Partition GUID (C12A7328-F81F-11D2-BA4B-00A0C93EC93B) in the
    # on-disk mixed-endian byte order that xorriso's -append_partition expects.
    local esp_type_guid="28732ac11ff8d211ba4b00a0c93ec93b"
    # Microsoft Basic Data Partition GUID (EBD0A0A2-B9E5-4433-87C0-68B6B72699C7)
    # in mixed-endian, used as the ISO MBR partition type so the ISO9660 area is
    # visible as a normal data partition when the stick is inspected.
    local iso_mbr_type_guid="a2a0d0ebe5b9334487c068b6b72699c7"

    host_priv xorriso \
        -as mkisofs \
        -r -V "$iso_volid" \
        -J -joliet-long \
        -l \
        -iso-level 3 \
        -full-iso9660-filenames \
        -o "$OUTPUT_DIR/$TARGET_NAME.iso" \
        \
        --grub2-mbr "$boot_hybrid_img" \
        -partition_offset 16 \
        --mbr-force-bootable \
        -append_partition 2 "$esp_type_guid" boot/grub/efiboot.img \
        -appended_part_as_gpt \
        -iso_mbr_part_type "$iso_mbr_type_guid" \
        \
        -c boot.catalog \
        -b boot/grub/bios.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --grub2-boot-info \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:all::' \
            -no-emul-boot \
        \
        .

    popd >/dev/null

    write_iso_hashes
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
    echo "                 (workspace in a system directory, ISO saved to your home)"
    echo "    2) Advanced  Adds config file loading (build-popos.cfg / --config),"
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

    ui_heading "Pop!_OS release (Ubuntu base codename)"
    cat <<'EOF'
    1) jammy     Pop!_OS 22.04 LTS
    2) noble     Pop!_OS 24.04 LTS
    3) resolute  Pop!_OS 26.04 LTS
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
        ui_err "No terminal is available. Use --kernel=system76|generic|lowlatency."
        exit 1
    fi

    local hv=""
    hv="$(release_version "${TARGET_UBUNTU_VERSION:-}")"

    ui_heading "Kernel flavor"
    echo "    1) system76    System76 kernel from the Pop!_OS repos (linux-system76,"
    echo "                   tracks the stable Linux branch)  [default]"
    printf '    2) generic     Ubuntu HWE kernel%s\n' \
        "${hv:+  (linux-generic-hwe-${hv})}"
    printf '    3) lowlatency  Ubuntu HWE low-latency kernel, better for audio workloads%s\n' \
        "${hv:+  (linux-lowlatency-hwe-${hv})}"

    local choice
    while true; do
        read -r -p "  Kernel [1/2/3, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|s|system76) export TARGET_KERNEL_FLAVOR="system76";   break ;;
            2|g|generic)     export TARGET_KERNEL_FLAVOR="generic";    break ;;
            3|l|lowlatency)  export TARGET_KERNEL_FLAVOR="lowlatency"; break ;;
            *)   ui_warn "Invalid selection: '$choice'. Please choose 1, 2, or 3." ;;
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

    >&2 echo "TARGET_KERNEL_FLAVOR is not set. Use --kernel=system76|generic|lowlatency for non-interactive runs."
    exit 1
}

function interactive_desktop_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --desktop=<desktop> (e.g. gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, or kde-plasma)."
        exit 1
    fi

    ui_heading "Desktop environment"
    echo "    (Ordered A-Z by desktop name. Pop's own desktops -- pop-desktop and COSMIC --"
    echo "     are intentionally NOT offered here; see the COSMIC note at the end of the build.)"
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
        ui_err "No terminal is available. Set TARGET_FIREFOX=0|1, TARGET_FIREFOX_ESR=0|1 and TARGET_FIREFOX_POPOS=0|1."
        exit 1
    fi

    ui_heading "Firefox Browser"
    echo "    1) Firefox Release (Mozilla APT)"
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
    echo "    3) Firefox from the Pop!_OS repository"
    echo "       The native deb System76 builds from Mozilla source (pop-os/packaging-firefox)"
    echo "       Same firefox package stock Pop!_OS ships -- a real browser, NOT Ubuntu's"
    echo "       snap-transition stub; verified at install time (deb > 10 MB, no snapd dependency)"
    echo "       Updates arrive through the Pop!_OS release repository together with the system"
    echo "       Ideal if you want the browser exactly as Pop!_OS ships it"
    echo ""
    echo "    4) Skip Firefox [default]"
    echo "       Do not install Firefox browser"
    echo "       Choose this if you prefer another browser or don't need Firefox"
    echo ""

    local choice
    while true; do
        read -r -p "  Firefox [1/2/3/4, Enter=4]: " choice
        case "${choice,,}" in
            1|r|release)
                export TARGET_FIREFOX="1"
                export TARGET_FIREFOX_ESR="0"
                export TARGET_FIREFOX_POPOS="0"
                break
                ;;
            2|e|esr)
                export TARGET_FIREFOX="0"
                export TARGET_FIREFOX_ESR="1"
                export TARGET_FIREFOX_POPOS="0"
                break
                ;;
            3|p|pop|popos|pop-os)
                export TARGET_FIREFOX="0"
                export TARGET_FIREFOX_ESR="0"
                export TARGET_FIREFOX_POPOS="1"
                break
                ;;
            ""|4|n|none|skip)
                export TARGET_FIREFOX="0"
                export TARGET_FIREFOX_ESR="0"
                export TARGET_FIREFOX_POPOS="0"
                break
                ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_FIREFOX=$TARGET_FIREFOX  TARGET_FIREFOX_ESR=$TARGET_FIREFOX_ESR  TARGET_FIREFOX_POPOS=$TARGET_FIREFOX_POPOS"
}

function interactive_thunderbird_pick() {
    interactive_toggle_pick TARGET_THUNDERBIRD \
        "Thunderbird (Mozilla PPA)" \
        "Pre-install thunderbird (Mozilla PPA + pin are configured either way)" \
        "Skip Thunderbird" \
        "Thunderbird"
}

function resolve_browser_selection() {
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

    if [[ -z "${TARGET_FIREFOX+x}" && -z "${TARGET_FIREFOX_ESR+x}" && -z "${TARGET_FIREFOX_POPOS+x}" ]]; then
        if prompts_enabled; then
            interactive_firefox_pick
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
    export TARGET_FIREFOX_POPOS="${TARGET_FIREFOX_POPOS:-0}"
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

# System76 hardware driver (system76-driver from the Pop!_OS repos): fan/
# keyboard/suspend support and system76-power. Only useful on System76
# machines; default is to skip.
function resolve_system76_driver_choice() {
    if [[ -n "${TARGET_SYSTEM76_DRIVER+x}" ]]; then
        export TARGET_SYSTEM76_DRIVER="${TARGET_SYSTEM76_DRIVER:-0}"
        return 0
    fi

    if prompts_enabled; then
        interactive_toggle_pick TARGET_SYSTEM76_DRIVER \
            "System76 hardware driver" \
            "Pre-install system76-driver (recommended only for System76 hardware)" \
            "Skip the System76 driver" \
            "System76 driver"
    else
        export TARGET_SYSTEM76_DRIVER=0
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

function interactive_installer_pick() {
    if ! prompts_enabled; then
        ui_err "No terminal is available. Use --installer=calamares|ubiquity."
        exit 1
    fi

    ui_heading "Live installer"
    echo "    1) Calamares  Default. Project config in scripts/calamares-popos (all releases)"
    echo "    2) Ubiquity   Classic Ubuntu installer (supported only on jammy / 22.04 LTS)"

    local choice
    while true; do
        read -r -p "  Installer [1/2, Enter=1]: " choice
        case "${choice,,}" in
            ""|1|c|calamares) export TARGET_INSTALLER="calamares"; break ;;
            2|u|ubiquity)
                if [[ "${TARGET_UBUNTU_VERSION:-}" != "jammy" ]]; then
                    ui_warn "Ubiquity is supported only on Ubuntu 22.04 LTS (jammy)."
                    ui_warn "Current release: '${TARGET_UBUNTU_VERSION:-unknown}'. Choose 1 (Calamares),"
                    ui_warn "or restart with --release=jammy if you need Ubiquity."
                    continue
                fi
                export TARGET_INSTALLER="ubiquity"; break ;;
            *) ui_warn "Invalid selection: '$choice'." ;;
        esac
    done
    ui_ok "TARGET_INSTALLER=$TARGET_INSTALLER"
}

# Ubiquity is only validated for jammy; Calamares is used for noble and resolute.
function validate_ubiquity_jammy_only() {
    if [[ "${TARGET_INSTALLER:-}" != "ubiquity" ]]; then
        return 0
    fi
    if [[ "${TARGET_UBUNTU_VERSION:-}" == "jammy" ]]; then
        return 0
    fi
    echo >&2 "ERROR: Ubiquity is supported only on Ubuntu 22.04 LTS (jammy)."
    echo >&2 "       This build targets '${TARGET_UBUNTU_VERSION:-unknown}'. Use Calamares instead (e.g. --installer=calamares)."
    exit 1
}

function resolve_installer_choice() {
    if [[ -n "${TARGET_INSTALLER:-}" ]]; then
        return 0
    fi

    if prompts_enabled; then
        interactive_installer_pick
        return 0
    fi

    export TARGET_INSTALLER=calamares
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
#     same idea as the old WSL relocation -- and the finished ISO lands in
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

    WORKSPACE_DIR="${ws_parent%/}/workspace-popos"
    WORKSPACE_CHROOT="$WORKSPACE_DIR/chroot"
    WORKSPACE_IMAGE="$WORKSPACE_DIR/image"

    # -- Output directory (final ISO + checksums) --------------------
    if [[ -n "${UVB_OUTPUT_DIR:-}" ]]; then
        OUTPUT_DIR="${UVB_OUTPUT_DIR%/}"
        echo "=====> Output directory (UVB_OUTPUT_DIR): $OUTPUT_DIR" >&2
    elif [[ "$interactive_advanced" -eq 1 ]]; then
        local _out
        read -r -p "  Output directory for the ISO [${user_home}]: " _out
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
    ui_kv "Pop!_OS release" "${TARGET_UBUNTU_VERSION:-?}${hv:+  (Pop!_OS ${hv} LTS)}"
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
    ui_kv "Installer"       "${TARGET_INSTALLER:-?}"
    local _bs=""
    case "${TARGET_BRAVE_CHANNEL:-release}" in
        none)              _bs="Brave: none" ;;
        release)           _bs="Brave: stable" ;;
        origin)            _bs="Brave: origin" ;;
    esac
    [[ "${TARGET_LIBREWOLF:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Librewolf"
    [[ "${TARGET_FIREFOX:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox"
    [[ "${TARGET_FIREFOX_ESR:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox ESR"
    [[ "${TARGET_FIREFOX_POPOS:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Firefox (Pop!_OS repo)"
    [[ "${TARGET_THUNDERBIRD:-0}" == "1" ]] && _bs="${_bs:+${_bs}; }Thunderbird"
    ui_kv "Browsers"       "${_bs}"
    ui_kv "Ubuntu Studio"  "${TARGET_UBUNTU_STUDIO:-0}"
    ui_kv "Pacstall"        "${TARGET_PACSTALL:-1}"
    ui_kv "System76 driver" "${TARGET_SYSTEM76_DRIVER:-0}"
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
    ui_kv "Output ISO"      "${OUTPUT_DIR:-?}/${TARGET_NAME:-popos}.iso"
    echo
}

function print_build_result() {
    local iso_path="${OUTPUT_DIR:-?}/${TARGET_NAME:-popos}.iso"
    if [[ ! -f "$iso_path" ]]; then
        ui_heading "Build finished"
        ui_info "No ISO produced at $iso_path (this is expected for partial runs)."
        return 0
    fi
    local size=""
    size="$(du -h --apparent-size "$iso_path" 2>/dev/null | awk '{print $1}')"

    ui_heading "Build complete"
    ui_kv "ISO"    "$iso_path"
    ui_kv "Size"   "${size:-unknown}"
    if [[ -f "$iso_path.sha1" ]]; then
        ui_kv "SHA1"   "$(awk '{print $1}' "$iso_path.sha1")"
    fi
    if [[ -f "$iso_path.sha256" ]]; then
        ui_kv "SHA256" "$(awk '{print $1}' "$iso_path.sha256")"
    fi
    echo
    echo "  Next steps:"
    echo "    The ISO is ready to use. Write it to a USB stick with your favorite"
    echo "    USB burner, or simply copy the file onto a USB drive that has Ventoy"
    echo "    installed. It also works as-is for PXE network boot, and for virtual"
    echo "    machines: just create a VM on whatever platform you prefer and boot"
    echo "    it from this ISO."
    echo
    case "${TARGET_UBUNTU_VERSION:-}" in
        noble|resolute)
            ui_heading "COSMIC desktop (optional, after installation)"
            echo "  COSMIC is not offered by this builder because it is still too buggy when"
            echo "  installed through Calamares. On the installed system (noble/resolute),"
            echo "  the Pop!_OS repositories are already configured, so you can add it with:"
            echo
            echo "      sudo apt update"
            echo "      sudo apt install cosmic-session"
            echo
            echo "  Then log out and pick the COSMIC session on the login screen"
            echo "  (gear/session menu), or install pop-desktop for the full Pop!_OS stack."
            echo
            ;;
    esac
}

# generate_config_wizard -- interactive wizard that generates a build-popos.cfg file.
# Walks the user through each setting and writes the result.
function generate_config_wizard() {
    if ! prompts_enabled; then
        ui_err "Config wizard requires an interactive terminal."
        exit 1
    fi

    local out_path="$SCRIPT_DIR/build-popos.cfg"

    ui_banner "Build Configuration Wizard"
    echo "  This wizard will generate a build-popos.cfg file with your settings."
    echo "  Press Enter to accept the [default] value shown in brackets."
    echo

    if [[ -f "$out_path" ]]; then
        if ! ui_confirm "  $out_path already exists. Overwrite?" n; then
            ui_info "Wizard cancelled."
            exit 0
        fi
    fi

    local _release _kernel _desktop _installer _mirror
    local _brave _librewolf _firefox _firefox_esr _thunderbird
    local _pacstall _ubuntu_studio _system76_driver _fwupd _openssh _cockpit
    local _locale _keyboard_layout _keyboard_variant
    local _advanced _name _workspace _output

    # Release
    echo "  Supported releases (Pop!_OS LTS): jammy (22.04), noble (24.04), resolute (26.04)"
    read -r -p "  Release [noble]: " _release
    _release="${_release:-noble}"

    # Kernel
    read -r -p "  Kernel flavor (system76 / generic / lowlatency) [system76]: " _kernel
    _kernel="${_kernel:-system76}"

    # Desktop
    echo "  Desktops: gnome, xfce, lxde, lxqt, mate, cinnamon, budgie, kde-plasma"
    read -r -p "  Desktop [gnome]: " _desktop
    _desktop="${_desktop:-gnome}"

    # Installer
    read -r -p "  Installer (calamares / ubiquity) [calamares]: " _installer
    _installer="${_installer:-calamares}"

    # Mirror
    read -r -p "  Mirror [https://apt.pop-os.org/ubuntu]: " _mirror
    _mirror="${_mirror:-https://apt.pop-os.org/ubuntu}"

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

    # Firefox from the Pop!_OS repository (native deb)
    read -r -p "  Pre-install Firefox from the Pop!_OS repo (native deb, not a snap stub)? (0/1) [0]: " _firefox_popos
    _firefox_popos="${_firefox_popos:-0}"

    # Thunderbird
    read -r -p "  Pre-install Thunderbird? (0/1) [0]: " _thunderbird
    _thunderbird="${_thunderbird:-0}"

    # Pacstall
    read -r -p "  Install Pacstall? (0/1) [1]: " _pacstall
    _pacstall="${_pacstall:-1}"

    # Ubuntu Studio
    read -r -p "  Install Ubuntu Studio packages? (0/1) [0]: " _ubuntu_studio
    _ubuntu_studio="${_ubuntu_studio:-0}"

    # System76 driver
    read -r -p "  Pre-install system76-driver (System76 hardware)? (0/1) [0]: " _system76_driver
    _system76_driver="${_system76_driver:-0}"

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
        read -r -p "  Output directory for the ISO (blank for your home directory): " _output
    fi

    # Custom name
    read -r -p "  Custom ISO name (blank for auto): " _name

    # Write the config file
    cat > "$out_path" <<WIZARD_EOF
# Pop!_OS Vanilla ISO Builder -- generated by config wizard
# $(date '+%Y-%m-%d %H:%M:%S %Z')

# --- Core ---
TARGET_UBUNTU_VERSION=${_release}
TARGET_KERNEL_FLAVOR=${_kernel}
TARGET_DESKTOP=${_desktop}
TARGET_INSTALLER=${_installer}
TARGET_UBUNTU_MIRROR=${_mirror}

# --- Browsers ---
TARGET_BRAVE_CHANNEL=${_brave}
TARGET_LIBREWOLF=${_librewolf}
TARGET_FIREFOX=${_firefox}
TARGET_FIREFOX_ESR=${_firefox_esr}
TARGET_FIREFOX_POPOS=${_firefox_popos}
TARGET_THUNDERBIRD=${_thunderbird}

# --- Package Managers ---
TARGET_PACSTALL=${_pacstall}

# --- Extras ---
TARGET_UBUNTU_STUDIO=${_ubuntu_studio}
TARGET_SYSTEM76_DRIVER=${_system76_driver}

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
    ui_info "Run './build.sh -' to start a build with these settings."
    exit 0
}

# load_config_file FILE -- source a config file (key=value lines, # comments, blank lines).
# Only recognized TARGET_* and GRUB_LIVEBOOT_LABEL variables are exported.
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
                TARGET_FIREFOX_ESR|TARGET_FIREFOX_POPOS|TARGET_THUNDERBIRD|TARGET_UBUNTU_STUDIO|\
                TARGET_PACSTALL|TARGET_SYSTEM76_DRIVER|TARGET_FWUPD|\
                TARGET_OPENSSH_SERVER|TARGET_COCKPIT|\
                TARGET_GNOME_INSTALL_RECOMMENDS|TARGET_NAME|\
                TARGET_LOCALE|TARGET_KEYBOARD_LAYOUT|TARGET_KEYBOARD_VARIANT|\
                TARGET_INSTALLER|TARGET_PACKAGE_REMOVE|\
                GRUB_LIVEBOOT_LABEL|UBUNTU_VANILLA_WORKSPACE|UVB_OUTPUT_DIR|NO_CONFIRM|\
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
    local cli_installer=""
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
    local cli_firefox_popos_set=0
    local cli_firefox_popos=0
    local cli_thunderbird_set=0
    local cli_thunderbird=0
    local cli_ubuntustudio_set=0
    local cli_ubuntustudio=0
    local cli_pacstall_set=0
    local cli_pacstall=0
    local cli_system76_driver_set=0
    local cli_system76_driver=0
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
            --kernel=system76|--kernel=generic|--kernel=lowlatency)
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
            --installer=calamares|--installer=ubiquity)
                cli_installer="${1#--installer=}"
                shift
                ;;
            --installer)
                cli_installer="$2"
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
            --firefox-popos)
                cli_firefox_popos_set=1
                cli_firefox_popos=1
                shift
                ;;
            --no-firefox-popos)
                cli_firefox_popos_set=1
                cli_firefox_popos=0
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
            --system76-driver)
                cli_system76_driver_set=1
                cli_system76_driver=1
                shift
                ;;
            --no-system76-driver)
                cli_system76_driver_set=1
                cli_system76_driver=0
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
        elif [[ -f "$SCRIPT_DIR/build-popos.cfg" ]]; then
            load_config_file "$SCRIPT_DIR/build-popos.cfg"
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

    ui_banner "Pop!_OS Vanilla ISO Builder"
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
    if [[ -n "$cli_installer" ]]; then
        export TARGET_INSTALLER="$cli_installer"
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
    if [[ "$cli_firefox_popos_set" -eq 1 ]]; then
        export TARGET_FIREFOX_POPOS="$cli_firefox_popos"
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
    if [[ "$cli_system76_driver_set" -eq 1 ]]; then
        export TARGET_SYSTEM76_DRIVER="$cli_system76_driver"
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

    if [[ -z "${TARGET_INSTALLER:-}" ]]; then
        resolve_installer_choice
    fi
    set_installer_and_manifest_defaults

    validate_ubiquity_jammy_only

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
    resolve_system76_driver_choice
    resolve_optional_service_choices

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
        echo "Chroot phase: build the root filesystem and the live image layout under /image."
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

# Configure the Pop!_OS repositories inside the chroot: the release,
# proprietary, and release-ubuntu suites, from the apt.pop-os.org CDN with
# apt-origin.pop-os.org as per-suite fallback (staging suites are
# intentionally excluded). The archive signing key is
# fetched from the Ubuntu keyserver; once the repos are reachable, the
# pop-keyring package takes over key maintenance. All three LTS targets are
# published, including resolute (26.04 LTS, released early July 2026); a
# suite that is temporarily unreachable is skipped with a warning, but the
# build aborts if none of the Pop!_OS suites can be added.
function setup_pop_apt_repos() {
    echo "=====> configuring Pop!_OS APT repositories from ${POP_APT_URL} (staging excluded) ..."

    apt-get install -y gnupg dirmngr ca-certificates curl

    install -d /usr/share/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d

    local keyring=/usr/share/keyrings/pop-os-archive-keyring.gpg
    local tmp_gpg_home
    tmp_gpg_home="$(mktemp -d)"
    gpg --homedir "$tmp_gpg_home" --batch --keyserver hkps://keyserver.ubuntu.com \
        --recv-keys "$POP_KEY_FINGERPRINT"
    gpg --homedir "$tmp_gpg_home" --batch --export "$POP_KEY_FINGERPRINT" > "$keyring"
    rm -rf "$tmp_gpg_home"

    # Suite names; staging suites are deliberately absent from this list.
    # Each suite is taken from the CDN (POP_APT_URL) when it publishes the
    # target release, falling back to the origin server only when it does
    # not -- bulk fetches straight from apt-origin get their TLS connections
    # dropped mid-transfer ("unexpected eof while reading").
    #
    # The sources are written in deb822 format under the filenames stock
    # Pop!_OS uses (pop-os-release.sources, pop-os-apps.sources): the
    # pop-default-settings postinst (pulled in by system76-driver) runs
    # grep/sed directly against /etc/apt/sources.list.d/pop-os-release.sources
    # and aborts the whole dpkg run with exit status 2 when that file does
    # not exist. It only checks that a Signed-By line is present, so pointing
    # Signed-By at our keyring is fine.
    local name base url srcfile added_any=0
    # Old one-line names written by earlier versions of this script; remove
    # them so advanced-mode re-runs don't end up with duplicate sources.
    rm -f /etc/apt/sources.list.d/pop-os-{release,proprietary,release-ubuntu}.list
    for name in release proprietary release-ubuntu; do
        case "$name" in
            release)        srcfile=/etc/apt/sources.list.d/pop-os-release.sources ;;
            proprietary)    srcfile=/etc/apt/sources.list.d/pop-os-apps.sources ;;
            release-ubuntu) srcfile=/etc/apt/sources.list.d/pop-os-release-ubuntu.sources ;;
        esac
        url=""
        for base in "$POP_APT_URL" "$POP_APT_ORIGIN_URL"; do
            if curl -fsIL "${base}/${name}/dists/${TARGET_UBUNTU_VERSION}/Release" >/dev/null 2>&1; then
                url="${base}/${name}"
                break
            fi
        done
        if [[ -n "$url" ]]; then
            cat <<EOF > "$srcfile"
X-Repolib-Name: Pop_OS ${name}
Enabled: yes
Types: deb
URIs: ${url}
Suites: ${TARGET_UBUNTU_VERSION}
Components: main
Signed-By: ${keyring}
EOF
            echo "=====> Pop!_OS APT: added ${url} ${TARGET_UBUNTU_VERSION} main (${srcfile##*/})"
            [[ "$url" == "${POP_APT_ORIGIN_URL}/"* ]] && \
                echo "  WARN  ${name}: using the origin server (CDN does not publish '${TARGET_UBUNTU_VERSION}'); downloads may be less reliable." >&2
            added_any=1
        else
            echo "  WARN  ${name} '${TARGET_UBUNTU_VERSION}' is unreachable on both ${POP_APT_URL} and ${POP_APT_ORIGIN_URL} -- skipping this suite." >&2
            # Write a disabled stub anyway: the pop-default-settings postinst
            # greps this exact file unconditionally and kills the dpkg run if
            # it is missing. "Enabled: no" keeps apt from ever using it, and
            # the Signed-By line is what the postinst checks for.
            cat <<EOF > "$srcfile"
X-Repolib-Name: Pop_OS ${name}
Enabled: no
Types: deb
URIs: ${POP_APT_URL}/${name}
Suites: ${TARGET_UBUNTU_VERSION}
Components: main
Signed-By: ${keyring}
EOF
        fi
    done
    if [[ "$added_any" -eq 0 ]]; then
        >&2 echo "ERROR: none of the Pop!_OS suites (release, proprietary, release-ubuntu) could be added for '${TARGET_UBUNTU_VERSION}'."
        >&2 echo "       Cannot build a Pop!_OS image for this release."
        exit 1
    fi

    # Prefer Pop!_OS packages over the Ubuntu archive -- but only for the
    # packages this build actually takes from Pop: OS identity (base-files),
    # the keyring/defaults (pop-*), and the System76 kernel/driver stack.
    #
    # Deliberately NOT the blanket "Package: *" pin that stock Pop!_OS ships
    # in pop-default-settings: this builder installs standard Ubuntu desktops
    # (vanilla-gnome-desktop, kubuntu-desktop, ...), and a repo-wide 1001 pin
    # forces Pop's release-ubuntu rebuilds (older GNOME libs, update-manager,
    # libadwaita, GTK4, ...) as the only candidates, which makes the Ubuntu
    # desktop metapackages' strictly versioned dependencies unsatisfiable
    # ("Depends: ... but it is not going to be installed", conflicting
    # assignments on update-manager-core). Pop-only packages (linux-system76's
    # concrete kernel builds, system76-power, ...) need no pin at all -- the
    # Pop repos are their only source.
    cat <<'EOF' > /etc/apt/preferences.d/pop-os-release
Package: base-files pop-* linux-system76* linux-image-system76* linux-headers-system76* system76-*
Pin: release o=pop-os-release
Pin-Priority: 1001
EOF

    apt-get update

    # Hand key maintenance to the packaged keyring when available.
    apt-get install -y pop-keyring || \
        echo "  WARN  pop-keyring not installable; keeping the keyserver-fetched key." >&2

    # /etc/os-release comes from base-files. Debootstrap installs Ubuntu's
    # base-files (ID=ubuntu); explicitly switch to Pop!_OS's base-files (the
    # o=pop-os-release pin at 1001 selects it even as a version downgrade) so
    # the identity is NAME="Pop!_OS" / ID=pop deterministically, instead of
    # relying on the later apt-get upgrade to swap it.
    echo "=====> switching to Pop!_OS base-files (/etc/os-release identity) ..."
    apt-get install -y --allow-downgrades base-files
    if grep -qs '^ID=pop$' /etc/os-release; then
        # shellcheck source=/dev/null
        echo "=====> /etc/os-release: $(. /etc/os-release && echo "${PRETTY_NAME:-${NAME:-unknown}}")"
    else
        echo "  WARN  /etc/os-release still does not identify as Pop!_OS (ID=pop)." >&2
        echo "  WARN  Pop!_OS base-files may not be published for '${TARGET_UBUNTU_VERSION}' yet." >&2
    fi
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

    setup_pop_apt_repos

    dbus-uuidgen > /etc/machine-id
    ln -fs /etc/machine-id /var/lib/dbus/machine-id

    dpkg-divert --local --rename --add /sbin/initctl
    # -f: advanced-mode re-runs enter this stage with the symlink already in
    # place; plain ln -s would fail under set -e.
    ln -sf /bin/true /sbin/initctl
}

# Full Calamares layout from scripts/calamares-popos (settings.conf + modules + curated i18n).
# Only the calamares binary package is installed -- no calamares-settings-* metapackages.
function apply_calamares_custom_config() {
    echo "=====> installing Calamares configuration from scripts/calamares-popos ..."
    if [[ ! -d /root/calamares-config ]] || [[ ! -f /root/calamares-config/settings.conf ]]; then
        >&2 echo "Internal error: scripts/calamares-popos must include settings.conf (host did not copy scripts/calamares-popos into the chroot)."
        exit 1
    fi
    install -d /etc/calamares/modules
    cp -a /root/calamares-config/settings.conf /etc/calamares/settings.conf
    cp -a /root/calamares-config/modules/. /etc/calamares/modules/

    if [[ -f /root/calamares-config/i18n/SUPPORTED ]]; then
        install -d /usr/share/i18n
        if [[ -f /usr/share/i18n/SUPPORTED ]]; then
            cp -a /usr/share/i18n/SUPPORTED /usr/share/i18n/SUPPORTED.stock-ubuntu-vanilla-backup
        fi
        cp /root/calamares-config/i18n/SUPPORTED /usr/share/i18n/SUPPORTED
    fi

    # Render the Pop!_OS branding template with the correct release version so the installer
    # shows "Pop!_OS 24.04 LTS" / "Pop!_OS 26.04 LTS" instead of the stock Calamares default
    # ("Fancy GNU/Linux ..."). Matches calamares-settings-ubuntu's per-flavor branding approach.
    local ubuntu_version
    ubuntu_version="$(release_version "$TARGET_UBUNTU_VERSION")"
    if [[ -z "$ubuntu_version" ]]; then
        >&2 echo "Internal error: no Pop!_OS marketing version for TARGET_UBUNTU_VERSION='$TARGET_UBUNTU_VERSION'."
        exit 1
    fi
    if [[ ! -f /root/calamares-config/branding/pop/branding.desc ]]; then
        >&2 echo "Internal error: scripts/calamares-popos/branding/pop/branding.desc is missing."
        exit 1
    fi
    install -d /etc/calamares/branding/pop
    # Copy all branding assets (QML slideshow, images); branding.desc is templated next.
    cp -a /root/calamares-config/branding/pop/. /etc/calamares/branding/pop/
    sed -e "s|@VERSION@|${ubuntu_version}|g" \
        -e "s|@CODENAME@|${TARGET_UBUNTU_VERSION}|g" \
        /root/calamares-config/branding/pop/branding.desc \
        > /etc/calamares/branding/pop/branding.desc
}

function install_pkg() {
    echo "=====> running install_pkg ... this will take a while ..."
    echo "=====> kernel metapackage: $TARGET_KERNEL_PACKAGE"
    apt-get -y upgrade

    apt-get install -y \
        sudo \
        ubuntu-standard \
        casper \
        discover \
        laptop-detect \
        os-prober \
        network-manager \
        net-tools \
        locales \
        grub-common \
        grub-gfxpayload-lists \
        grub-pc \
        grub-pc-bin \
        grub2-common \
        grub-efi-amd64-signed \
        shim-signed \
        mtools \
        unzip \
        binutils \
        gparted \
        dosfstools \
        e2fsprogs \
        btrfs-progs \
        xfsprogs \
        ntfs-3g \
        parted

    echo "=====> installing kernel metapackage (with Recommends): $TARGET_KERNEL_PACKAGE"
    apt-get install -y "$TARGET_KERNEL_PACKAGE"

    echo "=====> live installer: ${TARGET_INSTALLER}"
    case "${TARGET_INSTALLER}" in
        calamares)
            # Depends only (no Recommends): avoids pulling calamares-settings-* packages; config is 100% scripts/calamares-popos.
            apt-get install -y --no-install-recommends calamares
            apply_calamares_custom_config
            ;;
        ubiquity)
            if [[ "${TARGET_UBUNTU_VERSION}" != "jammy" ]]; then
                >&2 echo "Internal error: Ubiquity is supported only on jammy; got TARGET_UBUNTU_VERSION='${TARGET_UBUNTU_VERSION}'."
                exit 1
            fi
            # No-install-recommends prevents ubiquity-slideshow-ubuntu from being pulled in.
            apt-get install -y --no-install-recommends ubiquity ubiquity-frontend-gtk
            ;;
        *)
            >&2 echo "Internal error: unsupported TARGET_INSTALLER: ${TARGET_INSTALLER:-}"
            exit 1
            ;;
    esac

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

    cat <<EOF > /etc/NetworkManager/NetworkManager.conf
[main]
rc-manager=none
plugins=ifupdown,keyfile
dns=systemd-resolved

[ifupdown]
managed=false
EOF

    dpkg-reconfigure network-manager

    apt-get clean -y
}

function build_image() {
    echo "=====> running build_image ..."

    rm -rf /image
    mkdir -p /image/{casper,boot/grub,install,EFI/boot,EFI/ubuntu}

    pushd /image >/dev/null

    local vmlinuz_src initrd_src
    vmlinuz_src="$(ls -1 /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)"
    initrd_src="$(ls -1 /boot/initrd.img-* 2>/dev/null | sort -V | tail -1)"
    if [[ -z "${vmlinuz_src:-}" || ! -f "$vmlinuz_src" ]]; then
        echo "No /boot/vmlinuz-* file was found. Did the kernel install fail?" >&2
        exit 1
    fi
    if [[ -z "${initrd_src:-}" || ! -f "$initrd_src" ]]; then
        echo "No /boot/initrd.img-* file was found. Did the kernel install fail?" >&2
        exit 1
    fi
    cp "$vmlinuz_src" casper/vmlinuz
    cp "$initrd_src" casper/initrd

    local _memtest_url="https://memtest.org/download/v7.00/mt86plus_7.00.binaries.zip"
    local _memtest_sha256="19894151788a99c25c42644696527aba18cb210b2f9bca4a60e73586a6d78286"
    wget --progress=dot "$_memtest_url" -O install/memtest86.zip
    echo "${_memtest_sha256}  install/memtest86.zip" | sha256sum -c - || {
        >&2 echo "ERROR: Memtest86+ archive checksum mismatch -- aborting."
        rm -f install/memtest86.zip
        exit 1
    }
    unzip -p install/memtest86.zip memtest64.bin > install/memtest86+.bin
    unzip -p install/memtest86.zip memtest64.efi > install/memtest86+.efi
    rm -f install/memtest86.zip

    touch ubuntu
    cat <<EOF > boot/grub/grub.cfg

search --set=root --file /ubuntu

insmod all_video

set default="0"
set timeout=30

menuentry "$GRUB_LIVEBOOT_LABEL" {
    linux /casper/vmlinuz boot=casper nopersistent quiet splash ---
    initrd /casper/initrd
}

menuentry "Check the disc for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}

if [ "\$grub_platform" = "efi" ]; then
menuentry "UEFI firmware settings" {
    fwsetup
}

menuentry "Test memory with Memtest86+ (UEFI)" {
    linux /install/memtest86+.efi
}
else
menuentry "Test memory with Memtest86+ (BIOS)" {
    linux16 /install/memtest86+.bin
}
fi
EOF

    dpkg-query -W --showformat='${Package} ${Version}\n' | tee casper/filesystem.manifest >/dev/null

    cp -v casper/filesystem.manifest casper/filesystem.manifest-desktop

    # Anchor to "^package " so only the exact package is removed. An unanchored
    # substring match would also delete unrelated packages that merely contain
    # the name (e.g. removing "discover" would strip "plasma-discover" on KDE
    # builds, and casper would then purge it from the installed system).
    local pkg pkg_re
    for pkg in $TARGET_PACKAGE_REMOVE; do
        pkg_re="$(printf '%s' "$pkg" | sed 's/[][\\.*^$/]/\\&/g')"
        sed -i "/^${pkg_re} /d" casper/filesystem.manifest-desktop
    done

    cat <<EOF > README.diskdefines
#define DISKNAME  ${GRUB_LIVEBOOT_LABEL}
#define TYPE  binary
#define TYPEbinary  1
#define ARCH  amd64
#define ARCHamd64  1
#define DISKNUM  1
#define DISKNUM1  1
#define TOTALNUM  0
#define TOTALNUM0  1
EOF

    local _efi_src
    for _efi_src in /usr/lib/shim/shimx64.efi.signed.previous /usr/lib/shim/mmx64.efi /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed; do
        if [[ ! -f "$_efi_src" ]]; then
            echo "ERROR: Required EFI binary '$_efi_src' not found. Ensure shim-signed and grub-efi-amd64-signed are installed." >&2
            exit 1
        fi
    done
    cp /usr/lib/shim/shimx64.efi.signed.previous EFI/boot/bootx64.efi
    cp /usr/lib/shim/mmx64.efi EFI/boot/mmx64.efi
    cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed EFI/boot/grubx64.efi
    cp boot/grub/grub.cfg EFI/ubuntu/grub.cfg

    (
        cd boot/grub
        dd if=/dev/zero of=efiboot.img bs=1M count=10
        mkfs.vfat -F 16 efiboot.img
        LC_CTYPE=C mmd -i efiboot.img efi efi/ubuntu efi/boot
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/bootx64.efi ::efi/boot/bootx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/mmx64.efi ::efi/boot/mmx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ../../EFI/boot/grubx64.efi ::efi/boot/grubx64.efi
        LC_CTYPE=C mcopy -i efiboot.img ./grub.cfg ::efi/ubuntu/grub.cfg
    )

    grub-mkstandalone \
      --format=i386-pc \
      --output=boot/grub/core.img \
      --install-modules="linux16 linux normal iso9660 biosdisk memdisk search tar ls" \
      --modules="linux16 linux normal iso9660 biosdisk search" \
      --locales="" \
      --fonts="" \
      "boot/grub/grub.cfg=boot/grub/grub.cfg"

    cat /usr/lib/grub/i386-pc/cdboot.img boot/grub/core.img > boot/grub/bios.img

    find . -type f -print0 \
        | xargs -0 md5sum \
        | grep -v -e 'boot/grub/efiboot.img' -e 'boot/grub/bios.img' -e 'md5sum.txt' \
        > md5sum.txt

    popd >/dev/null
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
    set_installer_and_manifest_defaults
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
    export TARGET_FIREFOX_POPOS="${TARGET_FIREFOX_POPOS:-0}"
    export TARGET_THUNDERBIRD="${TARGET_THUNDERBIRD:-0}"
    export TARGET_UBUNTU_STUDIO="${TARGET_UBUNTU_STUDIO:-0}"
    export TARGET_SYSTEM76_DRIVER="${TARGET_SYSTEM76_DRIVER:-0}"
    export TARGET_FWUPD="${TARGET_FWUPD:-0}"
    export TARGET_OPENSSH_SERVER="${TARGET_OPENSSH_SERVER:-0}"
    export TARGET_COCKPIT="${TARGET_COCKPIT:-0}"
    validate_ubiquity_jammy_only
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
