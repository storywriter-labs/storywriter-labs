#!/bin/bash
# Minimal first-boot bootstrap for the Ghost instance.
# Ghost itself is installed manually with ghost-cli (see README) — this only
# creates swap so MySQL 8 + Node don't OOM on a 1 GB instance.
set -euo pipefail

SWAP_GB=${swap_size_gb}
SWAPFILE=/swapfile

if [ "$SWAP_GB" -gt 0 ] && [ ! -f "$SWAPFILE" ]; then
  fallocate -l "$${SWAP_GB}G" "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$(($SWAP_GB * 1024))
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
  echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab
  # Favour RAM, lean on swap only under real pressure.
  sysctl -w vm.swappiness=10
  echo "vm.swappiness=10" >> /etc/sysctl.conf
fi

apt-get update -y
