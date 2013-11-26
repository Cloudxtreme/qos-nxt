#!/bin/sh

LL=1
ECN=1
BQLLIMIT1000=9000
BQLLIMIT500=4500
BQLLIMIT10=1514
QDISC=fq_codel
FQ_LIMIT=""
IFACE=$1
SPEED=$2
TXLEN=$3
TXRING=$4

[ -z `which ethtool` ] && echo error: ethtool is required && exit 1
[ -z `which tc` ] && echo error: tc is required && exit 1

S=/sys/class/net
FQ_OPTS=""

[ $LL -eq 1 ] && FQ_OPTS="$FQ_OPTS quantum 500"
[ $ECN -eq 1 ] && FQ_OPTS="$FQ_OPTS ecn"

FLOW_KEYS="src,dst,proto,proto-src,proto-dst"

et() {
(
	ethtool -K $IFACE tso off
	ethtool -K $IFACE gso off
	ethtool -K $IFACE ufo off
	ethtool -K $IFACE gro off
	ethtool -K $IFACE lro off
	ethtool -G $IFACE tx $TXRING
) 2> /dev/null
}

wifi() {
	tc qdisc add dev $IFACE handle 1 root mq
	tc qdisc add dev $IFACE parent 1:1 $QDISC $FQ_OPTS $FQ_LIMIT
	tc qdisc add dev $IFACE parent 1:2 $QDISC $FQ_OPTS $FQ_LIMIT
	tc qdisc add dev $IFACE parent 1:3 $QDISC $FQ_OPTS $FQ_LIMIT
	tc qdisc add dev $IFACE parent 1:4 $QDISC $FQ_OPTS $FQ_LIMIT
}

mq() {
	local I=1
	tc qdisc add dev $IFACE handle 1 root mq

	for i in $S/$IFACE/queues/tx-*
	do
		tc qdisc add dev $IFACE parent 1:$(printf "%x" $I) $QDISC $FQ_OPTS $FQ_LIMIT
		I=`expr $I + 1`
	done
	I=`expr $I - 1`
	tc filter add dev $IFACE prio 1 protocol ip parent 1: handle 100 \
		flow hash keys ${FLOW_KEYS} divisor $I baseclass 1:1
}

fq_codel() {
	tc qdisc add dev $IFACE root $QDISC $FQ_OPTS $FQ_LIMIT
}

fix_speed() {
	[ "$SPEED" -lt 1001 ] && FQ_LIMIT="limit 1200" && BQLLIMIT=$BQLLIMIT1000
	[ "$SPEED" -lt 501 ] && FQ_LIMIT="limit 800" && BQLLIMIT=$BQLLIMIT500
	[ "$SPEED" -lt 11 ] && FQ_LIMIT="limit 400" && BQLLIMIT=$BQLLIMIT10
	[ $LL -eq 1 ] && et

	for I in /sys/class/net/$IFACE/queues/tx-*/byte_queue_limits/limit_max
		do
			echo $BQLLIMIT > $I
		done
}

fix_queues() {
	tc qdisc del dev $IFACE root 2> /dev/null
	ifconfig $IFACE txqueuelen $TXLEN
	local QUEUES=`ls -d $S/$IFACE/queues/tx-* | wc -l | awk '{print $1}'`
	if [ $QUEUES -gt 1 ]
	then
		if [ -x $S/$IFACE/phy80211 ]
		then
			wifi
		else
			mq
		fi
	else
		fq_codel
	fi
}

fix_speed
fix_queues

exit 0
