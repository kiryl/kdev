# BL1/BL2/BL31 + fiptool for one Trusted Firmware-A platform. The caller
# supplies the unpacked TF-A source (a flake input) and, optionally, patches
# to apply on top. Defaults target QEMU's virt machine with SDEI and the EL3
# exception handling framework on, so a kernel that speaks SDEI finds real
# firmware behind it; both are plain make flags and can be turned off.
#
# Output layout: $out/{bl1,bl2,bl31}.{bin,elf} and $out/bin/fiptool. FIP
# assembly is not done here: kdev packs the kernel as BL33 at launch, so a
# kernel change never rebuilds the firmware.
{
  stdenv,
  lib,
  src,
  patches ? [ ],
  pkgsCross,
  buildPackages,
  symlinkJoin,

  plat ? "qemu",
  debug ? true,
  sdeiSupport ? true,
  ehfSupport ? true,
  # ARM_LINUX_KERNEL_AS_BL33=1: BL2 hands the DTB address to BL33 in x0
  # (per Documentation/arm64/booting.txt) and skips the "BL33 expects
  # MPIDR in r0" path used for u-boot/UEFI BL33. Required when the
  # kernel Image is the FIP's BL33, which is how kdev boots; flip to false
  # if you're packing u-boot or EDK II.
  linuxKernelAsBl33 ? true,
  # QEMU's `-machine virt` defaults to gic-version=2; kdev boots every
  # aarch64 guest with gic-version=3. TF-A's plat/qemu defaults to GICv2;
  # override to GICv3 here so the BL31 GIC driver matches the emulated
  # hardware.
  gicVersion ? 3,
  # When non-null, sets PRELOADED_BL33_BASE so BL2 skips loading BL33
  # from FIP and jumps straight to this address. On the qemu virt
  # machine this is awkward in practice: QEMU's `-kernel` load address
  # (NS_DRAM0_BASE + 0x80000 = 0x40080000) overlaps with TF-A's
  # ARM_PRELOADED_DTB_BASE region (0x40000000-0x40100000), so the
  # `-kernel ... -append "..."` route this would enable conflicts with
  # the DTB. Kept as an option; kdev does not use it and supplies the
  # kernel cmdline by splicing it into the DTB it passes via -dtb.
  preloadedBl33Base ? null,
  extraMakeFlags ? [ ],
}:

let
  embedded = pkgsCross.aarch64-embedded;
  crossPrefix = embedded.stdenv.cc.targetPrefix;
  buildSubdir = if debug then "debug" else "release";
  flag = b: if b then "1" else "0";

  # TF-A's host tools (fiptool, cert_create) take a single OPENSSL_DIR
  # variable and expect /bin, /lib, /include all under it. nixpkgs splits
  # openssl across .bin/.dev/.out outputs, so merge them into a unified
  # tree for the build.
  openssl = buildPackages.openssl;
  opensslMerged = symlinkJoin {
    name = "openssl-merged";
    paths = [
      openssl.bin
      openssl.dev
      openssl.out
    ];
  };
in
stdenv.mkDerivation {
  pname = "tf-a-${plat}";
  version = "2.15.0";
  inherit src patches;

  nativeBuildInputs = [
    embedded.buildPackages.gcc
    embedded.buildPackages.binutils
    buildPackages.gnumake
    buildPackages.python3
    buildPackages.openssl
    buildPackages.perl
    buildPackages.dtc
  ];

  enableParallelBuilding = true;
  dontConfigure = true;

  # fiptool builds with -O0 in DEBUG=1 mode; Nix's default hardening
  # injects -D_FORTIFY_SOURCE, which requires optimization. Disable
  # both fortify variants so the host tools build. Also disable
  # stackprotector for the bare-metal cross build (BL1/BL2/BL31 have
  # their own canary scheme).
  hardeningDisable = [
    "fortify"
    "fortify3"
    "stackprotector"
  ];

  # `bl1 bl2 bl31` only — `fip` would require BL33 (the kernel), which
  # belongs in a separate fip.nix derivation so kernel changes don't force a
  # BL31 rebuild. `fiptool` is a host tool, built separately.
  #
  # TF-A v2.15 dropped the old CROSS_COMPILE-only workflow; toolchain
  # variables (CC, AS, LD, OC, OD, AR) are now read directly from the
  # environment via `aarch64-<tool>-parameter` in
  # make_helpers/toolchains/aarch64.mk. Nix's stdenv exports those names
  # pointing at the host gcc, so we have to override them on the make
  # command line (which beats env).
  buildPhase = ''
    runHook preBuild

    tfa_make() {
      make -j"$NIX_BUILD_CORES" \
        PLAT=${plat} \
        CC=${crossPrefix}gcc \
        CPP=${crossPrefix}gcc \
        AS=${crossPrefix}gcc \
        LD=${crossPrefix}gcc \
        OC=${crossPrefix}objcopy \
        OD=${crossPrefix}objdump \
        AR=${crossPrefix}gcc-ar \
        HOSTCC=gcc \
        HOSTLD=gcc \
        HOSTAR=gcc-ar \
        OPENSSL_DIR=${opensslMerged} \
        DEBUG=${flag debug} \
        SDEI_SUPPORT=${flag sdeiSupport} \
        EL3_EXCEPTION_HANDLING=${flag ehfSupport} \
        ARM_LINUX_KERNEL_AS_BL33=${flag linuxKernelAsBl33} \
        QEMU_USE_GIC_DRIVER=QEMU_GICV${toString gicVersion} \
        ${lib.optionalString (preloadedBl33Base != null) "PRELOADED_BL33_BASE=${preloadedBl33Base}"} \
        ${lib.concatStringsSep " " extraMakeFlags} \
        "$@"
    }

    tfa_make bl1 bl2 bl31
    tfa_make fiptool
    runHook postBuild
  '';

  # ELFs are kept alongside the raw .bin blobs so consumers can run
  # `aarch64-none-elf-nm`/`-objdump` on them — useful for confirming
  # build-time flags actually pulled in the symbols you expected (e.g.,
  # SDEI symbols in bl31.elf).
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    install -m0644 build/${plat}/${buildSubdir}/bl1.bin    "$out/"
    install -m0644 build/${plat}/${buildSubdir}/bl2.bin    "$out/"
    install -m0644 build/${plat}/${buildSubdir}/bl31.bin   "$out/"
    install -m0644 build/${plat}/${buildSubdir}/bl1/bl1.elf   "$out/"
    install -m0644 build/${plat}/${buildSubdir}/bl2/bl2.elf   "$out/"
    install -m0644 build/${plat}/${buildSubdir}/bl31/bl31.elf "$out/"
    install -m0755 tools/fiptool/fiptool                   "$out/bin/"
    runHook postInstall
  '';

  passthru = {
    inherit plat debug;
    inherit buildSubdir;
    inherit preloadedBl33Base;
  };

  meta = {
    description = "Trusted Firmware-A BL1/BL2/BL31 + fiptool for ${plat}";
    license = lib.licenses.bsd3;
    platforms = lib.platforms.linux;
  };
}
