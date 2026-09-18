# nyc-08

An aarch64 Azure VM hosting web services, deployed from tachikoma. Routine
changes go out with `bin/deploy-nyc-08.sh`; everything below is the setup that
makes that command work.

## Prerequisites on the deploying machine

The VM is aarch64 and underpowered, so closures are built on tachikoma and only
activated on the VM. That needs aarch64 emulation, which
`boot.binfmt.emulatedSystems` in `../tachikoma/configuration.nix` provides.
Check it with:

```sh
cat /proc/sys/fs/binfmt_misc/aarch64-linux   # "enabled"
nix config show extra-platforms              # includes aarch64-linux
```

`nyctef.com` is a private repo fetched over ssh, so the deploying machine needs
an ssh key registered with GitHub (`gh ssh-key add`). `programs.ssh.settings` in
`../../users/generic.nix` points ssh at the right key. Before that config is
activated, fetches need the key named explicitly:

```sh
GIT_SSH_COMMAND="ssh -i ~/.ssh/id_nyctef_2026 -o IdentitiesOnly=yes" \
  nix flake update nyctef-com
```

## Provisioning the VM

Create it as an **ARM64 Gen2** instance — Gen2 because the config boots UEFI via
systemd-boot, and the architecture and generation are both fixed at creation.
Give it at least 4GB of RAM, an admin user named `nyctef` with an ed25519 key,
and a static public IP (hardcoded in `web.nix` and `bin/deploy-nyc-08.sh`).

Open inbound 22, 80 and 443 in the network security group. The NixOS firewall
sits behind the NSG, so `services.caddy.openFirewall` alone is not enough.

## Installing

```sh
nix run github:nix-community/nixos-anywhere -- \
  -i ~/.ssh/id_nyctef_2026 --flake .#nyc-08 nyctef@<ip>
```

This erases the OS disk. Pass `-i` explicitly: without it nixos-anywhere
generates a temporary key, and `ssh-copy-id` then falls back to prompting for a
password that does not exist.

nixos-anywhere kexecs into an installer before partitioning, and the aarch64
installer image does not always boot cleanly. If SSH never comes back, the disk
has not been touched yet — disko runs after the post-kexec reconnect. Restart
the VM from the hypervisor (`az vm restart`, not a guest reboot) to get back to
the original OS.

When the serial console shows a `root@nixos-installer` prompt, the kexec
succeeded and only the reconnect failed. Recover from there rather than
restarting: the installer carries over the authorized keys of the user that ran
the kexec, so `root@<ip>` is reachable with the same key, and the remaining
phases can be run on their own.

```sh
nix run github:nix-community/nixos-anywhere -- \
  -i ~/.ssh/id_nyctef_2026 --phases disko,install,reboot --flake .#nyc-08 root@<ip>
```

## First deploy after installing

Deploys push closures built on tachikoma, and the daemon only accepts unsigned
paths from a user in `nix.settings.trusted-users`. That setting is in
`configuration.nix`, but it cannot be delivered by the mechanism it enables, so
the first deploy goes in as root:

```sh
OUT=$(nix build --no-link --print-out-paths .#nixosConfigurations.nyc-08.config.system.build.toplevel)

nix-store --export $(nix-store -qR "$OUT") | gzip | \
  ssh nyc-08 'gunzip | sudo nix-store --import'

ssh nyc-08 "sudo nix-env -p /nix/var/nix/profiles/system --set $OUT"
ssh nyc-08 "sudo $OUT/bin/switch-to-configuration switch"
```

`nix-store --import` as root skips the signature check. Confirm with
`ssh nyc-08 'nix config show trusted-users'`; after that `bin/deploy-nyc-08.sh`
works on its own.

## Host key

Root login is disabled and no account has a password, so the serial console is
read-only in practice. Read the host key from it during install, while the
installer still allows a console shell:

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

## TLS

Caddy requests Let's Encrypt certificates itself, which requires `nyctef.com`
and `www.nyctef.com` to resolve to this machine and port 80 to be reachable for
the HTTP-01 challenge. Until the A records point here, the `nyctef.com` block in
`web.nix` will fail validation on every start — harmless, but Let's Encrypt
rate-limits repeated failures, so comment it out for long tests. The
`http://<ip>` block serves the same content without TLS in the meantime.
