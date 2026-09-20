# Minimal static-busybox initramfs for diskless boots: enough userspace to
# land in a shell, read dmesg and poke /sys and /proc. Meant for kernels
# booted with `kdev-aarch64-tfa --initrd` (or embedded through
# CONFIG_INITRAMFS_SOURCE) where the NixOS rootfs is not wanted, such as
# early-boot, firmware-handover or kexec experiments.
#
# `extraInit` is a shell snippet /init runs after mounting the pseudo
# filesystems and before dropping to a shell; `extraInstall` runs at build
# time with the tree at ./root to add files. Both default to nothing.
#
# Output: $out/initramfs.cpio.gz.
{
  runCommand,
  pkgsCross,
  cpio,
  gzip,
  lib,

  cross ? pkgsCross.aarch64-multiplatform,
  extraInit ? "",
  extraInstall ? "",
}:

let
  busybox = cross.pkgsStatic.busybox;
in
runCommand "kdev-initramfs-${cross.stdenv.hostPlatform.linuxArch}"
  {
    nativeBuildInputs = [
      cpio
      gzip
    ];
    passthru = {
      inherit busybox;
    };
  }
  ''
    mkdir -p root/{bin,sbin,proc,sys,dev,tmp}
    install -m0755 ${busybox}/bin/busybox root/bin/busybox

    cat > root/init <<'INIT'
    #!/bin/busybox sh

    # Mount devtmpfs first so /dev/console exists for the redirect below.
    # Nix builds cannot mknod, so the archive has no static /dev/console and
    # /init starts with its standard streams closed.
    /bin/busybox mount -t devtmpfs devtmpfs /dev
    exec </dev/console >/dev/console 2>&1

    /bin/busybox mount -t proc     proc     /proc
    /bin/busybox mount -t sysfs    sysfs    /sys
    /bin/busybox mount -t debugfs  debugfs  /sys/kernel/debug 2>/dev/null
    /bin/busybox --install -s /bin

    echo
    echo "===== kdev initramfs: $(uname -m) $(uname -r) ====="
    echo "poweroff -f to stop the guest"
    echo
    ${lib.replaceStrings [ "\n" ] [ "\n    " ] extraInit}

    exec setsid -c /bin/sh
    INIT
    chmod 0755 root/init
    ${extraInstall}
    mkdir -p $out
    (cd root && find . | cpio -o -H newc --quiet) | gzip -9 > $out/initramfs.cpio.gz
  ''
