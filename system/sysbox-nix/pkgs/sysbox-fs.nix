{
  lib,
  buildGoModule,
  callPackage,
  libseccomp,
  pkg-config,
  fuse,
}:

let
  common = callPackage ./common.nix { };
in
buildGoModule {
  pname = "sysbox-fs";
  inherit (common) version src ldflags;

  modRoot = "sysbox-fs";
  vendorHash = "sha256-UG8SqdjivSBRhw47rE8mIjLGcoc7D7bKYxzzdPanyoI=";
  proxyVendor = true;

  nativeBuildInputs = [ pkg-config ] ++ common.protoNativeBuildInputs;
  buildInputs = [
    libseccomp
    fuse
  ];

  subPackages = [ "cmd/sysbox-fs" ];

  doCheck = false;

  inherit (common) overrideModAttrs;

  preBuild = common.protoPreBuild;

  meta = common.meta // {
    description = "Sysbox FUSE filesystem daemon — emulates procfs/sysfs inside system containers";
    mainProgram = "sysbox-fs";
  };
}
