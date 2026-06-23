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

  # oom_score_adj is only an OOM-kill priority hint, but on this kernel the
  # write is rejected with EACCES, which otherwise aborts container startup.
  # Warn and continue. (Patches the vendored runc copy, which is what cgo
  # actually compiles.)
  postConfigure = ''
    substituteInPlace vendor/github.com/opencontainers/runc/libcontainer/nsenter/nsexec.c \
      --replace-fail \
        'bail("failed to update /proc/self/oom_score_adj");' \
        'write_log(WARNING, "failed to update /proc/self/oom_score_adj: %m");'
  '';

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
