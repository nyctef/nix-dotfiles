{ lib
, buildGoModule
, callPackage
, libseccomp
, pkg-config
, fuse
}:

let
  common = callPackage ./common.nix { };
in
buildGoModule {
  pname = "sysbox-fs";
  inherit (common) version src ldflags;

  modRoot = "sysbox-fs";
  vendorHash = "sha256-vrWjlwy94MPoxBXvvHrPNARHTbom81Wv1NK+rl6Qr1U=";
  proxyVendor = false;

  nativeBuildInputs = [ pkg-config ] ++ common.protoNativeBuildInputs;
  buildInputs = [ libseccomp fuse ];

  subPackages = [ "cmd/sysbox-fs" ];

  doCheck = false;

  overrideModAttrs = old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ common.protoNativeBuildInputs;
    preBuild = (old.preBuild or "") + common.protoPreBuild;
  };

  preBuild = common.protoPreBuild;

  meta = common.meta // {
    description = "Sysbox FUSE filesystem daemon — emulates procfs/sysfs inside system containers";
    mainProgram = "sysbox-fs";
  };
}
