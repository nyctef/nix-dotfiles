{ lib
, buildGoModule
, callPackage
, libseccomp
, pkg-config
}:

let
  common = callPackage ./common.nix { };
in
buildGoModule {
  pname = "sysbox-mgr";
  inherit (common) version src ldflags;

  modRoot = "sysbox-mgr";
  vendorHash = "sha256-GM4a/PqMNwpnad6CGQ9wQtqAyIxypo1OO28MLX0mDw4=";
  proxyVendor = false;

  nativeBuildInputs = [ pkg-config ] ++ common.protoNativeBuildInputs;
  buildInputs = [ libseccomp ];

  tags = [ "seccomp" "apparmor" "idmapped_mnt" ];

  doCheck = false;

  overrideModAttrs = old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ common.protoNativeBuildInputs;
    preBuild = (old.preBuild or "") + common.protoPreBuild;
  };

  preBuild = common.protoPreBuild;

  meta = common.meta // {
    description = "Sysbox manager daemon — coordinates runc and fs components, allocates user-namespace ranges";
    mainProgram = "sysbox-mgr";
  };
}
