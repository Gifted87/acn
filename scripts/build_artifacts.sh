#!/bin/bash
set -e

# Configuration
KERNEL_URL="https://s3.amazonaws.com/spec.ccfc.min/img/quickstart_guide/x86_64/kernels/vmlinux-5.10.186"
ROOTFS_NAME="rootfs.ext4"
PRIV_DIR="priv"
NATIVE_DIR="native/acn_pilot"

echo "[Build] Starting ACN Firecracker Artifact Build..."

# 1. Ensure Priv Directory
mkdir -p $PRIV_DIR

# 2. Download Kernel (if missing)
if [ ! -f "$PRIV_DIR/vmlinux" ]; then
    echo "[Build] Downloading Kernel (vmlinux)..."
    curl -L -o "$PRIV_DIR/vmlinux" "$KERNEL_URL"
else
    echo "[Build] Kernel (vmlinux) exists. Skipping."
fi

# 3. Build ACN Pilot (Guest Agent)
echo "[Build] Compiling ACN Pilot (Rust)..."
if command -v cargo >/dev/null 2>&1; then
    cd $NATIVE_DIR
    # Build for musl (static) to run on Alpine
    rustup target add x86_64-unknown-linux-musl || true
    cargo build --release --target x86_64-unknown-linux-musl
    cp target/x86_64-unknown-linux-musl/release/acn_pilot ../../$PRIV_DIR/acn_pilot
    cd -
else
    echo "[Error] Cargo not found. Cannot build Guest Agent."
    exit 1
fi

# 4. Generate RootFS (via Docker)
echo "[Build] Generating RootFS via Docker..."
if command -v docker >/dev/null 2>&1; then
    # Create temp Dockerfile
    cat <<EOF > Dockerfile.rootfs
    FROM elixir:1.14-alpine
    # Install libs if needed, usually alpine is minimal
    # Copy Pilot as PID 1
    COPY priv/acn_pilot /sbin/init
    # Ensure proper permissions
    RUN chmod +x /sbin/init
    # Create mount points
    RUN mkdir -p /sys /proc /mnt/workspace
EOF

    # Build Image
    docker build -t acn_rootfs -f Dockerfile.rootfs .
    
    # Export to Tar
    id=$(docker create acn_rootfs)
    docker export $id > rootfs.tar
    docker rm $id
    
    # Convert Tar to Ext4 (requires virt-make-fs or root)
    if command -v virt-make-fs >/dev/null 2>&1; then
        echo "[Build] Converting tar to ext4..."
        virt-make-fs --format=raw --type=ext4 --size=+100M rootfs.tar $PRIV_DIR/$ROOTFS_NAME
        rm rootfs.tar
        rm Dockerfile.rootfs
        echo "[Success] RootFS created at $PRIV_DIR/$ROOTFS_NAME"
    else
        echo "[Warning] 'virt-make-fs' not found. Left 'rootfs.tar' for manual conversion."
        echo "Install libguestfs-tools or run: virt-make-fs --format=raw --type=ext4 rootfs.tar priv/rootfs.ext4"
    fi
else
    echo "[Error] Docker not found. Cannot build RootFS."
    exit 1
fi

echo "[Build] Complete."
