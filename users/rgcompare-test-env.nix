{ pkgs, ... }:

let
  # Package Flyway with its bundled JRE and drivers
  flyway = pkgs.stdenv.mkDerivation rec {
    pname = "flyway";
    version = "10.21.0";

    src = pkgs.fetchurl {
      url = "https://repo1.maven.org/maven2/org/flywaydb/flyway-commandline/${version}/flyway-commandline-${version}-linux-x64.tar.gz";
      sha256 = "sha256-4gVcGAp/nQmDrp7Aj035qWP/7vfxKA3oVXr9Lt2hH80=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];

    # Ignore missing GUI libraries since we only need headless JDBC
    autoPatchelfIgnoreMissingDeps = true;

    buildInputs = [
      pkgs.stdenv.cc.cc.lib
    ];

    installPhase = ''
      mkdir -p $out
      cp -r . $out/

      # Make the java binaries executable
      chmod +x $out/jre/bin/*
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
