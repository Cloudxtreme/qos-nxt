# qos-nxt

qos-nxt is a traffic shaping script based on the simple.qos scheduler and debloat scripts 
of the [cerowrt project](https://github.com/dtaht).

It was designed to run with [OpenWRT](http://openwrt.org) 12.09 Attitude Adjustment.

## Principles

qos-nxt combines HTB and fq_codel to define two queues: Priority and Regular. Priority is given the majority of the bandwidth (80%), 
with target to keep latency to a minimum for interactive traffic. Performances are guaranteed by fq_codel which evicts packets clogging
the processing queue.

Packets are allocated to a traffic class based on their DSCP flag as well as their source or destination ports. 
Currently, services given priority are as follow (please note that DSCP flag takes precedence if set):

- SSH
- SMTP
- SMTPS
- DNS
- NTP
- HTTP
- HTTPS
- FTP
- IMAP
- IMAPS
- POP3
- POP3S

## Pre-requisites

In order to use this script you will need to have the following packages installed on your OpenWRT router:

- kmod-sched
- kmod-sched-core
- ethtool

If you have a WNDR3800 router, the bin folder contains a custom build which includes all required dependencies. This release is based on [hnyman](https://forum.openwrt.org/viewtopic.php?id=28392) IPv6 build.

## Setup

1) Adjust settings in rc.local and simple-qos.sh

In rc.local, pay attention to the line below as they will be different for your setup. 
If you do not wish to debloat lan interfaces feel free to omit them. 

```bash
/etc/debloat.sh eth0 1000 100 64
/etc/debloat.sh eth0.1 1000 100 64
/etc/debloat.sh wlan1-1 75 32 16
...
```

If your router connect to your modem via an interface other than eth1, you will also have to change the top section of rc.local.

For simple-qos.sh please check the lines with a "(setup required)" comment. You will have to adjust your connection speed, overhead (select ethernet and set numeric values to 0 to disable) and actual internet interface (in my case pppoe-wan).

To determine your connection speed take the average as measured by [speedtest.net](http://speedtest.net) and take out 20% for safety.

2) Upload to router

```bash
scp simple-qos.sh root@router:/etc/
scp debloat.sh root@router:/etc/
scp rc.local root@router:/etc/
scp 10-qos root@router:/etc/hotplug.d/iface/
```

3) Start the script

```bash
ssh root@router "sh /etc/rc.local"
```

4) To monitor the filter performance, use the following commands:

Display class status (1:11 Priority, 1:12 Bulk):

```bash
tc -s class show dev pppoe-wan # pppoe-wan upload, ifb0 download. 
                               # Replace pppoe-wan by the interface configured in simple-qos.sh
```

Display filter status:

```bash
tc -s filter show dev pppoe-wan
```

