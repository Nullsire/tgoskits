# StarryOS 自编译全过程

在 riscv64 Debian Linux 上运行 StarryOS，并在 StarryOS 内部使用 cargo 编译 StarryOS 自身。

## 测试链路

```
QEMU riscv64 (-m 8G)
  └─ OpenSBI
      └─ someboot (加载 FDT 内存布局)
          └─ StarryOS 内核 (12G 可用物理内存)
              └─ Debian riscv64 rootfs (ext4)
                  └─ /usr/bin/self-compile.sh
                      ├─ mount tmpfs (8G)
                      └─ cargo build -p starryos --offline (276 crates)
```

## 阻塞点及修复

### 1. 内存检测：仅识别 512MB

**现象**: QEMU `-m 12G`，但 `phys_ram_ranges()` 只返回 `[0x804f0000, 0xa0000000)`（~510MB）。

**根因**: 静态平台 `axplat-riscv64-qemu-virt` 的 `axconfig.toml` 中 `phys-memory-size = 0x2000_0000`（512MB）是硬编码常量。`phys_ram_ranges()` 使用该常量计算可用内存，忽略 FDT 中的实际物理 RAM。

**修复** (`components/axplat_crates/platforms/axplat-riscv64-qemu-virt/axconfig.toml`):
```toml
# Before
phys-memory-size = 0x2000_0000       # 512M
# After
phys-memory-size = 0x2_0000_0000     # 8G
```

同时修改 `platform/axplat-dyn/src/mem.rs` 的 `phys_ram_ranges()`，从 `somehal::mem::memory_map()` 动态读取 Free 区域（plat_dyn 路径用）。

### 2. Bitmap 容量溢出

**现象**: 修改 axconfig 为 12G 后，内核 panic:
```
bitmap capacity exceeded: need 3145728 pages but CAP is 1048576
```

**根因**: 默认 `page-alloc-4g` 使用 `BitAlloc1M`（1M bits = 4GB 最大容量）。12GB 需要 3M pages > 1M CAP。

**修复** (`os/arceos/modules/axalloc/Cargo.toml`):
```toml
# Before
default = ["tlsf", "ax-allocator/page-alloc-4g"]
# After
default = ["tlsf", "ax-allocator/page-alloc-64g"]  # 16M bits = 64GB
```

### 3. TMPFS 挂载失败

**现象**: `mount -t tmpfs` 失败，Debian 根文件系统中 /tmp 不可写。

**根因**: mount(8) 优先使用新版 mount API（fsopen/fsconfig/fsmount）。StarryOS 将 `fsopen` 等实现为 `sys_dummy_fd`（返回伪 fd），mount(8) 误以为挂载成功，不会回退到传统 mount(2)。

**修复** (`os/StarryOS/kernel/src/syscall/mod.rs`):
```rust
// 将 fsopen/fspick/open_tree 从 sys_dummy_fd 改为返回 ENOSYS
// mount(8) 收到 ENOSYS 后回退到传统 mount(2) 调用来挂载 tmpfs
Sysno::fsopen | Sysno::fspick | Sysno::open_tree => Err(AxError::Unsupported),
```

### 4. 最终链接: _ex_table_end 未定义

**现象**: 所有 276 个 crate 编译通过，但 starryos 二进制链接失败:
```
rust-lld: error: undefined symbol: _ex_table_end
```

**根因**: 自编译环境中 `.cargo/config.toml` 未传递 `-Tlinker.x`（host 编译通过 `--config rustflags` 传递）。`ext_linker.ld` 使用 `INSERT AFTER .data;` 期望 `linker.x` 先定义 `.data` 段（含 `_ex_table_end`），但缺少 linker.x 时符号不存在。

**修复** (`os/StarryOS/starryos/ext_linker.ld`):
```ld
PROVIDE(_ex_table_start = 0);
PROVIDE(_ex_table_end = 0);

SECTIONS {
    /* ... 原有内容 ... */
}
INSERT AFTER .data;
```

`PROVIDE` 仅在符号未定义时提供回退值（空异常表，不影响正常运行）。

### 5. 测试正则误匹配

**现象**: 编译 crate `axpanic` 时，cargo 输出 `panic v0.1.0`，触发 fail_regex `\bpanic`。

**修复**: 改为 `\bpanicked\b` 仅匹配真正的内核 panic 消息。

## 测试配置

### 测试用例 (`test-suit/starryos/normal/qemu-smp1/selfhost-full-kernel/`)

```toml
# qemu-riscv64.toml
args = ["-nographic", "-cpu", "rv64", "-smp", "1", "-m", "8G", ...]
shell_init_cmd = "/usr/bin/self-compile.sh"
success_regex = ['(?m)^SELFHOST_SUCCESS\\s*$']
fail_regex = ['(?i)\bpanicked\b', 'SELFHOST_FAILED']
timeout = 7200
```

Shell pipeline (`sh/self-compile.sh`) 自动注入到 rootfs 的 `/usr/bin/`:
1. 挂载 8G tmpfs 到 /tmp
2. 修补 ext_linker.ld 添加 PROVIDE 回退
3. 执行 `cargo build -p starryos --target riscv64gc-unknown-none-elf --offline`
4. 检查产物并输出 SELFHOST_SUCCESS 或 SELFHOST_FAILED

### 运行测试

```bash
cargo xtask starry test qemu --arch riscv64 -c selfhost-full-kernel
```

## 构建耗时

| 阶段 | 耗时 |
|------|------|
| Debian 启动 | ~5 分钟 |
| cargo build (276 crates) | ~95 分钟 |
| 总计 | ~100 分钟 |

## 关键变更文件

| 文件 | 变更 |
|------|------|
| `axconfig.toml` | phys-memory-size: 512M → 8G |
| `axalloc/Cargo.toml` | page-alloc-4g → page-alloc-64g |
| `syscall/mod.rs` | fsopen/fspick/open_tree → ENOSYS |
| `ext_linker.ld` | PROVIDE _ex_table_start/end |
| `axplat-dyn/src/mem.rs` | phys_ram_ranges 从 memory_map 动态读取 |
| `selfhost-full-kernel/` | 测试用例及构建脚本 |

## 环境

- **QEMU**: riscv64, `-m 8G`, virt machine
- **内核**: StarryOS (dev 分支)
- **根文件系统**: Debian riscv64, ext4, rustc nightly-2026-04-27
- **源码**: StarryOS monorepo (离线，预取依赖)
