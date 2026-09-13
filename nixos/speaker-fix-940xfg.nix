# Samsung Galaxy Book3 Pro 14" (NP940XFG) internal speaker fix for NixOS.
#
# This is the declarative equivalent of `speaker-fix-940xfg/install.sh`. It is
# a *different* fix from `samsung-speaker-fix.nix`: that one builds the
# MAX98390 HDA out-of-tree modules for the Book4 Pro/Ultra and Book5 Pro. This
# board has no MAX98390 amps at all — it has an ALC298 codec whose four
# internal class-D amps (NIDs 0x38, 0x39, 0x3C, 0x3D) are never initialized
# because mainline has no SND_PCI_QUIRK entry for SSID 0x144dc882. The fix is
# pure userspace: replay the Windows COEF init sequence with hda-verb.
#
# Usage (configuration.nix):
#
#   imports = [ /path/to/samsung-galaxy-book-linux-fixes/nixos/speaker-fix-940xfg.nix ];
#   hardware.samsungGalaxyBook.speakerFix940xfg.enable = true;
#
# See nixos/README.md for flake-based usage.
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.samsungGalaxyBook.speakerFix940xfg;

  # Package the shipped script verbatim rather than re-encoding the COEF
  # sequence here — the bash installer and this module must not drift apart.
  # The script matches on vendor_id/subsystem_id itself and exits 0 on any
  # other codec, so firing it on the wrong hardware is harmless.
  alc298-amp-init = pkgs.stdenvNoCC.mkDerivation {
    pname = "alc298-amp-init";
    version = "1.0";

    src = ../speaker-fix-940xfg;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    dontConfigure = true;
    dontBuild = true;

    installPhase = ''
      install -Dm755 alc298-amp-init.sh $out/bin/alc298-amp-init
      patchShebangs $out/bin/alc298-amp-init
      wrapProgram $out/bin/alc298-amp-init \
        --prefix PATH : ${lib.makeBinPath [
          pkgs.alsa-tools
          pkgs.coreutils
          pkgs.util-linux
        ]}
    '';

    meta = with lib; {
      description = "ALC298 internal speaker amp init for Samsung Galaxy Book3 Pro 14in (940XFG)";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };
in
{
  options.hardware.samsungGalaxyBook.speakerFix940xfg = {
    # Do NOT enable on a Book4/Book5 with MAX98390 amps — use
    # samsung-speaker-fix.nix there instead.
    enable = lib.mkEnableOption ''the Samsung Galaxy Book3 Pro 14" (NP940XFG, ALC298, SSID 0x144dc882) internal speaker fix'';
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ alc298-amp-init ];

    # Deliberately no wantedBy: udev starts this unit once the sound card is
    # fully registered. Starting it from the boot transaction instead races the
    # codec — the script no-ops, and RemainAfterExit then makes udev's later
    # trigger do nothing at all.
    systemd.services.alc298-amp-init = {
      description = ''Initialize ALC298 internal speaker amps (Samsung Galaxy Book3 Pro 14" / 940XFG)'';
      documentation = [ "https://github.com/Andycodeman/samsung-galaxy-book-linux-fixes/issues/44" ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${alc298-amp-init}/bin/alc298-amp-init";
      };
    };

    # controlC* and not hwC?D*: systemd's own rules only tag controlC*, so a
    # hwC?D? trigger would never be tagged for systemd. controlC* appears from
    # snd_card_register(), i.e. after every codec's hwdep node exists.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="sound", KERNEL=="controlC?", TAG+="systemd", ENV{SYSTEMD_WANTS}+="alc298-amp-init.service"
    '';

    # Suspend power-cycles the codec, so the COEF writes are lost across S3.
    powerManagement.resumeCommands = ''
      ${alc298-amp-init}/bin/alc298-amp-init || true
    '';
  };
}
