# nyc-08 bootstrap

Setup that can't live in the nix config. Routine deploys are
`bin/deploy-nyc-08.sh`.

## Azure

- ARM64 **Gen2** instance; both are fixed at creation time.
- Admin user `nyctef`, authorized with `~/.ssh/id_nyctef_2026`.
- Static public IP, hardcoded in `web.nix` and `bin/deploy-nyc-08.sh`.
- NSG inbound 22, 80, 443. The NSG sits in front of the NixOS firewall.
- A records for `nyctef.com` and `www.nyctef.com`.

## GitHub

`nyctef-com` is a private input fetched over ssh, so the key needs registering:

```sh
gh ssh-key add ~/.ssh/id_nyctef_2026.pub
```

Until `users/generic.nix` is activated, ssh won't offer a key under that name
by itself:

```sh
GIT_SSH_COMMAND="ssh -i ~/.ssh/id_nyctef_2026 -o IdentitiesOnly=yes" \
  nix flake update nyctef-com
```

## Install

```sh
nix run github:nix-community/nixos-anywhere -- \
  -i ~/.ssh/id_nyctef_2026 --flake .#nyc-08 nyctef@<ip>
```

Erases the OS disk. `-i` is required: without it nixos-anywhere generates a
temporary key and `ssh-copy-id` falls back to prompting for a password that no
account has.

## First deploy

`nix.settings.trusted-users` is what lets deploys push unsigned closures, so it
can't be delivered by a deploy. Import it as root once:

```sh
OUT=$(nix build --no-link --print-out-paths .#nixosConfigurations.nyc-08.config.system.build.toplevel)

nix-store --export $(nix-store -qR "$OUT") | gzip | \
  ssh nyc-08 'gunzip | sudo nix-store --import'

ssh nyc-08 "sudo nix-env -p /nix/var/nix/profiles/system --set $OUT"
ssh nyc-08 "sudo $OUT/bin/switch-to-configuration switch"
```
