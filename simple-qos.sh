#!/bin/sh

UPLINK=370 #kbps
DOWNLINK=1450 #kbps

IFACE=pppoe-wan
DEV=ifb0

QDISC=fq_codel
AUTOFLOW=1
AUTOECN=1

ECN=""
NOECN=""
TC=/usr/sbin/tc

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
    
    insmod sch_${QDISC}
    insmod sch_ingress
    insmod act_mirred
    insmod cls_fw
    insmod sch_hfsc
    insmod ipt_multiport
    insmod ipt_dscp
    insmod ifb
    insmod cls_u32
    insmod em_u32
    
}

aqm_stop() {
    
    ipt -t mangle -D POSTROUTING -o $DEV -m dscp --dscp-class CS0 -g QOS_MARK_${IFACE}
    ipt -t mangle -D POSTROUTING -o $IFACE -m dscp --dscp-class CS0 -g QOS_MARK_${IFACE}
    ipt -t mangle -F QOS_MARK_${IFACE}
    ipt -t mangle -X QOS_MARK_${IFACE}
    $TC qdisc del dev $IFACE ingress
    $TC qdisc del dev $IFACE root
    $TC qdisc del dev $DEV root
    
}

fc() {
    
    $TC filter add dev $interface protocol ip parent $1 prio $prio u32 match ip tos $2 0xfc classid $3
    prio=$(($prio + 1))
    $TC filter add dev $interface protocol ipv6 parent $1 prio $prio u32 match ip6 priority $2 0xfc classid $3
    prio=$(($prio + 1))

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

qdisc_variants() {
    
    if [ "$AUTOECN" == 1 ]
    then
    case $QDISC in
        *codel|pie) ECN=ecn; NOECN=noecn ;;
        *) ;;
    esac
    fi
    
}

diffserv() {

    interface=$1
    prio=1

    $TC filter add dev $interface parent 1:0 protocol all prio 999 u32 \
            match ip protocol 0 0x00 flowid 1:12
    
    fc 1:0 0x30 1:12 # AF12
    fc 1:0 0x90 1:11 # AF42
    fc 1:0 0xc0 1:11 # CS6
    fc 1:0 0x02 1:12 # COS
    fc 1:0 0xb8 1:11 # EF
    fc 1:0 0x10 1:11 # IMM
    fc 1:0 0x08 1:12 # THRO
    fc 1:0 0x04 1:12 # REL
    fc 1:0 0x50 1:12 # AF22
    fc 1:0 0x70 1:12 # AF32
    fc 1:0 0x20 1:12 # CS1
    fc 1:0 0x40 1:12 # CS2
    fc 1:0 0x60 1:12 # CS3
    fc 1:0 0x80 1:11 # CS4
    fc 1:0 0xa0 1:11 # CS5
    fc 1:0 0xe0 1:11 # CS7
    fc 1:0 0x28 1:12 # AF11
    fc 1:0 0x38 1:12 # AF13
    fc 1:0 0x48 1:12 # AF21
    fc 1:0 0x58 1:12 # AF23
    fc 1:0 0x68 1:12 # AF31
    fc 1:0 0x78 1:12 # AF33
    fc 1:0 0x88 1:11 # AF41
    fc 1:0 0x98 1:11 # AF43
    fc 1:0 0x00 1:12 # DF/CS0

    $TC filter add dev $interface parent 1:0 protocol arp \
    prio $prio handle 1 fw classid 1:11

    prio=$(($prio + 1))

}

ipt_setup() {

    ipt -t mangle -N QOS_MARK_${IFACE}

    ipt -t mangle -A QOS_MARK_${IFACE} -j DSCP --set-dscp-class AF12
    
    ipt -t mangle -A QOS_MARK_${IFACE} -p udp -m multiport \
    --ports 20,21,22,25,53,80,110,123,443,465,993,995 -j DSCP --set-dscp-class AF42

    ipt -t mangle -A QOS_MARK_${IFACE} -p tcp -m multiport \
    --ports 20,21,22,25,53,80,110,123,443,465,993,995 -j DSCP --set-dscp-class AF42

    ipt -t mangle -A QOS_MARK_${IFACE} -p icmp -j DSCP --set-dscp-class CS6

    ipt -t mangle -A POSTROUTING -o $DEV -m dscp --dscp-class CS0 \
    -g QOS_MARK_${IFACE}

    ipt -t mangle -A POSTROUTING -o $IFACE -m dscp --dscp-class CS0 \
    -g QOS_MARK_${IFACE}

}

egress() {

    CEIL=$UPLINK
    EXPRESS=`expr $CEIL \* 80 / 100`
    BULK=`expr $CEIL \* 20 / 100`

    $TC qdisc del dev $IFACE root 2> /dev/null
    $TC qdisc add dev $IFACE root handle 1: hfsc

    $TC class add dev $IFACE parent 1: classid 1:1 hfsc sc rate ${CEIL}kbit \
    ul rate ${CEIL}kbit

    $TC class add dev $IFACE parent 1:1 classid 1:11 hfsc sc rate ${EXPRESS}kbit

    $TC class add dev $IFACE parent 1:1 classid 1:12 hfsc sc rate ${BULK}kbit

    $TC qdisc add dev $IFACE parent 1:11 handle 110: $QDISC limit 500 \
    $NOECN `get_quantum 375` `get_flows $EXPRESS`

    $TC qdisc add dev $IFACE parent 1:12 handle 120: $QDISC limit 500 \
    $NOECN `get_quantum 375` `get_flows $BULK`

    diffserv $IFACE

}

ingress() {

    CEIL=$DOWNLINK
    EXPRESS=`expr $CEIL \* 80 / 100`
    BULK=`expr $CEIL \* 20 / 100`

    $TC qdisc del dev $IFACE handle ffff: ingress 2> /dev/null
    $TC qdisc add dev $IFACE handle ffff: ingress

    $TC qdisc del dev $DEV root  2> /dev/null
    $TC qdisc add dev $DEV root handle 1: hfsc

    $TC class add dev $DEV parent 1: classid 1:1 hfsc sc rate ${CEIL}kbit \
    ul rate ${CEIL}kbit

    $TC class add dev $DEV parent 1:1 classid 1:11 hfsc sc rate ${EXPRESS}kbit

    $TC class add dev $DEV parent 1:1 classid 1:12 hfsc sc rate ${BULK}kbit

    $TC qdisc add dev $DEV parent 1:11 handle 110: $QDISC limit 500 \
    $ECN `get_quantum 375` `get_flows $EXPRESS`

    $TC qdisc add dev $DEV parent 1:12 handle 120: $QDISC limit 500 \
    $ECN `get_quantum 375` `get_flows $BULK`

    diffserv $DEV
    ifconfig $DEV up

    $TC filter add dev $IFACE parent ffff: protocol all prio 10 u32 \
    match u32 0 0 flowid 1:1 action mirred egress redirect dev $DEV

}

qdisc_variants
do_modules
aqm_stop
ipt_setup
egress
ingress
