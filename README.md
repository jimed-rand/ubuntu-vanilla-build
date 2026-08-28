# Ubuntu Vanilla ISO Builder (No Snap)

Create a bootable Ubuntu live ISO from a minimal base, with a strict no-Snap policy (`snapd` is pinned with APT priority `-1`).

This project is designed for:
- **Beginners** who want a working custom Ubuntu ISO with simple commands and interactive prompts.
- **Advanced users** who want deterministic output, chroot-level control, tunable package profiles, and full customization capabilities.

> [!NOTE]
> This project now is part of jimedrand.org, an new internet-based small organisation and place to develop the open source software that developed by [jimed-rand](https://github.com/jimed-rand) and contributors who've helping to working on it.
---

## What's New

Recent improvements include:
- **TTY / CLI Installer**: A Calamares-equivalent shell installer now ships on every ISO built by this project — `scripts/cli-installer/install-system`. Useful for installing from a TTY, a minimal/server ISO, or a headless VM console. Mirrors the same `welcome → locale → keyboard → partition → users → summary → mount → unpackfs → … → finished` sequence as the Calamares module list in `scripts/calamares/settings.conf`, and offers both TUI (whiptail/dialog) and plain text prompts. See [Installing from the Live ISO (CLI Installer)](#installing-from-the-live-iso-cli-installer).
- **Removable Media Disk Images**: Two new builders produce ready-to-flash raw `.img` files for USB sticks, SD cards, and other removable media — `scripts/build-removable.sh` (Ubuntu) and `scripts/build-popos-removable.sh` (Pop!_OS). Choose UEFI-only or Hybrid (BIOS + UEFI) firmware, sparse truncate / fallocate / dd allocation, image size 8/16/32/64 GB or custom, a desktop-ready or CLI/TTY-only profile, and whether to bake user credentials in at build time or create the user after deployment via a first-boot console wizard. Partition layout adapts to image size (8 GB → 2 GB swap, 16 GB+ → 4 GB swap) and `growpart` resizes root on first boot so a smaller image works on larger media. See [Building Removable Media Disk Images](#building-removable-media-disk-images). `start-here.sh` now also offers
- **Cloud & VM Disk Images**: Four new builders produce ready-to-use disk images instead of a live-installer ISO — `scripts/build-img.sh` (Ubuntu cloud `.img`), `scripts/build-vm.sh` (Ubuntu VM image with QCOW2/VDI/VMDK/VHDX exports), and their Pop!_OS counterparts `scripts/build-popos-img.sh` / `scripts/build-popos-vm.sh`. Choose UEFI-only or Hybrid (BIOS + UEFI) firmware, netplan/systemd-networkd or NetworkManager, the image allocation tool (sparse truncate, fallocate, or dd), disk size 32/64/128 GB or custom (fixed layout: 512 MB ESP + 4 GB swap + root gets the rest), a desktop-ready or CLI/TTY-only profile, and whether to bake user credentials in at build time or create the user after deployment (cloud-init for cloud images, a first-boot console wizard for VM images). See [Building Cloud & VM Disk Images](#building-cloud--vm-disk-images). `start-here.sh` now also asks which output type to build (`--output=iso|img|vm`).
- **Pop!_OS ISO Variant**: `scripts/build-popos.sh` builds a Pop!_OS ISO from the official Pop!_OS APT repositories (staging excluded) — see [Building Pop!_OS ISOs](#building-popos-isos). `start-here.sh` now asks which distro to build (Ubuntu or Pop!_OS).
- **Startup Mode Selection**: When run on a terminal without an explicit mode, `build.sh` first asks whether to build in **Basic** (default, guided prompts) or **Advanced** mode — an alternative to passing `--advanced`.
- **Build Hooks (Modloader)**: Drop `.sh` scripts into `scripts/hooks/pre-chroot/` and `scripts/hooks/chroot/` to customize the build — scripts run in sorted filename order, like a game modloader.
- **Advanced Mode**: `--advanced` flag preserves workspace on failure/Ctrl+C for faster re-runs, enables a persistent APT package cache to save bandwidth, and asks where to put the workspace (default `~/uvb-workspace`) and the finished ISO (default your home directory).
- **Tidy Paths**: In basic mode the workspace lives in a root-owned system directory (`/var/cache/ubuntu-vanilla-build/`) that stays out of your way — the same approach used on WSL — and the finished ISO is saved to your home directory (`/home/$USER`).
- **Config File Support** *(advanced mode)*: Load build options from a `build.cfg` file for repeatable builds (`--advanced --config=FILE -`), or generate one with `--generate-config`. Basic mode uses interactive prompts. The trailing `-` is optional — it means "run every build stage" and is the same as omitting it (`--advanced --config=FILE` runs all stages too). You only need `-` to pick a stage range (e.g. `setup_host - build_iso`).
- **Non-Interactive / Unattended Mode** *(advanced mode)*: `--advanced --no-interactive` disables all prompts; combined with `--locale` and `--keyboard-layout` for fully unattended builds.
- **Date+Time in ISO Name**: Generated ISOs include a UTC timestamp (e.g. `ubuntu-24.04-gnome-amd64-260703-041500.iso`) so old builds aren't overwritten.
- **Optional Pacstall**: Pacstall installation is configurable (`--pacstall` / `--no-pacstall`; installed by default).
- **Security Hardening**: Strict snapd blocking via APT pinning, signed keyrings for all third-party repositories, and optional package sets validated for installability before install.
- **Improved Error Handling**: Better error reporting and failure detection — no more silently swallowed failures, and invalid command ranges are rejected with a clear error.
- **Enhanced Desktop Support**: KDE Plasma, Cinnamon, Budgie, and LXDE with an automatic repair step in the installer.
- **Browser Flexibility**: Multiple browser options (Brave, LibreWolf, Firefox, Firefox ESR, Thunderbird) with configurable pre-installation.
- **Ubuntu Studio Integration**: Optional Ubuntu Studio package set for creative workloads.

---

## What This Build Produces

- **Bootable ISO**: A bootable ISO with GRUB for UEFI and BIOS.
- **Desktop choices**:
  - `gnome` (default, based on `vanilla-gnome-desktop`)
  - `xfce` (Xubuntu-like functional stack, without `xubuntu-*` branding packages; includes `labwc` for Wayland)
  - `lxde` (lightweight LXDE stack with `lightdm` and `slick-greeter`, for low-spec systems)
  - `lxqt` (LXQt via `lxqt` + `sddm` + `xorg`; no `lubuntu-desktop` / Lubuntu branding metapackages)
  - `mate` (`mate-desktop-environment` or lighter `mate-desktop-environment-core`, plus optional `mate-desktop-environment-extras`; `lightdm` + `slick-greeter`)
  - `cinnamon` (`cinnamon-desktop-environment` with `lightdm` and `slick-greeter`)
  - `budgie` (`budgie-desktop-environment` with `lightdm` and `slick-greeter`)
  - `kde-plasma` (KDE Plasma with selectable APT metapackage: `kde-full`, `kde-standard`, or `kde-plasma-desktop`)
- **Installer choices**:
  - `calamares` (default, all supported releases)
  - `ubiquity` (jammy only)
- **Browser repositories configured for**:
  - Brave (stable + Brave Origin, a minimalist privacy-focused build)
  - LibreWolf
  - Mozilla Firefox (`packages.mozilla.org` with pinning)
- **Optional pre-installs**: Brave channel, LibreWolf, Firefox, Firefox ESR, Thunderbird, and Ubuntu Studio package set.
- **Package Management Utilities**:
  - Pacstall installed by default through the official installer: [pacstall.dev](https://pacstall.dev) (disable with `--no-pacstall`).
  - Pre-configured Flatpak support with the Flathub repository (including the GNOME Software Flatpak plugin on GNOME desktop).
- **Outputs** (saved to your home directory by default — `UVB_OUTPUT_DIR` or the advanced-mode prompt picks another location; default name includes a UTC timestamp):
  - `${TARGET_NAME:-ubuntu-<version>-<desktop>-amd64-<yymmdd-hhmmss>}.iso`
  - `${TARGET_NAME:-ubuntu-<version>-<desktop>-amd64-<yymmdd-hhmmss>}.iso.sha1`
  - `${TARGET_NAME:-ubuntu-<version>-<desktop>-amd64-<yymmdd-hhmmss>}.iso.sha256`

---

## Supported Ubuntu Targets

Only these target releases are supported:

| Codename | Version | HWE Suffix |
| --- | --- | --- |
| `jammy` | 22.04 LTS | `-hwe-22.04` |
| `noble` | 24.04 LTS | `-hwe-24.04` |
| `resolute` | 26.04 LTS | `-hwe-26.04` |

*Note*: Use a host OS that is the same release as the target or newer.

---

## Building Pop!_OS ISOs

`scripts/build-popos.sh` is a Pop!_OS variant of `build.sh` with the same commands, options, and hooks. You can start it directly, or via `./start-here.sh --distro=popos` (without `--distro`, `start-here.sh` asks interactively).

### How it differs from the Ubuntu builder

- **Repositories**: everything comes from the CDN-backed `apt.pop-os.org` — debootstrap and the base system use the Ubuntu mirror (`https://apt.pop-os.org/ubuntu`), and the chroot additionally configures the `release`, `proprietary`, and `release-ubuntu` suites (falling back to `apt-origin.pop-os.org` per suite only when the CDN does not publish it) — all signed with the Pop!_OS archive keyring. Only the packages the build takes from Pop (`base-files`, `pop-*`, the System76 kernel/driver stack) are pinned (`o=pop-os-release`, priority 1001) — unlike stock Pop!_OS's repo-wide pin, so the standard Ubuntu desktops this builder installs keep resolving against the Ubuntu archive. **Staging repositories are deliberately excluded.**
- **Releases**: same three LTS targets — `jammy` (22.04), `noble` (24.04), and `resolute` (26.04, released early July 2026).
- **Kernel choice**: `--kernel=system76|generic|lowlatency`. The default `system76` installs `linux-system76` from the Pop!_OS repos (tracks the stable Linux branch); `generic`/`lowlatency` keep the stock Ubuntu HWE kernels.
- **Bootloader**: official Pop!_OS media use systemd-boot, which expects a large (>= 1 GiB) EFI System Partition. This builder keeps **GRUB** (hybrid BIOS + UEFI), so no oversized ESP is required.
- **System76 hardware driver (optional)**: `--system76-driver` (or `TARGET_SYSTEM76_DRIVER=1`) pre-installs `system76-driver` from the Pop!_OS repos for System76 machines (fan/keyboard/suspend support). Default is off — the repos stay configured, so it can always be installed later with `sudo apt install system76-driver`.
- **Calamares config**: comes from `scripts/calamares-popos/` (Pop!_OS branding); the module set matches `scripts/calamares/`.
- **Separate workspace/cache/config**: uses a `workspace-popos/` subdirectory (under the same workspace parent as Ubuntu builds), its own APT cache, and `scripts/build-popos.cfg`, so Ubuntu and Pop!_OS builds never collide.

### Desktop note: no pop-desktop / COSMIC option

The desktop choices are the same as the Ubuntu builder (GNOME default, XFCE, KDE Plasma, MATE, Cinnamon, Budgie, LXDE, LXQt). Pop's own desktops — `pop-desktop` and COSMIC — are **intentionally not offered**, because COSMIC still has too many bugs when installed through Calamares.

### Installing COSMIC after installation (noble / resolute)

The installed system already has the Pop!_OS repositories configured, so users who installed from this ISO can add COSMIC themselves:

```bash
sudo apt update
sudo apt install cosmic-session
```

Then log out and pick the **COSMIC** session from the session menu on the login screen. For the full Pop!_OS desktop stack instead, install `pop-desktop`. (The build also prints this note at the end of every noble/resolute Pop!_OS build.)

---

## Building Cloud & VM Disk Images

Besides the live-installer ISOs, six builders produce **ready-to-use disk images** — no installer involved; the image boots straight into a configured system:

| Script | Distro | Output |
| --- | --- | --- |
| `scripts/build-img.sh` | Ubuntu | Cloud image: raw `.img` for deployment to cloud VMs |
| `scripts/build-vm.sh` | Ubuntu | VM image: raw `.img` + QCOW2 / VDI / VMDK / VHDX exports |
| `scripts/build-removable.sh` | Ubuntu | Removable-media image: raw `.img` for USB sticks, SD cards, CF |
| `scripts/build-popos-img.sh` | Pop!_OS | Cloud image (Pop!_OS repos, staging excluded) |
| `scripts/build-popos-vm.sh` | Pop!_OS | VM image (Pop!_OS repos, staging excluded) |
| `scripts/build-popos-removable.sh` | Pop!_OS | Removable-media image (Pop!_OS repos, staging excluded) |

They are copies of `build.sh` / `build-popos.sh`: same stages up to `run_chroot` (same desktops, browsers, Pacstall, hooks, basic/advanced modes, config files), but the final stage is `build_disk_image` instead of `build_iso`.

### Image-specific choices (prompted interactively, or via flags)

- **Firmware** — `--firmware=uefi|hybrid` (default `uefi`). **UEFI-only** uses GPT with a 512 MB EFI System Partition. **Hybrid** boots on both BIOS *and* UEFI from the same disk: GPT with a 1 MiB BIOS boot partition plus the same 512 MB ESP, with GRUB installed for both the `i386-pc` and `x86_64-efi` targets. (`bios`/`legacy` are accepted as aliases for `hybrid`.)
- **Disk size** — `--disk-size=32|64|128|<GB>` (default `32`, minimum 10). Fixed layout: **ESP 512 MB + swap 4 GB + root = all remaining space** (a 32 GB image leaves ~27.5 GB for root).
- **Allocation tool** — `--alloc-tool=truncate|fallocate|dd` (default `truncate`). How the raw `.img` file is created on the build host: `truncate` makes a sparse file (instant; occupies only the data actually written), `fallocate` preallocates the full size up front, and `dd` fully zero-writes the file (slowest, maximum compatibility with picky tooling).
- **Profile** — `--profile=desktop|cli`. `desktop` is a desktop-ready image (you pick the desktop environment exactly like the ISO builders); `cli` is a CLI/TTY-only image with no desktop stack, GUI browsers, or Flatpak.
- **Network stack** — `--network=networkd|network-manager`. CLI images default to netplan + systemd-networkd but can use NetworkManager (nmcli/nmtui) instead; desktop images always use NetworkManager. On cloud images the choice is also wired into cloud-init's network renderer.
- **User account** — `--user-mode=build|deploy`:
  - `build` bakes a username + password into the image during the build (`--username`, `--password`, optional `--fullname` and `--hostname`; prompted on a TTY if omitted). On cloud images the baked account also becomes cloud-init's default user, so provider-injected SSH keys land on it.
  - `deploy` (cloud default) leaves user creation to **cloud-init** at deploy time; on VM images it installs a **first-boot wizard** that asks for username/password/hostname on the VM console the first time it starts.
- **VM export formats** (`build-vm.sh` / `build-popos-vm.sh` only) — `--formats=qcow2,vdi,vmdk,vhdx|all|none` (default `qcow2`; the raw `.img` is always kept). Conversion is done with `qemu-img` (`qemu-utils` is installed on the host automatically).

Cloud images always include `cloud-init` + `cloud-guest-utils` (growpart), a `ttyS0` serial console on the GRUB command line, and default `openssh-server` to **yes**. Each image plus its exports get `.sha1`/`.sha256` checksum files, like the ISOs.

### Examples

```bash
# Interactive (asks distro + output type):
./start-here.sh                       # pick "Cloud image" or "VM image"
./start-here.sh --distro=popos --output=vm

# Unattended Ubuntu cloud image, CLI-only, 64 GB, UEFI, user created by cloud-init:
cd scripts
./build-img.sh --advanced --no-interactive --release=noble --kernel=generic \
    --profile=cli --network=networkd --firmware=uefi --disk-size=64 --alloc-tool=truncate -

# Ubuntu VM image with a baked-in account, exported to QCOW2 + VirtualBox VDI:
./build-vm.sh --release=noble --kernel=generic --profile=desktop --desktop=xfce \
    --firmware=hybrid --disk-size=32 --user-mode=build --username=alice \
    --password='secret' --hostname=xfce-vm --formats=qcow2,vdi -
```

---

## Building Removable Media Disk Images

A pair of builders produces **ready-to-flash raw `.img` files for USB sticks, SD cards, CompactFlash, and any other removable media that BIOS/UEFI can boot from**. The same pipeline as the cloud/VM builders (`setup_host` → `debootstrap` → `run_chroot` → `build_disk_image`) is used, but the final image is laid out so a single `.img` can be written with `dd` / balenaEtcher / Rufus and boot directly on whatever computer picks it up.

| Script | Distro | Output |
| --- | --- | --- |
| `scripts/build-removable.sh` | Ubuntu | Removable-media image: raw `.img` for USB / SD / CF |
| `scripts/build-popos-removable.sh` | Pop!_OS | Removable-media image (Pop!_OS repos, staging excluded) |

### Image-specific choices (prompted interactively, or via flags)

- **Firmware** — `--firmware=uefi|hybrid` (default `hybrid`). **Hybrid** boots on both BIOS *and* UEFI from the same disk: GPT with a 1 MiB BIOS boot partition plus a 512 MB ESP, with GRUB installed for both the `i386-pc` and `x86_64-efi` targets. **UEFI-only** uses GPT with just the 512 MB ESP. (`bios` / `legacy` are accepted as aliases for `hybrid`.)
- **Disk size** — `--disk-size=8|16|32|64|<GB>` (default `16`, minimum `8`). The partition layout is computed from the image size:
  - **8 GB** image: 512 MB ESP + 2 GB swap + ~5.5 GB root
  - **16 GB** image: 512 MB ESP + 4 GB swap + ~11.5 GB root
  - **32 GB and up**: 512 MB ESP + 4 GB swap + the rest as root (rule: image `< 16 GB` → 2 GB swap, image `≥ 16 GB` → 4 GB swap)
  - On first boot, `growpart` expands the root partition to fill any leftover space on the physical stick or card, so flashing a 16 GB image onto a 64 GB stick works as expected.
  - The swap partition is always written to `/etc/fstab` by UUID (no `RESUME=` so hibernate is not bound to a generic swap UUID).
- **Allocation tool** — `--alloc-tool=truncate|fallocate|dd` (default `truncate`). Same as the cloud/VM builders: `truncate` makes a sparse file (instant; occupies only the data actually written), `fallocate` preallocates the full size up front, and `dd` fully zero-writes the file (slowest, maximum compatibility with picky tooling).
- **Profile** — `--profile=desktop|cli`. `desktop` is a desktop-ready image (you pick the desktop environment exactly like the ISO builder); `cli` is a CLI/TTY-only image with no desktop stack, GUI browsers, or Flatpak.
- **Network stack** — `--network=networkd|network-manager`. CLI images default to netplan + systemd-networkd but can use NetworkManager (nmcli/nmtui) instead; desktop images always use NetworkManager.
- **User account** — `--user-mode=build|deploy`:
  - `build` bakes a username + password into the image during the build (`--username`, `--password`, optional `--fullname` and `--hostname`; prompted on a TTY if omitted). cloud-init is told to treat that account as the default user, so any provider-injected metadata still lands on it.
  - `deploy` (default) leaves user creation to a **first-boot console wizard** that asks for username / password / hostname on the attached console the first time the image starts.

The same `cloud-init` + `cloud-guest-utils` packages as the cloud images are installed, but configured for the **NoCloud** datasource only (`datasource_list: [NoCloud, None]`) with a tiny meta-data / user-data seed under `/var/lib/cloud/seed/nocloud/` so first boot does not stall waiting for EC2/Azure/GCE metadata. Each image plus its checksums get `.sha1` / `.sha256` files, like the ISOs and cloud/VM images.

### Examples

```bash
# Interactive (asks distro + output type):
./start-here.sh --output=removable                # Ubuntu, removable media
./start-here.sh --distro=popos --output=removable # Pop!_OS, removable media

# Unattended Ubuntu removable image, CLI-only, 16 GB, hybrid firmware, baked-in user:
cd scripts
./build-removable.sh --advanced --no-interactive --release=noble --kernel=generic \
    --profile=cli --network=networkd --firmware=hybrid --disk-size=16 --alloc-tool=truncate \
    --user-mode=build --username=alice --password='secret' --hostname=stick01 -

# Pop!_OS removable image, GNOME desktop, 32 GB, hybrid firmware, first-boot user wizard:
./build-popos-removable.sh --release=noble --profile=desktop --desktop=gnome \
    --firmware=hybrid --disk-size=32 --user-mode=deploy -

# Custom 128 GB image with 4 GB swap and dd allocation (max compatibility):
./build-removable.sh --profile=desktop --desktop=kde-plasma --disk-size=128 \
    --alloc-tool=dd --user-mode=deploy -
```

After the build finishes, flash the image to your media:

```bash
# Find the device (e.g. /dev/sdb), then:
sudo dd if=ubuntu-noble-cli-removable-amd64-260726-120000.img of=/dev/sdX bs=4M status=progress conv=fsync
# or use balenaEtcher / Rufus / GNOME Disks / KDE Partition Manager.
```

The first boot takes a few seconds longer than usual while growpart resizes the root partition to fill the rest of the stick and the first-boot wizard (if `--user-mode=deploy`) prompts on the console.

---

## Installing from the Live ISO (CLI Installer)

Once you have built an ISO (Ubuntu or Pop!_OS) and booted a machine from it, the desktop variant launches **Calamares** automatically. A pure TTY/CLI environment has no desktop, so this project ships a Calamares-equivalent shell installer that walks the user through the same stages from a terminal:

| Step | What it asks | Calamares module it mirrors |
| --- | --- | --- |
| Welcome | Pick TUI (whiptail/dialog) or plain text prompts | `welcome` |
| Locale | Curated UTF-8 list (default `en_US.UTF-8`) | `locale` + `localecfg` |
| Keyboard | XKB layout (default `us`) | `keyboard` |
| Timezone | Tries NTP via `timedatectl`; falls back to the live clock if offline | `locale` (`useSystemTimezone: true`, no GeoIP) |
| Disk | Erase (Calamares GPT layout) **or** Manual (`cfdisk`) | `partition` |
| User | Full name, username (validated), password (twice, min 8), hostname | `users` |
| Summary | Review every answer, then confirm | `summary` |
| Install | Mount → unpack squashfs → machine-id → fstab → locale → keyboard → initramfs touch → users → display manager → network → hwclock → initramfs → grubcfg → GRUB install → packages → umount | full `exec:` sequence |
| Finished | `systemctl -i reboot` into the new system | `finished` |

Source: [scripts/cli-installer/install-system](scripts/cli-installer/install-system) (~1 200 lines, single self-contained bash script, passes `bash -n` and `shellcheck` cleanly).

### How to use it

The installer is a single self-contained bash script —
[`scripts/cli-installer/install-system`](scripts/cli-installer/install-system).
To use it on the live system, **make it executable first**, then **copy it
into the system** (e.g. `/usr/local/bin/`), then **run it**:

```bash
# 1. Make it executable FIRST (a fresh checkout from the repo or a fresh
#    copy off the live media is not always +x):
chmod +x scripts/cli-installer/install-system

# 2. Copy the script into the system — install(1) sets mode 0755 in one step:
sudo install -m 0755 scripts/cli-installer/install-system /usr/local/bin/

# 3. Run it as a normal system command:
sudo install-system
```

If you are iterating on the script and only need it on the live system
temporarily, you can skip step 2 and run it in place:

```bash
chmod +x scripts/cli-installer/install-system
sudo ./scripts/cli-installer/install-system
```

> The script aborts with a clear error if `/cdrom/casper/filesystem.squashfs`
> is not present — it is designed to run from the live ISO. For a non-live
> / minimal environment, debootstrap the rootfs manually first, then call
> the same chroot steps.

### What it does **not** do

- **LUKS full-disk encryption** — Calamares offers it; the CLI installer intentionally does not (use `cfdisk` to set up LUKS by hand if you need it).
- **Unattended / non-interactive mode** — by design, every step is answered on the TTY.
- **GeoIP** — the live ISO ships with no GeoIP (see `scripts/calamares/modules/locale.conf`), so the timezone step always asks the user.

For more detail see [scripts/cli-installer/README.md](scripts/cli-installer/README.md).

---

## Build Concepts

Understanding the build pipeline helps with troubleshooting and customization:

- **Host system**: The machine where you run `scripts/build.sh` (your current Ubuntu/Debian system).
- **Live system**: The rootfs built inside a chroot environment and packed into the ISO (what you boot from the USB).
- **Target system**: The final installed OS after running the installer from the live media.

### Build Pipeline Flow
The build process follows these stages:

1. **Host Setup**: Install required tools (`debootstrap`, `squashfs-tools`, `xorriso`) and prepare workspace.
2. **Debootstrap**: Create a minimal Ubuntu base system using the chosen release and mirror.
3. **Chroot Configuration**: Enter the chroot environment to:
   - Configure APT sources and pinning (including snapd blocking).
   - Install desktop environment and selected packages.
   - Configure browser repositories (Brave, LibreWolf, Firefox).
   - Install Pacstall and optional extras (Ubuntu Studio, etc.).
4. **Live Image Assembly**: Create the live filesystem structure with Casper integration.
5. **SquashFS + ISO Creation**: Compress the filesystem and generate the bootable ISO with GRUB.

```mermaid
graph TD
    A[Host: ./build.sh setup_host] -->|Install build dependencies| B[Host: ./build.sh debootstrap]
    B -->|Build minimal base rootfs| C[Chroot: ./build.sh run_chroot]
    C -->|Apply pins, configure repos, install desktop & browsers| D[Host: ./build.sh build_iso]
    D -->|SquashFS compress & assemble bootloader| E(Custom bootable .iso output)
```

### Security Features
- **Snapd Blocking**: APT pinning prevents snapd installation (Pin-Priority: -1) to block snap installations system-wide.
- **Package Availability Checks**: Optional package sets (e.g. Ubuntu Studio) are checked for installability and hidden snapd dependencies before installation.
- **Signed Repositories**: Third-party APT sources (Brave, LibreWolf, Mozilla) are configured with their vendor signing keyrings; Memtest86+ is downloaded with a pinned SHA-256 checksum.
- **Network Security**: Package and installer downloads use HTTPS.

---

## Requirements

### System Requirements
- **Host OS**: Ubuntu, Debian, openSUSE (Tumbleweed / Slowroll), or Arch Linux (and their common derivatives). The script auto-detects the host's package manager (`apt`/`dpkg`, `zypper`/`rpm`, or `pacman`) and translates dependencies accordingly. See [Host OS Compatibility](#host-os-compatibility) for the package-name differences.
- **Internet Access**: Required for downloading packages from Ubuntu and third-party repositories.
- **Disk Space**: Minimum 15-20 GB free space for debootstrap, squashfs, and ISO generation.
- **RAM**: 4 GB minimum (8 GB recommended for smoother builds).
- **Permissions**: `sudo` access. Both build scripts (and `start-here.sh`) validate sudo once up front and keep the credentials alive in the background, so you are not re-prompted for a password mid-build.

### Host OS Compatibility
The script supports building on:
- Ubuntu 22.04+ (jammy, noble, resolute)
- Debian 11+ (requires `ubuntu-archive-keyring` package)
- Ubuntu/Debian derivatives (Mint, Pop!_OS, etc.)
- openSUSE Tumbleweed and openSUSE Slowroll
  - *openSUSE Leap is not currently a planned target. If you would like to see it supported and are willing to help make sure it runs, contributions are very welcome -- please open an issue or PR.*
- Arch Linux and derivatives (Manjaro, Endeavour, CachyOS, etc.)

The host's package manager is auto-detected from `/etc/os-release`. Most dependencies use the same name across all three families (debootstrap, parted, dosfstools, e2fsprogs, rsync). The following tools have different package names depending on the host family:

| Tool (canonical) | Ubuntu/Debian | openSUSE | Arch |
| --- | --- | --- | --- |
| squashfs | `squashfs-tools` | `squashfs` | `squashfs-tools` |
| xorriso (ISO builder) | `xorriso` | `xorriso` | `libisoburn` |
| qemu-utils / qemu-img | `qemu-utils` | `qemu-tools` | `qemu-img` |

`start-here.sh` (and `scripts/build.sh` when run directly without the launcher) install the host dependencies for the chosen output type, using the host's own package manager. **The chroot is always Ubuntu** -- none of these host-side names affect the packages installed inside the chroot (those continue to use `apt-get`).

---

## Intended Use

This project is designed for **interactive, personal-system builds** that you run directly on your own machine, with full manual control over the process. It is **not** designed for unattended CI/CD pipelines running on provider-hosted runners such as **GitHub-hosted Actions** or **GitLab-hosted CI**, which impose disk-space, execution-time, and permission limitations that this project was not built around.

The build requires `sudo`, 15-20 GB of workspace, a full `debootstrap` pass, and direct interaction with the host system (chroot, mounts, partitioning). These requirements are not well-suited to ephemeral, provider-limited CI runners.

### Self-hosted CI/CD exception

Automated CI/CD usage is acceptable **if and only if** it runs on infrastructure you fully own and control — for example, a **self-hosted GitHub Actions runner** or a **self-hosted GitLab CI runner** on your own server. Self-hosted runners are not subject to the disk-space, execution-time, and permission constraints imposed by third-party-hosted runners, so the build can run there as designed.

**Advanced Mode** (`--advanced --no-interactive --config=build.cfg`) is the intended way to automate builds in that self-hosted scenario. It runs the full pipeline non-interactively with a config file, while still requiring the same `sudo`, workspace, and host-system access as an interactive build.

### Provider-hosted CI (GitHub Actions, etc.)

If you want to build via provider-hosted GitHub Actions (or a similar hosted CI) despite the limitations described above, you are welcome to do so — but please **fork the repository** and modify the workflow and build scripts to fit your own needs. Do not expect upstream support for that use case; this project is intentionally not maintained for, and does not target, ephemeral provider-hosted CI environments.

### General modifications

If you want to modify the build for your personal needs in general, please **fork the repository** and make changes in your fork. This keeps the upstream project focused on its original design: a personal, interactive ISO builder run on a system the user controls.

---

## Quick Start (Beginner Friendly)

### Getting Started in 3 Steps

1. **Clone this repository**:
   ```bash
   git clone <repository-url>
   cd ubuntu-vanilla-build
   ```

2. **Run the build script**:
   ```bash
   # Method 1: Using the convenience script from repository root
   # (asks whether to build Ubuntu or Pop!_OS; or pass --distro=ubuntu|popos)
   ./start-here.sh -

   # Method 2: Directly from scripts directory
   cd scripts/
   ./build.sh -          # Ubuntu ISO
   ./build-popos.sh -    # Pop!_OS ISO
   ```

3. **Follow the interactive wizard**:
   On a terminal (TTY), the script first asks which mode to use — press **Enter for Basic** — then prompts you step-by-step for the configuration.

---

## Interactive Prompts

The script is interactive by default on a TTY when required values are missing. The prompt wizard guides you through choosing:

- **Build mode**: Basic (default) or Advanced — asked first, unless `--advanced` or `ADVANCED_MODE` was given
- **Release**: `jammy`, `noble`, or `resolute`
- **Installer**: `calamares` or `ubiquity` (Ubiquity is validated for jammy only)
- **Kernel flavor**: `generic` or `lowlatency`
- **Desktop**: `gnome`, `xfce`, `lxde`, `lxqt`, `mate`, `cinnamon`, `budgie`, or `kde-plasma`
- **KDE package tier** (when desktop is `kde-plasma`): `kde-standard`, `kde-plasma-desktop`, or `kde-full`
- **MATE metapackage** (when desktop is `mate`): `mate-desktop-environment` or `mate-desktop-environment-core`, plus optional MATE extras
- **GNOME recommends toggle** (GNOME only): Enable/disable recommends for GNOME
- **Brave channel**: `release` (default), `origin`, or `none`
- **LibreWolf pre-install toggle**
- **Firefox**: release, ESR, or skip (default: skip)
- **Thunderbird pre-install toggle**
- **Ubuntu Studio package set toggle**
- **Pacstall toggle** (default: install)

Prompt defaults match the non-interactive fallbacks below, so pressing Enter everywhere yields the same ISO as an unattended run.

### Default Settings
If values are not explicitly set and interactive prompts are skipped, the default fallback settings are:
- **Installer**: `calamares`
- **Desktop**: `gnome`
- **Brave channel**: `release`
- **LibreWolf**: Disabled
- **Firefox / Firefox ESR**: Disabled
- **Thunderbird**: Disabled
- **Ubuntu Studio**: Disabled
- **GNOME Recommends**: Disabled
- **Pacstall**: Enabled

---

## Command-Line Options

### Basic Options
- `--release=jammy|noble|resolute` - Target Ubuntu release.
- `--mirror=URL` - Ubuntu package mirror (default: `https://archive.ubuntu.com/ubuntu/`).
- `--kernel=generic|lowlatency` - Kernel flavor.
- `--installer=calamares|ubiquity` - Installer type.
- `--desktop=<desktop>` - Desktop environment slug.

### Desktop-Specific Options
- `--kde=kde-full|kde-standard|kde-plasma-desktop` - KDE package tier.
  - `kde-plasma-desktop`: Minimal Plasma desktop.
  - `kde-standard`: Standard Plasma with common applications (default).
  - `kde-full`: Complete KDE suite with all applications.
- `--mate=full|core` - MATE metapackage choice.
  - `full`: Complete MATE desktop (default).
  - `core`: Lightweight MATE core.
- `--mate-extras` / `--no-mate-extras` - Add MATE extras package.

### Browser Options
- `--brave=none|release|origin` - Brave browser channel.
  - `release`: Stable Brave browser (default).
  - `origin`: Brave Origin — a minimalist, privacy-focused Brave build without the extra integrated features.
  - `none`: Skip Brave pre-installation (repo is still configured).
- `--librewolf` / `--no-librewolf` - Pre-install LibreWolf browser.
- `--firefox` / `--no-firefox` - Pre-install Firefox from Mozilla APT.
- `--firefox-esr` / `--no-firefox-esr` - Pre-install Firefox ESR from Mozilla PPA.
- `--thunderbird` / `--no-thunderbird` - Pre-install Thunderbird from Mozilla PPA.

*Note*: Browser repositories are always configured regardless of pre-installation choice, allowing you to easily `apt install` them post-install.

### Additional Options
- `--ubuntu-studio` / `--no-ubuntu-studio` - Include Ubuntu Studio creative packages.
- `--pacstall` / `--no-pacstall` - Install Pacstall package manager (default: yes).
- `--browser=release|origin` - Legacy alias for Brave selection (use `--brave` instead).

### Locale & Keyboard (Unattended Builds)
- `--locale=LOCALE` - System locale (e.g. `en_US.UTF-8`) to pre-seed for non-interactive locale configuration.
- `--keyboard-layout=LAYOUT` - Keyboard layout code (e.g. `us`, `de`, `fr`).
- `--keyboard-variant=VARIANT` - Keyboard variant (e.g. `intl`, `nodeadkeys`; optional).

### Config File & Interactive Mode
- `--config=FILE` - Load build options from a config file (KEY=VALUE format; **requires `--advanced`**). If not specified, `scripts/build.cfg` is loaded automatically when present in advanced mode.
- `--generate-config` - Launch an interactive wizard to generate a `build.cfg` file (advanced mode). Also available from the repository root as `./start-here.sh --create-config` (or `--generate-config`), which first asks which builder (Ubuntu or Pop!_OS) to generate the config for, then forwards `--generate-config` to it — no sudo or host dependencies needed for this shortcut.
- `--interactive` - Force interactive prompts even when stdin is not a TTY (**requires `--advanced`**).
- `--no-interactive` - Disable all interactive prompts; missing required values use defaults or cause an error (**requires `--advanced`**).

> **Note:** In basic mode (default), the build uses interactive prompts and sensible defaults — prompts appear whenever a terminal is attached, no flags needed. Config files and the `--interactive`/`--no-interactive` overrides are advanced-mode features for power users and CI pipelines. When you run `build.sh` on a terminal without choosing a mode, it first asks whether to run in Basic or Advanced mode (an alternative to passing `--advanced`).

### Build Hooks (Modloader)

Drop executable `.sh` scripts into the hooks directories to customize the build pipeline — like a game modloader:

```
scripts/hooks/
  pre-chroot/    # Runs on host after debootstrap, before entering chroot
  chroot/        # Runs inside chroot after packages are installed
```

Scripts are discovered and executed in **sorted filename order**. Use numeric prefixes to control load order:

```bash
hooks/pre-chroot/00-copy-skel-files.sh
hooks/pre-chroot/10-add-custom-repo.sh
hooks/chroot/00-install-extra-packages.sh
hooks/chroot/50-configure-services.sh
```

- Each hook receives all `TARGET_*` environment variables.
- Pre-chroot hooks also get `WORKSPACE_CHROOT` (path to the chroot root on the host).
- A failing hook aborts the build; use `|| true` for optional operations.
- `--hooks-dir=PATH` overrides the default `scripts/hooks/` directory.

See `scripts/hooks/README.md` for detailed documentation and examples.

### Advanced Mode

`--advanced` (or `ADVANCED_MODE=1` as an environment variable) unlocks features for power users:

1. **Config file support**: Auto-loads `scripts/build.cfg` if present, or use `--config=FILE` for a custom path. Generate one interactively with `--generate-config`. In basic mode (default), the build relies on interactive prompts instead.
2. **Workspace preservation**: On Ctrl+C or build failure, only bind mounts are unmounted — the workspace tree is kept intact. This lets you inspect or resume from a specific build stage (e.g. `./build.sh --advanced run_chroot`) without re-running debootstrap.
3. **Package cache**: A persistent APT cache directory (`~/.cache/ubuntu-vanilla-build/apt-cache/`) is bind-mounted into the chroot. Downloaded `.deb` files survive across builds, saving bandwidth on repeated builds.
4. **Workspace reuse**: `setup_host` reuses an existing workspace directory instead of cleaning it, allowing faster iteration.

---

## Advanced Execution Syntax

For developers who want to control specific build stages:
```bash
./build.sh [options] [start_cmd] [-] [end_cmd]
```

Host commands (run outside chroot):
- `setup_host` - Install host dependencies and prepare workspace.
- `debootstrap` - Create the minimal base rootfs.
- `run_chroot` - Execute the chroot build stages.
- `build_iso` - Create SquashFS and generate bootable ISO.

Examples:
- `./build.sh -` - Run the entire pipeline (default).
- `./build.sh setup_host` - Only run host setup.
- `./build.sh setup_host - debootstrap` - Run from setup_host through debootstrap.
- `./build.sh debootstrap - build_iso` - Run from debootstrap through ISO creation.

---

## Environment Variables

For advanced configurations, environment variables can be used instead of CLI flags:

### Core Build Variables
- `TARGET_UBUNTU_VERSION` - Ubuntu release codename (`jammy`, `noble`, `resolute`).
- `TARGET_UBUNTU_MIRROR` - Package mirror URL.
- `TARGET_KERNEL_FLAVOR` - Kernel type (`generic`, `lowlatency`).
- `TARGET_KERNEL_PACKAGE` - Override kernel metapackage name directly.
- `TARGET_INSTALLER` - Installer type (`calamares`, `ubiquity`).
- `TARGET_DESKTOP` - Desktop environment slug.

### Desktop-Specific Variables
- `TARGET_KDE_PACKAGE` - KDE metapackage when using kde-plasma.
- `TARGET_MATE_PACKAGE` - MATE metapackage.
- `TARGET_MATE_EXTRAS` - Set to `1` to install MATE extras.

### Browser Variables
- `TARGET_BRAVE_CHANNEL` - Brave channel (`none`, `release`, `origin`).
- `TARGET_BROWSER` - Legacy alias for Brave (use `TARGET_BRAVE_CHANNEL`).
- `TARGET_LIBREWOLF` - Set to `1` to pre-install LibreWolf.
- `TARGET_FIREFOX` - Set to `1` to pre-install Firefox.
- `TARGET_FIREFOX_ESR` - Set to `1` to pre-install Firefox ESR.
- `TARGET_FIREFOX_POPOS` - Set to `1` to pre-install Firefox from the Pop!_OS repository (`build-popos.sh` only). This is the native deb System76 builds from Mozilla source ([pop-os/packaging-firefox](https://github.com/pop-os/packaging-firefox)) — a real browser, not Ubuntu's snap-transition stub; the build verifies the candidate comes from the Pop!_OS repos, is larger than 10 MB, and has no snapd dependency before installing. Mutually exclusive with `TARGET_FIREFOX`.
- `TARGET_THUNDERBIRD` - Set to `1` to pre-install Thunderbird.

### Feature & Customization Variables
- `TARGET_UBUNTU_STUDIO` - Set to `1` to include Ubuntu Studio packages.
- `TARGET_FWUPD` - Set to `1` to pre-install `fwupd` as the last build step (default: `0`). Either way, fwupd is banned via an APT pin for the whole build so nothing can pull it in; the pin is removed before the ISO is finalized, so `sudo apt install fwupd` always works on the installed system.
- `TARGET_OPENSSH_SERVER` - Set to `1` to pre-install `openssh-server` (default: `0`). SSH host keys are never shipped in the image: they are wiped at the end of the build and regenerated on first boot by a oneshot systemd unit (`ssh-keygen -A`), so every installation gets a unique host identity.
- `TARGET_COCKPIT` - Set to `1` to pre-install [Cockpit](https://cockpit-project.org/) from the `${release}-backports` pocket for the latest version, as recommended upstream (default: `0`). The backports pocket is always configured, so it can also be installed later with `sudo apt install -t <release>-backports cockpit`.
- `TARGET_GNOME_INSTALL_RECOMMENDS` - Set to `1` to install GNOME with recommends.
- `TARGET_PACSTALL` - Set to `0` to skip Pacstall installation (default: `1`).
- `TARGET_PACKAGE_REMOVE` - Space-separated list of packages to remove from target system.
- `TARGET_NAME` - Custom output ISO base name (includes UTC timestamp by default).
- `GRUB_LIVEBOOT_LABEL` - Custom boot menu entry label.
- `UBUNTU_VANILLA_WORKSPACE` - Custom workspace parent directory (overrides the mode defaults: `/var/cache/ubuntu-vanilla-build` in basic mode, `~/uvb-workspace` in advanced mode).
- `UVB_OUTPUT_DIR` - Directory where the finished ISO and checksums are placed (default: your home directory).

### Locale & Keyboard Variables
- `TARGET_LOCALE` - System locale for unattended builds (e.g. `en_US.UTF-8`).
- `TARGET_KEYBOARD_LAYOUT` - Keyboard layout code (e.g. `us`, `de`).
- `TARGET_KEYBOARD_VARIANT` - Keyboard variant (optional, e.g. `intl`).

### Config & Interactive Variables
- `INTERACTIVE` - Set to `0` to disable interactive prompts (equivalent to `--no-interactive`; advanced mode only).
- `NO_CONFIRM` - Set to `1` to skip the pre-build confirmation prompt.
- `NO_COLOR` - Set (to any value) to disable colored terminal output; colors are also disabled automatically when stdout is not a TTY or `TERM=dumb`.

### Advanced Mode Variables
- `ADVANCED_MODE` - Set to `1` to preserve workspace on failure/interrupt and enable package cache.
- `HOOKS_DIR` - Custom path to the hooks directory (default: `scripts/hooks/`).

---

## Common Examples

```bash
# Jammy + generic kernel + defaults
./build.sh --release=jammy --kernel=generic -

# Jammy + Ubiquity installer (jammy only)
./build.sh --release=jammy --kernel=generic --installer=ubiquity -

# Jammy + Calamares + XFCE
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=xfce -

# Jammy + Calamares + LXDE (lightweight desktop)
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=lxde -

# Jammy + Calamares + LXQt (SDDM, no Lubuntu branding stack)
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=lxqt -

# Jammy + Calamares + MATE
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=mate -

# Jammy + MATE core + extras (non-interactive)
./build.sh --release=jammy --kernel=generic --desktop=mate --mate=core --mate-extras -

# Jammy + Calamares + Cinnamon
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=cinnamon -

# Jammy + Calamares + Budgie
./build.sh --release=jammy --kernel=generic --installer=calamares --desktop=budgie -

# Jammy + KDE Plasma desktop using the standard package set
./build.sh --release=jammy --kernel=generic --desktop=kde-plasma --kde=kde-standard -

# Noble + KDE Plasma desktop with full KDE package set
./build.sh --release=noble --kernel=generic --desktop=kde-plasma --kde=kde-full -

# Resolute + KDE Plasma desktop with minimal package set
./build.sh --release=resolute --kernel=generic --desktop=kde-plasma --kde=kde-plasma-desktop -

# Jammy + GNOME + LibreWolf and Firefox preinstalled
./build.sh --release=jammy --kernel=generic --desktop=gnome --librewolf --firefox -

# Noble + XFCE + lowlatency kernel
./build.sh --release=noble --kernel=lowlatency --desktop=xfce -

# Noble + GNOME + Brave Origin preinstalled
./build.sh --release=noble --kernel=generic --desktop=gnome --brave=origin -

# Noble + no Brave, but preinstall Firefox
./build.sh --release=noble --kernel=generic --brave=none --firefox -

# Noble + GNOME with recommends enabled
TARGET_GNOME_INSTALL_RECOMMENDS=1 ./build.sh --release=noble --kernel=generic --desktop=gnome -

# Noble + GNOME + Ubuntu Studio extras
./build.sh --release=noble --kernel=generic --desktop=gnome --ubuntu-studio -

# Noble + custom mirror
./build.sh --release=noble --kernel=generic --mirror=http://archive.ubuntu.com/ubuntu/ -

# Resolute + generic kernel + defaults
./build.sh --release=resolute --kernel=generic -

# Resolute + XFCE + lowlatency kernel
./build.sh --release=resolute --kernel=lowlatency --desktop=xfce -

# Resolute + GNOME + Brave skipped + LibreWolf preinstalled
./build.sh --release=resolute --kernel=generic --desktop=gnome --brave=none --librewolf -

# Resolute + GNOME + Brave Origin + Firefox preinstalled
./build.sh --release=resolute --kernel=generic --desktop=gnome --brave=origin --firefox -

# Resolute + GNOME with recommends enabled
TARGET_GNOME_INSTALL_RECOMMENDS=1 ./build.sh --release=resolute --kernel=generic --desktop=gnome -

# Advanced mode: generate a config file with the wizard
./build.sh --generate-config
# ...or from the repository root (asks Ubuntu or Pop!_OS first):
# ./start-here.sh --create-config

# Advanced mode: build using a config file
./build.sh --advanced --config=build.cfg -

# Advanced mode: preserve workspace for faster re-runs
./build.sh --advanced --release=noble --kernel=generic -
```

---

## Workspace and Output Behavior

### Workspace Directory
The build process uses a workspace directory to store temporary files:
- **Basic mode location**: `/var/cache/ubuntu-vanilla-build/workspace/` — a root-owned system directory kept out of the user's way (contains `chroot/` and `image/` subdirectories during build). Because it always lives on a Linux-native filesystem, WSL `/mnt/c` unpack issues can't occur.
- **Advanced mode location**: you are asked interactively where to put the workspace (default: `~/uvb-workspace`; the actual workspace becomes `<answer>/workspace`). Non-interactive advanced runs use the default silently.
- **Custom location (any mode)**: Set `UBUNTU_VANILLA_WORKSPACE=/some/path` to use a custom parent directory (actual workspace becomes `/some/path/workspace`) and skip the prompt.
- **WSL guard**: If the chosen workspace path lands on a Windows-backed mount (`/mnt/...`, `/media/...`, 9p/DrvFs), it is automatically relocated to the system directory above, because debootstrap cannot unpack reliably there.
- **Automatic cleanup**: On successful build, the workspace is automatically removed to save disk space. In basic mode, a failed or interrupted (Ctrl+C) build also unmounts the chroot bind mounts and removes the workspace automatically — no manual cleanup needed.
- **Advanced mode preservation**: With `--advanced`, the workspace is preserved on failure or Ctrl+C (only bind mounts are unmounted). This enables faster re-runs: debootstrap is skipped automatically when the chroot already exists, so you can jump straight to the failed stage.

### Output Files
After a successful build, the following files are placed in your home directory (`/home/$USER`) by default. In advanced mode you are asked interactively where to put them (default: your home directory), and `UVB_OUTPUT_DIR=/some/path` overrides the location in any mode. Files are chowned back to the invoking user, and the default name carries a UTC timestamp so repeat builds never overwrite each other:
- `${TARGET_NAME:-ubuntu-<version>-<desktop>-amd64-<yymmdd-hhmmss>}.iso` - The bootable ISO image.
- `${TARGET_NAME:-ubuntu-<version>-<desktop>-amd64-<yymmdd-hhmmss>}.iso.sha1` - SHA-1 checksum for verification.
- `${TARGET_NAME:-ubuntu-<version>-<desktop>-amd64-<yymmdd-hhmmss>}.iso.sha256` - SHA-256 checksum for verification.

---

## Package and Policy Details

### Core Policies
- **No Snap Policy**: `snapd` is blocked via APT pinning (`Pin-Priority: -1`) to ensure a snap-free Ubuntu experience. The Snap app-store backends (`gnome-software-plugin-snap`, `plasma-discover-backend-snap`) are pinned out too; the Flatpak backends (`gnome-software-plugin-flatpak`, `plasma-discover-backend-flatpak`) are installed instead.
- **No fwupd During Build**: `fwupd` is pinned out for the entire build so no package can pull it in. Unlike the snapd pin this one is build-time only — it is dropped before the ISO is finalized, and `TARGET_FWUPD=1` / `--fwupd` pre-installs fwupd on request.
- **Package Availability Checks**: Optional package sets (e.g. Ubuntu Studio) are checked for availability, installability, and hidden snapd dependencies before installation; unavailable ones are skipped with a log message.
- **Browser Repositories**: Brave, LibreWolf, and Firefox repositories are always configured (even if browsers aren't pre-installed).

### Calamares Installer Configuration
The build uses Calamares configuration from `scripts/calamares/`. Edit YAML files in this directory to modify installer flow, partitioning defaults, welcome screen, locale behavior, and post-install package removals.

### Desktop Environment Profiles
Each desktop environment has a carefully curated package set:
- **GNOME**: Uses `vanilla-gnome-desktop` with optional recommends (lighter by default).
- **XFCE**: Xubuntu-equivalent stack without `xubuntu-*` branding packages; includes `labwc` for Wayland sessions.
- **LXDE**: Lightweight stack with `lxde`, `xorg`, `lightdm`, and `slick-greeter` for low-spec systems.
- **LXQt**: Upstream-style stack with `lxqt`, `sddm`, and `xorg` (no Lubuntu branding).
- **MATE**: Full or core MATE desktop with `xorg`, `lightdm`, and `slick-greeter`; optional extras available.
- **Cinnamon**: Full Cinnamon desktop with `xorg`, `lightdm`, and `slick-greeter`.
- **Budgie**: Full Budgie desktop with `xorg`, `lightdm`, and `slick-greeter`.
- **KDE Plasma**: Selectable tier (`kde-plasma-desktop`, `kde-standard`, or `kde-full`); SDDM uses Plasma's own Breeze theme, installed explicitly and pinned via `/etc/sddm.conf.d`; Slick SDDM packages (any name combining `slick` and `sddm`) are excluded with an APT pin (`Pin-Priority: -1`), and any non-Breeze `sddm-theme-*` package pulled in by a metapackage is purged, so third-party themes cannot take over the login screen; Discover ships with the Flatpak backend (the Snap backend is blocked).

### Special Features
- **Pacstall**: Installed by default via the official script from [pacstall.dev](https://pacstall.dev); disable with `--no-pacstall` or `TARGET_PACSTALL=0`.
- **Flatpak**: Pre-configured with Flathub repository; GNOME Software Flatpak plugin included for GNOME, Discover Flatpak backend for KDE Plasma.
- **Ubuntu Studio**: Optional creative package set (audio, graphics, photography, publishing, video); unavailable dependencies are automatically skipped with logging.
- **Kernel Management**: HWE metapackages automatically selected based on release and kernel flavor (unless overridden with `TARGET_KERNEL_PACKAGE`).

### LXDE Repair Mechanism
For LXDE builds, Calamares includes an automatic repair step:
- Triggers when the installed system shows only Openbox instead of LXDE session.
- Runs `apt-get update && apt-get install --no-install-recommends lxde` in the target root.
- **Requires internet connection during installation** to access package mirrors.
- Offline installs skip this step (see troubleshooting section for manual fix).

---

## Verifying Build Artifacts

After building, verify the integrity of your ISO using the provided checksum files (replace the name with your actual timestamped ISO):
```bash
cd scripts/
sha256sum -c ubuntu-24.04-gnome-amd64-<yymmdd-hhmmss>.iso.sha256
sha1sum -c ubuntu-24.04-gnome-amd64-<yymmdd-hhmmss>.iso.sha1
```

### Testing the ISO
Before deploying, test your ISO in a virtual machine:
- **VirtualBox**: Create a new VM, attach the ISO as optical drive, boot and test live session and installation.
- **QEMU/KVM**: Use `qemu-system-x86_64 -cdrom <your-iso-file>.iso -m 4096 -enable-kvm`
- **VMware**: Create a new VM, attach ISO, and test the installation process.

### Creating Bootable USB
Use a tool like `dd`, `balenaEtcher`, or `Rufus` (Windows) to create a bootable USB:
```bash
# Using dd (Linux/macOS)
sudo dd if=<your-iso-file>.iso of=/dev/sdX bs=4M status=progress conv=fsync
```
> [!WARNING]
> Replace `/dev/sdX` with your actual USB device (use `lsblk` to identify). Writing to the wrong device will result in data loss.

---

## Troubleshooting

### Common Issues
- **No interactive prompts in CI/non-TTY environments**: Provide all required options explicitly (`--release`, `--kernel`, and any toggles).
- **Ubiquity installer rejected**: Use `--installer=ubiquity` only with `--release=jammy` (22.04 LTS).
- **Debian host keyring error**: Install `ubuntu-archive-keyring` package: `sudo apt install ubuntu-archive-keyring`
- **Build fails on WSL Windows mount**: The workspace always defaults to a Linux-native path now; if you point `UBUNTU_VANILLA_WORKSPACE` (or the advanced-mode prompt) at `/mnt/...`, it is relocated automatically to `/var/cache/ubuntu-vanilla-build`.
- **Missing package in chosen release**: Script logs and skips unavailable/uninstallable packages with warnings.
- **LXDE installed system shows only Openbox**: Connect to internet during Calamares installation so the LXDE repair step can reach mirrors, or manually fix after boot (see below).

### LXDE Openbox-Only Issue
If you install an LXDE ISO while offline and the system boots to Openbox only:

**After you get internet:**
1. Boot into the installed system and select the Openbox session.
2. Open a terminal and run:
   ```bash
   sudo apt update
   sudo apt install --no-install-recommends lxde
   ```
3. Log out or reboot.
4. At the login screen, select **LXDE Session**, then log in.

**Panel configuration fix:**
If the taskbar/panel looks wrong or missing:
- Right-click the LXDE panel → Edit Panel → Panel Preferences.
- Remove the **Desktop Pager** and **Desktop Spacer** applets.

### Advanced Debugging
For detailed debugging, you can run individual build stages:
```bash
# Run only host setup to check dependencies
./build.sh setup_host

# Run debootstrap stage to check base system creation
./build.sh debootstrap

# Run chroot stage to check package installation
./build.sh run_chroot
```

---

## Advanced Customization

### Modifying Calamares Configuration
For deep customization of the installer experience, edit the YAML files in `scripts/calamares/`:
- `settings.conf` - Main Calamares configuration and module sequence.
- `modules/` - Individual module configurations (partitioning, users, packages, etc.).
- `branding/` - Visual branding and slideshow content.
- `i18n/SUPPORTED` - Supported locales.

### Adding Custom Packages
The recommended way to add custom packages is with **build hooks** (see [Build Hooks](#build-hooks-modloader)). Drop a script into `scripts/hooks/chroot/` that runs `apt-get install -y <your-packages>` — no need to modify `build.sh` at all.

Alternatively, for permanent changes to the build pipeline itself, modify the `customize_image()` function in `scripts/build.sh`. Look for the desktop-specific sections and add your packages to the appropriate `apt-get install` commands.

### Creating Custom Desktop Profiles
To add a new desktop environment variant:
1. Add the desktop name to the validation in `normalize_desktop_variant()`.
2. Add installation logic in the `customize_image()` function under a new case statement.
3. Update the help text in `host_help()` to document the new option.

---

## Contributing

Contributions are welcome! Areas for contribution:
- Additional desktop environment profiles.
- Package selection optimizations.
- Documentation improvements.
- Bug fixes and error handling enhancements.

---

## License

Licensed under **GNU General Public License v2.0**. See `LICENSE`.
