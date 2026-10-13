#!/bin/bash

show_help()
{
	echo "Usage: change_proc_sched [process] [policy] [priority]"
	echo ""
	echo "       process:  name or pid is okay"
	echo "       policy:   normal, fifo, rr,"
	echo "       priority: should valid with the selected policy"
	echo ""
	exit
}

if [ $# -lt 3 ]
then
show_help
fi

s_policy=$2
s_priority=$3

# find valid pids
if [ -d "/proc/$1" ]
then
## use pid as parameter
pids=$1
else
## use process name as parameter
pids=`pidof $1`
fi

if [ -z "$pids" ]
then
	echo "Invalid process $1"
	exit
fi

echo $pids | tr -s " " "\n" | xargs -i ls /proc/{}/task | tr -s " " "\n" | xargs -i /usr/local/bin/change_sched --pid {} --policy $s_policy --priority $s_priority
