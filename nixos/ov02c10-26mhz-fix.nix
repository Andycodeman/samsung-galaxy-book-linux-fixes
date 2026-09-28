# OV02C10 26 MHz external-clock fix for NixOS.
#
# Some Galaxy Book3/Book4 boards clock the OV02C10 at 26 MHz, but the in-tree
# driver only accepts 19.2 MHz and refuses to probe:
#
#   ov02c10 i2c-OVTI02C1:00: error -EINVAL: external clock 26000000 is not supported
#   ov02c10 i2c-OVTI02C1:00: probe with driver ov02c10 failed with error -22
#
# When that happens the sensor never appears at all, so *no* camera stack can
# work — not libcamera, not icamerasrc/`hardware.ipu6`. Fix this first, then
# worry about the camera stack.
#
# This is the declarative equivalent of `ov02c10-26mhz-fix/install.sh` (DKMS).
# The 26 MHz clock is a per-BOARD property, not per-model: two machines with
# the same model number can disagree. Decide by the dmesg line above, never by
# model. That is why this is strictly opt-in.
#
# Usage (configuration.nix):
#
#   imports = [ /path/to/samsung-galaxy-book-linux-fixes/nixos/ov02c10-26mhz-fix.nix ];
#   hardware.samsungGalaxyBook.ov02c10ClockFix.enable = true;
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.samsungGalaxyBook.ov02c10ClockFix;

  kernelPackages = config.boot.kernelPackages;
  kernel = kernelPackages.kernel;
  kernelUsesClang = (kernel.stdenv.cc.isClang or false);
  cc = if kernelUsesClang then pkgs.llvmPackages.clang-unwrapped else pkgs.gcc;
  clangMakeFlags = lib.optionalString kernelUsesClang
    "LLVM=1 CC=${cc}/bin/clang LD=${pkgs.llvmPackages.lld}/bin/ld.lld";

  ov02c10Module = pkgs.stdenvNoCC.mkDerivation {
    pname = "ov02c10-26mhz";
    version = "1.0-${kernel.modDirVersion}";

    src = ../ov02c10-26mhz-fix;

    nativeBuildInputs = [ kernel.dev cc pkgs.gnumake pkgs.perl ]
      ++ lib.optionals kernelUsesClang [ pkgs.llvmPackages.lld ];

    buildPhase = ''
      make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build \
        M=$PWD modules ${clangMakeFlags}
    '';

    # updates/ is where DKMS puts it. NixOS merges the kernel and every
    # boot.extraModulePackages into one buildEnv and re-runs depmod over the
    # result; depmod's default search order puts updates/ ahead of the in-tree
    # kernel/ tree, so this copy is the one modules.dep resolves to. Verified
    # against a synthetic in-tree conflict, not assumed.
    installPhase = ''
      install -Dm644 ov02c10.ko \
        $out/lib/modules/${kernel.modDirVersion}/updates/ov02c10.ko
    '';

    meta = with lib; {
      description = "OV02C10 sensor driver patched to accept a 26 MHz external clock";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };
in
{
  options.hardware.samsungGalaxyBook.ov02c10ClockFix = {
    # Strictly opt-in: confirm the clock rejection in dmesg first. On an
    # unaffected board this replaces a working in-tree driver for no reason.
    enable = lib.mkEnableOption ''the patched OV02C10 driver that accepts a 26 MHz external clock. Enable only if dmesg shows "external clock 26000000 is not supported" - the clock rate is per-board, so do not go by model number'';
  };

  config = lib.mkIf cfg.enable {
    boot.extraModulePackages = [ ov02c10Module ];
  };
}
