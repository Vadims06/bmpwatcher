#!/bin/sh
# Moves host1 from r14 to r15: a MAC move between two VTEPs in VNI 1010.
set -eu
lab=clab-13-hosts-demo-bgp
docker exec "$lab-host1" ip link set eth1 down
docker exec "$lab-host1" ip addr del 10.10.10.11/24 dev eth1
docker exec "$lab-host1" ip addr add 10.10.10.11/24 dev eth2
docker exec "$lab-host1" ip link set eth2 up
docker exec "$lab-host1" ip route add 10.10.20.0/24 via 10.10.10.1
docker exec "$lab-host1" ping -c3 -W3 10.10.10.1 >/dev/null
echo "host1 now sits behind r15 (VTEP 123.15.15.15)"
