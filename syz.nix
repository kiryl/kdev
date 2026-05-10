{
  pkgs,
  vmImage,
  vmImageFileName,
  syzkaller,
}:
let
  # Canonical list of syzkaller-required kernel configs. Sourced from
  # syzkaller/docs/linux/kernel_configs.md plus the five this harness needs
  # (virtiofs shares + pvpanic crash dump).
  requireY = [
    "KCOV"
    "KCOV_INSTRUMENT_ALL"
    "DEBUG_INFO"
    "KASAN"
    "KASAN_INLINE"
    "LOCKDEP"
    "PROVE_LOCKING"
    "DEBUG_ATOMIC_SLEEP"
    "PROVE_RCU"
    "DEBUG_LIST"
    "FAULT_INJECTION"
    "FAULT_INJECTION_DEBUG_FS"
    "FAILSLAB"
    "FAIL_PAGE_ALLOC"
    "FAIL_MAKE_REQUEST"
    "FAIL_IO_TIMEOUT"
    "FAIL_FUTEX"
    "UBSAN"
    # harness prereqs
    "FUSE_FS"
    "VIRTIO_FS"
    "VIRTIO_PCI"
    "PVPANIC"
    "PVPANIC_PCI"
  ];
  requireN = [ "RANDOMIZE_BASE" ];
  requireYStr = builtins.concatStringsSep " " requireY;
  requireNStr = builtins.concatStringsSep " " requireN;
in
{
  config-check = pkgs.writeShellApplication {
    name = "syz-config-check";
    runtimeInputs = [
      pkgs.gnugrep
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail

      CONFIG="''${1:-}"
      if [ -z "$CONFIG" ] || [ "$CONFIG" = "-h" ] || [ "$CONFIG" = "--help" ]; then
        cat <<'USAGE'
      usage: syz-config-check PATH-TO-.config

      Audits a kernel .config for the symbols syzkaller needs (plus this
      harness's virtiofs + pvpanic deps). Exits 0 if all set, 1 otherwise
      with a ready-to-paste `scripts/config` fix line.
      USAGE
        exit "$([ -z "$CONFIG" ] && echo 2 || echo 0)"
      fi
      if [ ! -f "$CONFIG" ]; then
        echo "syz-config-check: $CONFIG not found" >&2
        exit 2
      fi

      missing_y=()
      missing_n=()
      for s in ${requireYStr}; do
        if ! grep -qE "^CONFIG_$s=y\$" "$CONFIG"; then
          missing_y+=("$s")
        fi
      done
      # shellcheck disable=SC2043  # list currently has one entry; may grow
      for s in ${requireNStr}; do
        if grep -qE "^CONFIG_$s=y\$" "$CONFIG"; then
          missing_n+=("$s")
        fi
      done

      if [ "''${#missing_y[@]}" -eq 0 ] && [ "''${#missing_n[@]}" -eq 0 ]; then
        echo "OK: $CONFIG has every syzkaller-required symbol"
        exit 0
      fi

      echo "$CONFIG is missing syzkaller-required configs:" >&2
      if [ "''${#missing_y[@]}" -gt 0 ]; then
        echo "  must be =y: ''${missing_y[*]}" >&2
      fi
      if [ "''${#missing_n[@]}" -gt 0 ]; then
        echo "  must be =n: ''${missing_n[*]}" >&2
      fi
      echo "" >&2
      line="  scripts/config --file $CONFIG"
      for s in "''${missing_y[@]}"; do line+=" --enable $s"; done
      for s in "''${missing_n[@]}"; do line+=" --disable $s"; done
      echo "Fix:" >&2
      echo "$line" >&2
      build_dir=$(dirname "$CONFIG")
      echo "  (cd \$(kernel-tree); make O=$build_dir olddefconfig)" >&2
      exit 1
    '';
  };

  init = pkgs.writeShellApplication {
    name = "syz-init";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.openssh
    ];
    text = ''
      set -euo pipefail

      WORKDIR="''${1:-}"
      KERNEL_BUILD="''${2:-}"
      if [ -z "$WORKDIR" ] || [ "$WORKDIR" = "-h" ] || [ "$WORKDIR" = "--help" ]; then
        cat <<'USAGE'
      usage: syz-init WORKDIR [KERNEL_BUILD]

      Scaffolds a syzkaller workdir:
        - generates $HOME/var/.syz/{id_ed25519,authorized_keys} if missing
          (the VM image picks up authorized_keys via virtiofs at boot)
        - writes WORKDIR/syz.cfg pointing at the store paths for the
          harness's vm-image and the nixpkgs syzkaller package

      If KERNEL_BUILD is omitted, syz-init walks up from PWD to find a
      kernel tree (Kbuild + MAINTAINERS) and uses <tree>/build-syz.
      USAGE
        exit "$([ -z "$WORKDIR" ] && echo 2 || echo 0)"
      fi
      if [ -e "$WORKDIR" ]; then
        echo "syz-init: $WORKDIR already exists; refusing to overwrite" >&2
        exit 1
      fi

      if [ -z "$KERNEL_BUILD" ]; then
        dir="$PWD"
        while [ "$dir" != "/" ]; do
          if [ -f "$dir/Kbuild" ] && [ -f "$dir/MAINTAINERS" ]; then
            KERNEL_BUILD="$dir/build-syz"
            break
          fi
          dir=$(dirname "$dir")
        done
        if [ -z "$KERNEL_BUILD" ]; then
          echo "syz-init: not in a kernel tree (no Kbuild+MAINTAINERS while walking up from $PWD)" >&2
          echo "  cd into your kernel worktree, or pass KERNEL_BUILD as the second argument." >&2
          exit 2
        fi
      fi

      SYZ_KEY_DIR="$HOME/var/.syz"
      mkdir -p "$SYZ_KEY_DIR"
      if [ ! -f "$SYZ_KEY_DIR/id_ed25519" ]; then
        ssh-keygen -t ed25519 -N "" -f "$SYZ_KEY_DIR/id_ed25519" -C "syzkaller-dev" -q
        cp "$SYZ_KEY_DIR/id_ed25519.pub" "$SYZ_KEY_DIR/authorized_keys"
        echo "syz-init: generated $SYZ_KEY_DIR/id_ed25519 + authorized_keys"
      else
        if ! grep -qxF "$(cat "$SYZ_KEY_DIR/id_ed25519.pub")" "$SYZ_KEY_DIR/authorized_keys" 2>/dev/null; then
          cat "$SYZ_KEY_DIR/id_ed25519.pub" >> "$SYZ_KEY_DIR/authorized_keys"
          echo "syz-init: appended pubkey to $SYZ_KEY_DIR/authorized_keys"
        fi
      fi
      chmod 600 "$SYZ_KEY_DIR/id_ed25519"

      mkdir -p "$WORKDIR/work"
      cat > "$WORKDIR/syz.cfg" <<EOF
      {
        "target": "linux/amd64",
        "http": "127.0.0.1:56741",
        "workdir": "$WORKDIR/work",
        "kernel_obj": "$KERNEL_BUILD",
        "image": "${vmImage}/${vmImageFileName}",
        "sshkey": "$SYZ_KEY_DIR/id_ed25519",
        "syzkaller": "${syzkaller}",
        "procs": 4,
        "type": "qemu",
        "vm": {
          "count": 4,
          "kernel": "$KERNEL_BUILD/arch/x86/boot/bzImage",
          "cpu": 2,
          "mem": 2048,
          "cmdline": "init=/nix/var/nix/profiles/system/init root=/dev/vda2 rootfstype=ext4 rootwait"
        }
      }
      EOF
      chmod 644 "$WORKDIR/syz.cfg"

      cat <<SETUP
      syz-init: wrote $WORKDIR/syz.cfg

      Next steps:
        1. mkdir -p $KERNEL_BUILD && cp your .config there
        2. syz-config-check $KERNEL_BUILD/.config
           # paste the scripts/config line it prints to enable KCOV/KASAN/etc.
           # then: make O=$KERNEL_BUILD olddefconfig && kmake-syz -j\$(nproc)
        3. cd $WORKDIR && syz-manager -config syz.cfg
        Web UI:  http://127.0.0.1:56741
        Crashes: $WORKDIR/work/crashes/
      SETUP
    '';
  };

  kmake-syz = pkgs.writeShellApplication {
    name = "kmake-syz";
    runtimeInputs = [ pkgs.gnumake ];
    text = ''
      BUILD_DIR="''${KBUILD_OUTPUT:-}"
      if [ -z "$BUILD_DIR" ]; then
        dir="$PWD"
        while [ "$dir" != "/" ]; do
          if [ -f "$dir/Kbuild" ] && [ -f "$dir/MAINTAINERS" ]; then
            BUILD_DIR="$dir/build-syz"
            break
          fi
          dir=$(dirname "$dir")
        done
        if [ -z "$BUILD_DIR" ]; then
          echo "kmake-syz: not in a kernel tree (no Kbuild+MAINTAINERS while walking up from $PWD)" >&2
          echo "  cd into your kernel worktree, or set KBUILD_OUTPUT=<build-dir>" >&2
          exit 2
        fi
      fi
      mkdir -p "$BUILD_DIR"
      exec make O="$BUILD_DIR" "$@"
    '';
  };
}
