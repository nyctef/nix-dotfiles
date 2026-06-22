{ symlinkJoin
, callPackage
, lib
}:

let
  fs = callPackage ./sysbox-fs.nix { };
  mgr = callPackage ./sysbox-mgr.nix { };
  runc = callPackage ./sysbox-runc.nix { };
  common = callPackage ./common.nix { };
in
symlinkJoin {
  name = "sysbox-${common.version}";
  paths = [ fs mgr runc ];

  passthru = {
    inherit fs mgr runc;
    inherit (common) version;
  };

  meta = common.meta // {
    description = "Sysbox container runtime (sysbox-fs + sysbox-mgr + sysbox-runc combined)";
  };
}
