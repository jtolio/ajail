#!/bin/bash
#
# mkvoid.sh - Create a Void Linux root filesystem using static xbps
#
# This script must be run as root (sudo ./mkvoid.sh ...)
#
set -euo pipefail

# Defaults
VOID_MIRROR="https://repo-default.voidlinux.org"
ARCH="$(uname -m)"
PACKAGES=""
TARGET_USER=""
MUSL=false

# Base packages for a minimal system with a package manager
BASE_PACKAGES="base-files xbps bash coreutils grep sed gawk"

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS] <output-dir>

Create a minimal Void Linux root filesystem.

Options:
  -m, --mirror URL        Void mirror (default: $VOID_MIRROR)
  -a, --arch ARCH         Target architecture (default: $ARCH)
  -p, --packages PKGS     Comma or space-separated list of additional packages
                          Example: -p vim,git,curl
      --musl              Use musl variant instead of glibc
  -u, --user USER         Change ownership to USER after creation
  -h, --help              Show this help

Examples:
  sudo $0 /tmp/myvoid
  sudo $0 -p vim,git,curl /tmp/void-dev
  sudo $0 --musl -p "build-base git" -u \$USER /tmp/void-musl
  sudo $0 -p "gcc make python3" -u \$USER /tmp/devenv

The script installs: $BASE_PACKAGES
Additional packages can be added with -p/--packages.
EOF
    exit "${1:-0}"
}

die() {
    echo "Error: $1" >&2
    exit 1
}

cleanup() {
    if [[ -n "${XBPS_DIR:-}" && -d "$XBPS_DIR" ]]; then
        rm -rf "$XBPS_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mirror)
            VOID_MIRROR="$2"
            shift 2
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -p|--packages)
            PACKAGES="$2"
            shift 2
            ;;
        --musl)
            MUSL=true
            shift
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

# Determine architecture strings and repo URL
if [[ "$ARCH" == "x86_64" ]]; then
    if [[ "$MUSL" == true ]]; then
        XBPS_ARCH="x86_64-musl"
        REPO="${VOID_MIRROR}/current/musl"
    else
        XBPS_ARCH="x86_64"
        REPO="${VOID_MIRROR}/current"
    fi
    XBPS_STATIC_ARCH="x86_64-musl"
elif [[ "$ARCH" == "aarch64" ]]; then
    if [[ "$MUSL" == true ]]; then
        XBPS_ARCH="aarch64-musl"
        REPO="${VOID_MIRROR}/current/aarch64"
    else
        XBPS_ARCH="aarch64"
        REPO="${VOID_MIRROR}/current/aarch64"
    fi
    XBPS_STATIC_ARCH="aarch64-musl"
else
    die "Unsupported architecture: $ARCH (supported: x86_64, aarch64)"
fi

XBPS_STATIC_URL="${VOID_MIRROR}/static/xbps-static-latest.${XBPS_STATIC_ARCH}.tar.xz"
KEYS_URL="https://github.com/void-linux/void-mklive/archive/refs/heads/master.tar.gz"

echo "Creating Void Linux rootfs..."
echo "  Mirror:  $VOID_MIRROR"
echo "  Arch:    $XBPS_ARCH"
echo "  Repo:    $REPO"
echo "  Output:  $OUTPUT_DIR"
if [[ -n "$PACKAGES" ]]; then
    echo "  Extra packages: $PACKAGES"
fi
if [[ -n "$TARGET_USER" ]]; then
    echo "  Owner:   $TARGET_USER"
fi
echo

# Download static xbps
XBPS_DIR=$(mktemp -d)
echo "Downloading static xbps..."

if command -v wget &>/dev/null; then
    wget -q -O- "$XBPS_STATIC_URL" | tar xJ -C "$XBPS_DIR"
elif command -v curl &>/dev/null; then
    curl -fsSL "$XBPS_STATIC_URL" | tar xJ -C "$XBPS_DIR"
else
    die "wget or curl is required"
fi

XBPS_INSTALL="$XBPS_DIR/usr/bin/xbps-install"
XBPS_RECONFIGURE="$XBPS_DIR/usr/bin/xbps-reconfigure"
if [[ ! -x "$XBPS_INSTALL" ]]; then
    die "Failed to find xbps-install in static tarball"
fi

# Create output directory and pre-seed signing keys
mkdir -p "$OUTPUT_DIR/var/db/xbps/keys"

echo "Downloading Void signing keys..."
if command -v wget &>/dev/null; then
    wget -q -O- "$KEYS_URL" | tar xz --strip-components=2 -C "$OUTPUT_DIR/var/db/xbps/keys" --wildcards "*/keys/*.plist"
elif command -v curl &>/dev/null; then
    curl -fsSL "$KEYS_URL" | tar xz --strip-components=2 -C "$OUTPUT_DIR/var/db/xbps/keys" --wildcards "*/keys/*.plist"
fi

if [[ -z "$(ls "$OUTPUT_DIR/var/db/xbps/keys/")" ]]; then
    die "Failed to download signing keys"
fi

# Convert comma-separated packages to space-separated
PACKAGES="${PACKAGES//,/ }"

# Combine base and extra packages
ALL_PACKAGES="$BASE_PACKAGES $PACKAGES"

echo "Syncing repository index..."
XBPS_ARCH="$XBPS_ARCH" "$XBPS_INSTALL" -S \
    -R "$REPO" \
    -r "$OUTPUT_DIR"

echo "Installing packages: $ALL_PACKAGES"
echo
XBPS_ARCH="$XBPS_ARCH" "$XBPS_INSTALL" -Sy \
    -R "$REPO" \
    -r "$OUTPUT_DIR" \
    $ALL_PACKAGES

# Reconfigure installed packages
echo "Reconfiguring packages..."
XBPS_ARCH="$XBPS_ARCH" "$XBPS_RECONFIGURE" -r "$OUTPUT_DIR" -fa 2>/dev/null || true

# Set up repository config for future package installs inside the jail
mkdir -p "$OUTPUT_DIR/etc/xbps.d"
cat > "$OUTPUT_DIR/etc/xbps.d/00-repository-main.conf" <<EOF
repository=$REPO
EOF

# Clean package cache
rm -rf "$OUTPUT_DIR/var/cache/xbps"

# Clean up files that cause issues with unprivileged import:
# 1. Remove device nodes - bwrap mounts its own /dev anyway
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
echo "Void Linux rootfs created successfully at: $OUTPUT_DIR"
