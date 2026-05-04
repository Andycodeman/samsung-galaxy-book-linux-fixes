{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.samsungGalaxyBook.webcamFixBook5;
  kernelPackages = config.boot.kernelPackages;
  kernel = kernelPackages.kernel;
  kernelUsesClang = (kernel.stdenv.cc.isClang or false);
  cc = if kernelUsesClang then pkgs.llvmPackages.clang-unwrapped else pkgs.gcc;
  clangMakeFlags = lib.optionalString kernelUsesClang "LLVM=1 CC=${cc}/bin/clang LD=${pkgs.llvmPackages.lld}/bin/ld.lld";

  visionDriversSrc = pkgs.fetchFromGitHub {
    owner = "intel";
    repo = "vision-drivers";
    rev = "a8d772f261bc90376944956b7bfd49b325ffa2f2";
    hash = "sha256-zOvCZKGwOGT9kcJiefzx/duHqR0V8PYhNbqsMHkH1r4=";
  };

  intelCvsModule = pkgs.stdenvNoCC.mkDerivation {
    pname = "vision-driver";
    version = "1.0.0-${kernelPackages.kernel.modDirVersion}";

    src = visionDriversSrc;

    nativeBuildInputs = [ kernelPackages.kernel.dev cc pkgs.gnumake pkgs.perl ]
      ++ lib.optionals kernelUsesClang [ pkgs.llvmPackages.lld ];

    buildPhase = ''
      make -C ${kernelPackages.kernel.dev}/lib/modules/${kernelPackages.kernel.modDirVersion}/build \
        M=$PWD modules ${clangMakeFlags}
    '';

    installPhase = ''
      install -Dm644 intel_cvs.ko $out/lib/modules/${kernelPackages.kernel.modDirVersion}/extra/intel_cvs.ko
    '';

    meta = with lib; {
      description = "Intel Vision Driver (intel_cvs) for Samsung Galaxy Book5 webcam support";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  ipuBridgeModule = pkgs.stdenvNoCC.mkDerivation {
    pname = "ipu-bridge-fix";
    version = "1.1-${kernelPackages.kernel.modDirVersion}";

    src = ../webcam-fix-book5/ipu-bridge-fix;

    nativeBuildInputs = [ kernelPackages.kernel.dev cc pkgs.gnumake pkgs.perl ]
      ++ lib.optionals kernelUsesClang [ pkgs.llvmPackages.lld ];

    buildPhase = ''
      make -C ${kernelPackages.kernel.dev}/lib/modules/${kernelPackages.kernel.modDirVersion}/build \
        M=$PWD modules ${clangMakeFlags}
    '';

    installPhase = ''
      install -Dm644 ipu-bridge.ko $out/lib/modules/${kernelPackages.kernel.modDirVersion}/extra/ipu-bridge.ko
    '';

    meta = with lib; {
      description = "Samsung ipu-bridge rotation fix for Galaxy Book5 cameras";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  cameraRelayMonitor = pkgs.stdenvNoCC.mkDerivation {
    pname = "camera-relay-monitor";
    version = "1.0";

    src = ../camera-relay;

    nativeBuildInputs = [ pkgs.gcc ];

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      gcc -O2 -Wall -o camera-relay-monitor camera-relay-monitor.c
    '';

    installPhase = ''
      install -Dm755 camera-relay-monitor $out/bin/camera-relay-monitor
    '';
  };

  cameraRelay = pkgs.stdenvNoCC.mkDerivation {
    pname = "camera-relay";
    version = "1.0";

    src = ../camera-relay;

    nativeBuildInputs = [ pkgs.makeWrapper ];

    dontConfigure = true;
    dontFixup = true;

    installPhase = ''
      install -Dm755 camera-relay $out/share/camera-relay/camera-relay

      substituteInPlace $out/share/camera-relay/camera-relay \
        --replace "/usr/local/bin/camera-relay-monitor" "${cameraRelayMonitor}/bin/camera-relay-monitor" \
        --replace "/usr/local/bin/camera-relay" "$out/bin/camera-relay"

      mkdir -p $out/bin
      makeWrapper $out/share/camera-relay/camera-relay $out/bin/camera-relay \
        --prefix PATH : ${lib.makeBinPath [
          pkgs.bash
          pkgs.coreutils
          pkgs.findutils
          pkgs.gawk
          pkgs.gnugrep
          pkgs.gnused
          pkgs.kmod
          pkgs.procps
          pkgs.systemd
          pkgs.util-linux
          pkgs.libcamera
          pkgs.gst_all_1.gstreamer
          pkgs.gst_all_1.gst-plugins-base
          pkgs.gst_all_1.gst-plugins-good
          pkgs.gst_all_1.gst-plugins-bad
        ]} \
        --set LIBCAMERA_IPA_MODULE_PATH ${pkgs.libcamera}/lib/libcamera/ipa \
        --prefix GST_PLUGIN_PATH : ${lib.makeSearchPath "lib/gstreamer-1.0" [ pkgs.libcamera ]} \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ pkgs.libcamera ]}
    '';

    meta = with lib; {
      description = "On-demand libcamera to v4l2loopback relay for Samsung Galaxy Book5";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  cameraRelayServiceEnvironment = {
    LIBCAMERA_IPA_MODULE_PATH = "${pkgs.libcamera}/lib/libcamera/ipa";
    GST_PLUGIN_PATH = lib.makeSearchPath "lib/gstreamer-1.0" [ pkgs.libcamera ];
    LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.libcamera ];
  };

  wireplumberLuaRule = ''
    -- Disable raw V4L2 IPU7 ISYS capture nodes in PipeWire.
    -- These are internal pipeline nodes from the IPU7 kernel driver that output
    -- raw bayer data unusable by applications. libcamera handles the actual camera
    -- pipeline and exposes a proper source — this rule only affects the V4L2 monitor.

    table.insert(v4l2_monitor.rules, {
      matches = {
        {
          { "api.v4l2.cap.card", "matches", "ipu7" },
        },
      },
      apply_properties = {
        ["device.disabled"] = true,
      },
    })
  '';

  wireplumberConfRule = ''
    # Disable raw V4L2 IPU7 ISYS capture nodes in PipeWire.
    # These are internal pipeline nodes from the IPU7 kernel driver that output
    # raw bayer data unusable by applications. libcamera handles the actual camera
    # pipeline and exposes a proper source — this rule only affects the V4L2 monitor.

    monitor.v4l2.rules = [
      {
        matches = [
          { api.v4l2.cap.card = "ipu7" }
        ]
        actions = {
          update-props = {
            device.disabled = true
          }
        }
      }
    ]
  '';

  wireplumberUsesConf = lib.versionAtLeast (pkgs.wireplumber.version or "0.5") "0.5";
in
{
  options.hardware.samsungGalaxyBook.webcamFixBook5 = {
    videoFlip = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Force the OV02E10 sensor to be treated as rotation=180 inside
        libcamera, and apply the same flip to the camera-relay output
        via `RELAY_COLOR_FILTER=videoflip method=vertical-flip` for the
        v4l2loopback path.

        Enable this on Samsung Galaxy Book 360 / convertible models
        (NP960QHA, NP960QFG, NP960QGK, ...) where the OV02E10 sensor is
        physically mounted inverted. Normally the bundled ipu-bridge
        kernel module override reports rotation=180 to libcamera via
        SSDB and everything Just Works — but on NixOS the in-tree
        ipu-bridge can win at modprobe time and the rotation is never
        reported. This option papers over that by:

        1. Setting `LIBCAMERA_FORCE_OV02E10_ROTATION=180` system-wide,
           which the bundled libcamera bayer-fix patch consumes to
           force a 180-degree transform on the ov02e10 sensor only.
           PipeWire-using apps (Firefox with
           `media.webrtc.camera.allow-pipewire = true`, GNOME
           Snapshot, etc.) get correctly oriented + correctly coloured
           output via libcamera-direct.

        2. Setting `RELAY_COLOR_FILTER=videoflip method=vertical-flip`
           on the camera-relay user service so V4L2-only apps that go
           through the v4l2loopback bridge also get a flipped frame.

        Strictly opt-in. The env var is only consumed by the libcamera
        bayer-fix patch when the sensor model is exactly `ov02e10`, so
        other sensors and other distros' libcamera builds are
        unaffected even if the env var is set.

        Leave disabled if your image is already correctly oriented.
      '';
    };
  };

  config = {
  # OV02E10 (Book5) can show purple/green tint when rotated because the
  # kernel driver may not update Bayer layout metadata after transform.
  # Patch libcamera Simple pipeline to recompute Bayer order from transform.
  # Also install the OV02C10 / OV02E10 sensor color tuning files into
  # libcamera's IPA simple-pipeline data dir — without these, libcamera's
  # software ISP falls back to uncalibrated.yaml (no CCM) and produces a
  # heavily desaturated, green-tinted image.
  nixpkgs.overlays = [
    (final: prev: {
      libcamera = prev.libcamera.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
          ../webcam-fix-book5/libcamera-bayer-fix/bayer-fix-v0.6.patch
        ];
        postPatch = (old.postPatch or "") + ''
          # libcamera 0.7.0 does NOT register CameraSensorHelper for OV02C10
          # or OV02E10. Without these helpers, IPASoft's auto-exposure falls
          # back to a generic linear-gain default that fails on these
          # sensors — apps connect but get no usable frames (or a dim,
          # washed-out image). The bash installer's
          # build-patched-libcamera.sh adds them via sed; we mirror that
          # here as a postPatch so the helpers land in the libcamera
          # derivation. Both sensors share the same gain model as OV02C10
          # (gain = value/16), confirmed by the OV02E10 datasheet.
          HELPER_FILE=""
          for candidate in src/ipa/libipa/camera_sensor_helper.cpp \
                           src/libcamera/sensor/camera_sensor_helper.cpp; do
            if [ -f "$candidate" ]; then
              HELPER_FILE="$candidate"
              break
            fi
          done
          if [ -n "$HELPER_FILE" ]; then
            if ! grep -q 'CameraSensorHelperOv02c10' "$HELPER_FILE"; then
              sed -i '/#endif.*__DOXYGEN__/i\
          class CameraSensorHelperOv02c10 : public CameraSensorHelper\
          {\
          public:\
          \tCameraSensorHelperOv02c10()\
          \t{\
          \t\tgain_ = AnalogueGainLinear{ 1, 0, 0, 16 };\
          \t}\
          };\
          REGISTER_CAMERA_SENSOR_HELPER("ov02c10", CameraSensorHelperOv02c10)\
          ' "$HELPER_FILE"
            fi
            if ! grep -q 'CameraSensorHelperOv02e10' "$HELPER_FILE"; then
              sed -i '/#endif.*__DOXYGEN__/i\
          class CameraSensorHelperOv02e10 : public CameraSensorHelper\
          {\
          public:\
          \tCameraSensorHelperOv02e10()\
          \t{\
          \t\tgain_ = AnalogueGainLinear{ 1, 0, 0, 16 };\
          \t}\
          };\
          REGISTER_CAMERA_SENSOR_HELPER("ov02e10", CameraSensorHelperOv02e10)\
          ' "$HELPER_FILE"
            fi
          fi
        '';
        postInstall = (old.postInstall or "") + ''
          install -Dm644 ${../webcam-fix-book5/ov02c10.yaml} \
            $out/share/libcamera/ipa/simple/ov02c10.yaml
          install -Dm644 ${../webcam-fix-book5/ov02e10.yaml} \
            $out/share/libcamera/ipa/simple/ov02e10.yaml
        '';
      });
    })
  ];

  boot.initrd.kernelModules = [
    "usb_ljca"
    "gpio_ljca"
    "intel_cvs"
    "ipu-bridge"
  ];

  boot.kernelModules = [
    "usb_ljca"
    "gpio_ljca"
    "intel_cvs"
    "ipu-bridge"
    "v4l2loopback"
  ];

  boot.extraModulePackages = [
    intelCvsModule
    ipuBridgeModule
    kernelPackages.v4l2loopback
  ];

  environment.systemPackages = [ cameraRelay ];
  environment.sessionVariables = {
    LIBCAMERA_IPA_MODULE_PATH = "${pkgs.libcamera}/lib/libcamera/ipa";
  } // lib.optionalAttrs cfg.videoFlip {
    # Consumed by the bundled libcamera bayer-fix patch only when sensor
    # model is exactly "ov02e10" — strict opt-in, no effect on other
    # sensors or systems where the env var isn't set.
    LIBCAMERA_FORCE_OV02E10_ROTATION = "180";
  };

  environment.etc = {
    "modules-load.d/intel-ipu7-camera.conf".text = ''
      # IPU7 camera module chain for Lunar Lake
      # LJCA provides GPIO/USB control for the vision subsystem
      usb_ljca
      gpio_ljca
      # Intel Computer Vision Subsystem — powers the camera sensor
      intel_cvs
    '';

    "modprobe.d/intel-ipu7-camera.conf".text = ''
      # Ensure LJCA and intel_cvs are loaded before the camera sensor probes.
      # Without this, the sensor may fail to bind on boot.
      # LJCA (GPIO/USB) -> intel_cvs (CVS) -> sensor
      softdep intel_cvs pre: usb_ljca gpio_ljca
      softdep ov02c10 pre: intel_cvs usb_ljca gpio_ljca
      softdep ov02e10 pre: intel_cvs usb_ljca gpio_ljca
    '';

    "modprobe.d/99-camera-relay-loopback.conf".text = ''
      options v4l2loopback devices=1 exclusive_caps=0 card_label="Camera Relay"
    '';
  } // lib.optionalAttrs wireplumberUsesConf {
    "wireplumber/wireplumber.conf.d/50-disable-ipu7-v4l2.conf".text = wireplumberConfRule;
  } // lib.optionalAttrs (!wireplumberUsesConf) {
    "wireplumber/main.lua.d/51-disable-ipu7-v4l2.lua".text = wireplumberLuaRule;
  };

  systemd.user.services.camera-relay = {
    description = "Camera Relay (on-demand libcamera to v4l2loopback)";
    after = [ "pipewire.service" "wireplumber.service" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${cameraRelay}/bin/camera-relay start --on-demand";
      ExecStop = "${cameraRelay}/bin/camera-relay stop";
      Restart = "on-failure";
      RestartSec = 5;
    };
    environment = cameraRelayServiceEnvironment // lib.optionalAttrs cfg.videoFlip {
      RELAY_COLOR_FILTER = "videoflip method=vertical-flip";
      LIBCAMERA_FORCE_OV02E10_ROTATION = "180";
    };
  };

  # Also push LIBCAMERA_FORCE_OV02E10_ROTATION onto PipeWire/WirePlumber so
  # libcamera-direct apps (Firefox with PipeWire WebRTC, GNOME Snapshot,
  # etc.) get the rotation override. environment.sessionVariables flows
  # to user systemd via PAM session import on next login, but explicit
  # service env makes the fix take effect immediately after rebuild +
  # `systemctl --user restart pipewire wireplumber`.
  systemd.user.services.pipewire.environment = lib.optionalAttrs cfg.videoFlip {
    LIBCAMERA_FORCE_OV02E10_ROTATION = "180";
  };
  systemd.user.services.wireplumber.environment = lib.optionalAttrs cfg.videoFlip {
    LIBCAMERA_FORCE_OV02E10_ROTATION = "180";
  };
  };
  };
}