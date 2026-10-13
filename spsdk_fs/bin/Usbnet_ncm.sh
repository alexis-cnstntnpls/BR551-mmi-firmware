#!/bin/sh
insmod /usr/local/drivers/mii.ko
insmod /usr/local/drivers/usbnet.ko
insmod /usr/local/drivers/cdc_ncm.ko
lsmod
