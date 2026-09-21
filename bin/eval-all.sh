#!/bin/sh
# Evaluate every nixosConfiguration, homeConfiguration and package in the flake
# in a single nix invocation, so that all evaluation warnings show up together.
#
# Warnings are emitted once per thunk, so evaluating one output at a time (as
# the apply scripts do) only ever shows the subset of warnings reachable from
# that output.
#
# Each output is wrapped in tryEval: a failing one is reported as FAILED
# instead of stopping the rest of the evaluation.
cd "$(dirname -- "$0")/.." || exit 1
exec nix eval --impure --raw --expr '
  let
    flake = builtins.getFlake (toString ./.);
    lib = flake.inputs.nixpkgs.lib;
    try = name: v: let r = builtins.tryEval v; in "${name}: ${if r.success then r.value else "FAILED (re-evaluate this output on its own for the error)"}";
  in
  lib.concatStringsSep "\n" (
    (lib.mapAttrsToList (n: v: try "nixos:${n}" v.config.system.build.toplevel.drvPath) flake.nixosConfigurations)
    ++ (lib.mapAttrsToList (n: v: try "home:${n}" v.activationPackage.drvPath) flake.homeConfigurations)
    ++ (lib.mapAttrsToList (n: v: try "pkg:${n}" v.drvPath) flake.packages.${builtins.currentSystem})
  ) + "\n"
' "$@"
