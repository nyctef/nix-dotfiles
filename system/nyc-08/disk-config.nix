# Declarative partitioning for nixos-anywhere, applied by disko during install.
#
# Azure Gen2 VMs boot UEFI and present the OS disk as /dev/sda. The ephemeral
# resource disk (/dev/sdb on most sizes) is deliberately left alone: its
# contents are lost on deallocate, so nothing here may depend on it.
#
# Check `lsblk` on the target before deploying and override if the OS disk
# lands somewhere else:
#   nixos-anywhere --disk-encryption-keys ... --flake .#nyc-08 \
#     --option ... # or just edit `device` below
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/sda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          priority = 1;
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
