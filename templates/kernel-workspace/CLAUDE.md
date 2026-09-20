# Kernel work area

Each subdirectory of this tree is expected to be a Linux kernel source
worktree (`git worktree add ...` or a plain clone). The `.envrc` here
activates the `kdev` devShell via direnv, so the tools below land on
`PATH` whenever you `cd` into any worktree.

## Tooling on PATH (inside the devShell)

- `kdev` — boot the current tree's kernel in a NixOS VM (KVM on the
  host). Auto-detects `--kernel` by walking up from `$PWD` to a tree
  root (`Kbuild` + `MAINTAINERS`), then trying
  `<tree>/build/arch/x86/boot/bzImage`.
- `kmake-aarch64`, `kmake-riscv`, `kmake-powerpc64`, `kmake-powerpc64le`,
  `kmake-loongarch64`, `kmake-mips64`, `kmake-s390x`, `kmake-arm` —
  cross-compile wrappers. Each bundles a GCC + binutils for that target
  and execs `make` with `ARCH` / `CROSS_COMPILE` preset.
- `nix run <kdev>#vm-aarch64` / `#vm-aarch64-tfa` — arm64 guests under
  TCG; the second boots through Trusted Firmware-A (real EL3, PSCI, SDEI).
  Diskless boots take `--initrd` with `<kdev>#initramfs-aarch64`.
- `kmake-syz` — `make` wrapper defaulting `O=<tree>/build-syz` for a
  dedicated KCOV+KASAN fuzzing build.
- `syz-config-check PATH` — audits a `.config` for syzkaller's required
  symbols and prints a ready-to-paste `scripts/config` fix line.
- `syz-init WORKDIR` — scaffolds a syzkaller workdir with SSH keys and
  a `syz.cfg` pointing at the right store paths for the harness.
- `syz-manager` — syzkaller itself, from nixpkgs.
- `drgn`, `gdb`, `bpftrace`, `trace-cmd`, `bpftools`, `pahole`, `perf`,
  `strace`, `qemu-system-x86_64`, `qemu-img`, `clang`/`lld`, `spatch`
  (Coccinelle, for `make coccicheck`) and the usual kernel build deps.

## Automation-friendly patterns (shell scripts / CI / Claude)

```sh
# Run a one-liner inside the guest; stdout = test's stdout only.
# rc: 0..127 = test's exit code, 124 = --run-timeout, 125 = VM didn't
# complete (early panic, boot failure, kdev-run service crash).
kdev --quiet --run 'echo hello; uname -r' --run-timeout 60

# Preserve log/exit/dmesg/serial.log after a run for post-mortem:
kdev --quiet --run './reproduce.sh' --keep-artifacts ./out/

# Capture a drgn-readable crash dump on guest panic:
kdev --quiet --run 'echo c > /proc/sysrq-trigger' --crash-dump ./panic.core
drgn -c ./panic.core -s $(pwd)/build/vmlinux

# Attach gdb to kernel before first instruction:
kdev --gdb-wait           # terminal 1 — freezes CPU at entry
gdb $(pwd)/build/vmlinux -ex 'target remote :1234'  # terminal 2

# QEMU -d tracing for MMU/interrupt debugging (requires TCG, no KVM):
kdev --tcg -- -d mmu,int,guest_errors -D /tmp/qemu-trace.log
```

## Required kernel configs for the harness

Flip these in any `.config` you plan to boot under `kdev`:

- Shares (virtiofs): `CONFIG_FUSE_FS=y`, `CONFIG_VIRTIO_FS=y`,
  `CONFIG_VIRTIO_PCI=y`.
- Crash dump: `CONFIG_PVPANIC=y`, `CONFIG_PVPANIC_PCI=y`.
- Module share (only if `--modules-install` is used): `CONFIG_MODULES=y`.
- Debug symbols for drgn/gdb: `CONFIG_DEBUG_INFO=y` (and
  `CONFIG_GDB_SCRIPTS=y` for `lx-*` helpers).

`kdev` parses `.config` before booting and aborts with the exact
`scripts/config` line if shares-required symbols are missing.

## Conventions

- Build dirs live inside each worktree: `build/` (native perf),
  `build-<arch>/` (cross), `build-syz/` (fuzzing). Nothing is hardcoded
  to a specific worktree — `kdev` auto-detects the tree root from
  `$PWD`.
- Host shares: `$HOME/git` and `$HOME/var` are virtiofs-shared into the
  guest at `/home/kas/git` and `/home/kas/var` (the in-guest mount
  points are hardcoded to `kas` regardless of the host user — that's
  the guest's login user).
- The guest auto-logs in as `kas` (password `test`, root password
  `test`). Drop your syzkaller SSH `authorized_keys` at
  `$HOME/var/.syz/authorized_keys` so the in-guest sshd picks it up.

## Full reference

See the kdev flake's README for every flag, the VM internals, the
selftest list, and the drgn / syzkaller recipes in detail.
