{
  lib,
  buildGoModule,
  callPackage,
  libseccomp,
  pkg-config,
}:

let
  common = callPackage ./common.nix { };
in
buildGoModule {
  pname = "sysbox-mgr";
  inherit (common) version src ldflags;

  modRoot = "sysbox-mgr";
  vendorHash = "sha256-ReP9wHyhRlKRPedm25NV1yo0cVCQOjSeQt105NbbGLU=";
  proxyVendor = true;

  nativeBuildInputs = [ pkg-config ] ++ common.protoNativeBuildInputs;
  buildInputs = [ libseccomp ];

  tags = [
    "seccomp"
    "apparmor"
    "idmapped_mnt"
  ];

  doCheck = false;

  inherit (common) overrideModAttrs;

  preBuild = common.protoPreBuild;

  meta = common.meta // {
    description = "Sysbox manager daemon — coordinates runc and fs components, allocates user-namespace ranges";
    mainProgram = "sysbox-mgr";
  };
}
