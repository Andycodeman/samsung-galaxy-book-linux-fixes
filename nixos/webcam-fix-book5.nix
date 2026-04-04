{ config, lib, pkgs, ... }:

let
  kernelPackages = config.boot.kernelPackages;
  cc = pkgs.llvmPackages.clang-unwrapped;

  visionDriversSrc = pkgs.fetchFromGitHub {
    owner = "intel";
    repo = "vision-drivers";
    rev = "main";
    hash = "sha256-zOvCZKGwOGT9kcJiefzx/duHqR0V8PYhNbqsMHkH1r4=";
  };

  intelCvsModule = pkgs.stdenvNoCC.mkDerivation {
    pname = "vision-driver";
    version = "1.0.0-${kernelPackages.kernel.modDirVersion}";

    src = visionDriversSrc;

    nativeBuildInputs = [ kernelPackages.kernel.dev cc pkgs.gnumake pkgs.perl pkgs.llvmPackages.lld ];

    buildPhase = ''
      make -C ${kernelPackages.kernel.dev}/lib/modules/${kernelPackages.kernel.modDirVersion}/build \
        M=$PWD modules LLVM=1 CC=${cc}/bin/clang LD=${pkgs.llvmPackages.lld}/bin/ld.lld
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

    nativeBuildInputs = [ kernelPackages.kernel.dev cc pkgs.gnumake pkgs.perl pkgs.llvmPackages.lld ];

    buildPhase = ''
      make -C ${kernelPackages.kernel.dev}/lib/modules/${kernelPackages.kernel.modDirVersion}/build \
        M=$PWD modules LLVM=1 CC=${cc}/bin/clang LD=${pkgs.llvmPackages.lld}/bin/ld.lld
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
  environment.sessionVariables.LIBCAMERA_IPA_MODULE_PATH = "${pkgs.libcamera}/lib/libcamera/ipa";

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
    environment = cameraRelayServiceEnvironment;
  };
}