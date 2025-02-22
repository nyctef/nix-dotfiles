### nix dotfiles

initial config based on [video tutorials by Wil T][1]

### setup

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



[1]: https://www.youtube.com/watch?v=Dy3KHMuDNS8
