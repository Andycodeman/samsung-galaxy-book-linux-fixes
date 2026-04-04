{ pkgs, config, ... }:

let
  lib = pkgs.lib;
  cfg = config.hardware.samsungGalaxyBook.speakerFix;

  kernelPackages = config.boot.kernelPackages;

  # Out-of-tree kernel module for MAX98390 HDA speaker amplifier
  max98390-hda = kernelPackages.callPackage ./max98390-hda-module.nix {
    sourceType = cfg.source;
    localSrc = cfg.localSrc;
    githubOwner = cfg.githubOwner;
    githubRepo = cfg.githubRepo;
    githubRev = cfg.githubRev;
    githubHash = cfg.githubHash;
  };

  # I2C setup script to create devices for additional amplifiers
  i2cSetupScript = pkgs.writeShellScript "max98390-hda-i2c-setup" ''
    export PATH="${pkgs.i2c-tools}/bin:$PATH"

    ACTION="''${1:-start}"

    ALL_ADDRS="0x38 0x39 0x3c 0x3d"

    find_i2c_bus() {
      local dev_path parent_name bus_num
      for dev in /sys/bus/i2c/devices/*MAX98390*; do
        [ -e "$dev" ] || continue
        dev_path="$(readlink -f "$dev")"
        parent_name="$(basename "$(dirname "$dev_path")")"
        bus_num="$(echo "$parent_name" | sed -n 's/^i2c-\([0-9]\+\)$/\1/p')"
        if [ -n "$bus_num" ]; then
          echo "$bus_num"
          return 0
        fi
        bus_num="$(echo "$dev_path" | sed -n 's|.*/i2c-\([0-9]\+\)/.*|\1|p')"
        if [ -n "$bus_num" ]; then
          echo "$bus_num"
          return 0
        fi
      done
      for acpi in /sys/bus/acpi/devices/MAX98390:*; do
        [ -e "$acpi/physical_node" ] || continue
        dev_path="$(readlink -f "$acpi/physical_node")"
        parent_name="$(basename "$(dirname "$dev_path")")"
        bus_num="$(echo "$parent_name" | sed -n 's/^i2c-\([0-9]\+\)$/\1/p')"
        if [ -n "$bus_num" ]; then
          echo "$bus_num"
          return 0
        fi
        bus_num="$(echo "$dev_path" | sed -n 's|.*/i2c-\([0-9]\+\)/.*|\1|p')"
        if [ -n "$bus_num" ]; then
          echo "$bus_num"
          return 0
        fi
      done
      return 1
    }

    find_present_addrs() {
      local bus="$1" addr present=""
      for addr in $ALL_ADDRS; do
        [ "$addr" = "0x38" ] && continue
        if [ -e "/sys/bus/i2c/devices/''${bus}-00''${addr#0x}" ]; then
          continue
        fi
        if i2cget -y "$bus" "$addr" 0x00 b >/dev/null 2>&1; then
          present="$present $addr"
        fi
      done
      echo "$present"
    }

    BUS=$(find_i2c_bus)
    if [ -z "$BUS" ]; then
      echo "max98390-hda: No MAX98390 ACPI device found on I2C bus" >&2
      exit 0
    fi

    SYSFS="/sys/bus/i2c/devices/i2c-''${BUS}"

    case "$ACTION" in
      start)
        ADDRS=$(find_present_addrs "$BUS")
        if [ -z "$ADDRS" ]; then
          echo "max98390-hda: No additional amplifiers found on bus $BUS"
        else
          count=$(echo "$ADDRS" | wc -w)
          echo "max98390-hda: Found $count additional amplifier(s) on bus $BUS:$ADDRS"
          for addr in $ADDRS; do
            echo "max98390-hda $addr" > "$SYSFS/new_device" 2>/dev/null || true
          done
        fi
        ;;
      stop)
        for addr in 0x3d 0x3c 0x39; do
          echo "$addr" > "$SYSFS/delete_device" 2>/dev/null || true
        done
        ;;
    esac
  '';
in
{
  options.hardware.samsungGalaxyBook.speakerFix = {
    source = lib.mkOption {
      type = lib.types.enum [ "github" "local" ];
      default = "github";
      description = "Source for building the MAX98390 speaker modules.";
    };

    localSrc = lib.mkOption {
      type = lib.types.path;
      default = ../speaker-fix/src;
      description = "Local path used when source is set to local.";
    };

    githubOwner = lib.mkOption {
      type = lib.types.str;
      default = "Andycodeman";
      description = "GitHub owner used when source is set to github.";
    };

    githubRepo = lib.mkOption {
      type = lib.types.str;
      default = "samsung-galaxy-book-linux-fixes";
      description = "GitHub repository used when source is set to github.";
    };

    githubRev = lib.mkOption {
      type = lib.types.str;
      default = "v0.3.26";
      description = "Git revision or tag used when source is set to github.";
    };

    githubHash = lib.mkOption {
      type = lib.types.str;
      default = "sha256-THezjEOxkaVnFY72zQyK2ER5VunOROm+i72JtSFCeMA=";
      description = "Content hash for the GitHub source tarball.";
    };
  };

  config = {
    # Build and install the out-of-tree kernel modules
    boot.extraModulePackages = [ max98390-hda ];

    # Load the modules at boot
    boot.kernelModules = [
      "i2c-dev"
      "snd-hda-scodec-max98390"
      "snd-hda-scodec-max98390-i2c"
    ];

    # i2c-tools needed for amplifier detection
    environment.systemPackages = [ pkgs.i2c-tools ];

    # Systemd service to create I2C devices for additional amplifiers
    systemd.services.max98390-hda-i2c-setup = {
      description = "Create I2C devices for MAX98390 HDA speaker amplifiers";
      after = [ "systemd-modules-load.service" ];
      before = [ "sound.target" ];
      wantedBy = [ "sound.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${i2cSetupScript} start";
        ExecStop = "${i2cSetupScript} stop";
      };
    };
  };
}
