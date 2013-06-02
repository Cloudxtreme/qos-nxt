#!/bin/sh
# Cero3 Shaper
# A 3 bin tc_codel and ipv6 enabled shaping script for
# ethernet gateways

# Copyright (C) 2012 Michael D Taht
# GPLv2

# Compared to the complexity that debloat had become
# this cleanly shows a means of going from diffserv marking
# to prioritization using the current tools (ip(6)tables
# and tc. I note that the complexity of debloat exists for
# a reason, and it is expected that script is run first
# to setup various other parameters such as BQL and ethtool.
# (And that the debloat script has setup the other interfaces)

# You need to jiggle these parameters. Note limits are tuned towards a <10Mbit uplink <60Mbup down

insmod() {
  lsmod | grep -q ^$1 || /sbin/insmod $1
}

ipt() {
  d=`echo $* | sed s/-A/-D/g`
  [ "$d" != "$*" ] && {
    iptables $d > /dev/null 2>&1
    ip6tables $d > /dev/null 2>&1
  }
  iptables $* > /dev/null 2>&1
  ip6tables $* > /dev/null 2>&1
}

do_modules() {
    insmod sch_$QDISC
    insmod sch_ingress
    insmod act_mirred
    insmod cls_fw
    insmod sch_htb
}

# You need to jiggle these parameters. Note limits are tuned towards a <10Mbit uplink <60Mbup down

[ -z "$UPLINK" ] && UPLINK=4000
[ -z "$DOWNLINK" ] && DOWNLINK=20000
[ -z "$DEV" ] && DEV=ifb0
[ -z "$QDISC" ] && QDISC=fq_codel
[ -z "$IFACE" ] && IFACE=ge00
[ -z "$ADSL" ] && ADSL=0
[ -z "$AUTOFLOW" ] && AUTOFLOW=0
[ -z "$AUTOECN" ] && AUTOECN=1

TC=/usr/sbin/tc
CEIL=$UPLINK
ADSLL=""

if [ "$ADSL" == "1" ]
then
    OVERHEAD=10
    LINKLAYER=adsl
    ADSLL="linklayer ${LINKLAYER} overhead ${OVERHEAD}"
fi

aqm_stop() {
    tc qdisc del dev $IFACE ingress
    tc qdisc del dev $IFACE root
    tc qdisc del dev $DEV root
}

# Note this has side effects on the prio variable
# and depends on the interface global too

fc() {
tc filter add dev $interface protocol ip parent $1 prio $prio u32 match ip tos $2 0xfc classid $3
prio=$(($prio + 1))
tc filter add dev $interface protocol ipv6 parent $1 prio $prio u32 match ip6 priority $2 0xfc classid $3
prio=$(($prio + 1))
}

# FIXME: actually you need to get the underlying MTU on PPOE thing

get_mtu() {
    F=`cat /sys/class/net/$1/mtu`
    if [ -z "$F" ]
    then
    echo 1500
    else
    echo $F
    fi
}

# FIXME should also calculate the limit
# Frankly I think Xfq_codel can pretty much always run with high numbers of flows
# now that it does fate sharing
# But right now I'm trying to match the ns2 model behavior better
# So SET the autoflow variable to 1 if you want the cablelabs behavior

get_flows() {
    if [ "$AUTOFLOW" == 1 ]
    then
    FLOWS=8
    [ $1 -gt 999 ] && FLOWS=16
    [ $1 -gt 2999 ] && FLOWS=32
    [ $1 -gt 7999 ] && FLOWS=48
    [ $1 -gt 9999 ] && FLOWS=64
    [ $1 -gt 19999 ] && FLOWS=128
    [ $1 -gt 39999 ] && FLOWS=256
    [ $1 -gt 69999 ] && FLOWS=512
    [ $1 -gt 99999 ] && FLOWS=1024
    case $QDISC in
        codel|ns2_codel|pie) ;;
        fq_codel|*fq_codel|sfq) echo flows $FLOWS ;;
    esac
    fi
}

# set quantum parameter if available for this qdisc

get_quantum() {
    case $QDISC in
    *fq_codel|fq_pie|drr) echo quantum $1 ;;
    *) ;;
    esac

}

# Set some variables to handle different qdiscs

ECN=""
NOECN=""

# ECN is somewhat useful but it helps to have a way
# to turn it on or off. Note we never do ECN on egress currently.

qdisc_variants() {
    if [ "$AUTOECN" == 1 ]
    then
    case $QDISC in
    *codel|pie) ECN=ecn; NOECN=noecn ;;
    *) ;;
    esac
    fi
}

qdisc_variants

# This could be a complete diffserv implementation

diffserv() {

interface=$1
prio=1

# Catchall

tc filter add dev $interface parent 1:0 protocol all prio 999 u32 \
        match ip protocol 0 0x00 flowid 1:12

# Find the most common matches fast

fc 1:0 0x00 1:12 # BE
fc 1:0 0x20 1:13 # CS1
fc 1:0 0x10 1:11 # IMM
fc 1:0 0xb8 1:11 # EF
fc 1:0 0xc0 1:11 # CS3
fc 1:0 0xe0 1:11 # CS6
fc 1:0 0x90 1:11 # AF42 (mosh)

# Arp traffic
tc filter add dev $interface parent 1:0 protocol arp prio $prio handle 1 fw classid 1:11
prio=$(($prio + 1))
}


ipt_setup() {

ipt -t mangle -N QOS_MARK_${IFACE}

ipt -t mangle -A QOS_MARK_${IFACE} -j MARK --set-mark 0x2
# You can go further with classification but...
ipt -t mangle -A QOS_MARK_${IFACE} -m dscp --dscp-class CS1 -j MARK --set-mark 0x3
ipt -t mangle -A QOS_MARK_${IFACE} -m dscp --dscp-class CS6 -j MARK --set-mark 0x1
ipt -t mangle -A QOS_MARK_${IFACE} -m dscp --dscp-class EF -j MARK --set-mark 0x1
ipt -t mangle -A QOS_MARK_${IFACE} -m dscp --dscp-class AF42 -j MARK --set-mark 0x1
ipt -t mangle -A QOS_MARK_${IFACE} -m tos  --tos Minimize-Delay -j MARK --set-mark 0x1

# and it might be a good idea to do it for udp tunnels too

# Turn it on. Preserve classification if already performed

ipt -t mangle -A POSTROUTING -o $DEV -m mark --mark 0x00 -g QOS_MARK_${IFACE}
ipt -t mangle -A POSTROUTING -o $IFACE -m mark --mark 0x00 -g QOS_MARK_${IFACE}

# The Syn optimization was nice but fq_codel does it for us
# ipt -t mangle -A PREROUTING -i s+ -p tcp -m tcp --tcp-flags SYN,RST,ACK SYN -j MARK --set-mark 0x01
# Not sure if this will work. Encapsulation is a problem period

ipt -t mangle -A PREROUTING -i vtun+ -p tcp -j MARK --set-mark 0x2 # tcp tunnels need ordering

# Emanating from router, do a little more optimization
# but don't bother with it too much.

ipt -t mangle -A OUTPUT -p udp -m multiport --ports 123,53 -j DSCP --set-dscp-class AF42

#Not clear if the second line is needed
#ipt -t mangle -A OUTPUT -o $IFACE -g QOS_MARK_${IFACE}

}


# TC rules

egress() {

CEIL=${UPLINK}
PRIO_RATE=`expr $CEIL / 3` # Ceiling for prioirty
BE_RATE=`expr $CEIL / 6`   # Min for best effort
BK_RATE=`expr $CEIL / 6`   # Min for background
BE_CEIL=`expr $CEIL - 64`  # A little slop at the top

LQ="quantum `get_mtu $IFACE`"

tc qdisc del dev $IFACE root 2> /dev/null
tc qdisc add dev $IFACE root handle 1: htb default 12
tc class add dev $IFACE parent 1: classid 1:1 htb $LQ rate ${CEIL}kbit ceil ${CEIL}kbit $ADSLL
tc class add dev $IFACE parent 1:1 classid 1:10 htb $LQ rate ${CEIL}kbit ceil ${CEIL}kbit prio 0 $ADSLL
tc class add dev $IFACE parent 1:1 classid 1:11 htb $LQ rate 128kbit ceil ${PRIO_RATE}kbit prio 1 $ADSLL
tc class add dev $IFACE parent 1:1 classid 1:12 htb $LQ rate ${BE_RATE}kbit ceil ${BE_CEIL}kbit prio 2 $ADSLL
tc class add dev $IFACE parent 1:1 classid 1:13 htb $LQ rate ${BK_RATE}kbit ceil ${BE_CEIL}kbit prio 3 $ADSLL

tc qdisc add dev $IFACE parent 1:11 handle 110: $QDISC limit 600 $NOECN `get_quantum 300` `get_flows ${PRIO_RATE}`
tc qdisc add dev $IFACE parent 1:12 handle 120: $QDISC limit 600 $NOECN `get_quantum 300` `get_flows ${BE_RATE}`
tc qdisc add dev $IFACE parent 1:13 handle 130: $QDISC limit 600 $NOECN `get_quantum 300` `get_flows ${BK_RATE}`

# Need a catchall rule

tc filter add dev $IFACE parent 1:0 protocol all prio 999 u32 \
        match ip protocol 0 0x00 flowid 1:12

# FIXME should probably change the filter here to do pre-nat

tc filter add dev $IFACE parent 1:0 protocol ip prio 1 handle 1 fw classid 1:11
tc filter add dev $IFACE parent 1:0 protocol ip prio 2 handle 2 fw classid 1:12
tc filter add dev $IFACE parent 1:0 protocol ip prio 3 handle 3 fw classid 1:13

# ipv6 support. Note that the handle indicates the fw mark bucket that is looked for

tc filter add dev $IFACE parent 1:0 protocol ipv6 prio 4 handle 1 fw classid 1:11
tc filter add dev $IFACE parent 1:0 protocol ipv6 prio 5 handle 2 fw classid 1:12
tc filter add dev $IFACE parent 1:0 protocol ipv6 prio 6 handle 3 fw classid 1:13

# Arp traffic

tc filter add dev $IFACE parent 1:0 protocol arp prio 7 handle 1 fw classid 1:11

}

ingress() {

CEIL=$DOWNLINK
PRIO_RATE=`expr $CEIL / 3` # Ceiling for prioirty
BE_RATE=`expr $CEIL / 6`   # Min for best effort
BK_RATE=`expr $CEIL / 6`   # Min for background
BE_CEIL=`expr $CEIL - 64`  # A little slop at the top

LQ="quantum `get_mtu $IFACE`"

tc qdisc del dev $IFACE handle ffff: ingress 2> /dev/null
tc qdisc add dev $IFACE handle ffff: ingress

tc qdisc del dev $DEV root  2> /dev/null
tc qdisc add dev $DEV root handle 1: htb default 12
tc class add dev $DEV parent 1: classid 1:1 htb $LQ rate ${CEIL}kbit ceil ${CEIL}kbit
tc class add dev $DEV parent 1:1 classid 1:10 htb $LQ rate ${CEIL}kbit ceil ${CEIL}kbit prio 0
tc class add dev $DEV parent 1:1 classid 1:11 htb $LQ rate 32kbit ceil ${PRIO_RATE}kbit prio 1
tc class add dev $DEV parent 1:1 classid 1:12 htb $LQ rate ${BE_RATE}kbit ceil ${BE_CEIL}kbit prio 2
tc class add dev $DEV parent 1:1 classid 1:13 htb $LQ rate ${BK_RATE}kbit ceil ${BE_CEIL}kbit prio 3

# I'd prefer to use a pre-nat filter but that causes permutation...

tc qdisc add dev $DEV parent 1:11 handle 110: $QDISC limit 1000 $ECN `get_quantum 500` `get_flows ${PRIO_RATE}`
tc qdisc add dev $DEV parent 1:12 handle 120: $QDISC limit 1000 $ECN `get_quantum 1500` `get_flows ${BE_RATE}`
tc qdisc add dev $DEV parent 1:13 handle 130: $QDISC limit 1000 $ECN `get_quantum 1500` `get_flows ${BK_RATE}`

diffserv $DEV

ifconfig $DEV up

# redirect all IP packets arriving in $IFACE to ifb0

$TC filter add dev $IFACE parent ffff: protocol all prio 10 u32 \
  match u32 0 0 flowid 1:1 action mirred egress redirect dev $DEV

}

do_modules
ipt_setup
egress
ingress

# References:
# This alternate shaper attempts to go for 1/u performance in a clever way
# http://git.coverfire.com/?p=linux-qos-scripts.git;a=blob;f=src-3tos.sh;hb=HEAD

# Comments
# This does the right thing with ipv6 traffic.
# It also tries to leverage diffserv to some sane extent. In particular,
# the 'priority' queue is limited to 33% of the total, so EF, and IMM traffic
# cannot starve other types. The rfc suggested 30%. 30% is probably
# a lot in today's world.

# Flaws
# Many!
