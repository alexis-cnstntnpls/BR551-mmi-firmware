#!/bin/sh

trap '' HUP

WD_FILE=/dev/watchdog
wait_sec=30

while [ $wait_sec -gt 0 ];
do
	if [ -e $WD_FILE ]; then
		sp_wd_config -e
		WATCHDOG_ENABLE=$?
		sp_wd_config -t
		WATCHDOG_RENEW=$?
		if [ "$WATCHDOG_ENABLE" == "1" ]; then
			echo enable watchdog timeout=$WATCHDOG_RENEW
			(nice -n -20 nohup sp_wd_usr -t $WATCHDOG_RENEW >/dev/null) &
		else
			echo disable watchdog
			sp_wd_usr -d
		fi
		break
	fi
	sleep 1
	wait_sec=$((wait_sec-1))
done
