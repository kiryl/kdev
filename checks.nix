{
  pkgs,
  kdev,
  kdevAarch64,
  kdevAarch64Tfa,
  kmakeWrappers,
  testBuildDeps,
  syzConfigCheck,
}:
let
  inherit (pkgs) runCommand;

  mkKdevCheck =
    name: script:
    runCommand name { } ''
      set -euo pipefail
      KDEV=${kdev}/bin/kdev
      ${script}
      mkdir -p $out
      : > $out/ok
    '';

  mkKdevAarch64Check =
    name: script:
    runCommand name { } ''
      set -euo pipefail
      KDEV=${kdevAarch64}/bin/kdev-aarch64
      ${script}
      mkdir -p $out
      : > $out/ok
    '';

  mkKdevAarch64TfaCheck =
    name: script:
    runCommand name { } ''
      set -euo pipefail
      KDEV=${kdevAarch64Tfa}/bin/kdev-aarch64-tfa
      ${script}
      mkdir -p $out
      : > $out/ok
    '';

  mkGoodBuildDir = ''
    mkdir -p kb/include/config kb/arch/x86/boot
    echo "7.0.0-test" > kb/include/config/kernel.release
    : > kb/arch/x86/boot/bzImage
    cat > kb/.config <<'EOF'
    CONFIG_MODULES=y
    CONFIG_FUSE_FS=y
    CONFIG_VIRTIO_FS=y
    CONFIG_VIRTIO_PCI=y
    EOF
  '';
in
{
  kdev-help = mkKdevCheck "kdev-help" ''
    $KDEV --help > help.out
    for flag in --kernel --initrd --image --append --root --memory --cores \
                --overlay --persist --no-share-git --no-share-var \
                --gdb --gdb-wait --gdb-port --modules-install --kernel-build \
                --tcg --run --run-script --run-timeout --quiet --keep-artifacts \
                --crash-dump; do
      grep -q -- "$flag" help.out || { echo "help missing $flag"; exit 1; }
    done
  '';

  kdev-unknown-flag = mkKdevCheck "kdev-unknown-flag" ''
    if $KDEV --not-a-real-flag > out.log 2>&1; then
      echo "expected non-zero exit for unknown flag"; exit 1
    fi
    grep -q "unknown argument" out.log
  '';

  kdev-missing-kernel = mkKdevCheck "kdev-missing-kernel" ''
    export HOME=$PWD/empty-home
    mkdir -p "$HOME"
    if $KDEV > out.log 2>&1; then
      echo "expected non-zero exit when kernel cannot be found"; exit 1
    fi
    grep -q "cannot auto-detect" out.log
  '';

  kdev-rejects-missing-virtio-fs = mkKdevCheck "kdev-rejects-missing-virtio-fs" ''
    mkdir -p kb/include/config kb/arch/x86/boot mods/lib/modules/7.0.0-test
    echo "7.0.0-test" > kb/include/config/kernel.release
    : > kb/arch/x86/boot/bzImage
    touch mods/lib/modules/7.0.0-test/modules.dep
    cat > kb/.config <<'EOF'
    CONFIG_MODULES=y
    CONFIG_FUSE_FS=y
    CONFIG_VIRTIO_PCI=y
    # CONFIG_VIRTIO_FS is not set
    EOF

    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --modules-install $PWD/mods > out.log 2>&1; then
      echo "expected non-zero exit for missing CONFIG_VIRTIO_FS"; exit 1
    fi
    grep -q "CONFIG_VIRTIO_FS" out.log
  '';

  kdev-rejects-module-fuse-fs = mkKdevCheck "kdev-rejects-module-fuse-fs" ''
    mkdir -p kb/include/config kb/arch/x86/boot mods/lib/modules/7.0.0-test
    echo "7.0.0-test" > kb/include/config/kernel.release
    : > kb/arch/x86/boot/bzImage
    touch mods/lib/modules/7.0.0-test/modules.dep
    cat > kb/.config <<'EOF'
    CONFIG_MODULES=y
    CONFIG_FUSE_FS=m
    CONFIG_VIRTIO_FS=y
    CONFIG_VIRTIO_PCI=y
    EOF

    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --modules-install $PWD/mods > out.log 2>&1; then
      echo "expected non-zero exit for =m CONFIG_FUSE_FS"; exit 1
    fi
    grep -q "CONFIG_FUSE_FS" out.log
  '';

  kdev-rejects-missing-kver = mkKdevCheck "kdev-rejects-missing-kver" ''
    ${mkGoodBuildDir}
    mkdir -p mods/lib/modules/some-other-kver

    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --modules-install $PWD/mods > out.log 2>&1; then
      echo "expected non-zero exit for missing kver dir"; exit 1
    fi
    grep -q "7.0.0-test" out.log
    grep -q "modules_install" out.log
  '';

  kdev-rejects-missing-modules-dir = mkKdevCheck "kdev-rejects-missing-modules-dir" ''
    ${mkGoodBuildDir}
    mkdir -p no-modules-dir

    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --modules-install $PWD/no-modules-dir > out.log 2>&1; then
      echo "expected non-zero exit when lib/modules absent"; exit 1
    fi
    grep -q "lib/modules" out.log
  '';

  kdev-run-rejects-both-run-and-script = mkKdevCheck "kdev-run-rejects-both-run-and-script" ''
    ${mkGoodBuildDir}
    : > runscript
    chmod +x runscript
    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --run 'echo hi' --run-script $PWD/runscript > out.log 2>&1; then
      echo "expected non-zero exit for --run + --run-script"; exit 1
    fi
    grep -q "mutually exclusive" out.log
  '';

  kdev-run-rejects-no-share-var = mkKdevCheck "kdev-run-rejects-no-share-var" ''
    ${mkGoodBuildDir}
    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --no-share-var --run 'echo hi' > out.log 2>&1; then
      echo "expected non-zero exit for --run with --no-share-var"; exit 1
    fi
    grep -q "HOME/var" out.log
  '';

  kdev-quiet-requires-run = mkKdevCheck "kdev-quiet-requires-run" ''
    ${mkGoodBuildDir}
    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --quiet > out.log 2>&1; then
      echo "expected non-zero exit for --quiet without --run"; exit 1
    fi
    grep -q "requires --run" out.log
  '';

  kdev-keep-artifacts-refuses-existing = mkKdevCheck "kdev-keep-artifacts-refuses-existing" ''
    ${mkGoodBuildDir}
    mkdir -p already-there
    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --run 'true' --keep-artifacts $PWD/already-there > out.log 2>&1; then
      echo "expected non-zero exit when --keep-artifacts target exists"; exit 1
    fi
    grep -q "refusing to overwrite" out.log
  '';

  kdev-crash-dump-refuses-existing = mkKdevCheck "kdev-crash-dump-refuses-existing" ''
    ${mkGoodBuildDir}
    : > existing.core
    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --crash-dump $PWD/existing.core > out.log 2>&1; then
      echo "expected non-zero exit when --crash-dump target exists"; exit 1
    fi
    grep -q "refusing to overwrite" out.log
  '';

  kdev-crash-dump-requires-pvpanic = mkKdevCheck "kdev-crash-dump-requires-pvpanic" ''
    mkdir -p kb/include/config kb/arch/x86/boot
    echo "7.0.0-test" > kb/include/config/kernel.release
    : > kb/arch/x86/boot/bzImage
    cat > kb/.config <<'EOF'
    CONFIG_MODULES=y
    CONFIG_FUSE_FS=y
    CONFIG_VIRTIO_FS=y
    CONFIG_VIRTIO_PCI=y
    # CONFIG_PVPANIC is not set
    # CONFIG_PVPANIC_PCI is not set
    EOF
    if $KDEV --kernel $PWD/kb/arch/x86/boot/bzImage \
               --kernel-build $PWD/kb \
               --crash-dump $PWD/test.core > out.log 2>&1; then
      echo "expected non-zero exit without CONFIG_PVPANIC_PCI"; exit 1
    fi
    grep -q "CONFIG_PVPANIC_PCI" out.log
  '';

  kdev-aarch64-help = mkKdevAarch64Check "kdev-aarch64-help" ''
    $KDEV --help > help.out
    grep -q "Guest arch: aarch64" help.out
    grep -q "qemu-system-aarch64" help.out
    grep -q "arch/arm64/boot/Image" help.out
  '';

  kdev-aarch64-detects-arm64-image = mkKdevAarch64Check "kdev-aarch64-detects-arm64-image" ''
    mkdir -p tree/arch/arm64/boot
    : > tree/arch/arm64/boot/Image
    : > tree/Kbuild
    : > tree/MAINTAINERS
    cd tree
    # No image is configured, so we expect the script to detect the kernel
    # successfully then abort at the rootfs-image check.
    if $KDEV > ../out.log 2>&1; then
      echo "expected non-zero exit when no rootfs image is set"; exit 1
    fi
    grep -q "no rootfs image set" ../out.log
  '';

  kdev-aarch64-ignores-x86-bzImage = mkKdevAarch64Check "kdev-aarch64-ignores-x86-bzImage" ''
    mkdir -p tree/arch/x86/boot
    : > tree/arch/x86/boot/bzImage
    : > tree/Kbuild
    : > tree/MAINTAINERS
    cd tree
    if $KDEV > ../out.log 2>&1; then
      echo "expected non-zero exit when only an x86 bzImage exists"; exit 1
    fi
    grep -q "cannot auto-detect" ../out.log
  '';

  kdev-aarch64-requires-image = mkKdevAarch64Check "kdev-aarch64-requires-image" ''
    : > fake-Image
    if $KDEV --kernel $PWD/fake-Image > out.log 2>&1; then
      echo "expected non-zero exit when no image is configured"; exit 1
    fi
    grep -q "no rootfs image set" out.log
    grep -q "KDEV_VM_IMAGE" out.log
  '';

  kdev-aarch64-tfa-help = mkKdevAarch64TfaCheck "kdev-aarch64-tfa-help" ''
    $KDEV --help > help.out
    grep -q "Guest arch: aarch64-tfa" help.out
    grep -q "qemu-system-aarch64" help.out
    grep -q "Firmware boot" help.out
  '';

  kdev-aarch64-tfa-diskless-rejects-run = mkKdevAarch64TfaCheck "kdev-aarch64-tfa-diskless-rejects-run" ''
    : > fake-Image
    if $KDEV --kernel $PWD/fake-Image --run true > out.log 2>&1; then
      echo "expected non-zero exit for --run without an image"; exit 1
    fi
    grep -q "need --image: --run" out.log
  '';

  kdev-aarch64-tfa-diskless-rejects-root = mkKdevAarch64TfaCheck "kdev-aarch64-tfa-diskless-rejects-root" ''
    : > fake-Image
    if $KDEV --kernel $PWD/fake-Image --root /dev/vda1 --modules-install /nope > out.log 2>&1; then
      echo "expected non-zero exit for --root without an image"; exit 1
    fi
    grep -q -- "--root" out.log
    grep -q -- "--modules-install" out.log
  '';

  cross-aarch64-produces-arm64-elf =
    let
      cross = pkgs.pkgsCross.aarch64-multiplatform;
    in
    runCommand "cross-aarch64-produces-arm64-elf"
      {
        nativeBuildInputs = [
          cross.buildPackages.gcc
          pkgs.file
        ];
      }
      ''
        set -euo pipefail
        echo 'int kernel_like(void){return 0;}' > t.c
        ${cross.stdenv.cc.targetPrefix}gcc -c -o t.o t.c
        file t.o | tee result.txt
        grep -q "ARM aarch64" result.txt
        mkdir -p $out
        cp result.txt $out/
      '';

  kmake-aarch64-sets-vars-and-cross-builds =
    runCommand "kmake-aarch64-sets-vars-and-cross-builds"
      {
        nativeBuildInputs = kmakeWrappers ++ [ pkgs.file ];
      }
      ''
        set -euo pipefail
        printf '%s\n' \
          '.RECIPEPREFIX := >' \
          'all: hello.o' \
          'hello.o: hello.c' \
          '>$(CROSS_COMPILE)gcc -c -o $@ $<' \
          'show:' \
          '>@echo "ARCH=$(ARCH)"' \
          '>@echo "CROSS_COMPILE=$(CROSS_COMPILE)"' \
          > Makefile
        echo 'int kernel_like(void) { return 0; }' > hello.c

        kmake-aarch64 show > vars.txt
        grep -q '^ARCH=arm64$' vars.txt
        grep -q '^CROSS_COMPILE=aarch64-unknown-linux-gnu-$' vars.txt

        kmake-aarch64
        file hello.o | tee result.txt
        grep -q "ARM aarch64" result.txt

        mkdir -p $out
        cp vars.txt result.txt $out/
      '';

  test-tools-interp-matches-pkgs-glibc =
    runCommand "test-tools-interp-matches-pkgs-glibc"
      {
        nativeBuildInputs = testBuildDeps;
      }
      ''
        set -euo pipefail
        echo 'int main(void) { return 0; }' > t.c
        gcc -o t t.c
        interp=$(patchelf --print-interpreter t)
        echo "interpreter: $interp"
        case "$interp" in
          ${pkgs.glibc}/*) ;;
          *)
            echo "FAIL: interp=$interp is not under ${pkgs.glibc}"
            echo "      (host-built test binary would link a glibc the guest doesn't have)"
            exit 1
            ;;
        esac
        mkdir -p $out
        : > $out/ok
      '';

  syz-config-check-rejects-bad = runCommand "syz-config-check-rejects-bad" { } ''
    set -euo pipefail
    cat > bad.config <<'EOF'
    CONFIG_DEBUG_INFO=y
    # CONFIG_KCOV is not set
    # CONFIG_KASAN is not set
    CONFIG_RANDOMIZE_BASE=y
    EOF
    if ${syzConfigCheck}/bin/syz-config-check $PWD/bad.config > out.log 2>&1; then
      echo "expected non-zero exit for bad config"; exit 1
    fi
    grep -q KCOV out.log
    grep -q KASAN out.log
    grep -q RANDOMIZE_BASE out.log
    mkdir -p $out
    : > $out/ok
  '';

  syz-config-check-accepts-good = runCommand "syz-config-check-accepts-good" { } ''
    set -euo pipefail
    cat > good.config <<'EOF'
    CONFIG_KCOV=y
    CONFIG_KCOV_INSTRUMENT_ALL=y
    CONFIG_DEBUG_INFO=y
    CONFIG_KASAN=y
    CONFIG_KASAN_INLINE=y
    CONFIG_LOCKDEP=y
    CONFIG_PROVE_LOCKING=y
    CONFIG_DEBUG_ATOMIC_SLEEP=y
    CONFIG_PROVE_RCU=y
    CONFIG_DEBUG_LIST=y
    CONFIG_FAULT_INJECTION=y
    CONFIG_FAULT_INJECTION_DEBUG_FS=y
    CONFIG_FAILSLAB=y
    CONFIG_FAIL_PAGE_ALLOC=y
    CONFIG_FAIL_MAKE_REQUEST=y
    CONFIG_FAIL_IO_TIMEOUT=y
    CONFIG_FAIL_FUTEX=y
    CONFIG_UBSAN=y
    CONFIG_FUSE_FS=y
    CONFIG_VIRTIO_FS=y
    CONFIG_VIRTIO_PCI=y
    CONFIG_PVPANIC=y
    CONFIG_PVPANIC_PCI=y
    # CONFIG_RANDOMIZE_BASE is not set
    EOF
    ${syzConfigCheck}/bin/syz-config-check $PWD/good.config > out.log 2>&1
    grep -q "^OK" out.log
    mkdir -p $out
    : > $out/ok
  '';
}
