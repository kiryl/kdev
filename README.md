# kdev

A Nix flake for Linux kernel development: fast VM boot of user-built kernels,
cross-compile shells for every arch kbuild CI covers, and debug tooling.

## What you get

- `nix run .#vm` — boots your freshly-built kernel in ~2 s against a stable
  NixOS rootfs (no image rebuild on kernel change). Direct `-kernel` boot, no
  initrd required.
- `nix develop` — native build + debug shell (`gdb`, `drgn`, `bpftrace`,
  `trace-cmd`, `bpftools`, `pahole`, `perf`, `strace`, `clang`/`lld`, qemu).
- `nix develop .#<arch>` — cross-compile shells with `ARCH` and
  `CROSS_COMPILE` preset (aarch64, riscv, powerpc64, powerpc64le,
  loongarch64, mips64, s390x, arm).
- `nix flake check` — hermetic selftests for `kdev`'s arg parsing and
  config validation, plus a cross-compile smoke check.

## Requirements

- Linux host with Nix + flakes enabled.
- `/dev/kvm` accessible for x86_64 (the native VM uses KVM acceleration).
- x86_64 host (the native VM image targets x86_64; the aarch64 image is
  cross-built — see below).
- A kernel worktree somewhere on the host. All tooling that takes a
  kernel path auto-detects by walking up from `$PWD` until it finds a
  tree root (`Kbuild` + `MAINTAINERS`), so it works from any worktree
  under e.g. `~/linux/`. Override with an explicit flag when needed.

## Quick start

```sh
# one-time (pulls NixOS image closure from cache)
nix build .#vm-image

# build a kernel (in any worktree)
cd ~/linux/<worktree>
make O=build defconfig
make O=build -j$(nproc)

# boot it
nix run .#vm
```

`kdev` picks `--kernel` in this order: `./arch/x86/boot/bzImage` →
`./build/arch/x86/boot/bzImage` → walk up from `$PWD` to a kernel tree
root and try `<tree>/build/arch/x86/boot/bzImage` then
`<tree>/arch/x86/boot/bzImage`. Runs from `~/linux/torvalds/`,
`~/linux/mm/fs/btrfs/`, etc. — wherever you are in a kernel tree.

### direnv integration

If you use `direnv` with `nix-direnv`, drop this at the root of your kernel
work area (e.g. `~/linux/.envrc`):

```sh
use flake ~/git/kdev
```

Then `cd` into any worktree (e.g. `~/linux/<worktree>`) auto-enters the default shell — `kdev`,
`drgn`, `gdb`, `bpftrace`, the qemu binaries, and every native kbuild dep
are on `PATH`. Subsequent examples in this README use `kdev` directly
assuming this layer is active; `nix run ~/git/kdev#vm` is the
equivalent if it isn't.

For a one-step scaffold (`.envrc` + a `CLAUDE.md` digest of the tooling
on PATH, automation patterns, and the required kernel configs), use the
flake template:

```sh
cd ~/linux           # or wherever your kernel worktrees live
nix flake init -t ~/git/kdev#kernel-workspace
direnv allow
```

The generated `CLAUDE.md` is auto-loaded by Claude Code for any session
launched under that directory, so any Claude working in a worktree
discovers the harness without needing to be re-briefed.

For cross-compiling the same tree to multiple arches without swapping
shells, the default shell ships one `kmake-<arch>` wrapper per cross
target — see [cross compilation](#cross-compilation) below. These work
from any kernel dir the existing `.envrc` activates the default shell
in, so a single `~/linux/.envrc` covers native + every cross arch.

Per-arch `.envrc` layering is still useful if you prefer the cross gcc
on `PATH` directly (e.g. to run `aarch64-unknown-linux-gnu-gcc` without
going through `make`):

```sh
# <kernel-tree>/build-aarch64/.envrc
use flake ~/git/kdev#aarch64
```

One-liner to scaffold all eight (run inside a given worktree):

```sh
for arch in aarch64 riscv powerpc64 powerpc64le loongarch64 mips64 s390x arm; do
  dir=build-$arch
  mkdir -p "$dir"
  echo "use flake ~/git/kdev#$arch" > "$dir/.envrc"
  direnv allow "$dir"
done
```

#### Picking up flake edits

`nix-direnv` caches the evaluated env and only re-evaluates when a watched
file's mtime changes — by default that's `flake.lock` and `flake.nix`.
Edits to `kdev.nix`, `vm.nix`, or `checks.nix` alone won't trigger a
reload, so your shell will keep running the old `kdev`. Fix:

```sh
touch ~/git/kdev/flake.nix
```

Next `cd` into the tree re-evaluates. Alternatively, add the files to the
watch list so any source edit invalidates the cache:

```sh
# in ~/linux/.envrc, after `use flake ...`
nix_direnv_watch_file ~/git/kdev/flake.nix \
                      ~/git/kdev/kdev.nix \
                      ~/git/kdev/vm.nix \
                      ~/git/kdev/checks.nix
```

Kernel boot prerequisites:

- `CONFIG_VIRTIO_BLK=y` and `CONFIG_VIRTIO_PCI=y` (boot disk)
- `CONFIG_EXT4_FS=y` (root fs type)
- `CONFIG_FUSE_FS=y` and `CONFIG_VIRTIO_FS=y` (host shares via virtiofs)

x86_64 defconfig does NOT enable `CONFIG_VIRTIO_FS` / `CONFIG_FUSE_FS` —
enable them explicitly. One-liner:

```sh
scripts/config --file build/.config --enable FUSE_FS --enable VIRTIO_FS
make O=build olddefconfig
```

`kdev` parses your build's `.config` and aborts with a clear message
listing what's missing if any share is active. Pass `--no-share-git
--no-share-var` (and omit `--modules-install`) to skip the check.

No initrd is used — required drivers must be built in, not modules.

## Foreign-arch workflows (aarch64)

Cross-arch emulation lets you boot an arm64 kernel under TCG on an x86_64
host. Useful for experimenting with arch-specific features without arm64
hardware.

```sh
# one-time: cross-build the aarch64 rootfs (heavy — see prerequisite below)
nix build .#vm-image-aarch64

# in your kernel tree
kmake-aarch64 O=build-arm64 defconfig
scripts/config --file build-arm64/.config --enable FUSE_FS --enable VIRTIO_FS
kmake-aarch64 O=build-arm64 olddefconfig
kmake-aarch64 O=build-arm64 -j$(nproc)

# boot it (TCG; no KVM since host is x86)
nix run ~/git/kdev#vm-aarch64
```

The aarch64 kdev (`kdev-aarch64`) auto-detects `arch/arm64/boot/Image` the
same way the native variant finds `bzImage`. Cmdline rewrites
`console=ttyS0` → `ttyAMA0`; qemu launches with `-machine virt,gic-version=3
-cpu max`. All other features (`--gdb`, `--run`, `--crash-dump`,
`--modules-install`, virtiofs shares) work unchanged.

To use `kdev-aarch64` directly (e.g., from a script that already knows the
image path):

```sh
nix run ~/git/kdev#kdev-aarch64 -- --image $(nix build --no-link --print-out-paths ~/git/kdev#vm-image-aarch64)/<filename>.qcow2 ...
# or simpler — let the launcher resolve the image:
nix run ~/git/kdev#vm-aarch64 -- --gdb-wait
```

Without `--image`/`$KDEV_VM_IMAGE`, the bare `kdev-aarch64` aborts with a
pointer to `nix run .#vm-aarch64`.

### Prerequisite: cross-building the aarch64 image

`packages.vm-image-aarch64` is a full NixOS qcow2 built for aarch64-linux.
On an x86_64 host you need one of:

1. **binfmt-misc registered for aarch64** (recommended). On NixOS hosts,
   add to `/etc/nixos/configuration.nix`:

   ```nix
   boot.binfmt.emulatedSystems = [ "aarch64-linux" ];
   ```

   then `nixos-rebuild switch`. This registers qemu-user via binfmt so
   Nix can transparently run aarch64 build scripts during the image build.

2. **A remote aarch64 builder** configured in `nix.conf`.

3. **Cache-only build** — if the entire closure is on Hydra, no execution
   is needed. In practice the image's final assembly step usually requires
   running aarch64 code, so binfmt is the most reliable path.

Boot time under TCG is significantly slower than KVM-x86 (expect 10–30s to
userspace depending on host CPU). Drop `--cores` / `--memory` to keep
emulation overhead manageable.

## Native workflows

### Day-to-day

With direnv active in the kernel tree:

```sh
make -j$(nproc) && kdev
```

Without direnv:

```sh
make -j$(nproc) && nix run ~/git/kdev#vm
```

Exit the VM with `Ctrl-a x` (qemu monitor escape).

### Kernel debugging with gdb

```sh
# terminal 1
kdev --gdb-wait

# terminal 2
gdb $(pwd)/build/vmlinux -ex 'target remote :1234'
(gdb) hbreak start_kernel
(gdb) continue
```

`--gdb` attaches a gdbserver but boots immediately. `--gdb-wait` freezes the
CPU at entry so you can set early breakpoints. Either flag auto-appends
`nokaslr` so addresses match `vmlinux`. `--gdb-port N` overrides the default
1234.

Run `make scripts_gdb` once in your kernel tree to build the `lx-*` helpers
(`lx-ps`, `lx-dmesg`, …); gdb loads them automatically when you file-load
`vmlinux`.

### QEMU internal tracing (TCG mode)

For early-boot / MMU / interrupt debugging below the gdb stub's horizon,
run the guest under TCG and turn on qemu's `-d`:

```sh
kdev --tcg -c 2 -m 2048 -- -d mmu,int,guest_errors -D /tmp/qemu-trace.log
```

`--tcg` swaps `-enable-kvm`/`-cpu host` out of the qemu command line and
replaces them with `-cpu max`; everything else (virtiofs, memfd/numa,
serial, gdb, shares) works unchanged. `-d` knobs: `int`, `mmu`, `page`,
`exec`, `in_asm`, `cpu_reset`, `guest_errors`, `unimp` — run
`qemu-system-x86_64 -d help` for the full list. Output goes to stderr by
default; `-D PATH` redirects to a file. TCG boot is noticeably slower
than KVM, so dial down `--cores` / `--memory` if you only need a quick
trace.

Combine with `--gdb-wait` to attach gdb before any trace-producing
instruction runs.

### Iterating on a test case

Run a test inside the guest and get its exit code back on the host — good
for the edit-build-run loop:

```sh
# one-liner
kdev --run 'cd /home/kas/var/tests/foo && ./repro.sh' --run-timeout 60
echo "test rc=$?"

# stage a host script
kdev --run-script ./my-test.sh --run-timeout 60
```

What happens:

1. `kdev` writes the script to `$HOME/var/.kdev-run/run-<ts>-<pid>/script`
   (in the `$HOME/var` share the guest already sees at `/home/kas/var`).
2. `kdev.run=<that-path>` is appended to the kernel cmdline.
3. Inside the guest, `kdev-run.service` (oneshot, `After=multi-user.target`,
   `ConditionKernelCommandLine=kdev.run`) picks up the path, runs the
   script, tees stdout+stderr to `<dir>/log`, writes the exit code to
   `<dir>/exit`, then `systemctl --no-block poweroff`.
4. `kdev` reads `<dir>/exit` after qemu returns and exits with that code
   (124 on timeout or if the VM never wrote the file). The staging dir is
   removed by the host on exit.

Scripts execute as `root` inside the guest, output streams to the serial
console as it runs, and `--run-timeout` caps wall-clock time (qemu is
wrapped in `timeout --foreground --kill-after=5`). Because the stage dir
lives under `$HOME/var`, the run's log is still on disk on the host under
`$HOME/var/.kdev-run/...` if you interrupt kdev before cleanup.

`--run` and `--run-script` are mutually exclusive; `--no-share-var` turns
off the whole mechanism.

#### Running from CI / Claude / scripts

For automation, use `--quiet` so only the test's own stdout reaches the
caller's stdout — no boot logs, no qemu banners, no systemd spinner:

```sh
kdev --quiet --run 'echo HELLO; uname -r; echo BYE'
# prints exactly:
#   HELLO
#   7.0.0-rc6-...
#   BYE
# and exits with the test's rc
```

When `--run`/`--run-script` is set and `--run-timeout` is omitted,
`kdev` defaults the timeout to 120 s so a hung guest can't eat the
caller's tool-call budget.

Exit codes for the `--run` mode:

| rc | meaning |
| --- | --- |
| `0..127` | the test's own exit code (propagated verbatim) |
| `124` | `--run-timeout` elapsed; qemu was killed |
| `125` | VM ran but wrote no exit file (early panic, boot failure, kdev-run.service itself failed) |

On failure, keep the staging dir on the host for post-mortem:

```sh
kdev --quiet --run './reproducer.sh' --keep-artifacts ./last-run
# ./last-run/ contains:
#   script    the exact script that was staged
#   log       test stdout+stderr
#   exit      test exit code (same file the service wrote)
#   dmesg     full dmesg from that boot
#   serial.log full serial console (only in --quiet mode)
```

The staging dir can be anywhere the target doesn't exist yet; the parent
is created if needed. Without `--keep-artifacts`, the stage dir under
`$HOME/var/.kdev-run/run-<ts>-<pid>/` is removed by `kdev` on exit.

### Kernel crash dumps + drgn

When the guest panics, `kdev --crash-dump PATH` writes an ELF crash
dump to PATH that `drgn` can read with full symbol resolution.

Prerequisites in the guest kernel `.config`:

```
CONFIG_PVPANIC=y
CONFIG_PVPANIC_PCI=y
CONFIG_VMCORE_INFO=y    # implied by CONFIG_DEBUG_INFO=y
CONFIG_DEBUG_INFO=y     # for drgn to read DWARF
```

`kdev` aborts with the exact scripts/config line to run if `PVPANIC`
or `PVPANIC_PCI` is missing.

Reproduce + capture:

```sh
kdev --quiet \
  --run 'echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger' \
  --crash-dump ./panic.core
# rc=125 (guest never finished the test — expected for a deliberate crash)
```

What happens under the hood:

1. `kdev` adds `-device pvpanic-pci` and `-action panic=pause` to qemu
   and opens a unix-socket monitor.
2. Guest's pvpanic driver signals qemu when panic fires; qemu pauses
   instead of auto-resetting.
3. A background socat loop in `kdev` polls `info status`; on
   `paused (guest-panicked)` it runs `dump-guest-memory -p PATH` and
   `quit`. The dump is an ELF core containing guest RAM + the
   `vmcoreinfo` PT_NOTE qemu already wires in via `-device vmcoreinfo`.

Load it in drgn:

```sh
drgn -c ./panic.core -s $(pwd)/build/vmlinux
```

Typical first things to look at:

```py
# crashed task + its stack
t = prog.crashed_thread()
print(t.object.comm.string_().decode(), int(t.object.pid))
for f in t.stack_trace():
    print(f)

# kernel release sanity
prog["init_uts_ns"].name.release.string_()

# dmesg ring
from drgn.helpers.linux import log
for msg in log.get_printk_records(prog):
    print(msg.text.decode(errors='replace'))

# iterate tasks
from drgn.helpers.linux import tasks
for t in tasks.for_each_task(prog):
    print(int(t.pid), t.comm.string_().decode())
```

drgn is already in the default devShell (via `./drgn.nix`), so these
commands work as-is once you've `cd`'d into the kernel tree with direnv
active.

### Fuzzing with syzkaller

`syz-manager` is in the default shell; two wrappers scaffold the rest:

```sh
# 1. Keep a dedicated syz build dir alongside your perf build.
cp -a build build-syz

# 2. Flip syzkaller-required configs (KCOV, KASAN, fault injection, ...).
syz-config-check build-syz/.config
# If missing, paste the `scripts/config ... --enable ...` line it prints,
# then:
make O=build-syz olddefconfig
kmake-syz -j$(nproc)     # same as `make O=<tree>/build-syz $@`

# 3. Scaffold a workdir + SSH key + syz.cfg.
syz-init /tmp/syz-work
# Generates ~/var/.syz/{id_ed25519,authorized_keys} if missing; writes
# /tmp/syz-work/syz.cfg pointing at packages.vm-image and
# pkgs.syzkaller with cmdline override for our root=/dev/vda2 layout.

# 4. Run.
cd /tmp/syz-work && syz-manager -config syz.cfg
# Web UI: http://127.0.0.1:56741
# Crashes: /tmp/syz-work/work/crashes/
```

How it fits together:

- **SSH-key injection via virtiofs.** `vm.nix` has
  `services.openssh.authorizedKeysFiles` prepend
  `/home/kas/var/.syz/authorized_keys` — a path in the existing
  `$HOME/var` share. `syz-init` drops the pubkey there on the host;
  sshd in the guest reads it at connection time. No image rebuild per
  key.
- **Shared rootfs, swapped kernel.** syzkaller boots `packages.vm-image`
  with its own qemu invocation and passes `--kernel
  build-syz/arch/x86/boot/bzImage` from your syz-build dir. The daily
  `kdev` flow is untouched.
- **One tree, two configs.** `build/` stays KCOV-free for
  performance-sensitive work; `build-syz/` carries the fuzzing
  instrumentation. `kmake-syz` is a five-line wrapper that defaults
  `O=<tree>/build-syz` (detected by walking up from `$PWD`), so you can `kmake-syz menuconfig`
  etc. without typing the `O=` every time.

Required kernel configs (what `syz-config-check` verifies):

- Coverage: `CONFIG_KCOV`, `CONFIG_KCOV_INSTRUMENT_ALL`
- Debuginfo: `CONFIG_DEBUG_INFO`
- Sanitizers: `CONFIG_KASAN` + `CONFIG_KASAN_INLINE`, `CONFIG_UBSAN`
- Locking/RCU checks: `CONFIG_LOCKDEP`, `CONFIG_PROVE_LOCKING`,
  `CONFIG_DEBUG_ATOMIC_SLEEP`, `CONFIG_PROVE_RCU`, `CONFIG_DEBUG_LIST`
- Fault injection: `CONFIG_FAULT_INJECTION`,
  `CONFIG_FAULT_INJECTION_DEBUG_FS`, `CONFIG_FAILSLAB`,
  `CONFIG_FAIL_PAGE_ALLOC`, `CONFIG_FAIL_MAKE_REQUEST`,
  `CONFIG_FAIL_IO_TIMEOUT`, `CONFIG_FAIL_FUTEX`
- Harness shares/panic: `CONFIG_FUSE_FS`, `CONFIG_VIRTIO_FS`,
  `CONFIG_VIRTIO_PCI`, `CONFIG_PVPANIC`, `CONFIG_PVPANIC_PCI`
- Must be `=n`: `CONFIG_RANDOMIZE_BASE` (deterministic symbol
  addresses for crash dedup).

Crash triage: syzkaller lands crashes under
`$WORKDIR/work/crashes/<hash>/`. For a drgn session against a
particular crash, combine with this harness's crash-dump feature — boot
syzkaller's reproducer via `kdev --crash-dump ./panic.core` against
`build-syz/vmlinux`, then `drgn -c panic.core -s build-syz/vmlinux` (see
the crash-dump section).

syzkaller version comes from nixpkgs; the pin in `flake.lock` currently
tracks `0-unstable-2024-01-09`. To float forward, bump nixpkgs with
`nix flake update nixpkgs`.

Combine with `--keep-artifacts` to save the serial log + dmesg alongside
the core:

```sh
kdev --quiet --run 'reproduce-bug.sh' \
  --crash-dump ./panic.core \
  --keep-artifacts ./postmortem/
```

Then `./postmortem/log`, `./postmortem/dmesg`, `./postmortem/serial.log`,
and `./panic.core` together give you the full forensics set.

### In-VM modules

When you build a kernel with `=m` modules, install them somewhere on the
host and share with `--modules-install`:

```sh
make modules -j$(nproc)
make modules_install INSTALL_MOD_PATH=/tmp/mods
kdev --modules-install /tmp/mods
# inside VM:
modprobe foo
```

The share is mounted read-only at `/lib/modules` via virtiofs. `kdev`
validates the kernel's `.config` beforehand — if `CONFIG_{MODULES,FUSE_FS,
VIRTIO_FS,VIRTIO_PCI}` isn't `=y`, it aborts before launching qemu.
Leave `--modules-install` off to skip the mount entirely.

### Persistence

By default the rootfs is ephemeral (`qemu -snapshot`). Changes in the VM
are discarded at exit.

- `--overlay PATH` uses a qcow2 overlay on top of the nix-store base — VM
  state persists in that overlay across runs.
- `--persist` copies the base image into `./kernel-vm.qcow2` and edits it
  in place. Destructive; the copy happens once, then every run writes to
  it.

## Cross compilation

The default shell exposes eight `kmake-<arch>` wrappers, each bundling
its own GCC 14.3.0 cross toolchain and `make` preset with the right
`ARCH` and `CROSS_COMPILE`. Use them from the kernel tree without
switching shells:

```sh
cd ~/linux/<worktree>
kmake-aarch64    O=build-arm64       defconfig && kmake-aarch64    O=build-arm64       -j$(nproc)
kmake-riscv      O=build-riscv       defconfig && kmake-riscv      O=build-riscv       -j$(nproc)
kmake-loongarch64 O=build-loongarch64 defconfig && kmake-loongarch64 O=build-loongarch64 -j$(nproc)
```

You can drive the same tree against multiple arches back-to-back in one
shell session. The wrappers forward all arguments to `make` verbatim, so
`kmake-aarch64 clean`, `kmake-aarch64 menuconfig`, etc. all work.

| Wrapper | ARCH | CROSS_COMPILE prefix |
| --- | --- | --- |
| `kmake-aarch64` | `arm64` | `aarch64-unknown-linux-gnu-` |
| `kmake-riscv` | `riscv` | `riscv64-unknown-linux-gnu-` |
| `kmake-powerpc64` | `powerpc` | `powerpc64-unknown-linux-gnuabielfv2-` |
| `kmake-powerpc64le` | `powerpc` | `powerpc64le-unknown-linux-gnu-` |
| `kmake-loongarch64` | `loongarch` | `loongarch64-unknown-linux-gnu-` |
| `kmake-mips64` | `mips` | `mips64-unknown-linux-gnuabi64-` |
| `kmake-s390x` | `s390` | `s390x-unknown-linux-gnu-` |
| `kmake-arm` | `arm` | `armv7l-unknown-linux-gnueabihf-` |

If you'd rather have the cross gcc on `PATH` directly (not behind `make`),
switch to the matching devShell:

```sh
nix develop ~/git/kdev#aarch64
# or per-build-dir .envrc — see "direnv integration"
```

`LLVM=1` also works — `clang` and `lld` are in every shell, so
`kmake-aarch64 LLVM=1 O=build-arm64 defconfig` picks up clang's
cross-targeting without needing the gcc wrapper.

Toolchain version: GCC 14.3.0, binutils 2.44 (via `pkgsCross` in pinned
nixpkgs-unstable).

## kdev reference

Run `nix run .#vm -- --help` for the full list. Key flags:

| Flag | Default | Notes |
| --- | --- | --- |
| `-k`, `--kernel PATH` | auto-detect | Path to `bzImage`. |
| `--initrd PATH` | none | Pass a matching initrd if you can't build drivers `=y`. |
| `-i`, `--image PATH` | nix-store qcow2 | Rootfs base image. |
| `-a`, `--append STR` | `""` | Extra kernel cmdline. |
| `--root DEV` | `/dev/vda2` | Root device argument. |
| `-m`, `--memory MB` | `8192` | Also `$VM_MEMORY`. |
| `-c`, `--cores N` | `8` | Also `$VM_CORES`. |
| `-o`, `--overlay PATH` | none (ephemeral) | Persistent qcow2 overlay. |
| `-p`, `--persist` | off | Edit the base image in place. |
| `-g`, `--gdb` | off | Enable qemu gdbserver on TCP. |
| `--gdb-wait` | off | Same + freeze CPU at entry. |
| `--gdb-port N` | `1234` | |
| `--modules-install DIR` | none | Share `DIR/lib/modules` at `/lib/modules`. |
| `--kernel-build DIR` | derived from `--kernel` | For `.config` and kver lookup. |
| `--no-share-git`, `--no-share-var` | off | Skip `~/git` / `~/var` virtiofs shares. |
| `--tcg` | off | TCG mode (no KVM, `-cpu max`); enables qemu `-d` tracing. |
| `--run CMD` | off | Run CMD inside the guest, poweroff, propagate exit code. |
| `--run-script PATH` | off | Same as `--run`, copying PATH from the host. |
| `--run-timeout SEC` | 120 with `--run*` | Kill qemu if the test hasn't finished. |
| `-q`, `--quiet` | off | Only the test's stdout reaches ours. Needs `--run`/`--run-script`. |
| `--keep-artifacts DIR` | off | Preserve log/exit/dmesg/serial.log in DIR instead of deleting. |
| `--crash-dump PATH` | off | On guest panic, write an ELF core to PATH (drgn-readable). |
| `--` | | Everything after is appended to the qemu command line. |

Each run pins the rootfs image in use as an indirect GC root under
`$XDG_STATE_HOME/kdev/vm-image-<arch>` (default `~/.local/state/kdev/`), so
`nix-collect-garbage` does not delete the image out from under the next
boot. Set `KDEV_NO_PIN=1` to skip that.

## Flake outputs

- `devShells.default` — native build + full debug tools.
- `devShells.<arch>` — cross-compile shell (see table above).
- `packages.vm-image` — NixOS qcow2 (x86_64), produced by
  `system.build.image` from `${nixpkgs}/nixos/modules/virtualisation/disk-image.nix`.
- `packages.vm-image-aarch64` — cross-built aarch64 NixOS qcow2 (needs
  binfmt-misc on the host; see *Foreign-arch workflows* above).
- `packages.kdev` — the qemu wrapper shell script (x86_64).
- `packages.kdev-aarch64` — qemu wrapper shell script targeting aarch64.
  Image is supplied via `$KDEV_VM_IMAGE` or `--image`; the bare script
  does not bake the image path so it builds without binfmt.
- `packages.default` — alias for `kdev`.
- `apps.vm` — `nix run .#vm` entry point.
- `apps.vm-aarch64` — `nix run .#vm-aarch64` entry point. Thin wrapper
  that sets `$KDEV_VM_IMAGE` to the cross-built aarch64 image and
  execs `kdev-aarch64` — building this app triggers the image build.
- `nixosConfigurations.kernel-vm` — the NixOS config that builds the
  rootfs. Edit `vm.nix` to add guest packages or settings.
- `nixosConfigurations.kernel-vm-aarch64` — aarch64 variant of the same
  config (consumes `vm.nix` with `kdevArch = "aarch64"`).
- `packages.{syz-config-check,syz-init,kmake-syz}` and matching
  `apps.syz-*` — syzkaller helpers (see *Fuzzing with syzkaller*).
- `checks.<arch>.*` — selftests, run with `nix flake check`.

## VM internals

- 32 GiB ext4 rootfs on `/dev/vda2`, ESP on `/dev/vda1` (unused by direct
  boot but kept for occasional bootloader-path testing).
- Serial console `ttyS0,115200` — VM runs with `-nographic`.
- Auto-login as user `kas` (password `test`, also root password `test`
  for emergency). `sshd` runs, DHCP via user-mode networking.
- Host shares via virtiofs with `x-systemd.automount`:
  `$HOME/git → /home/kas/git`, `$HOME/var → /home/kas/var`,
  `$MODULES_INSTALL/lib/modules → /lib/modules` (only when
  `--modules-install` is passed).
- Per share, `kdev` spawns a `virtiofsd` sidecar on a socket under a
  per-run tempdir and adds `-chardev socket,… -device
  vhost-user-fs-pci,…`. vhost-user-fs requires shared guest memory, so
  every run also includes `-object memory-backend-memfd,share=on` +
  `-numa node,memdev=mem` sized to `--memory`. `trap EXIT` kills the
  daemons and removes the tempdir when qemu exits.

The guest kernel inside the qcow2 (NixOS LTS) is unused in normal
workflow — `kdev` always overrides via `-kernel`. It's there because
`disk-image.nix` requires a bootable image, and for the rare case where
you want to boot the image directly with qemu-system-x86_64 and no
`-kernel`.

## Selftests

```sh
nix flake check
```

Runs hermetic checks for `kdev` argument parsing, config-validation
paths, and a cross-compile smoke test. Individual checks:

- `kdev-help` — every documented flag appears in `--help`.
- `kdev-unknown-flag` — unknown flag exits non-zero with useful message.
- `kdev-missing-kernel` — exits non-zero when no kernel can be located.
- `kdev-rejects-missing-virtio-fs` — rejects `# CONFIG_VIRTIO_FS is not set`
  with `--modules-install`.
- `kdev-rejects-module-fuse-fs` — rejects `CONFIG_FUSE_FS=m`.
- `kdev-rejects-missing-kver` — rejects when the kernel's kver subdir
  isn't present in `$INSTALL_MOD_PATH`.
- `kdev-rejects-missing-modules-dir` — rejects when `lib/modules` is
  absent under `$INSTALL_MOD_PATH`.
- `cross-aarch64-produces-arm64-elf` — the aarch64 cross gcc builds an
  object file that `file` reports as `ARM aarch64`.
- `kmake-aarch64-sets-vars-and-cross-builds` — `kmake-aarch64` exports
  `ARCH=arm64` + `CROSS_COMPILE=aarch64-unknown-linux-gnu-` to a stub
  Makefile, and the resulting object is an aarch64 ELF.
- `kdev-run-rejects-both-run-and-script` — `--run` and `--run-script`
  together abort with a useful message.
- `kdev-run-rejects-no-share-var` — `--run` with `--no-share-var`
  aborts (the staging dir lives under `$HOME/var`).
- `kdev-quiet-requires-run` — `--quiet` without `--run`/`--run-script`
  aborts with a pointer to the requirement.
- `kdev-keep-artifacts-refuses-existing` — `--keep-artifacts DIR`
  refuses to overwrite an existing `DIR`.
- `kdev-crash-dump-refuses-existing` — ditto for `--crash-dump PATH`.
- `kdev-crash-dump-requires-pvpanic` — aborts when the kernel
  `.config` lacks `CONFIG_PVPANIC_PCI=y`, with the exact
  `scripts/config` line to fix it.
- `syz-config-check-rejects-bad` — a stub `.config` missing KCOV/KASAN
  and setting `RANDOMIZE_BASE=y` is rejected with all three symbols
  named in the output.
- `syz-config-check-accepts-good` — a `.config` with every required
  symbol correctly set passes with `OK:` on stdout.

End-to-end VM boot is not in the hermetic check set — it needs KVM and a
real kernel and isn't safe inside the Nix sandbox. Do it manually with
`nix run .#vm`.
