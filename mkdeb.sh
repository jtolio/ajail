#!/bin/bash
#
# mkdeb.sh - Create a Debian root filesystem using debootstrap
#
# This script must be run as root (sudo ./mkdeb.sh ...)
# The resulting rootfs can be imported into ajail with:
#   ajail import <name> <path>
#
set -euo pipefail

# Defaults
SUITE="bookworm"
MIRROR="http://deb.debian.org/debian"
VARIANT="minbase"
PACKAGES=""
TARGET_USER=""

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS] <output-dir>

Create a minimal Debian root filesystem using debootstrap.

Options:
  -s, --suite SUITE       Debian suite (default: $SUITE)
                          Examples: bookworm, bullseye, trixie, sid
  -m, --mirror URL        Debian mirror (default: $MIRROR)
  -p, --packages PKGS     Comma-separated list of additional packages
                          Example: -p vim,git,curl
  -u, --user USER         Change ownership to USER after creation
                          (for use with ajail import)
  -h, --help              Show this help

Examples:
  sudo $0 /tmp/mydebian
  sudo $0 -s sid -p vim,git /tmp/mysid
  sudo $0 -p build-essential,git -u \$USER /tmp/devenv

The script uses --variant=minbase for a minimal installation.
Additional packages can be added with -p/--packages.
EOF
    exit "${1:-0}"
}

die() {
    echo "Error: $1" >&2
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--suite)
            SUITE="$2"
            shift 2
            ;;
        -m|--mirror)
            MIRROR="$2"
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
            break
            ;;
    esac
done

# Check for output directory argument
if [[ $# -lt 1 ]]; then
    usage 1
fi

OUTPUT_DIR="$1"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    die "This script must be run as root. Use: sudo $0 ..."
fi

# Check if debootstrap is available
if ! command -v debootstrap &>/dev/null; then
    die "debootstrap not found. Install it with:
  Fedora: dnf install debootstrap
  Debian/Ubuntu: apt install debootstrap
  Arch: pacman -S debootstrap"
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

echo "Creating Debian rootfs..."
echo "  Suite:   $SUITE"
echo "  Mirror:  $MIRROR"
echo "  Variant: $VARIANT"
echo "  Output:  $OUTPUT_DIR"
if [[ -n "$PACKAGES" ]]; then
    echo "  Extra packages: $PACKAGES"
fi
if [[ -n "$TARGET_USER" ]]; then
    echo "  Owner:   $TARGET_USER"
fi
echo

mkdir -p "$(dirname "$OUTPUT_DIR")"

# Build debootstrap command
DEBOOTSTRAP_ARGS=(
    "--variant=$VARIANT"
)

# Add include packages if specified
if [[ -n "$PACKAGES" ]]; then
    DEBOOTSTRAP_ARGS+=("--include=$PACKAGES")
fi

# Run debootstrap
echo "Running debootstrap..."
debootstrap "${DEBOOTSTRAP_ARGS[@]}" "$SUITE" "$OUTPUT_DIR" "$MIRROR"

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
echo "Debian rootfs created successfully at: $OUTPUT_DIR"
