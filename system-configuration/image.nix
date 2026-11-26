{
  modulesPath,
  pkgs,
  config,
  lib,
  ...
}:

{
  imports = [
    (modulesPath + "/image/repart.nix")
    (modulesPath + "/profiles/image-based-appliance.nix")
  ];

  # How to mount everything
  fileSystems = {
    "/" = {
      device = "/dev/disk/by-partlabel/root";
      fsType = "xfs";
    };
    "/boot" = {
      device = "/dev/disk/by-partlabel/boot";
      fsType = "vfat";
    };
    "/nix/store" = {
      device = "/dev/disk/by-partlabel/nix-store_${config.system.image.version}";
      fsType = "squashfs";
    };
  };

  # boot is systemd-boot + UKI
  boot.loader.grub.enable = false;

  system.image.id = "bespokeos";
  system.nixos.distroName = "BespokeOS";

  # First-boot initrd and runtime systemd-repart configuration
  boot.initrd.systemd = {
    repart.enable = true;
    extraBin."mkfs.xfs" = "${pkgs.xfsprogs}/bin/mkfs.xfs";
    services.systemd-repart = {
      requires = lib.mkForce [ "dev-disk-by\\x2dpartlabel-boot.device" ];
      after = lib.mkForce [
        "dev-disk-by\\x2dpartlabel-boot.device"
        "systemd-tmpfiles-setup-dev.service"
      ];
      before = [
        "sysroot.mount"
        "initrd-root-fs.target"
      ];
      wantedBy = [ "sysroot.mount" ];
      environment.TMPDIR = "/tmp";
      serviceConfig = {
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = lib.mkForce [
          ""
          "${pkgs.writeShellScript "systemd-repart-initrd" ''
            set -eux
            part=$(${pkgs.coreutils}/bin/readlink -f /dev/disk/by-partlabel/boot)
            disk=/dev/$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/dirname "$(${pkgs.coreutils}/bin/readlink -f "/sys/class/block/$(${pkgs.coreutils}/bin/basename "$part")")")")
            ${config.boot.initrd.systemd.package}/bin/systemd-repart --definitions=/etc/repart.d --dry-run=no "$disk"
            ${config.boot.initrd.systemd.package}/bin/udevadm settle
          ''}"
        ];
      };
    };
  };

  systemd.repart = {
    enable = true;
    partitions = {
      "10-esp" = {
        Type = "esp";
        SizeMinBytes = "200M";
      };
      "20-nix-store-a" = {
        Type = "linux-generic";
        ReadOnly = "yes";
        SizeMinBytes = "2G";
        SizeMaxBytes = "2G";
      };
      "30-nix-store-b" = {
        Type = "linux-generic";
        Label = "_empty";
        ReadOnly = "yes";
        SizeMinBytes = "2G";
        SizeMaxBytes = "2G";
      };
      "40-root" = {
        Type = "root";
        Format = "xfs";
        Label = "root";
        SizeMinBytes = "300M";
        GrowFileSystem = "yes";
        Weight = 1000;
        MakeDirectories = "/boot /nix/store /var /etc /root /home /tmp";
      };
    };
  };

  # Build-time image description (ESP + minimized Slot A; Slot B and root are created on first boot)
  image.repart =
    let
      inherit (pkgs.stdenv.hostPlatform) efiArch;
    in
    {
      enable = true;
      name = config.system.image.id;
      split = true;
      compression = {
        enable = true;
        algorithm = "zstd";
      };

      partitions = {
        esp = {
          contents = {
            "/EFI/BOOT/BOOT${lib.toUpper efiArch}.EFI".source =
              "${pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${efiArch}.efi";

            "/EFI/Linux/${config.system.boot.loader.ukiFile}".source =
              "${config.system.build.uki}/${config.system.boot.loader.ukiFile}";

            # Optional but we don't see the system selection w/o timeout
            "/loader/loader.conf".source = builtins.toFile "loader.conf" ''
              timeout 5
            '';
          };
          repartConfig = {
            Type = "esp";
            Label = "boot";
            Format = "vfat";
            SizeMinBytes = "200M";
            SplitName = "-";
          };
        };
        nix-store = {
          storePaths = [ config.system.build.toplevel ];
          nixStorePrefix = "/";
          repartConfig = {
            Type = "linux-generic";
            Label = "nix-store_${config.system.image.version}";
            Minimize = "best";
            Format = "squashfs";
            ReadOnly = "yes";
            SplitName = "nix-store";
          };
        };
      };
    };
}
