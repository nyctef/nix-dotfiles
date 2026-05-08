{ pkgs, ... }:

let
  # Package Flyway with its bundled JRE and drivers
  flyway = pkgs.stdenv.mkDerivation rec {
    pname = "flyway";
    version = "12.5.0";

    src = pkgs.fetchurl {
      url = "https://download.red-gate.com/maven/release/com/redgate/flyway/flyway-commandline/${version}/flyway-commandline-${version}-linux-x64.tar.gz";
      sha256 = "sha256-qofx3/LL6ZepDlQKmLUhqTU4XnACbeQtNGOf9yST8/k=";
    };

    nativeBuildInputs = [ pkgs.autoPatchelfHook ];

    # The Redgate edition's bundled JRE links against X11/GUI libs even for CLI use
    autoPatchelfIgnoreMissingDeps = true;

    # The bundled rgcompare directory ships .NET PE assemblies (.dll files
    # that are CoreCLR managed code, not ELF). Nix's default fixupPhase runs
    # `strip` over everything under lib/, which partially mangles the PE
    # headers and causes CoreCLR to fail with BadImageFormat (0x8007000B)
    # when it tries to load System.Private.CoreLib.dll.
    dontStrip = true;

    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.libx11
      pkgs.libxext
      pkgs.libxi
      pkgs.libxrender
      pkgs.libxtst
      # rgcompare's bundled .NET runtime dlopens libicu at runtime via
      # libSystem.Globalization.Native.so.
      pkgs.icu
    ];

    installPhase = ''
      mkdir -p $out/lib/flyway $out/bin
      cp -r . $out/lib/flyway/

      # Make the java binaries executable
      chmod +x $out/lib/flyway/jre/bin/*

      # Wrapper that exec's flyway from its original directory.
      # LD_LIBRARY_PATH points the bundled .NET globalization helper
      # (libSystem.Globalization.Native.so dlopens libicuuc/libicui18n at
      # runtime — autoPatchelfHook can't add an RPATH for dlopen targets).
      cat > $out/bin/flyway <<WRAPPER
      #!/bin/sh
      export LD_LIBRARY_PATH="${pkgs.icu}/lib\''${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
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

  home.file.".local/flyway".source = "${flyway}/lib/flyway";
}
