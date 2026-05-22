#!/usr/bin/bash
set -euo pipefail

echo "SELFHOST_START"
export PATH=/root/.cargo/bin:/usr/local/bin:$PATH
export RUSTUP_HOME=/root/.rustup
export CARGO_HOME=/root/.cargo

echo "RUSTC=$(rustc --version)"
echo "CARGO=$(cargo --version)"
echo "FREE_KB=$(df /opt | tail -1 | awk '{print \$4}')"

echo "MOUNT_TEST_START"
mount -t tmpfs -o size=8G tmpfs /tmp
echo "TMPFS_MOUNTED"
df -h /tmp

export CARGO_TARGET_DIR=/tmp/build/target
export CARGO_BUILD_JOBS=1
mkdir -p "$CARGO_TARGET_DIR"

cd /opt/starryos

# Apply ext_linker.ld fix for self-compilation
cat > os/StarryOS/starryos/ext_linker.ld << 'LINKER_EOF'
PROVIDE(_ex_table_start = 0);
PROVIDE(_ex_table_end = 0);

SECTIONS {
    .static_keys : {
        __start___static_keys = .;
        KEEP(*(__static_keys))
        __stop___static_keys = .;
    }

    .dyndbg : {
        __start___dyndbg = .;
        KEEP(*(__dyndbg))
        __stop___dyndbg = .;
    }
}

INSERT AFTER .data;
LINKER_EOF
echo "LINKER_FIXED"

echo "CARGO_BUILD_START"
cargo build -p starryos --target riscv64gc-unknown-none-elf --offline 2>&1
echo "CARGO_BUILD_PASSED"

BINARY=/tmp/build/target/riscv64gc-unknown-none-elf/debug/starryos
if [ -f "$BINARY" ] && [ -s "$BINARY" ]; then
    echo "BINARY_EXISTS"
    ls -la "$BINARY"
    echo "SELFHOST_SUCCESS"
else
    echo "BINARY_MISSING"
    echo "SELFHOST_FAILED"
fi
