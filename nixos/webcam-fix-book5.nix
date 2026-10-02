{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.hardware.samsungGalaxyBook.webcamFixBook5;
  inherit (config.boot) kernelPackages;
  inherit (kernelPackages) kernel;
  kernelUsesClang = kernel.stdenv.cc.isClang or false;
  cc =
    if kernelUsesClang
    then pkgs.llvmPackages.clang-unwrapped
    else pkgs.gcc;
  # The kernel's own make flags, not pkgs.llvmPackages: kernels that pin their
  # own nixpkgs (CachyOS) are built with a different clang/lld than the system
  # one, and objtool rejects objects from a mismatched toolchain.
  clangMakeFlags = lib.optionalString kernelUsesClang (lib.escapeShellArgs kernel.commonMakeFlags);

  # Scoped patched libcamera: same patches/yamls as upstream
  # webcam-fix-book5.nix, but as a side package instead of a global
  # nixpkgs.overlays override. System pkgs.libcamera (and therefore
  # pipewire -> sdl2-compat -> ffmpeg -> qtwebengine/electron) stays stock
  # and hits cache.nixos.org. Only the relay uses this build.
  libcamera-book5 = pkgs.libcamera.overrideAttrs (old: {
    patches =
      (old.patches or [])
      ++ [
        ../webcam-fix-book5/libcamera-bayer-fix/bayer-fix-v0.7.patch
        ../webcam-fix-book5/libcamera-bayer-fix/blc-channel-levels.patch
        ../webcam-fix-book5/libcamera-bayer-fix/agc-min-gain-step.patch
        ../webcam-fix-book5/libcamera-bayer-fix/awb-skip-saturated.patch
        ../webcam-fix-book5/libcamera-bayer-fix/agc-exposure-target.patch
      ];

    postPatch =
      (old.postPatch or "")
      + ''
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
    postInstall =
      (old.postInstall or "")
      + ''
        install -Dm644 ${../webcam-fix-book5/ov02c10.yaml} \
          $out/share/libcamera/ipa/simple/ov02c10.yaml
        install -Dm644 ${../webcam-fix-book5/ov02e10.yaml} \
          $out/share/libcamera/ipa/simple/ov02e10.yaml
      ''
      # Per-channel pedestals as offset + slope * analogue gain, fitted from
      # covered-lens raw frames at 1x-4x with dgain=1020 (960XHA). The sensor
      # digital gain scales the offsets, so they only hold for that profile.
      + lib.optionalString (cfg.lowNoise.enable && cfg.lowNoise.digitalGain == 1020) ''
        substituteInPlace $out/share/libcamera/ipa/simple/ov02e10.yaml \
          --replace-fail "      blackLevel: 4096" "      blackLevel: 4096
              channelLevels:
                r: [ 4023, -20 ]
                g: [ 4016, 56 ]
                b: [ 3995, 53 ]"
      '';
  });

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

    nativeBuildInputs =
      [kernelPackages.kernel.dev cc pkgs.gnumake pkgs.perl]
      ++ lib.optionals kernelUsesClang [pkgs.llvmPackages.lld];

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

    nativeBuildInputs =
      [kernelPackages.kernel.dev cc pkgs.gnumake pkgs.perl]
      ++ lib.optionals kernelUsesClang [pkgs.llvmPackages.lld];

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

  ov02e10LowNoiseModule = pkgs.stdenvNoCC.mkDerivation {
    pname = "ov02e10-lownoise";
    version = "1.0-${kernelPackages.kernel.modDirVersion}";

    src = ../webcam-fix-book5/ov02e10-lownoise-fix;

    nativeBuildInputs =
      [kernelPackages.kernel.dev cc pkgs.gnumake pkgs.perl]
      ++ lib.optionals kernelUsesClang [pkgs.llvmPackages.lld];

    buildPhase = ''
      make -C ${kernelPackages.kernel.dev}/lib/modules/${kernelPackages.kernel.modDirVersion}/build \
        M=$PWD modules ${clangMakeFlags}
    '';

    installPhase = ''
      install -Dm644 ov02e10.ko $out/lib/modules/${kernelPackages.kernel.modDirVersion}/extra/ov02e10.ko
    '';

    meta = with lib; {
      description = "OV02E10 driver with analog gain cap and digital gain parameters";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  cameraRelayMonitor = pkgs.stdenvNoCC.mkDerivation {
    pname = "camera-relay-monitor";
    version = "1.0";

    src = ../camera-relay;

    nativeBuildInputs = [pkgs.gcc];

    dontConfigure = true;
    dontFixup = true;

    buildPhase = ''
      gcc -O2 -Wall -o camera-relay-monitor camera-relay-monitor.c
    '';

    installPhase = ''
      install -Dm755 camera-relay-monitor $out/bin/camera-relay-monitor
    '';
  };

  relayGstPlugins = [
    pkgs.gst_all_1.gstreamer
    pkgs.gst_all_1.gst-plugins-base
    pkgs.gst_all_1.gst-plugins-good
    pkgs.gst_all_1.gst-plugins-bad
    libcamera-book5
  ];

  # The launcher execs gst-launch with a fresh environment and only trusts
  # FHS paths, so point it at the store. It is not installed setgid here:
  # the ISYS nodes are not restricted to a camera-relay group on NixOS.
  cameraRelayGst = pkgs.stdenv.mkDerivation {
    pname = "camera-relay-gst";
    version = "1.0";

    src = ../camera-relay;

    dontConfigure = true;

    postPatch =
      ''
        substituteInPlace camera-relay-gst.c \
          --replace-fail '"/usr/bin/gst-launch-1.0", "/usr/local/bin/gst-launch-1.0"' \
                         '"${pkgs.gst_all_1.gstreamer.bin}/bin/gst-launch-1.0"' \
          --replace-fail '"/usr/local/bin/cam", "/usr/bin/cam"' \
                         '"${libcamera-book5}/bin/cam"' \
          --replace-fail '"/usr/lib/", "/usr/lib64/", "/usr/share/",' \
                         '"/nix/store/", "/usr/lib/", "/usr/lib64/", "/usr/share/",' \
          --replace-fail '"/etc/glvnd/egl_vendor.d/", "/usr/share/glvnd/egl_vendor.d/",' \
                         '"/run/opengl-driver/share/glvnd/egl_vendor.d/", "/etc/glvnd/egl_vendor.d/", "/usr/share/glvnd/egl_vendor.d/",'
      ''
      # The fresh environment would drop the rotation override, and without it
      # the bayer-fix patch decodes the grid wrong (purple/green tint).
      + lib.optionalString cfg.videoFlip ''
        substituteInPlace camera-relay-gst.c \
          --replace-fail 'snprintf(buf[b], sizeof(buf[b]), "MESA_SHADER_CACHE_DIR=%s/mesa", cache_dir);' \
                         'snprintf(buf[b], sizeof(buf[b]), "MESA_SHADER_CACHE_DIR=%s/mesa", cache_dir); env[n++] = "LIBCAMERA_FORCE_OV02E10_ROTATION=180";'
      '';

    buildPhase = ''
      $CC -O2 -Wall -o camera-relay-gst camera-relay-gst.c
    '';

    installPhase = ''
      install -Dm755 camera-relay-gst $out/bin/camera-relay-gst
    '';
  };

  cameraRelay = pkgs.stdenvNoCC.mkDerivation {
    pname = "camera-relay";
    version = "1.0";

    src = ../camera-relay;

    nativeBuildInputs = [pkgs.makeWrapper];

    dontConfigure = true;
    dontFixup = true;

    installPhase = ''
      install -Dm755 camera-relay $out/share/camera-relay/camera-relay

      substituteInPlace $out/share/camera-relay/camera-relay \
        --replace "/usr/local/bin/camera-relay-monitor" "${cameraRelayMonitor}/bin/camera-relay-monitor" \
        --replace "/usr/local/bin/camera-relay-gst" "${cameraRelayGst}/bin/camera-relay-gst" \
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
        # nudge-wireplumber: v4l2-ctl, pw-dump and python3
        pkgs.v4l-utils
        pkgs.pipewire
        pkgs.python3
        libcamera-book5
        pkgs.gst_all_1.gstreamer
        pkgs.gst_all_1.gst-plugins-base
        pkgs.gst_all_1.gst-plugins-good
        pkgs.gst_all_1.gst-plugins-bad
      ]} \
        --set LIBCAMERA_IPA_MODULE_PATH ${libcamera-book5}/lib/libcamera/ipa \
        --prefix GST_PLUGIN_PATH : ${lib.makeSearchPath "lib/gstreamer-1.0" [libcamera-book5]} \
        --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [libcamera-book5]}
    '';

    meta = with lib; {
      description = "On-demand libcamera to v4l2loopback relay for Samsung Galaxy Book5";
      license = licenses.gpl2Only;
      platforms = platforms.linux;
    };
  };

  cameraRelayServiceEnvironment = {
    LIBCAMERA_IPA_MODULE_PATH = "${libcamera-book5}/lib/libcamera/ipa";
    GST_PLUGIN_SYSTEM_PATH_1_0 = lib.makeSearchPath "lib/gstreamer-1.0" (map lib.getLib [
      pkgs.gst_all_1.gstreamer
      pkgs.gst_all_1.gst-plugins-base
      pkgs.gst_all_1.gst-plugins-good
      pkgs.gst_all_1.gst-plugins-bad
    ]);
    # The launcher drops GST_PLUGIN_SYSTEM_PATH_1_0, so every plugin the
    # pipeline needs has to be on GST_PLUGIN_PATH.
    GST_PLUGIN_PATH = lib.makeSearchPath "lib/gstreamer-1.0" (map lib.getLib relayGstPlugins);
    LD_LIBRARY_PATH = lib.makeLibraryPath [libcamera-book5];
  };

  wireplumberLuaRule = ''
    -- Disable raw V4L2 IPU7 ISYS capture nodes in PipeWire.
    -- These are internal pipeline nodes from the IPU7 kernel driver that output
    -- raw bayer data unusable by applications. libcamera handles the actual camera
    -- pipeline and exposes a proper source. This rule only affects the V4L2 monitor.

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
    # pipeline and exposes a proper source. This rule only affects the V4L2 monitor.

    monitor.v4l2.rules = [
      {
        matches = [
          { api.v4l2.cap.card = "ipu7" }
        ]
        actions = {
          update-props = {
            device.disabled = true
            # api.v4l2.cap.card only reaches the node props, where
            # device.disabled is ignored.
            node.disabled = true
          }
        }
      }
    ]
  '';

  wireplumberUsesConf = lib.versionAtLeast (pkgs.wireplumber.version or "0.5") "0.5";
in {
  options.hardware.samsungGalaxyBook.webcamFixBook5 = {
    enable = lib.mkEnableOption "Samsung Galaxy Book 5 webcam fix (IPU7/OV02C10/OV02E10, relay-scoped libcamera, no system overlay)";

    videoFlip = lib.mkOption {
      type = lib.types.bool;
      default = false;
      example = true;
      description = ''
        Force the OV02E10 sensor to be treated as rotation=180 inside
        the patched relay libcamera. This corrects the Bayer grid decoding
        (fixing purple color tints) and provides rotation metadata.

        Enable this on Samsung Galaxy Book 360 / convertible models
        (NP960QHA, NP960QFG, NP960QGK, ...) where the OV02E10 sensor is
        physically mounted inverted.

        Strictly opt-in. The env var is only consumed by the libcamera
        bayer-fix patch when the sensor model is exactly `ov02e10`.
      '';
    };

    loopbackVideoNr = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.unsigned;
      default = null;
      example = 50;
      description = ''
        Fixed /dev/videoN number for the relay loopback. By default it takes
        whichever number is free when the module loads, which races the IPU7
        nodes. Pin it for consumers that need a stable path, such as face
        authentication daemons that open the node directly.
      '';
    };

    relayColorFilter = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "videoflip method=vertical-flip ! videobalance hue=0.05 saturation=0.95";
      description = ''
        Optional GStreamer elements to apply to the camera-relay output.
        Can be used to apply video flips or color balancing for V4L2 apps.
      '';
    };

    lowNoise = {
      enable = lib.mkEnableOption ''
        the OV02E10 low-noise driver, which caps analog gain and makes up the
        brightness with sensor digital gain. At high analog gain the sensor's
        column noise and per-channel black offset grow, showing as vertical
        bands and green shadows in dim rooms. See
        webcam-fix-book5/ov02e10-lownoise-fix/README.md
      '';

      maxAnalogueGain = lib.mkOption {
        type = lib.types.ints.between 16 248;
        default = 64;
        description = "Analog gain ceiling in sensor units (16 = 1x, 64 = 4x, 248 = 15.5x).";
      };

      digitalGain = lib.mkOption {
        type = lib.types.ints.between 256 1020;
        default = 1020;
        description = "Fixed sensor digital gain (256 = 1x, 1020 = ~4x).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
      # Intentionally no nixpkgs.overlays here. Upstream patches libcamera
      # globally, which cascades: libcamera -> pipewire -> sdl2-compat ->
      # ffmpeg -> qtwebengine/electron (hours of source builds, no binary
      # cache hit). libcamera-book5 above carries the same bayer-fix patch,
      # sensor helpers and tuning yamls but is referenced only by the relay,
      # so system pipewire/ffmpeg stay stock and cached.
      #
      # WirePlumber's libcamera monitor is disabled below so PipeWire
      # consumers (Chromium, Electron, Firefox PipeWire camera) only see the
      # relay node instead of a stock-libcamera one with the wrong bayer order.

      boot = {
        initrd.kernelModules = [
          "usb_ljca"
          "gpio_ljca"
          "intel_cvs"
          "ipu-bridge"
        ];

        kernelModules = [
          "usb_ljca"
          "gpio_ljca"
          "intel_cvs"
          "ipu-bridge"
          "v4l2loopback"
        ];

        extraModulePackages =
          [
            intelCvsModule
            ipuBridgeModule
            kernelPackages.v4l2loopback
          ]
          ++ lib.optional cfg.lowNoise.enable ov02e10LowNoiseModule;

        extraModprobeConfig = lib.mkIf cfg.lowNoise.enable ''
          options ov02e10 max_again=${toString cfg.lowNoise.maxAnalogueGain} dgain=${toString cfg.lowNoise.digitalGain}
        '';
      };

      environment = {
        systemPackages = [cameraRelay];

        sessionVariables =
          {
            LIBCAMERA_IPA_MODULE_PATH = "${libcamera-book5}/lib/libcamera/ipa";
          }
          // lib.optionalAttrs cfg.videoFlip {
            LIBCAMERA_FORCE_OV02E10_ROTATION = "180";
          };

        etc =
          {
            "modules-load.d/intel-ipu7-camera.conf".text = ''
              # IPU7 camera module chain for Lunar Lake
              # LJCA provides GPIO/USB control for the vision subsystem
              usb_ljca
              gpio_ljca
              # Intel Computer Vision Subsystem, powers the camera sensor
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
              options v4l2loopback devices=1 exclusive_caps=0 card_label="Built-in Front Camera"${lib.optionalString (cfg.loopbackVideoNr != null) " video_nr=${toString cfg.loopbackVideoNr}"}
            '';
          }
          // lib.optionalAttrs wireplumberUsesConf {
            "wireplumber/wireplumber.conf.d/50-disable-ipu7-v4l2.conf".text = wireplumberConfRule;
          }
          // lib.optionalAttrs (!wireplumberUsesConf) {
            "wireplumber/main.lua.d/51-disable-ipu7-v4l2.lua".text = wireplumberLuaRule;
          };
      };

      # Also keeps PipeWire from holding the sensor the relay needs.
      services.pipewire.wireplumber.extraConfig."51-disable-libcamera-monitor" = {
        "wireplumber.profiles".main."monitor.libcamera" = "disabled";
      };

      systemd.user.services = {
        camera-relay = {
          description = "Camera Relay (on-demand libcamera to v4l2loopback)";
          after = ["pipewire.service" "wireplumber.service"];
          wantedBy = ["default.target"];
          serviceConfig = {
            Type = "simple";
            CacheDirectory = "camera-relay";
            RuntimeDirectory = "camera-relay";
            ExecStart = "${cameraRelay}/bin/camera-relay start --on-demand";
            # WirePlumber probes the loopback before the monitor pins YUYV and
            # caches the catch-all range, which WebRTC cannot use.
            ExecStartPost = "-${cameraRelay}/bin/camera-relay nudge-wireplumber";
            ExecStop = "${cameraRelay}/bin/camera-relay stop";
            Restart = "on-failure";
            RestartSec = 5;
          };
          environment =
            cameraRelayServiceEnvironment
            // lib.optionalAttrs cfg.videoFlip {
              LIBCAMERA_FORCE_OV02E10_ROTATION = "180";
            }
            // lib.optionalAttrs (cfg.relayColorFilter != "") {
              RELAY_COLOR_FILTER = cfg.relayColorFilter;
            };
        };

        pipewire.environment = lib.optionalAttrs cfg.videoFlip {
          LIBCAMERA_FORCE_OV02E10_ROTATION = "180";
        };

        wireplumber.environment = lib.optionalAttrs cfg.videoFlip {
          LIBCAMERA_FORCE_OV02E10_ROTATION = "180";
        };
      };
  };
}
