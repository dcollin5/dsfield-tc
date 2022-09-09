#!/bin/sh -x

# Maximum allowed downlink. Set to 90% of the achievable downlink in kbits/s
DOWNLINK=100000

# Interface facing the Internet
EXTDEV=ens3

# Load IFB, all other modules all loaded automatically
modprobe ifb
ip link set dev ifb0 down

# Clear old queuing disciplines (qdisc) on the interfaces and the MANGLE table
tc qdisc del dev $EXTDEV root    2> /dev/null > /dev/null
tc qdisc del dev $EXTDEV ingress 2> /dev/null > /dev/null
tc qdisc del dev ifb0 root       2> /dev/null > /dev/null
tc qdisc del dev ifb0 ingress    2> /dev/null > /dev/null
iptables -t mangle -F
iptables -t mangle -X QOS

# appending "stop" (without quotes) after the name of the script stops here.
if [ "$1" = "stop" ]
then
        echo "Shaping removed on $EXTDEV."
        exit
fi

tc qdisc replace dev $EXTDEV root handle 1: htb default 10
###Create a three top-level classes that handle 1:1,1:2,1:3 which limits the totalbandwidth
###allowed to 40mbit/s,10mbit/s, and 1mbit/s.
tc class add dev $EXTDEV parent 1: classid 1:1 htb rate 40mbit
##Create three child classes for different uses
tc class add dev $EXTDEV parent 1:1 classid 1:10 htb rate 40mbit ceil 40mbit prio 1
tc class add dev $EXTDEV parent 1:1 classid 1:40 htb rate 10mbit ceil 10mbit prio 2
tc class add dev $EXTDEV parent 1:1 classid 1:80 htb rate 1mbit ceil 1mbit prio 3
tc filter add dev $EXTDEV parent 1:0 u32 match ip dsfield 0x4 0x4 classid 1:40
tc filter add dev $EXTDEV parent 1:0 u32 match ip dsfield 0x8 0x8 classid 1:80


ip link set dev ifb0 up

# HTB classes on IFB with rate limiting
tc qdisc add dev ifb0 root handle 3: htb default 30
tc class add dev ifb0 parent 3: classid 3:3 htb rate 40mbit
tc class add dev ifb0 parent 3:3 classid 3:30 htb rate 20mbit
tc class add dev ifb0 parent 3:3 classid 3:40 htb rate 10mbit
tc class add dev ifb0 parent 3:3 classid 3:80 htb rate 1mbit

#set packet filtering on tagged packets

# Packets marked with "2" on IFB flow through class 3:31
tc filter add dev ifb0 parent 3:0 protocol ip handle 4 fw flowid 3:40
# Packets marked with "3" on IFB flow through class 3:33
tc filter add dev ifb0 parent 3:0 protocol ip handle 8 fw flowid 3:80


# Outgoing traffic from 192.168.1.50 is marked with "3"
iptables -t mangle -N QOS
iptables -t mangle -A FORWARD -o $EXTDEV -j QOS
iptables -t mangle -A OUTPUT -o $EXTDEV -j QOS
iptables -t mangle -A QOS -j CONNMARK --restore-mark
iptables -t mangle -A QOS -m tos --tos 0x4 -m mark --mark 0 -j MARK --set-mark 4
iptables -t mangle -A QOS -m tos --tos 0x8 -m mark --mark 0 -j MARK --set-mark 8
iptables -t mangle -A QOS -j CONNMARK --save-mark

# Forward all ingress traffic on internet interface to the IFB device
tc qdisc add dev $EXTDEV ingress handle ffff:
tc filter add dev $EXTDEV parent ffff: protocol ip \
        u32 match u32 0 0 \
        action connmark \
        action mirred egress redirect dev ifb0 \
        flowid ffff:1

exit 0

