{ pkgs, ... }:

let
  # Package Flyway with its bundled JRE and drivers
  flyway = pkgs.stdenv.mkDerivation rec {
    pname = "flyway";
    version = "12.1.0";

    src = pkgs.fetchurl {
      url = "https://github.com/flyway/flyway/releases/download/flyway-${version}/flyway-commandline-${version}-linux-x64.tar.gz";
      sha256 = "sha256-CCFNWTqbZtfce89XzukhovJ6p6DKdBCrQu3RJ1rYk24=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];

    # Ignore missing GUI libraries since we only need headless JDBC
    autoPatchelfIgnoreMissingDeps = true;

    buildInputs = [
      pkgs.stdenv.cc.cc.lib
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
