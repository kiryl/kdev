{
  description = "Linux kernel development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      flake.nixosConfigurations.kernel-vm = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ ./vm.nix ];
      };

      flake.templates =
        let
          kernel-workspace = {
            path = ./templates/kernel-workspace;
            description = "direnv + CLAUDE.md scaffold for a kernel worktree area";
          };
        in
        {
          inherit kernel-workspace;
          default = kernel-workspace;
        };

      perSystem =
        { pkgs, lib, ... }:
        let
          vmCfg = self.nixosConfigurations.kernel-vm.config;
          vmImage = vmCfg.system.build.image;
          vmImageFileName = vmCfg.image.filePath;
          kdev = pkgs.callPackage ./kdev.nix { inherit vmImage vmImageFileName; };

          kernelNativeDeps = with pkgs; [
            bc
            bintools
            bison
            clang
            coccinelle
            cpio
            elfutils
            flex
            gitFull
            gmp
            gnumake
            kmod
            libmpc
            lld
            llvm
            lzop
            mpfr
            ncurses
            nettools
            openssl
            pahole
            perl
            python3
            python3Packages.gitpython
            python3Packages.ply
            ripgrep
            zlib
            zstd
          ];

          kernelDebugDeps = [
            pkgs.gdb
            pkgs.qemu_kvm
            pkgs.bpftools
            pkgs.bpftrace
            pkgs.trace-cmd
            pkgs.syzkaller
            (pkgs.callPackage ./drgn.nix { })
            kdev
          ];

          # Toolchain + libs for building userspace test cases that will
          # run inside the kernel-vm guest. Same nixpkgs as the guest, so
          # binaries' /nix/store interpreter paths already exist in the
          # guest closure -> no host/guest glibc drift.
          testBuildDeps = with pkgs; [
            gcc
            clang
            lld
            gnumake
            pkg-config
            bintools
            patchelf
            python3
          ];
          testRuntimeDeps = with pkgs; [
            libcap
            libelf
            elfutils
            zlib
            numactl
            libaio
            liburing
            libmnl
            libnl
            openssl
          ];

          syz = import ./syz.nix {
            inherit pkgs vmImage vmImageFileName;
            inherit (pkgs) syzkaller;
          };

          crossArches = {
            aarch64 = {
              attr = "aarch64-multiplatform";
              kernelArch = "arm64";
            };
            riscv = {
              attr = "riscv64";
              kernelArch = "riscv";
            };
            powerpc64 = {
              attr = "ppc64";
              kernelArch = "powerpc";
            };
            powerpc64le = {
              attr = "powernv";
              kernelArch = "powerpc";
            };
            loongarch64 = {
              attr = "loongarch64-linux";
              kernelArch = "loongarch";
            };
            mips64 = {
              attr = "mips64-linux-gnuabi64";
              kernelArch = "mips";
            };
            s390x = {
              attr = "s390x";
              kernelArch = "s390";
            };
            arm = {
              attr = "armv7l-hf-multiplatform";
              kernelArch = "arm";
            };
          };

          mkCrossShell =
            name:
            {
              attr,
              kernelArch,
            }:
            let
              cross = pkgs.pkgsCross.${attr};
            in
            pkgs.mkShell {
              name = "kernel-${name}";
              nativeBuildInputs = kernelNativeDeps ++ [
                cross.buildPackages.gcc
                cross.buildPackages.binutils
              ];
              ARCH = kernelArch;
              CROSS_COMPILE = cross.stdenv.cc.targetPrefix;
            };

          mkKmakeWrapper =
            name:
            {
              attr,
              kernelArch,
            }:
            let
              cross = pkgs.pkgsCross.${attr};
            in
            pkgs.writeShellApplication {
              name = "kmake-${name}";
              runtimeInputs = [
                pkgs.gnumake
                cross.buildPackages.gcc
                cross.buildPackages.binutils
              ];
              text = ''
                exec make \
                  ARCH=${kernelArch} \
                  CROSS_COMPILE=${cross.stdenv.cc.targetPrefix} \
                  "$@"
              '';
            };

          kmakeWrappers = lib.mapAttrsToList mkKmakeWrapper crossArches;
        in
        {
          packages = {
            vm-image = vmImage;
            kdev = kdev;
            default = kdev;
            syz-config-check = syz.config-check;
            syz-init = syz.init;
            kmake-syz = syz.kmake-syz;
          };

          apps.vm = {
            type = "app";
            program = "${kdev}/bin/kdev";
          };
          apps.syz-config-check = {
            type = "app";
            program = "${syz.config-check}/bin/syz-config-check";
          };
          apps.syz-init = {
            type = "app";
            program = "${syz.init}/bin/syz-init";
          };

          devShells = {
            default = pkgs.mkShell {
              name = "kernel-native";
              nativeBuildInputs =
                kernelNativeDeps
                ++ kernelDebugDeps
                ++ kmakeWrappers
                ++ [
                  syz.config-check
                  syz.init
                  syz.kmake-syz
                ];
            };
            test-tools = pkgs.mkShell {
              name = "kdev-test-tools";
              nativeBuildInputs = testBuildDeps;
              buildInputs = testRuntimeDeps;
            };
          } // lib.mapAttrs mkCrossShell crossArches;

          checks = import ./checks.nix {
            inherit
              pkgs
              kdev
              kmakeWrappers
              testBuildDeps
              ;
            syzConfigCheck = syz.config-check;
          };
        };
    };
}
