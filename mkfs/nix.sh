#!/bin/bash
#
# mknix.sh - Create a minimal root filesystem with Nix package manager
#
# The Nix binary tarball is self-contained (ships its own glibc, bash, etc.)
# so we build a minimal rootfs skeleton and install Nix into it.
#
# This script must be run as root (sudo ./mknix.sh ...)
#
set -euo pipefail

# Defaults
NIX_VERSION="2.33.3"
ARCH="$(uname -m)"
PACKAGES=""
TARGET_USER=""

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS] <output-dir>

Create a minimal root filesystem with Nix package manager pre-installed.

The resulting rootfs contains Nix configured for single-user mode, suitable
for use in ajail. Inside the jail, use 'nix profile add nixpkgs#<pkg>'
to install packages from the binary cache.

Options:
  -v, --nix-version VER   Nix version (default: $NIX_VERSION)
  -a, --arch ARCH         Target architecture (default: $ARCH)
  -p, --packages PKGS     Comma or space-separated list of nixpkgs to install
                          Example: -p git,python3,nodejs
  -u, --user USER         Change ownership to USER after creation
  -h, --help              Show this help

Examples:
  sudo $0 /tmp/mynix
  sudo $0 -p git,python3,nodejs -u \$USER ~/.ajail/fs/nix
  sudo $0 -v 2.33.3 -u \$USER /tmp/nix

Inside the jail:
  nix profile add nixpkgs#git
  nix profile add nixpkgs#python3
  nix profile add nixpkgs#nodejs
EOF
    exit "${1:-0}"
}

die() {
    echo "Error: $1" >&2
    exit 1
}

cleanup() {
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# Parse arguments
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--nix-version)
            NIX_VERSION="$2"
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
# Uses unshare --mount so proc/dev mounts are cleaned up automatically.
run_in_rootfs() {
    unshare --mount --fork -- /bin/bash -c '
        mount --bind "$1" "$1"
        mount -t proc proc "$1/proc"
        mount -t devtmpfs devtmpfs "$1/dev" 2>/dev/null || mount -t tmpfs tmpfs "$1/dev"
        mkdir -p "$1/dev/pts"
        mount -t devpts devpts "$1/dev/pts" 2>/dev/null || true
        cp /etc/resolv.conf "$1/etc/resolv.conf" 2>/dev/null || true
        chroot "$1" /bin/bash -c "$2"
    ' _ "$OUTPUT_DIR" "$1"
}

# Determine system string for download URL
if [[ "$ARCH" == "x86_64" ]]; then
    NIX_SYSTEM="x86_64-linux"
elif [[ "$ARCH" == "aarch64" ]]; then
    NIX_SYSTEM="aarch64-linux"
else
    die "Unsupported architecture: $ARCH (supported: x86_64, aarch64)"
fi

NIX_TARBALL_URL="https://releases.nixos.org/nix/nix-${NIX_VERSION}/nix-${NIX_VERSION}-${NIX_SYSTEM}.tar.xz"

# Need wget or curl
if command -v wget &>/dev/null; then
    DOWNLOAD_CMD="wget -q -O"
elif command -v curl &>/dev/null; then
    DOWNLOAD_CMD="curl -fsSL -o"
else
    die "wget or curl is required"
fi

echo "Creating Nix rootfs..."
echo "  Nix:     $NIX_VERSION"
echo "  Arch:    $ARCH"
echo "  Output:  $OUTPUT_DIR"
if [[ -n "$PACKAGES" ]]; then
    echo "  Extra packages: $PACKAGES"
fi
if [[ -n "$TARGET_USER" ]]; then
    echo "  Owner:   $TARGET_USER"
fi
echo

# Download Nix binary tarball
WORK_DIR=$(mktemp -d)
echo "Downloading Nix ${NIX_VERSION}..."
$DOWNLOAD_CMD "$WORK_DIR/nix.tar.xz" "$NIX_TARBALL_URL"

echo "Extracting Nix tarball..."
tar xf "$WORK_DIR/nix.tar.xz" -C "$WORK_DIR"
NIX_EXTRACTED="$WORK_DIR/nix-${NIX_VERSION}-${NIX_SYSTEM}"
if [[ ! -d "$NIX_EXTRACTED" ]]; then
    die "Unexpected tarball structure (expected $NIX_EXTRACTED)"
fi

# Find the nix store path in the tarball (store paths have hash prefixes)
NIX_STORE_PATH=$(cd "$NIX_EXTRACTED/store" && ls -1d *-nix-"${NIX_VERSION}" 2>/dev/null | head -1) || true
if [[ -z "$NIX_STORE_PATH" ]]; then
    die "Could not find nix store path in tarball"
fi

# Find the cacert store path
CACERT_STORE_PATH=$(cd "$NIX_EXTRACTED/store" && ls -1d *-nss-cacert-* 2>/dev/null | head -1) || true
if [[ -z "$CACERT_STORE_PATH" ]]; then
    echo "Warning: could not find nss-cacert in tarball, skipping CA cert setup"
fi

# Create the rootfs skeleton
echo "Creating rootfs skeleton..."
mkdir -p "$OUTPUT_DIR"

# Basic directory structure
mkdir -p "$OUTPUT_DIR"/{bin,dev,etc,proc,tmp,var/tmp,root,usr/bin,nix/store,nix/var/nix}
chmod 1777 "$OUTPUT_DIR/tmp" "$OUTPUT_DIR/var/tmp"

# Minimal /etc/passwd and /etc/group
cat > "$OUTPUT_DIR/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:Nobody:/:/sbin/nologin
EOF

cat > "$OUTPUT_DIR/etc/group" <<'EOF'
root:x:0:
nobody:x:65534:
EOF

cat > "$OUTPUT_DIR/etc/shadow" <<'EOF'
root:!:1::::::
nobody:!:1::::::
EOF
chmod 640 "$OUTPUT_DIR/etc/shadow"

# Hostname and basic config
echo "nix-jail" > "$OUTPUT_DIR/etc/hostname"
echo "127.0.0.1 localhost nix-jail" > "$OUTPUT_DIR/etc/hosts"

# Copy store paths into the rootfs
echo "Installing Nix store paths..."
for storepath in "$NIX_EXTRACTED/store/"*; do
    name=$(basename "$storepath")
    cp -RP --preserve=ownership,timestamps "$storepath" "$OUTPUT_DIR/nix/store/$name.$$"
    chmod -R a-w "$OUTPUT_DIR/nix/store/$name.$$"
    chmod +w "$OUTPUT_DIR/nix/store/$name.$$"
    mv "$OUTPUT_DIR/nix/store/$name.$$" "$OUTPUT_DIR/nix/store/$name"
    chmod -w "$OUTPUT_DIR/nix/store/$name"
done

# Find the bash from the nix store for use as /bin/sh
BASH_STORE_PATH=$(cd "$OUTPUT_DIR/nix/store" && ls -1d *-bash-* 2>/dev/null | head -1) || true
if [[ -n "$BASH_STORE_PATH" && -x "$OUTPUT_DIR/nix/store/$BASH_STORE_PATH/bin/bash" ]]; then
    ln -sf "/nix/store/$BASH_STORE_PATH/bin/bash" "$OUTPUT_DIR/bin/bash"
    ln -sf "/nix/store/$BASH_STORE_PATH/bin/bash" "$OUTPUT_DIR/bin/sh"
else
    die "Could not find bash in nix store for /bin/sh"
fi

# /usr/bin/env is needed for #!/usr/bin/env shebangs
cat > "$OUTPUT_DIR/usr/bin/env" <<'ENVSCRIPT'
#!/bin/sh
exec "$@"
ENVSCRIPT
chmod +x "$OUTPUT_DIR/usr/bin/env"

# Set up CA certificates from the nix store
if [[ -n "$CACERT_STORE_PATH" ]]; then
    mkdir -p "$OUTPUT_DIR/etc/ssl/certs"
    CERT_FILE="$OUTPUT_DIR/nix/store/$CACERT_STORE_PATH/etc/ssl/certs/ca-bundle.crt"
    if [[ -f "$CERT_FILE" ]]; then
        ln -sf "/nix/store/$CACERT_STORE_PATH/etc/ssl/certs/ca-bundle.crt" "$OUTPUT_DIR/etc/ssl/certs/ca-bundle.crt"
        ln -sf "/nix/store/$CACERT_STORE_PATH/etc/ssl/certs/ca-bundle.crt" "$OUTPUT_DIR/etc/ssl/certs/ca-certificates.crt"
    fi
fi

# Write nix.conf for single-user mode
# (must exist before running nix commands to avoid nixbld group errors)
mkdir -p "$OUTPUT_DIR/etc/nix"
cat > "$OUTPUT_DIR/etc/nix/nix.conf" <<'EOF'
# Configured for single-user mode inside a jail.
# No daemon, no build users, no sandboxing.
sandbox = false
filter-syscalls = false
build-users-group =
experimental-features = nix-command flakes
EOF

echo "Registering Nix store paths..."
run_in_rootfs "/nix/store/$NIX_STORE_PATH/bin/nix-store --load-db" < "$NIX_EXTRACTED/.reginfo"

echo "Setting up Nix profile..."
CACERT_CMD=""
if [[ -n "$CACERT_STORE_PATH" ]]; then
    CACERT_CMD="&& /nix/store/$NIX_STORE_PATH/bin/nix-env -i /nix/store/$CACERT_STORE_PATH"
fi
run_in_rootfs "/nix/store/$NIX_STORE_PATH/bin/nix-env -i /nix/store/$NIX_STORE_PATH $CACERT_CMD"

echo "Installing coreutils..."
run_in_rootfs "HOME=/root USER=root NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt /nix/store/$NIX_STORE_PATH/bin/nix profile add nixpkgs#coreutils"

# Install extra packages if requested
if [[ -n "$PACKAGES" ]]; then
    # Convert comma-separated packages to space-separated
    PACKAGES="${PACKAGES//,/ }"
    for pkg in $PACKAGES; do
        echo "Installing $pkg..."
        run_in_rootfs "HOME=/root USER=root NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt /nix/store/$NIX_STORE_PATH/bin/nix profile add nixpkgs#$pkg"
    done
fi

# Set up /root/.profile to source nix environment and set PATH
mkdir -p "$OUTPUT_DIR/root"
cat > "$OUTPUT_DIR/root/.profile" <<'PROFILE'
if [ -e /root/.nix-profile/etc/profile.d/nix.sh ]; then
    . /root/.nix-profile/etc/profile.d/nix.sh
fi
export NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
export NIX_PATH=nixpkgs=flake:nixpkgs
PROFILE

cat > "$OUTPUT_DIR/root/.bashrc" <<'BASHRC'
[ -f /root/.profile ] && . /root/.profile
BASHRC

# Clean up files that cause issues with unprivileged import:
# 1. Remove device nodes - ajail mounts its own /dev anyway
# 2. Remove setuid/setgid bits - they don't work in user namespaces
# 3. Ensure all files are readable by owner (for copying)
echo "Cleaning up for unprivileged import..."
rm -rf "$OUTPUT_DIR/dev/"* 2>/dev/null || true
find "$OUTPUT_DIR" -perm /6000 -type f -exec chmod ug-s {} \; 2>/dev/null || true
chmod -R u+r "$OUTPUT_DIR"

# Change ownership if requested
if [[ -n "$TARGET_USER" ]]; then
    echo "Changing ownership to $TARGET_USER..."
    chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" "$OUTPUT_DIR"
fi

echo
echo "Nix rootfs created successfully at: $OUTPUT_DIR"
echo
echo "Usage inside ajail:"
echo "  nix profile add nixpkgs#git"
echo "  nix profile add nixpkgs#python3"
echo "  nix profile add nixpkgs#nodejs"
echo
echo "Note: use ajail --fs-edit to persist /nix/store across sessions,"
echo "otherwise installed packages will be lost."
