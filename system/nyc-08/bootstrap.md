Notes on manual setup to get stuff working before regular nix deploys

## Azure

- ARM64 VM with >= 4GB RAM to give nix-anywhere room to work with
- Admin user `nyctef`, authorized with `~/.ssh/id_nyctef_2026.pub`.
- Static public IP, hardcoded in the ssh alias config in `generic.nix`
- VM configured to allow inbound connections on 22/80/443

## GitHub

Any flakes referenced in private repos get fetched via ssh auth. Make sure
`id_nyctef_2026.pub` is configured on github (should already be done)

```sh
gh ssh-key add ~/.ssh/id_nyctef_2026.pub
```

There's a bit of a catch-22 where the flake overall won't build correctly
if it can't fetch private repos as flake inputs, but also we can't apply the
`settings."github.com".IdentityFile` config to provide that auth if we can't
build the config. The following can help get it unstuck if it happens again:

```sh
GIT_SSH_COMMAND="ssh -i ~/.ssh/id_nyctef_2026 -o IdentitiesOnly=yes" \
  nix flake update nyctef-com
```

## Install

```sh
nix run github:nix-community/nixos-anywhere -- \
  -i ~/.ssh/id_nyctef_2026 --flake .#nyc-08 nyctef@<ip>
```

Erases everything on the target (but that should be a freshly-built VM, so
we don't care).

Not sure if this always reproduces, but we did get stuck at one point where
kexec had succeded but the machine was stuck after the reboot just showing a
nixos installation prompt at the serial console. In that case running

```sh
nix run github:nix-community/nixos-anywhere -- \
  -i ~/.ssh/id_nyctef_2026 \
  --phases disko,install,reboot \
  --flake .#nyc-08 \
  root@<ip>
```

(targeting `root` instead of `nyctef`, and skipping the kexec phase`) got it
working again.

## First deploy

`nix.settings.trusted-users` is another catch-22: we want to run nixos-rebuild
as non-root, but we can't do that if our non-root user isn't trusted (since that
essentially gives root access on the machine anyway). First deploy uses ssh+sudo
to work around this problem, then subsequent deploys can use the nicer command
in `deploy-nyc-08.sh`.

(TODO: maybe we should just give up and either use the below method more
consistently, or give up and accept that we just have full root on the target
machine? it's not a problem for now anyway since any subsequent deploys with
the regular script work fine).

```sh
OUT=$(nix build --no-link --print-out-paths .#nixosConfigurations.nyc-08.config.system.build.toplevel)

nix-store --export $(nix-store -qR "$OUT") | gzip | \
  ssh nyc-08 'gunzip | sudo nix-store --import'

ssh nyc-08 "sudo nix-env -p /nix/var/nix/profiles/system --set $OUT"
ssh nyc-08 "sudo $OUT/bin/switch-to-configuration switch"
```
