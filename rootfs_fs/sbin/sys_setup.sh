#!/bin/sh

cp -rfa /etc /root /tmp/sp/
mount /tmp/sp/etc /etc
mount /tmp/sp/root /root

# Swap related settings
echo 100 > /proc/sys/vm/swappiness
echo 36M > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0

dbus-uuidgen > /etc/machine-id

mkdir /tmp/etc_up /tmp/etc_wk /system/etc && mount -t overlay -o lowerdir=/usr/local/etc,upperdir=/tmp/etc_up,workdir=/tmp/etc_wk overlay /system/etc

