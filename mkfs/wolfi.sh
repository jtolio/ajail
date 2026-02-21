#!/bin/bash
#
# mkwolfi.sh - Create a Wolfi Linux root filesystem using apk.static
#
# Wolfi is a glibc-based distro by Chainguard that uses the same apk package
# manager as Alpine. It was designed for containers and single-user environments.
#
# This script must be run as root (sudo ./mkwolfi.sh ...)
#
set -euo pipefail

# Defaults
ARCH="$(uname -m)"
PACKAGES=""
TARGET_USER=""

# apk.static download info (same as Alpine - Wolfi uses compatible apk v2)
APK_TOOLS_VERSION="2.14.10"
APK_TOOLS_URI="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v${APK_TOOLS_VERSION}/x86_64/apk.static"
APK_TOOLS_SHA256="34bb1a96f0258982377a289392d4ea9f3f4b767a4bb5806b1b87179b79ad8a1c"

# Wolfi repository
WOLFI_REPO="https://packages.wolfi.dev/os"
WOLFI_KEY_URL="https://packages.wolfi.dev/os/wolfi-signing.rsa.pub"

# Base packages for a minimal system
BASE_PACKAGES="wolfi-base bash"

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS] <output-dir>

Create a minimal Wolfi Linux root filesystem.

Wolfi is a glibc-based container-oriented distro using the apk package
manager (same as Alpine). Good for when you need glibc compatibility
with the simplicity of apk.

Options:
  -a, --arch ARCH         Target architecture (default: $ARCH)
  -p, --packages PKGS     Comma or space-separated list of additional packages
                          Example: -p bash,git,curl
  -u, --user USER         Change ownership to USER after creation
  -h, --help              Show this help

Examples:
  sudo $0 /tmp/mywolfi
  sudo $0 -p bash,git,curl /tmp/wolfi-dev
  sudo $0 -p "build-base git python3" -u \$USER /tmp/devenv

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
    if [[ -n "${APK_STATIC:-}" && -f "$APK_STATIC" ]]; then
        rm -f "$APK_STATIC"
    fi
    if [[ -n "${KEY_DIR:-}" && -d "$KEY_DIR" ]]; then
        rm -rf "$KEY_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--arch)
            ARCH="$2"
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

# Need wget or curl
if command -v wget &>/dev/null; then
    DOWNLOAD_CMD="wget -q -O"
elif command -v curl &>/dev/null; then
    DOWNLOAD_CMD="curl -fsSL -o"
else
    die "wget or curl is required"
fi

echo "Creating Wolfi rootfs..."
echo "  Arch:    $ARCH"
echo "  Output:  $OUTPUT_DIR"
if [[ -n "$PACKAGES" ]]; then
    echo "  Extra packages: $PACKAGES"
fi
if [[ -n "$TARGET_USER" ]]; then
    echo "  Owner:   $TARGET_USER"
fi
echo

# Download apk.static
APK_STATIC=$(mktemp)
echo "Downloading apk.static v${APK_TOOLS_VERSION}..."

# Adjust download URL for architecture
if [[ "$ARCH" == "x86_64" ]]; then
    APK_URI="$APK_TOOLS_URI"
elif [[ "$ARCH" == "aarch64" ]]; then
    APK_URI="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v${APK_TOOLS_VERSION}/aarch64/apk.static"
    APK_TOOLS_SHA256=""  # Different hash for aarch64, skip verification
else
    die "Unsupported architecture: $ARCH (supported: x86_64, aarch64)"
fi

$DOWNLOAD_CMD "$APK_STATIC" "$APK_URI"
chmod +x "$APK_STATIC"

# Verify checksum (x86_64 only)
if [[ -n "$APK_TOOLS_SHA256" && "$ARCH" == "x86_64" ]]; then
    echo "Verifying apk.static checksum..."
    echo "$APK_TOOLS_SHA256  $APK_STATIC" | sha256sum -c - || die "Checksum verification failed"
fi

# Download Wolfi signing key
KEY_DIR=$(mktemp -d)
echo "Downloading Wolfi signing key..."
$DOWNLOAD_CMD "$KEY_DIR/wolfi-signing.rsa.pub" "$WOLFI_KEY_URL"

# Create output directory with merged /usr layout
# Wolfi uses usrmerge: /lib, /bin, /sbin are symlinks into /usr.
# These must exist before apk runs, otherwise apk creates /lib as a real
# directory and wolfi-baselayout's later attempt to symlink it fails.
mkdir -p "$OUTPUT_DIR/usr/bin" "$OUTPUT_DIR/usr/lib"
ln -s usr/bin "$OUTPUT_DIR/bin"
ln -s usr/bin "$OUTPUT_DIR/sbin"
ln -s usr/lib "$OUTPUT_DIR/lib"
ln -s usr/lib "$OUTPUT_DIR/lib64"

# Convert comma-separated packages to space-separated
PACKAGES="${PACKAGES//,/ }"

# Combine base and extra packages
ALL_PACKAGES="$BASE_PACKAGES $PACKAGES"

echo "Installing packages: $ALL_PACKAGES"
echo

# Run apk to bootstrap the rootfs
"$APK_STATIC" \
    --arch "$ARCH" \
    -X "$WOLFI_REPO" \
    -U \
    --keys-dir "$KEY_DIR" \
    --root "$OUTPUT_DIR" \
    --initdb \
    add $ALL_PACKAGES

# Set up /etc/apk/repositories for future package installs
mkdir -p "$OUTPUT_DIR/etc/apk"
cat > "$OUTPUT_DIR/etc/apk/repositories" <<EOF
$WOLFI_REPO
EOF

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
echo "Wolfi rootfs created successfully at: $OUTPUT_DIR"
