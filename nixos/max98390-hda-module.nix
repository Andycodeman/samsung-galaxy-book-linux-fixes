{
  stdenvNoCC,
  lib,
  kernel,
  fetchFromGitHub,
  llvmPackages,
  gcc,
  sourceType ? "github",
  localSrc ? ../speaker-fix/src,
  githubOwner ? "Andycodeman",
  githubRepo ? "samsung-galaxy-book-linux-fixes",
  githubRev ? "v0.3.26",
  githubHash ? "sha256-THezjEOxkaVnFY72zQyK2ER5VunOROm+i72JtSFCeMA=",
}:

let
  kernelUsesClang = kernel.stdenv.cc.isClang or false;
  cc = if kernelUsesClang then llvmPackages.clang-unwrapped else gcc;
  src = if sourceType == "local" then localSrc else fetchFromGitHub {
    owner = githubOwner;
    repo = githubRepo;
    rev = githubRev;
    hash = githubHash;
  };
in

stdenvNoCC.mkDerivation {
  pname = "max98390-hda";
  version = "1.0-${kernel.version}";

  inherit src;
  sourceRoot = lib.optionalString (sourceType == "github") "source/speaker-fix/src";

  nativeBuildInputs =
    kernel.moduleBuildDependencies
    ++ [ cc ]
    ++ lib.optionals kernelUsesClang [ llvmPackages.lld ];

  makeFlags = [
    "KVER=${kernel.modDirVersion}"
    "KDIR=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
  ] ++ lib.optionals kernelUsesClang [
    "LLVM=1"
    "CC=${cc}/bin/clang"
    "LD=${llvmPackages.lld}/bin/ld.lld"
  ];

  installPhase = ''
    install -D snd-hda-scodec-max98390.ko $out/lib/modules/${kernel.modDirVersion}/extra/snd-hda-scodec-max98390.ko
    install -D snd-hda-scodec-max98390-i2c.ko $out/lib/modules/${kernel.modDirVersion}/extra/snd-hda-scodec-max98390-i2c.ko
  '';

  meta = with lib; {
    description = "MAX98390 HDA speaker amplifier driver for Samsung Galaxy Book4";
    license = licenses.gpl2Only;
    platforms = platforms.linux;
  };
}
