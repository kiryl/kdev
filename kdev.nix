{
  vmImage ? null,
  vmImageFileName ? null,
  writeShellApplication,
  qemu,
  qemu_kvm,
  qemu-utils,
  virtiofsd,
  coreutils,
  socat,
  dtc,
  arch ? "x86_64",
  # Output of tf-a.nix: bl1.bin and fip.bin (BL2 + BL31), built to jump to a
  # preloaded BL33 at 0x60000000. Required for arch = "aarch64-tfa",
  # ignored otherwise.
  tfaFirmware ? null,
}:
let
  hasEmbeddedImage = vmImage != null && vmImageFileName != null;
  imageBaseLine =
    if hasEmbeddedImage then
      ''IMAGE_BASE="${vmImage}/${vmImageFileName}"''
    else
      ''IMAGE_BASE="''${KDEV_VM_IMAGE:-}"'';
  archCfg =
    if arch == "x86_64" then
      {
        binaryName = "kdev";
        qemuPkg = qemu_kvm;
        qemuBin = "qemu-system-x86_64";
        console = "ttyS0";
        kernelRelPath = "arch/x86/boot/bzImage";
        kernelKind = "bzImage";
        kvmCapable = true;
        tcgCpu = "max";
        machineArgs = [ ];
        firmware = null;
      }
    else if arch == "aarch64" then
      {
        binaryName = "kdev-aarch64";
        qemuPkg = qemu;
        qemuBin = "qemu-system-aarch64";
        console = "ttyAMA0";
        kernelRelPath = "arch/arm64/boot/Image";
        kernelKind = "Image";
        kvmCapable = false;
        tcgCpu = "max";
        machineArgs = [
          "-machine"
          "virt,gic-version=3"
        ];
        firmware = null;
      }
    else if arch == "aarch64-tfa" then
      {
        # aarch64 booted through Trusted Firmware-A: BL1 runs from the
        # secure flash, BL2 loads BL31 from a FIP and jumps to the kernel
        # qemu placed in RAM, and the guest gets PSCI, SDEI and EL3 from
        # real firmware.
        binaryName = "kdev-aarch64-tfa";
        qemuPkg = qemu;
        qemuBin = "qemu-system-aarch64";
        console = "ttyAMA0";
        kernelRelPath = "arch/arm64/boot/Image";
        kernelKind = "Image";
        kvmCapable = false;
        # TF-A's CPU support library keys off the MIDR, so -cpu max (an
        # invented MIDR) does not boot BL1; a Cortex-A57 does.
        tcgCpu = "cortex-a57";
        # secure=on enables EL3 and the secure pflash that holds BL1+FIP;
        # gic-version must match what TF-A was built with (tf-a.nix).
        machineArgs = [
          "-machine"
          "virt,secure=on,gic-version=3"
        ];
        firmware =
          if tfaFirmware == null then throw "kdev: arch=aarch64-tfa requires tfaFirmware" else tfaFirmware;
      }
    else
      throw "kdev: unsupported arch ${arch}";
  machineArgsLiteral = builtins.concatStringsSep " " (map (s: "'" + s + "'") archCfg.machineArgs);
  firmwareStorePath = if archCfg.firmware == null then "" else toString archCfg.firmware;
  tfaHelpNote =
    if archCfg.firmware == null then
      ""
    else
      ''

        Firmware boot (${arch}):
          BL1 and a FIP with BL2 and BL31 boot via -bios; the kernel is placed
          in RAM by qemu's loader device at the address TF-A jumps to, so
          qemu's -kernel/-append/-initrd are not used and the cmdline and any
          --initrd go through the device tree instead. With --image (or via
          `nix run .#vm-${arch}`) the NixOS guest boots as usual. Without an
          image the boot is diskless: the kernel runs off an embedded initramfs
          or --initrd, and --run, --modules-install, --root and the host shares
          are unavailable. --gdb-wait stops at the first BL1 instruction.
      '';
in
writeShellApplication {
  name = archCfg.binaryName;
  runtimeInputs = [
    archCfg.qemuPkg
    qemu-utils
    virtiofsd
    coreutils
    socat
    dtc
  ];
  text = ''
    set -euo pipefail

    ${imageBaseLine}

    KDEV_ARCH="${arch}"
    QEMU_BIN="${archCfg.qemuBin}"
    CONSOLE_DEV="${archCfg.console}"
    KERNEL_REL_PATH="${archCfg.kernelRelPath}"
    KVM_CAPABLE=${if archCfg.kvmCapable then "1" else "0"}
    MACHINE_ARGS=(${machineArgsLiteral})
    FIRMWARE_TFA="${firmwareStorePath}"
    TCG_CPU="${archCfg.tcgCpu}"

    KERNEL=""
    INITRD=""
    IMAGE=""
    APPEND=""
    ROOT="/dev/vda2"
    ROOT_USED=0
    DISKLESS=0
    MEMORY="''${VM_MEMORY:-8192}"
    CORES="''${VM_CORES:-8}"
    OVERLAY=""
    PERSIST=0
    SHARE_GIT="''${HOME}/git"
    SHARE_VAR="''${HOME}/var"
    GDB_ENABLED=0
    GDB_WAIT=0
    GDB_PORT=1234
    MODULES_INSTALL=""
    KERNEL_BUILD=""
    TCG=0
    RUN_CMD=""
    RUN_SCRIPT=""
    RUN_TIMEOUT=0
    QUIET=0
    KEEP_ARTIFACTS=""
    STAGING=""
    CRASH_DUMP=""
    CRASH_LISTENER_PID=""
    EXTRA_QEMU=()

    usage() {
      cat <<'EOF'
    Usage: ${archCfg.binaryName} [options] [-- extra-qemu-args...]

      Guest arch: ${arch} (qemu binary: ${archCfg.qemuBin})

      -k, --kernel PATH     Kernel image. Default: walks up from PWD to a kernel
                            tree root (Kbuild + MAINTAINERS), then tries
                            <tree>/build/${archCfg.kernelRelPath}. Also accepts
                            ./${archCfg.kernelRelPath} or ./build/${archCfg.kernelRelPath}
                            if you're already in a tree or build dir.
          --initrd PATH     Initrd to pass to -initrd (default: none; requires drivers =y)
      -i, --image PATH      Base qcow2 rootfs (default: nix-store vm-image)
      -a, --append STR      Extra kernel cmdline args (appended to defaults)
          --root DEV        Root device / spec (default: /dev/vda2)
      -m, --memory MB       Memory in MB (default: 8192, or $VM_MEMORY)
      -c, --cores N         CPU cores (default: 8, or $VM_CORES)
      -o, --overlay PATH    Persistent qcow2 overlay on top of base (default: ephemeral -snapshot)
      -p, --persist         Edit base image in-place (copies to ./kernel-vm.qcow2 if base is in /nix/store)
          --no-share-git    Do not share $HOME/git into guest
          --no-share-var    Do not share $HOME/var into guest
      -g, --gdb             Expose qemu gdbserver on tcp::PORT (kernel boots; attach any time)
          --gdb-wait        Same as --gdb but freeze CPU at entry (gdb must 'continue' to start)
          --gdb-port N      gdbserver TCP port (default: 1234)
          --modules-install DIR
                            Host path populated by `make modules_install INSTALL_MOD_PATH=DIR`.
                            DIR/lib/modules is virtiofs-shared ro at /lib/modules in the guest so
                            modprobe resolves to the kernel being booted.
          --kernel-build DIR
                            Kernel build dir for .config inspection (default: derived from --kernel).
          --tcg             Run qemu in TCG (software) mode instead of KVM.
                            Swaps -enable-kvm for default accel and -cpu host for -cpu max.
                            Required for -d mmu/int-style debug tracing. Slower boot.
          --run CMD         Run CMD as a bash script inside the guest after multi-user.target,
                            capture its exit code + log, then poweroff. kdev exits with the
                            test's exit code, 124 on --run-timeout, or 125 if the VM never
                            wrote an exit file (early panic, boot failure, etc.).
          --run-script PATH Same as --run, but copy PATH from the host and execute it.
          --run-timeout SEC Kill qemu if the test hasn't completed in SEC seconds.
                            When --run/--run-script is set and this is omitted, defaults to 120.
      -q, --quiet           Suppress qemu/boot/systemd chatter. Only the test script's own
                            stdout+stderr reaches stdout. Requires --run/--run-script.
                            Intended for automation (CI, Claude, scripts).
          --keep-artifacts DIR
                            On exit, move the test's staging dir (log, exit, dmesg) to DIR
                            instead of deleting it. DIR must not exist yet.
          --crash-dump PATH
                            On guest panic (via pvpanic-pci), qemu is paused and its memory
                            is dumped to PATH as an ELF crash dump (drgn-readable).
                            Requires CONFIG_PVPANIC_PCI=y (alongside the implied PVPANIC=y).
                            Read with: drgn -c PATH -s <kernel-build>/vmlinux
      -h, --help            Show this help

    Environment:
      VM_MEMORY, VM_CORES   Override defaults without passing flags.
      KDEV_NO_PIN           Set to skip pinning the rootfs image as a GC root.
                            By default each run refreshes an indirect GC root at
                            $XDG_STATE_HOME/kdev/vm-image-<arch> (falling back to
                            ~/.local/state), so the image in use survives
                            nix-collect-garbage; the previously pinned image is
                            released.

    Anything after `--` is appended verbatim to the qemu command line.

    Kernel-config prerequisites for the host shares:
      CONFIG_FUSE_FS=y, CONFIG_VIRTIO_FS=y, CONFIG_VIRTIO_PCI=y
      (CONFIG_MODULES=y additionally for --modules-install)
      kdev parses the build's .config and aborts if any are missing.

    Kernel-debug notes:
      Build with CONFIG_DEBUG_INFO=y, CONFIG_GDB_SCRIPTS=y, CONFIG_DEBUG_KERNEL=y.
      When --gdb/--gdb-wait is set, `nokaslr` is appended. Attach with:
        gdb <build>/vmlinux -ex 'target remote :<port>'
      (run `make scripts_gdb` in the kernel tree once to build the lx-* helpers.)

    QEMU internal tracing (requires --tcg, or implicit for non-native arch):
      ${archCfg.binaryName} --tcg -- -d mmu,int -D /tmp/qemu-trace.log
      Useful -d knobs: int, mmu, page, exec, in_asm, cpu_reset, guest_errors,
      unimp. See ${archCfg.qemuBin} -d help for the full list.${tfaHelpNote}
    EOF
    }

    while [ $# -gt 0 ]; do
      case "$1" in
        -k|--kernel) KERNEL="$2"; shift 2 ;;
        --initrd) INITRD="$2"; shift 2 ;;
        -i|--image) IMAGE="$2"; shift 2 ;;
        -a|--append) APPEND="$2"; shift 2 ;;
        --root) ROOT="$2"; ROOT_USED=1; shift 2 ;;
        -m|--memory) MEMORY="$2"; shift 2 ;;
        -c|--cores) CORES="$2"; shift 2 ;;
        -o|--overlay) OVERLAY="$2"; shift 2 ;;
        -p|--persist) PERSIST=1; shift ;;
        --no-share-git) SHARE_GIT=""; shift ;;
        --no-share-var) SHARE_VAR=""; shift ;;
        -g|--gdb) GDB_ENABLED=1; shift ;;
        --gdb-wait) GDB_ENABLED=1; GDB_WAIT=1; shift ;;
        --gdb-port) GDB_ENABLED=1; GDB_PORT="$2"; shift 2 ;;
        --modules-install) MODULES_INSTALL="$2"; shift 2 ;;
        --kernel-build) KERNEL_BUILD="$2"; shift 2 ;;
        --tcg) TCG=1; shift ;;
        --run) RUN_CMD="$2"; shift 2 ;;
        --run-script) RUN_SCRIPT="$2"; shift 2 ;;
        --run-timeout) RUN_TIMEOUT="$2"; shift 2 ;;
        -q|--quiet) QUIET=1; shift ;;
        --keep-artifacts) KEEP_ARTIFACTS="$2"; shift 2 ;;
        --crash-dump) CRASH_DUMP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; EXTRA_QEMU=("$@"); break ;;
        *) echo "kdev: unknown argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    if [ -z "$KERNEL" ]; then
      # PWD-relative — works when $PWD is a tree root or a build dir.
      for c in "./$KERNEL_REL_PATH" "./build/$KERNEL_REL_PATH"; do
        if [ -f "$c" ]; then KERNEL="$c"; break; fi
      done
    fi
    if [ -z "$KERNEL" ]; then
      # Walk up from PWD looking for a kernel tree root, then try $tree/build.
      dir="$PWD"
      while [ "$dir" != "/" ]; do
        if [ -f "$dir/Kbuild" ] && [ -f "$dir/MAINTAINERS" ]; then
          if [ -f "$dir/build/$KERNEL_REL_PATH" ]; then
            KERNEL="$dir/build/$KERNEL_REL_PATH"
          elif [ -f "$dir/$KERNEL_REL_PATH" ]; then
            KERNEL="$dir/$KERNEL_REL_PATH"
          fi
          break
        fi
        dir=$(dirname "$dir")
      done
    fi
    if [ -z "$KERNEL" ] || [ ! -f "$KERNEL" ]; then
      echo "kdev: cannot auto-detect a kernel image from $PWD" >&2
      echo "  cd into your kernel tree (or its build/ dir), or pass --kernel PATH." >&2
      exit 1
    fi

    if [ -z "$IMAGE" ]; then
      IMAGE="$IMAGE_BASE"
    fi
    if [ -z "$IMAGE" ] && [ -n "$FIRMWARE_TFA" ]; then
      # Firmware boot without a rootfs: the kernel runs off its initramfs,
      # embedded or --initrd. Nothing that relies on the NixOS guest applies.
      DISKLESS=1
      err=""
      [ "$ROOT_USED" -eq 1 ]    && err="$err --root"
      [ -n "$OVERLAY" ]         && err="$err --overlay"
      [ "$PERSIST" -eq 1 ]      && err="$err --persist"
      [ -n "$RUN_CMD" ]         && err="$err --run"
      [ -n "$RUN_SCRIPT" ]      && err="$err --run-script"
      [ -n "$MODULES_INSTALL" ] && err="$err --modules-install"
      if [ -n "$err" ]; then
        echo "kdev: no rootfs image, so this is a diskless firmware boot; these need --image:$err" >&2
        exit 2
      fi
      SHARE_GIT=""
      SHARE_VAR=""
    fi
    if [ "$DISKLESS" -eq 0 ]; then
      if [ -z "$IMAGE" ]; then
        echo "kdev: no rootfs image set." >&2
        echo "kdev: pass --image PATH, or set KDEV_VM_IMAGE, or run via 'nix run .#vm-$KDEV_ARCH'." >&2
        exit 1
      fi
      if [ ! -f "$IMAGE" ]; then
        echo "kdev: base image not found: $IMAGE" >&2
        exit 1
      fi

      # Pin the rootfs image against `nix-collect-garbage`. Each run refreshes
      # an indirect GC root at a fixed per-arch path, so the image currently
      # in use is always protected and the previously pinned one is released
      # (the symlink is overwritten atomically). Best-effort: skip silently if
      # the image isn't a store path, the user opted out via KDEV_NO_PIN, or
      # nix-store isn't reachable.
      case "$IMAGE" in
        /nix/store/*)
          if [ -z "''${KDEV_NO_PIN:-}" ] && command -v nix-store >/dev/null 2>&1; then
            # Reduce the in-store file path to its top-level store path
            # (/nix/store/<spec>/...  ->  /nix/store/<spec>) so the whole
            # image closure is rooted, not just the file.
            pin_rest="''${IMAGE#/nix/store/}"
            pin_store="/nix/store/''${pin_rest%%/*}"
            pin_dir="''${XDG_STATE_HOME:-$HOME/.local/state}/kdev"
            if mkdir -p "$pin_dir" 2>/dev/null; then
              nix-store --realise "$pin_store" \
                --add-root "$pin_dir/vm-image-$KDEV_ARCH" --indirect \
                >/dev/null 2>&1 \
                || echo "kdev: warning: could not pin rootfs image as a GC root" >&2
            fi
          fi
          ;;
      esac
    fi

    if [ -z "$KERNEL_BUILD" ]; then
      case "$KERNEL" in
        */arch/*/boot/*) KERNEL_BUILD="''${KERNEL%/arch/*/boot/*}" ;;
      esac
    fi

    # Decide which virtiofs shares will be active.
    SHARE_PAIRS=()
    if [ -n "$SHARE_GIT" ] && [ -d "$SHARE_GIT" ]; then
      SHARE_PAIRS+=("home-kas-git:$SHARE_GIT:rw")
    fi
    if [ -n "$SHARE_VAR" ] && [ -d "$SHARE_VAR" ]; then
      SHARE_PAIRS+=("home-kas-var:$SHARE_VAR:rw")
    fi
    if [ -n "$MODULES_INSTALL" ]; then
      if [ ! -d "$MODULES_INSTALL/lib/modules" ]; then
        echo "kdev: $MODULES_INSTALL/lib/modules does not exist" >&2
        echo "kdev: run 'make modules_install INSTALL_MOD_PATH=$MODULES_INSTALL' first" >&2
        exit 1
      fi
      if [ -n "$KERNEL_BUILD" ] && [ -f "$KERNEL_BUILD/include/config/kernel.release" ]; then
        kver=$(cat "$KERNEL_BUILD/include/config/kernel.release")
        if [ ! -d "$MODULES_INSTALL/lib/modules/$kver" ]; then
          echo "kdev: no modules for kernel $kver at $MODULES_INSTALL/lib/modules/" >&2
          echo "kdev: did you re-run modules_install after rebuilding the kernel?" >&2
          exit 1
        fi
      fi
      SHARE_PAIRS+=("kernel-modules:$MODULES_INSTALL/lib/modules:ro")
    fi

    # Config check: when any share is active we need FUSE_FS + VIRTIO_FS + VIRTIO_PCI =y;
    # MODULES is additionally required if the modules share is on.
    if [ ''${#SHARE_PAIRS[@]} -gt 0 ] && [ -n "$KERNEL_BUILD" ] && [ -f "$KERNEL_BUILD/.config" ]; then
      kcfg="$KERNEL_BUILD/.config"
      required="FUSE_FS VIRTIO_FS VIRTIO_PCI"
      if [ -n "$MODULES_INSTALL" ]; then
        required="$required MODULES"
      fi
      missing=""
      for sym in $required; do
        if ! grep -qE "^CONFIG_$sym=y\$" "$kcfg"; then
          missing="$missing CONFIG_$sym"
        fi
      done
      if [ -n "$missing" ]; then
        echo "kdev: kernel config at $kcfg is missing required =y symbols for virtiofs shares:" >&2
        for m in $missing; do echo "  $m" >&2; done
        echo "kdev: enable them (e.g. scripts/config --enable $(echo "$missing" | tr ' ' '\n' | sed 's/^ *//' | grep -v '^$' | head -c 200)) and rebuild," >&2
        echo "kdev: or pass --no-share-git --no-share-var (and omit --modules-install) to skip shares." >&2
        exit 1
      fi
    fi

    DISK_ARGS=()
    if [ "$DISKLESS" -eq 0 ]; then
      if [ "$PERSIST" -eq 1 ]; then
        if [[ "$IMAGE" == /nix/store/* ]]; then
          LOCAL="./kernel-vm.qcow2"
          if [ ! -f "$LOCAL" ]; then
            echo "kdev: copying $IMAGE to $LOCAL (one-time)"
            install -m 0644 "$IMAGE" "$LOCAL"
          fi
          IMAGE="$LOCAL"
        fi
        DISK_ARGS+=(-drive "file=$IMAGE,format=qcow2,if=virtio")
      elif [ -n "$OVERLAY" ]; then
        if [ ! -f "$OVERLAY" ]; then
          echo "kdev: creating overlay $OVERLAY (backing file: $IMAGE)"
          qemu-img create -f qcow2 -F qcow2 -b "$IMAGE" "$OVERLAY" >/dev/null
        fi
        DISK_ARGS+=(-drive "file=$OVERLAY,format=qcow2,if=virtio")
      else
        DISK_ARGS+=(-drive "file=$IMAGE,format=qcow2,if=virtio,snapshot=on")
      fi
    fi

    # Use NixOS's stage-2 wrapper (prepare-root) as init, not the systemd
    # binary at .../system/init. prepare-root sets up /run/current-system
    # and /run/booted-system before exec'ing systemd; without it, /etc/passwd's
    # shell path /run/current-system/sw/bin/bash is dangling and login fails
    # ("Cannot execute /run/current-system/sw/bin/bash"). We skip this in
    # normal NixOS boot because initrd-stage-1 handles it, but kdev boots
    # directly with -kernel (no initrd).
    if [ "$DISKLESS" -eq 1 ]; then
      FULL_APPEND="console=$CONSOLE_DEV,115200"
    else
      FULL_APPEND="console=$CONSOLE_DEV,115200 root=$ROOT rootfstype=ext4 rootwait init=/nix/var/nix/profiles/system/prepare-root"
    fi
    if [ -n "$FIRMWARE_TFA" ]; then
      # The firmware leaves the virt machine's pl011 set up; earlycon lets
      # the kernel print from its first line instead of after the driver
      # probes, which is where firmware-handover problems show up.
      FULL_APPEND="$FULL_APPEND earlycon=pl011,0x9000000"
    fi
    if [ "$GDB_ENABLED" -eq 1 ]; then
      FULL_APPEND="$FULL_APPEND nokaslr"
    fi
    FULL_APPEND="$FULL_APPEND $APPEND"

    GDB_ARGS=()
    if [ "$GDB_ENABLED" -eq 1 ]; then
      GDB_ARGS+=(-gdb "tcp::$GDB_PORT")
      if [ "$GDB_WAIT" -eq 1 ]; then
        GDB_ARGS+=(-S)
      fi
      echo "kdev: gdbserver listening on tcp::$GDB_PORT" >&2
      if [ "$GDB_WAIT" -eq 1 ]; then
        echo "kdev: CPU frozen at entry; attach gdb and 'continue' to boot" >&2
      fi
      echo "kdev: attach with: gdb <build>/vmlinux -ex 'target remote :$GDB_PORT'" >&2
    fi

    INITRD_ARGS=()
    if [ -n "$INITRD" ]; then
      if [ ! -f "$INITRD" ]; then
        echo "kdev: initrd not found: $INITRD" >&2
        exit 1
      fi
      # In firmware mode the initrd goes through the device tree instead
      # (see the boot arguments below).
      [ -n "$FIRMWARE_TFA" ] || INITRD_ARGS+=(-initrd "$INITRD")
    fi

    # Virtiofsd sidecars. Sockets live under a tempdir that is cleaned at exit.
    RUN_TMP=$(mktemp -d -t kdev-XXXXXX)
    VIOFS_PIDS=()
    # shellcheck disable=SC2329  # invoked via `trap cleanup EXIT INT TERM`
    cleanup() {
      local pid
      for pid in "''${VIOFS_PIDS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
      done
      [ -n "$CRASH_LISTENER_PID" ] && kill "$CRASH_LISTENER_PID" 2>/dev/null || true
      rm -rf "$RUN_TMP"
      if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
        rm -rf "$STAGING" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT INT TERM

    # --quiet is only meaningful when we know where "just the test output" comes from.
    if [ "$QUIET" -eq 1 ] && [ -z "$RUN_CMD" ] && [ -z "$RUN_SCRIPT" ]; then
      echo "kdev: --quiet requires --run or --run-script" >&2
      exit 1
    fi

    if [ -n "$KEEP_ARTIFACTS" ] && [ -e "$KEEP_ARTIFACTS" ]; then
      echo "kdev: --keep-artifacts: $KEEP_ARTIFACTS already exists; refusing to overwrite" >&2
      exit 1
    fi

    if [ -n "$CRASH_DUMP" ]; then
      if [ -e "$CRASH_DUMP" ]; then
        echo "kdev: --crash-dump: $CRASH_DUMP already exists; refusing to overwrite" >&2
        exit 1
      fi
      if [ -n "$KERNEL_BUILD" ] && [ -f "$KERNEL_BUILD/.config" ]; then
        kcfg="$KERNEL_BUILD/.config"
        missing=""
        for sym in PVPANIC PVPANIC_PCI; do
          if ! grep -qE "^CONFIG_$sym=y\$" "$kcfg"; then
            missing="$missing CONFIG_$sym"
          fi
        done
        if [ -n "$missing" ]; then
          echo "kdev: --crash-dump requires these =y in $kcfg:" >&2
          for m in $missing; do echo "  $m" >&2; done
          echo "  scripts/config --file $kcfg --enable PVPANIC --enable PVPANIC_PCI && make olddefconfig" >&2
          exit 1
        fi
      fi
    fi

    # --run / --run-script: stage a script under $HOME/var/.kdev-run/<id>/
    # so the kdev-run guest service can find it via the $HOME/var virtiofs share.
    if [ -n "$RUN_CMD" ] || [ -n "$RUN_SCRIPT" ]; then
      if [ -n "$RUN_CMD" ] && [ -n "$RUN_SCRIPT" ]; then
        echo "kdev: --run and --run-script are mutually exclusive" >&2
        exit 1
      fi
      if [ -z "$SHARE_VAR" ] || [ ! -d "$SHARE_VAR" ]; then
        echo "kdev: --run/--run-script requires \$HOME/var to be shared (don't pass --no-share-var)" >&2
        exit 1
      fi
      if [ "$RUN_TIMEOUT" -eq 0 ]; then
        RUN_TIMEOUT=120
        [ "$QUIET" -eq 1 ] || echo "kdev: defaulting --run-timeout to ''${RUN_TIMEOUT}s" >&2
      fi
      STAGING="$SHARE_VAR/.kdev-run/run-$(date +%s)-$$"
      mkdir -p "$STAGING"
      if [ -n "$RUN_SCRIPT" ]; then
        if [ ! -r "$RUN_SCRIPT" ]; then
          echo "kdev: --run-script: $RUN_SCRIPT not readable" >&2
          exit 1
        fi
        install -m 0755 "$RUN_SCRIPT" "$STAGING/script"
      else
        printf '#!/usr/bin/env bash\n%s\n' "$RUN_CMD" > "$STAGING/script"
        chmod 0755 "$STAGING/script"
      fi
      FULL_APPEND="$FULL_APPEND kdev.run=$STAGING"
      [ "$QUIET" -eq 1 ] || echo "kdev: test staged at $STAGING; will poweroff guest on completion" >&2
    fi

    SHARE_ARGS=()
    for pair in "''${SHARE_PAIRS[@]:-}"; do
      [ -z "$pair" ] && continue
      tag="''${pair%%:*}"
      rest="''${pair#*:}"
      path="''${rest%:*}"
      mode="''${rest##*:}"
      sock="$RUN_TMP/viofs-$tag.sock"

      viofs_args=(--socket-path="$sock" --shared-dir="$path" --sandbox=none)
      [ "$mode" = "ro" ] && viofs_args+=(--readonly)

      virtiofsd "''${viofs_args[@]}" >"$RUN_TMP/viofs-$tag.log" 2>&1 &
      VIOFS_PIDS+=("$!")

      for _ in $(seq 1 50); do
        [ -S "$sock" ] && break
        sleep 0.05
      done
      if [ ! -S "$sock" ]; then
        echo "kdev: virtiofsd failed to start for tag=$tag" >&2
        echo "--- virtiofsd log ---" >&2
        cat "$RUN_TMP/viofs-$tag.log" >&2 || true
        exit 1
      fi

      SHARE_ARGS+=(
        -chardev "socket,id=char-$tag,path=$sock"
        -device  "vhost-user-fs-pci,queue-size=1024,chardev=char-$tag,tag=$tag"
      )
    done

    # virtiofs requires guest memory to be shareable.
    MEM_ARGS=(
      -m "$MEMORY"
      -object "memory-backend-memfd,id=mem,size=''${MEMORY}M,share=on"
      -numa   "node,memdev=mem"
    )

    # KVM by default when the host arch matches the guest arch; otherwise TCG
    # (foreign-arch emulation). --tcg forces TCG even when KVM is available.
    if [ "$KVM_CAPABLE" -eq 0 ] || [ "$TCG" -eq 1 ]; then
      ACCEL_ARGS=(-cpu "$TCG_CPU")
      if [ "$KVM_CAPABLE" -eq 0 ]; then
        [ "$QUIET" -eq 1 ] || echo "kdev: $KDEV_ARCH guest under TCG (no KVM on this host); boot will be slow." >&2
      else
        echo "kdev: TCG mode; boot will be slow. Pass -- -d <opts> -D <log> for tracing." >&2
      fi
    else
      ACCEL_ARGS=(-enable-kvm -cpu host)
    fi

    QEMU_PREFIX=()
    if [ "$RUN_TIMEOUT" -gt 0 ]; then
      QEMU_PREFIX=(timeout --foreground --kill-after=5 "$RUN_TIMEOUT")
    fi

    # In --quiet mode, console goes to a file; otherwise qemu uses mon:stdio.
    QEMU_CONSOLE_ARGS=(-nographic -serial mon:stdio)
    if [ "$QUIET" -eq 1 ]; then
      QEMU_CONSOLE_ARGS=(-display none -serial "file:$RUN_TMP/serial.log")
    fi

    # --crash-dump: pvpanic + monitor socket + background panic listener.
    CRASH_ARGS=()
    if [ -n "$CRASH_DUMP" ]; then
      crash_sock="$RUN_TMP/mon-crash.sock"
      CRASH_ARGS=(
        -device pvpanic-pci
        -action panic=pause
        -chardev "socket,id=mon-crash,path=$crash_sock,server=on,wait=off"
        -mon "chardev=mon-crash,mode=readline"
      )
      (
        # wait for qemu to create the monitor socket
        for _ in $(seq 1 100); do
          [ -S "$crash_sock" ] && break
          sleep 0.1
        done
        [ -S "$crash_sock" ] || exit 0
        while :; do
          resp=$(printf 'info status\n' | socat -t 2 - "UNIX-CONNECT:$crash_sock" 2>/dev/null || true)
          if [ -z "$resp" ]; then
            # qemu is gone
            exit 0
          fi
          case "$resp" in
            *guest-panicked*)
              [ "$QUIET" -eq 1 ] || echo "kdev: guest panicked; dumping memory to $CRASH_DUMP" >&2
              printf 'dump-guest-memory -p %s\nquit\n' "$CRASH_DUMP" | \
                socat -t 120 - "UNIX-CONNECT:$crash_sock" >/dev/null 2>&1 || true
              exit 0
              ;;
          esac
          sleep 1
        done
      ) &
      CRASH_LISTENER_PID=$!
    fi

    BOOT_ARGS=(-kernel "$KERNEL" "''${INITRD_ARGS[@]}" -append "$FULL_APPEND")
    if [ -n "$FIRMWARE_TFA" ]; then
      # Firmware boot: BL1 at the start of a 64 MiB flash image (the virt
      # machine's pflash slots are fixed at that size) and the FIP with BL2
      # and BL31 at 256 KiB. The kernel is not in the flash: TF-A was built
      # to jump to a BL33 already at KERNEL_LOAD_ADDR, and qemu's generic
      # loader device puts it there. A debug kernel Image is well over
      # 64 MiB, which is why it cannot ride in the FIP.
      KERNEL_LOAD_ADDR=0x60000000
      FLASH="$RUN_TMP/flash.bin"
      install -m0644 "$FIRMWARE_TFA/bl1.bin" "$FLASH"
      truncate -s 64M "$FLASH"
      dd if="$FIRMWARE_TFA/fip.bin" of="$FLASH" bs=64k seek=4 conv=notrunc status=none

      # Without -kernel QEMU refuses -append and -initrd, so both go through
      # the device tree: dump the DTB QEMU generates for this exact machine
      # (same cpu, smp and memory, so the nodes match), set /chosen/bootargs
      # and, for an initrd, the linux,initrd-* range, and hand it back with
      # -dtb. BL2 adds PSCI and its own nodes to it as usual.
      DTB="$RUN_TMP/qemu.dtb"
      "$QEMU_BIN" "''${MACHINE_ARGS[@]}" "''${ACCEL_ARGS[@]}" -smp "$CORES" \
        "''${MEM_ARGS[@]}" -bios "$FLASH" -display none \
        -machine "dumpdtb=$DTB" >/dev/null 2>&1
      fdtput -t s "$DTB" /chosen bootargs "$FULL_APPEND"
      BOOT_ARGS=(-bios "$FLASH" -dtb "$DTB"
                 -device "loader,file=$KERNEL,addr=$KERNEL_LOAD_ADDR,force-raw=on")

      if [ -n "$INITRD" ]; then
        # The initrd goes above the kernel: the arm64 Image header says how
        # much room the kernel needs past its load address.
        image_size=$(od -An -t u8 -j16 -N8 "$KERNEL" | tr -d ' ')
        initrd_size=$(stat -c %s "$INITRD")
        initrd_addr=$(( (KERNEL_LOAD_ADDR + image_size + 0x4000000 + 0x1fffff) & ~0x1fffff ))
        initrd_end=$(( initrd_addr + initrd_size ))
        ram_end=$(( 0x40000000 + MEMORY * 1024 * 1024 ))
        if [ "$initrd_end" -gt "$ram_end" ]; then
          echo "kdev: --initrd does not fit: needs RAM through $(printf '0x%x' "$initrd_end"), guest ends at $(printf '0x%x' "$ram_end"); raise --memory" >&2
          exit 1
        fi
        fdtput -t x "$DTB" /chosen linux,initrd-start "$(printf '0x%x' "$initrd_addr")"
        fdtput -t x "$DTB" /chosen linux,initrd-end "$(printf '0x%x' "$initrd_end")"
        BOOT_ARGS+=(-device "loader,file=$INITRD,addr=$(printf '0x%x' "$initrd_addr"),force-raw=on")
      fi
    fi

    # shellcheck disable=SC2054  # qemu option values contain commas; that's intentional
    QEMU_INVOKE=(
      "''${QEMU_PREFIX[@]}"
      "$QEMU_BIN"
      "''${MACHINE_ARGS[@]}"
      "''${ACCEL_ARGS[@]}"
      -smp "$CORES"
      "''${MEM_ARGS[@]}"
      "''${BOOT_ARGS[@]}"
      "''${DISK_ARGS[@]}"
      "''${QEMU_CONSOLE_ARGS[@]}"
      -nic user,model=virtio-net-pci
      -device vmcoreinfo
      "''${SHARE_ARGS[@]}"
      "''${GDB_ARGS[@]}"
      "''${CRASH_ARGS[@]}"
      "''${EXTRA_QEMU[@]}"
    )

    set +e
    if [ "$QUIET" -eq 1 ]; then
      "''${QEMU_INVOKE[@]}" > /dev/null 2>&1
    else
      "''${QEMU_INVOKE[@]}"
    fi
    qemu_rc=$?
    set -e

    # Exit-code propagation when --run was used.
    if [ -n "$STAGING" ]; then
      if [ "$qemu_rc" -eq 124 ]; then
        [ "$QUIET" -eq 1 ] || echo "kdev: qemu killed by --run-timeout after ''${RUN_TIMEOUT}s" >&2
        exit_code=124
      elif [ -f "$STAGING/exit" ]; then
        exit_code=$(cat "$STAGING/exit" 2>/dev/null || echo 125)
        [ "$QUIET" -eq 1 ] || echo "kdev: test exit=$exit_code" >&2
      else
        [ "$QUIET" -eq 1 ] || echo "kdev: test did not complete (no $STAGING/exit file); qemu rc=$qemu_rc" >&2
        exit_code=125
      fi

      # In quiet mode, emit ONLY the test's own stdout/stderr on our stdout.
      if [ "$QUIET" -eq 1 ] && [ -f "$STAGING/log" ]; then
        cat "$STAGING/log"
      fi

      # Preserve artifacts if requested (before trap cleans the staging dir).
      if [ -n "$KEEP_ARTIFACTS" ]; then
        mkdir -p "$(dirname "$KEEP_ARTIFACTS")"
        cp -a "$STAGING" "$KEEP_ARTIFACTS"
        # Also grab the quiet-mode serial log if it exists.
        if [ -f "$RUN_TMP/serial.log" ]; then
          cp "$RUN_TMP/serial.log" "$KEEP_ARTIFACTS/serial.log"
        fi
        [ "$QUIET" -eq 1 ] || echo "kdev: artifacts kept at $KEEP_ARTIFACTS" >&2
      fi

      exit "$exit_code"
    fi
    exit "$qemu_rc"
  '';
}
