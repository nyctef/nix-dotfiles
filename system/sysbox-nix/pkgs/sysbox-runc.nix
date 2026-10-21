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
  pname = "sysbox-runc";
  inherit (common) version src ldflags;

  modRoot = "sysbox-runc";
  vendorHash = "sha256-fNrG1F9t3DRl8Vtw3ex1zBwfa3EZKFokPwdPMYGOaaw=";
  proxyVendor = true;

  # oom_score_adj is only an OOM-kill priority hint, but on this kernel the
  # write is rejected with EACCES, which otherwise aborts container startup.
  # Warn and continue. (go.mod replaces opencontainers/runc with ./, so this
  # source file is what cgo actually compiles.)
  postPatch = ''
    substituteInPlace sysbox-runc/libcontainer/nsenter/nsexec.c \
      --replace-fail \
        'bail("failed to update /proc/self/oom_score_adj");' \
        'write_log(WARNING, "failed to update /proc/self/oom_score_adj: %m");'
  '';

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
