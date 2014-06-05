#!/bin/sh

UPLINK=400 #kbps (setup required)
DOWNLINK=1700 #kbps (setup required)
LIMIT=500 #packets
QUANTUM=375 #bytes

#LINK LAYER ADAPTATION
LINKLAYER="atm" #adsl, ethernet, atm (setup required)
#PPPoA + VC/Mux: -4 atm
#PPPoA + VC/LLC: 4 atm
#PPPoE + VC/Mux: 20 atm
#PPPoE + VC/LLC: 28 atm
OVERHEAD_EGRESS=28 # (setup required)
#PPPoA + VC/Mux: 10 atm
#PPPoA + VC/LLC: 18 atm
#PPPoE + VC/Mux: 34 atm
#PPPoE + VC/LLC: 42 atm
OVERHEAD_INGRESS=42 # (setup required)

STAB_MTU=2047
STAB_MPU=0
STAB_TSIZE=512

#INTERFACE CONFIGURATION
IFACE=pppoe-wan # (setup required)
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
    insmod sch_htb
    insmod cls_fw
    insmod cls_u32
    insmod act_mirred
    insmod ifb
    insmod em_u32

}

aqm_stop() {

    $TC qdisc del dev $IFACE ingress
    $TC qdisc del dev $IFACE root
    $TC qdisc del dev $DEV root

}

get_mtu() {
    
    BW=$2
    F=`cat /sys/class/net/$1/mtu`
    if [ -z "$F" ]
    then
        F=1500
    fi
    if [ $BW -gt 20000 ]
    then
        F=$(($F * 2))
    fi
    if [ $BW -gt 30000 ]
    then
        F=$(($F * 2))
    fi
    if [ $BW -gt 40000 ]
    then
        F=$(($F * 2))
    fi
    if [ $BW -gt 50000 ]
    then
        F=$(($F * 2))
    fi
    if [ $BW -gt 60000 ]
    then
        F=$(($F * 2))
    fi
    if [ $BW -gt 80000 ]
    then
        F=$(($F * 2))
    fi
    echo $F
	
}

fc() {

    $TC filter add dev $1 protocol ip parent $2 prio $prio \
    u32 match ip tos $3 0xfc classid $4
    prio=$(($prio + 1))
    $TC filter add dev $1 protocol ipv6 parent $2 prio $prio \
    u32 match ip6 priority $3 0xfc classid $4
    prio=$(($prio + 1))

}

dc() {

    $TC filter add dev $1 protocol ip parent $2 prio $prio \
    u32 match ip dport $3 0xffff classid $4
    prio=$(($prio + 1))
    $TC filter add dev $1 protocol ipv6 parent $2 prio $prio \
    u32 match ip dport $3 0xffff classid $4
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

get_stab_string_e() {

    STABSTRING=""
    STABSTRING="stab mtu ${STAB_MTU} tsize ${STAB_TSIZE} mpu ${STAB_MPU}
    overhead ${OVERHEAD_EGRESS} linklayer ${LINKLAYER}"
    echo ${STABSTRING}

}

get_stab_string_i() {

    STABSTRING=""
    STABSTRING="stab mtu ${STAB_MTU} tsize ${STAB_TSIZE} mpu ${STAB_MPU}
    overhead ${OVERHEAD_INGRESS} linklayer ${LINKLAYER}"
    echo ${STABSTRING}

}

diffserv() {

    interface=$1
    prio=$2

    fc $interface 1:0 0x30 1:12 # AF12
    fc $interface 1:0 0x90 1:11 # AF42
    fc $interface 1:0 0xc0 1:11 # CS6
    fc $interface 1:0 0x70 1:11 # AF32
    fc $interface 1:0 0x50 1:12 # AF22
    fc $interface 1:0 0xb8 1:11 # EF
    fc $interface 1:0 0x10 1:11 # IMM
    fc $interface 1:0 0x20 1:12 # CS1
    fc $interface 1:0 0x40 1:12 # CS2
    fc $interface 1:0 0x60 1:11 # CS3
    fc $interface 1:0 0x80 1:11 # CS4
    fc $interface 1:0 0xa0 1:11 # CS5
    fc $interface 1:0 0xe0 1:11 # CS7
    fc $interface 1:0 0x28 1:12 # AF11
    fc $interface 1:0 0x38 1:12 # AF13
    fc $interface 1:0 0x48 1:12 # AF21
    fc $interface 1:0 0x58 1:12 # AF23
    fc $interface 1:0 0x68 1:11 # AF31
    fc $interface 1:0 0x78 1:11 # AF33
    fc $interface 1:0 0x88 1:11 # AF41
    fc $interface 1:0 0x98 1:11 # AF43

}

egress() {

    CEIL=$UPLINK
    EXPRESS=`expr $CEIL \* 80 / 100`
    BULK=`expr $CEIL \* 20 / 100`
    LQ="quantum `get_mtu $IFACE $CEIL`"

    $TC qdisc del dev $IFACE root 2> /dev/null
    $TC qdisc add dev $IFACE root handle 1: `get_stab_string_e` htb default 12

    $TC class add dev $IFACE parent 1: classid 1:1 htb $LQ rate ${CEIL}kbit \
    ceil ${CEIL}kbit

    $TC class add dev $IFACE parent 1:1 classid 1:11 htb $LQ rate ${EXPRESS}kbit \
    ceil ${CEIL}kbit burst 800kbit prio 1

    $TC class add dev $IFACE parent 1:1 classid 1:12 htb $LQ rate ${BULK}kbit \
    ceil ${CEIL}kbit prio 2

    $TC qdisc add dev $IFACE parent 1:11 handle 110: $QDISC limit $LIMIT \
    $NOECN `get_quantum $QUANTUM` `get_flows $EXPRESS`

    $TC qdisc add dev $IFACE parent 1:12 handle 120: $QDISC limit $LIMIT \
    $NOECN `get_quantum $QUANTUM` `get_flows $BULK`

    diffserv $IFACE 1

    dc $IFACE 1:0 20 1:11
    dc $IFACE 1:0 21 1:11
    dc $IFACE 1:0 22 1:11
    dc $IFACE 1:0 25 1:11
    dc $IFACE 1:0 53 1:11
    dc $IFACE 1:0 80 1:11
    dc $IFACE 1:0 110 1:11
    dc $IFACE 1:0 123 1:11
    dc $IFACE 1:0 443 1:11
    dc $IFACE 1:0 465 1:11
    dc $IFACE 1:0 993 1:11
    dc $IFACE 1:0 995 1:11

}

ingress() {

    CEIL=$DOWNLINK
    LQ="quantum `get_mtu $IFACE $CEIL`"

    $TC qdisc del dev $IFACE handle ffff: ingress 2> /dev/null
    $TC qdisc add dev $IFACE handle ffff: ingress

    $TC qdisc del dev $DEV root 2> /dev/null
    $TC qdisc add dev $DEV root handle 1: `get_stab_string_i` htb default 11

    $TC class add dev $DEV parent 1: classid 1:1 htb $LQ rate ${CEIL}kbit \
    ceil ${CEIL}kbit

    $TC class add dev $DEV parent 1:1 classid 1:11 htb $LQ rate ${CEIL}kbit \
    ceil ${CEIL}kbit prio 1

    $TC qdisc add dev $DEV parent 1:11 handle 110: $QDISC limit $LIMIT \
    $ECN `get_quantum $QUANTUM` `get_flows $CEIL`
    
    ifconfig $DEV up

    $TC filter add dev $IFACE parent ffff: protocol all prio 1 u32 \
    match u32 0 0 flowid 1:1 action mirred egress redirect dev $DEV

}

qdisc_variants
do_modules
aqm_stop
egress
ingress
