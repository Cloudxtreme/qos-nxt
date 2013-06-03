#!/bin/sh

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
    insmod sch_hfsc
    insmod ipt_multiport
    insmod ipt_dscp
    insmod ipt_tos
    insmod ipt_length
    insmod ifb
    insmod cls_u32
    insmod em_u32
    insmod sch_fq_codel
}

[ -z "$UPLINK" ] && UPLINK=210
[ -z "$DOWNLINK" ] && DOWNLINK=1600
[ -z "$DEV" ] && DEV=ifb0
[ -z "$QDISC" ] && QDISC=fq_codel
[ -z "$IFACE" ] && IFACE=pppoe-wan
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
    ipt -t mangle -D POSTROUTING -o $DEV -m dscp --dscp-class CS0 -g QOS_MARK_${IFACE}
    ipt -t mangle -D POSTROUTING -o $IFACE -m dscp --dscp-class CS0 -g QOS_MARK_${IFACE}
    ipt -X QOS_MARK_${IFACE}
    tc qdisc del dev $IFACE ingress
    tc qdisc del dev $IFACE root
    tc qdisc del dev $DEV root
}


fc() {
tc filter add dev $interface protocol ip parent $1 prio $prio u32 match ip tos $2 0xfc classid $3
prio=$(($prio + 1))
tc filter add dev $interface protocol ipv6 parent $1 prio $prio u32 match ip6 priority $2 0xfc classid $3
prio=$(($prio + 1))
}

get_mtu() {
    F=`cat /sys/class/net/$1/mtu`
    if [ -z "$F" ]
    then
    echo 1500
    else
    echo $F
    fi
}

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

diffserv() {

interface=$1
prio=1

# Catchall

tc filter add dev $interface parent 1:0 protocol all prio 999 u32 \
        match ip protocol 0 0x00 flowid 1:13

fc 1:0 0x00 1:13 # DF/CS0
fc 1:0 0x30 1:13 # AF12
fc 1:0 0xb8 1:11 # EF
fc 1:0 0x90 1:11 # AF42
fc 1:0 0x10 1:11 # IMM
fc 1:0 0x50 1:12 # AF22
fc 1:0 0x70 1:12 # AF32
fc 1:0 0x20 1:13 # CS1
fc 1:0 0x40 1:12 # CS2
fc 1:0 0x60 1:12 # CS3
fc 1:0 0x80 1:11 # CS4
fc 1:0 0xa0 1:11 # CS5
fc 1:0 0xc0 1:11 # CS6
fc 1:0 0xe0 1:11 # CS7
fc 1:0 0x28 1:13 # AF11
fc 1:0 0x38 1:13 # AF13
fc 1:0 0x48 1:12 # AF21
fc 1:0 0x58 1:12 # AF23
fc 1:0 0x68 1:12 # AF31
fc 1:0 0x78 1:12 # AF33
fc 1:0 0x88 1:11 # AF41
fc 1:0 0x98 1:11 # AF43

# Arp traffic
tc filter add dev $interface parent 1:0 protocol arp prio $prio handle 1 fw classid 1:11
prio=$(($prio + 1))

}


ipt_setup() {

ipt -t mangle -N QOS_MARK_${IFACE}

ipt -t mangle -A QOS_MARK_${IFACE} -j DSCP --set-dscp-class AF12
ipt -t mangle -A QOS_MARK_${IFACE} -p icmp -j DSCP --set-dscp-class CS6
ipt -t mangle -A QOS_MARK_${IFACE} -s 192.168.10.50/32 -j DSCP --set-dscp-class EF
ipt -t mangle -A QOS_MARK_${IFACE} -p udp -m multiport --ports 20,21,22,25,53,80,110,123,443,993,995 -j DSCP --set-dscp-class AF22
ipt -t mangle -A QOS_MARK_${IFACE} -p tcp -m multiport --ports 20,21,22,25,53,80,110,123,443,993,995 -j DSCP --set-dscp-class AF22
ipt -t mangle -A QOS_MARK_${IFACE} -m length --length 0:120 -m DSCP --dscp-class AF22 -j DSCP --set-dscp-class AF42

ipt -t mangle -A POSTROUTING -o $DEV -m dscp --dscp-class CS0 -g QOS_MARK_${IFACE}
ipt -t mangle -A POSTROUTING -o $IFACE -m dscp --dscp-class CS0 -g QOS_MARK_${IFACE}

}


# TC rules

egress() {

CEIL=${UPLINK}
EXPRESS=`expr $CEIL \* 60 / 100`
PRIORITY=`expr $CEIL \* 35 / 100`
BULK=`expr $CEIL \* 5 / 100`

tc qdisc del dev $IFACE root 2> /dev/null
tc qdisc add dev $IFACE root handle 1: hfsc default 13
tc class add dev $IFACE parent 1: classid 1:1 hfsc sc rate ${CEIL}kbit ul rate ${CEIL}kbit

tc class add dev $IFACE parent 1:1 classid 1:11 hfsc sc rate ${EXPRESS}kbit ul rate ${CEIL}kbit
tc class add dev $IFACE parent 1:1 classid 1:12 hfsc sc rate ${PRIORITY}kbit ul rate ${CEIL}kbit
tc class add dev $IFACE parent 1:1 classid 1:13 hfsc sc rate ${BULK}kbit ul rate ${CEIL}kbit

tc qdisc add dev $IFACE parent 1:11 handle 110: $QDISC limit 20 $NOECN `get_quantum 240` `get_flows ${EXPRESS}`
tc qdisc add dev $IFACE parent 1:12 handle 120: $QDISC limit 20 $NOECN `get_quantum 480` `get_flows ${PRIORITY}`
tc qdisc add dev $IFACE parent 1:13 handle 130: $QDISC limit 50 $NOECN `get_quantum 1480` `get_flows ${BULK}`

diffserv $IFACE

}

ingress() {

CEIL=$DOWNLINK
EXPRESS=`expr $CEIL \* 60 / 100`
PRIORITY=`expr $CEIL \* 35 / 100`
BULK=`expr $CEIL \* 5 / 100`

tc qdisc del dev $IFACE handle ffff: ingress 2> /dev/null
tc qdisc add dev $IFACE handle ffff: ingress

tc qdisc del dev $DEV root  2> /dev/null
tc qdisc add dev $DEV root handle 1: hfsc default 13
tc class add dev $DEV parent 1: classid 1:1 hfsc sc rate ${CEIL}kbit ul rate ${CEIL}kbit

tc class add dev $DEV parent 1:1 classid 1:11 hfsc sc rate ${EXPRESS}kbit ul rate ${CEIL}kbit
tc class add dev $DEV parent 1:1 classid 1:12 hfsc sc rate ${PRIORITY}kbit ul rate ${CEIL}kbit
tc class add dev $DEV parent 1:1 classid 1:13 hfsc sc rate ${BULK}kbit ul rate ${CEIL}kbit

tc qdisc add dev $DEV parent 1:11 handle 110: $QDISC limit 25 $ECN `get_quantum 240` `get_flows ${EXPRESS}`
tc qdisc add dev $DEV parent 1:12 handle 120: $QDISC limit 50 $ECN `get_quantum 1480` `get_flows ${PRIORITY}`
tc qdisc add dev $DEV parent 1:13 handle 130: $QDISC limit 400 $ECN `get_quantum 1480` `get_flows ${BULK}`

diffserv $DEV

ifconfig $DEV up

$TC filter add dev $IFACE parent ffff: protocol all prio 10 u32 \
  match u32 0 0 flowid 1:1 action mirred egress redirect dev $DEV

}

do_modules
aqm_stop
ipt_setup
egress
ingress
