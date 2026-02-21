#!/bin/bash
#
# mkarch.sh - Create an Arch Linux root filesystem using the bootstrap tarball
#
# This script must be run as root (sudo ./mkarch.sh ...)
#
set -euo pipefail

# Defaults
ARCH_MIRROR="https://geo.mirror.pkgbuild.com"
PACKAGES=""
TARGET_USER=""

# The bootstrap tarball includes pacman and enough to install more packages.
# We install the 'base' metapackage on top for a complete rootfs.
BASE_PACKAGES="base"

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS] <output-dir>

Create a minimal Arch Linux root filesystem.

Options:
  -m, --mirror URL        Arch mirror (default: $ARCH_MIRROR)
  -p, --packages PKGS     Comma or space-separated list of additional packages
                          Example: -p vim,git,curl
  -u, --user USER         Change ownership to USER after creation
  -h, --help              Show this help

Examples:
  sudo $0 /tmp/myarch
  sudo $0 -p vim,git,curl /tmp/arch-dev
  sudo $0 -p "base-devel git python nodejs" -u \$USER /tmp/devenv

The script installs the 'base' metapackage plus any additional packages.
Pacman is configured to work in single-uid environments (DisableSandbox,
no DownloadUser).
EOF
    exit "${1:-0}"
}

die() {
    echo "Error: $1" >&2
    exit 1
}

cleanup() {
    if [[ -n "${BOOTSTRAP_TAR:-}" && -f "$BOOTSTRAP_TAR" ]]; then
        rm -f "$BOOTSTRAP_TAR"
    fi
}
trap cleanup EXIT

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mirror)
            ARCH_MIRROR="$2"
            shift 2
            ;;
        -p|--packages)
            PACKAGES="$2"
            shift 2
            ;;
        -u|--user)
            TARGET_USER="$2"
            shift 2
            ;;
        -h|--help)
            usage 0
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

# Check for output directory argument
if [[ ${#POSITIONAL[@]} -lt 1 ]]; then
    usage 1
fi

OUTPUT_DIR="${POSITIONAL[0]}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root. Use: sudo $0 ..."
fi

# Check if output directory already exists
if [[ -e "$OUTPUT_DIR" ]]; then
    die "Output directory '$OUTPUT_DIR' already exists"
fi

# Validate target user if specified
if [[ -n "$TARGET_USER" ]]; then
    if ! id "$TARGET_USER" &>/dev/null; then
        die "User '$TARGET_USER' does not exist"
    fi
fi

# Run a command inside the rootfs using chroot.
# Uses unshare --mount so proc/dev/resolv.conf mounts are cleaned up automatically.
run_in_rootfs() {
    unshare --mount --fork -- /bin/bash -c '
        mount --bind "$1" "$1"
        mount -t proc proc "$1/proc"
        mount -t devtmpfs devtmpfs "$1/dev" 2>/dev/null || mount -t tmpfs tmpfs "$1/dev"
        cp /etc/resolv.conf "$1/etc/resolv.conf" 2>/dev/null || true
        chroot "$1" /bin/bash -c "$2"
    ' _ "$OUTPUT_DIR" "$1"
}

# Need zstd for the bootstrap tarball
if ! command -v zstd &>/dev/null; then
    die "zstd is required (the bootstrap tarball is zstd-compressed).
  Fedora: dnf install zstd
  Debian/Ubuntu: apt install zstd
  Alpine: apk add zstd"
fi

# Need wget or curl
if command -v wget &>/dev/null; then
    DOWNLOAD_CMD="wget -q -O"
elif command -v curl &>/dev/null; then
    DOWNLOAD_CMD="curl -fsSL -o"
else
    die "wget or curl is required"
fi

BOOTSTRAP_URL="${ARCH_MIRROR}/iso/latest/archlinux-bootstrap-x86_64.tar.zst"

echo "Creating Arch Linux rootfs..."
echo "  Mirror:  $ARCH_MIRROR"
echo "  Output:  $OUTPUT_DIR"
if [[ -n "$PACKAGES" ]]; then
    echo "  Extra packages: $PACKAGES"
fi
if [[ -n "$TARGET_USER" ]]; then
    echo "  Owner:   $TARGET_USER"
fi
echo

# Download bootstrap tarball
BOOTSTRAP_TAR=$(mktemp --suffix=.tar.zst)
echo "Downloading Arch bootstrap tarball..."
$DOWNLOAD_CMD "$BOOTSTRAP_TAR" "$BOOTSTRAP_URL"

# Extract the bootstrap tarball
echo "Extracting bootstrap tarball..."
mkdir -p "$OUTPUT_DIR"
tar xf "$BOOTSTRAP_TAR" --numeric-owner --strip-components=1 -C "$OUTPUT_DIR"

# Configure mirrorlist
echo "Configuring pacman..."
echo "Server = ${ARCH_MIRROR}/\$repo/os/\$arch" > "$OUTPUT_DIR/etc/pacman.d/mirrorlist"

# Configure pacman.conf for single-uid environments:
# 1. Add DisableSandbox (Landlock/seccomp may not work in containers)
# 2. Comment out DownloadUser (the 'alpm' user won't exist)
if [[ -f "$OUTPUT_DIR/etc/pacman.conf" ]]; then
    # Comment out DownloadUser if present
    sed -i 's/^DownloadUser/#DownloadUser/' "$OUTPUT_DIR/etc/pacman.conf"
    # Add DisableSandbox after the [options] line if not already present
    if ! grep -q '^DisableSandbox' "$OUTPUT_DIR/etc/pacman.conf"; then
        sed -i '/^\[options\]/a DisableSandbox' "$OUTPUT_DIR/etc/pacman.conf"
    fi
fi

# Convert comma-separated packages to space-separated
PACKAGES="${PACKAGES//,/ }"

# Combine base and extra packages
ALL_PACKAGES="$BASE_PACKAGES $PACKAGES"

echo "Initializing pacman keyring..."
run_in_rootfs "pacman-key --init && pacman-key --populate"

echo "Installing packages: $ALL_PACKAGES"
echo
run_in_rootfs "pacman -Sy --noconfirm $ALL_PACKAGES"

# Clean package cache
rm -rf "$OUTPUT_DIR/var/cache/pacman/pkg/"*

# Clean up files that cause issues with unprivileged import:
# 1. Remove device nodes - ajail mounts its own /dev anyway
# 2. Remove setuid/setgid bits - they don't work in user namespaces
# 3. Ensure all files are readable by owner (for copying)
echo "Cleaning up for unprivileged import..."
rm -rf "$OUTPUT_DIR/dev/"*
find "$OUTPUT_DIR" -perm /6000 -type f -exec chmod ug-s {} \; 2>/dev/null || true
chmod -R u+r "$OUTPUT_DIR"

# Change ownership if requested
if [[ -n "$TARGET_USER" ]]; then
    echo "Changing ownership to $TARGET_USER..."
    chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$OUTPUT_DIR"
fi

echo
echo "Arch Linux rootfs created successfully at: $OUTPUT_DIR"
