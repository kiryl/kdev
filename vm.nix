{
  pkgs,
  lib,
  modulesPath,
  ...
}:
{
  imports = [
    "${modulesPath}/virtualisation/disk-image.nix"
  ];

  image.baseName = "kernel-vm";
  virtualisation.diskSize = 32 * 1024;

  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty0"
  ];

  boot.initrd.availableKernelModules = [
    "virtio_blk"
    "virtio_net"
    "virtio_pci"
    "virtio_scsi"
    "virtio_rng"
    "virtiofs"
  ];
  boot.kernelModules = [ "virtiofs" ];

  fileSystems."/home/kas/git" = {
    device = "home-kas-git";
    fsType = "virtiofs";
    options = [
      "nofail"
      "x-systemd.automount"
    ];
  };
  fileSystems."/home/kas/var" = {
    device = "home-kas-var";
    fsType = "virtiofs";
    options = [
      "nofail"
      "x-systemd.automount"
    ];
  };
  fileSystems."/lib/modules" = {
    device = "kernel-modules";
    fsType = "virtiofs";
    options = [
      "ro"
      "nofail"
      "x-systemd.automount"
      "x-systemd.mount-timeout=5s"
    ];
  };

  networking.hostName = "kernel-vm";
  networking.useDHCP = lib.mkDefault true;
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = lib.mkForce "yes";
    settings.PasswordAuthentication = true;
    # syzkaller drops its pubkey here on the host; we read it via the
    # existing $HOME/var virtiofs share. No image rebuild per key.
    authorizedKeysFiles = lib.mkBefore [ "/home/kas/var/.syz/authorized_keys" ];
  };

  environment.systemPackages = with pkgs; [
    bpftools
    bpftrace
    fio
    gdb
    kmod
    perf
    strace
    trace-cmd
    xfsprogs
    (callPackage ./drgn.nix { })
  ];

  users.users.kas = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
    initialPassword = "test";
  };
  users.users.root.initialPassword = "test";
  security.sudo.wheelNeedsPassword = false;

  services.getty.autologinUser = "kas";

  # Test-case runner: picks up `kdev.run=<dir>` from the kernel cmdline,
  # executes <dir>/script as root, writes stdout+stderr to <dir>/log and
  # exit code to <dir>/exit, then powers off. kdev on the host stages
  # the script under $HOME/var/.kdev-run/<id>/ and reads back the result.
  systemd.services.kdev-run = {
    description = "linux-dev-env test-case runner (kdev.run=<dir>)";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    unitConfig.ConditionKernelCommandLine = "kdev.run";
    path = with pkgs; [
      bash
      coreutils
      systemd
      util-linux
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = false;
      User = "root";
      StandardOutput = "journal+console";
      StandardError = "journal+console";
    };
    script = ''
      run_dir=$(tr ' ' '\n' < /proc/cmdline | grep -oE '^kdev\.run=.+' || true)
      run_dir=''${run_dir#kdev.run=}
      rc=127
      if [ -n "$run_dir" ] && [ -d "$run_dir" ] && [ -x "$run_dir/script" ]; then
        echo "kdev-run: executing $run_dir/script"
        "$run_dir/script" 2>&1 | tee "$run_dir/log"
        rc=''${PIPESTATUS[0]:-1}
        echo "kdev-run: exit=$rc"
      else
        echo "kdev-run: bad run_dir=$run_dir" >&2
      fi
      if [ -n "$run_dir" ] && [ -d "$run_dir" ]; then
        echo "$rc" > "$run_dir/exit" 2>/dev/null || true
        dmesg > "$run_dir/dmesg" 2>/dev/null || true
      fi
      sync
      # --no-block: return before the shutdown job stops this very service.
      systemctl --no-block poweroff
      exit 0
    '';
  };

  system.stateVersion = "25.05";
}
