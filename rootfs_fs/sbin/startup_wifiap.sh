#!/bin/sh
/usr/local/bin/wifi_control --enableap
/usr/local/bin/nw_control --startup
/usr/local/bin/nw_control --ebdev wifi
/usr/local/bin/nw_control --ebap wlan0