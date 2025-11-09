### nix dotfiles

initial config based on [video tutorials by Wil T][1]

### setup (on nixos)

on a fresh machine: (not super well tested)

```bash
sudo nixos-rebuild switch --flake github:nyctef/nix-dotfiles#<hostname>
```

```bash
sudo nix-channel --add https://github.com/nix-community/home-manager/archive/release-24.05.tar.gz home-manager

sudo nix-channel --update

nix-shell '<home-manager>' -A install
```

```bash
home-manager switch --flake .
```

### setup (codespace)

- Assumes running as root inside a Debian-ish container
- Creates a multi-user nix install even though we're just running as root, since the single-user install script refuses to run in this case

```bash
# work around https://github.com/NixOS/nix/issues/6680
apt-get update
apt install -y acl
setfacl -k /tmp

# set hostname to what the flake expects
hostname codespace

# install nix (accept prompts)
sh <(curl --proto '=https' --tlsv1.2 -L https://nixos.org/nix/install) --daemon

# install home-manager (may require a new terminal)
nix-channel --add https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager
nix-channel --update
nix-shell '<home-manager>' -A install

# install this repo
apt-get install -y gh
gh repo clone nyctef/nix-dotfiles ~/.dotfiles
cd ~/.dotfiles
home-manager --extra-experimental-features 'nix-command flakes' switch --flake .#root@codespace
```



[1]: https://www.youtube.com/watch?v=Dy3KHMuDNS8
