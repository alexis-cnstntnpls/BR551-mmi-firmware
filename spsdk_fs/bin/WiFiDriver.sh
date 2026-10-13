#!/bin/sh
insmod /usr/local/drivers/cfg80211.ko
insmod /usr/local/drivers/8811cu.ko
insmod /usr/local/drivers/lib80211.ko
insmod /usr/local/drivers/lib80211_crypt_ccmp.ko
insmod /usr/local/drivers/lib80211_crypt_tkip.ko
insmod /usr/local/drivers/lib80211_crypt_wep.ko
lsmod