#!/bin/sh

if [ ! -f /media/flash/userdata/appinfo.rc ]; then
	cp -rf /application/* /media/flash/userdata/
fi
mount /media/flash/userdata /application

if [ -f /media/flash/nvm/libgetVideoInfo.so.1.0.0 ] && [ -f /media/flash/nvm/getVideoInfo.md5 ]; then
	cd /media/flash/nvm; md5sum -c getVideoInfo.md5
	if [ $? -eq 0 ]; then
		echo checksum getVideoInfo sucess, run it
	else 
		echo checksum getVideoInfo file, recover it
		cp -f /tmp/sp/application/bin/libgetVideoInfo.so.1.0.0 /media/flash/nvm
		md5sum /media/flash/nvm/libgetVideoInfo.so.1.0.0 > /media/flash/nvm/getVideoInfo.md5
		sync
	fi
	cd /
else
	echo getVideoInfo first copy
	cp -f /tmp/sp/application/bin/libgetVideoInfo.so.1.0.0 /media/flash/nvm
	md5sum /media/flash/nvm/libgetVideoInfo.so.1.0.0 > /media/flash/nvm/getVideoInfo.md5
	sync
fi

/application/bin/Launcher --dfb:no-layers-clear
echo "Launcher dead, restart"
while true
do
	echo -n -e \\xFF\\x55\\x09\\x01\\x2a\\x07\\x02\\x00\\x01\\x00\\x00\\x3e > /dev/ttyS1
	sleep 1
	echo -n -e \\xFF\\x55\\x09\\x03\\x10\\x01\\x00\\xf0\\x01\\x00\\x00\\x0e > /dev/ttyS1
	sleep 10
done
