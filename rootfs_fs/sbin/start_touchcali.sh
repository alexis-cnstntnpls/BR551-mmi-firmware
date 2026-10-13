#!/bin/sh

eval $( awk '/PANEL_TYPE/ { print "TOUCH_TYPE=" $2 " " } /PANEL_HAS_KEY/ { printf "TOUCH_WITH_KEY=" $2 " " } ' /proc/sp_touch )

if [[ ${TOUCH_WITH_KEY} && ${TOUCH_WITH_KEY} = "yes" ]]; then
   # Open for supporting tslib
   export TSLIB_GRAB_ENABLE=0
   export QT_QPA_GENERIC_PLUGINS='evdevkeyboard'
fi

#gplink added
if [ ! -f /media/flash/userdata/cp_back.png ]; then
	echo "No carplay back icon, copy one."
	cp /tmp/sp/application/etc/carplay/CPIcon_gplink.png /media/flash/userdata/cp_back.png
fi

if [[ ${TOUCH_TYPE} && ${TOUCH_TYPE} = "r-type" ]] ; then
    # Check checksum
    TOUCH_CONF_MD5=/media/flash/nvm/touch_conf.md5
    md5sum -cs $TOUCH_CONF_MD5
    if [[ $? -eq 0 ]]; then
        cat $QT_CUSTOMIZE_TOUCH_CONF > /dev/touch_conf
        setprop ro.start.ncLauncher 1
    else
        # Touch calibration
        rm -v $QT_CUSTOMIZE_TOUCH_CONF
        touchcalibration --dfb:no-layers-clear
        md5sum $QT_CUSTOMIZE_TOUCH_CONF > $TOUCH_CONF_MD5
        setprop ro.start.Launcher 1
    fi
else
    setprop ro.start.ncLauncher 1
fi

