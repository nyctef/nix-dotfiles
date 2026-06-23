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
  pname = "sysbox-runc";
  inherit (common) version src ldflags;

  modRoot = "sysbox-runc";
  vendorHash = "sha256-e2RxH1XPyaTpwMmxnBSPwd8+qWjZD92BEk58kfMlFPU=";
  proxyVendor = false;

  patches = [ ./nsexec-oom-nonfatal.patch ];

  nativeBuildInputs = [ pkg-config ] ++ common.protoNativeBuildInputs;
  buildInputs = [ libseccomp ];

  tags = [ "seccomp" "apparmor" "idmapped_mnt" ];

  doCheck = false;

  overrideModAttrs = old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ common.protoNativeBuildInputs;
    preBuild = (old.preBuild or "") + common.protoPreBuild;
  };

  preBuild = common.protoPreBuild;

  postInstall = ''
    if [ ! -e "$out/bin/sysbox-runc" ] && [ -e "$out/bin/sysbox" ]; then
      mv "$out/bin/sysbox" "$out/bin/sysbox-runc"
    fi
  '';

  meta = common.meta // {
    description = "Sysbox OCI runtime — fork of runc that runs system containers with unprivileged user namespaces";
    mainProgram = "sysbox-runc";
  };
}
