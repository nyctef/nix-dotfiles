{ pkgs, ... }:

let
  # Package Flyway with its bundled JRE and drivers
  flyway = pkgs.stdenv.mkDerivation rec {
    pname = "flyway";
    version = "12.1.0";

    src = pkgs.fetchurl {
      url = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/${version}/flyway-commandline-${version}-linux-x64.tar.gz";
      sha256 = "sha256-Ov0qoPOSRJEVv0YyEsgaRe8bfWfNMQCzI2fF9CYAX9c=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];

    # The Redgate edition's bundled JRE links against X11/GUI libs even for CLI use
    autoPatchelfIgnoreMissingDeps = true;

    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.libx11
      pkgs.libxext
      pkgs.libxi
      pkgs.libxrender
      pkgs.libxtst
    ];

    installPhase = ''
      mkdir -p $out/lib/flyway $out/bin
      cp -r . $out/lib/flyway/

      # Make the java binaries executable
      chmod +x $out/lib/flyway/jre/bin/*

      # Wrapper that exec's flyway from its original directory
      cat > $out/bin/flyway <<WRAPPER
      #!/bin/sh
      exec $out/lib/flyway/flyway "\$@"
      WRAPPER
      chmod +x $out/bin/flyway
    '';

    meta = with pkgs.lib; {
      description = "Flyway database migration tool with bundled JRE";
      homepage = "https://flywaydb.org/";
      platforms = platforms.linux;
    };
  };
in
{
  home.packages = [
    flyway
  ];
}
