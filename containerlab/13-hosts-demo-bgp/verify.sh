#!/bin/sh
# Fails unless every BGP EVPN session is up and hosts reach each other over
# VNI 1010 (L2) and through VRF tenant1 (L3).
set -eu
lab=clab-13-hosts-demo-bgp

established() {
  docker exec "$lab-$1" vtysh -c 'show bgp l2vpn evpn summary' 2>/dev/null \
    | grep -cE ' [0-9]+ +[0-9]+ +N/A$' || true
}

# RR1 peers with four leaves and RR2; RR2 with three leaves (r131 is RR1-only) and RR1
timeout 180 sh -c "until [ \$(docker exec $lab-r100 vtysh -c 'show bgp l2vpn evpn summary' 2>/dev/null | grep -cE ' [0-9]+ +[0-9]+ +N/A\$') -eq 5 ] \
  && [ \$(docker exec $lab-r101 vtysh -c 'show bgp l2vpn evpn summary' 2>/dev/null | grep -cE ' [0-9]+ +[0-9]+ +N/A\$') -eq 4 ]; do sleep 3; done" \
  || { echo "BGP EVPN sessions: RR1 $(established r100)/5, RR2 $(established r101)/4" >&2; exit 1; }

# the first packets wait for EVPN to learn each host, so warm up before asserting
docker exec "$lab-host1" ping -c1 -W1 10.10.10.1 >/dev/null || true
docker exec "$lab-host2" ping -c1 -W1 10.10.10.1 >/dev/null || true
docker exec "$lab-host3" ping -c1 -W1 10.10.20.1 >/dev/null || true
sleep 3
docker exec "$lab-host1" ping -c3 -W3 10.10.10.12 >/dev/null || { echo "host1 -> host2 (L2, VNI 1010) failed" >&2; exit 1; }
docker exec "$lab-host1" ping -c3 -W3 10.10.20.13 >/dev/null || { echo "host1 -> host3 (L3, VRF tenant1) failed" >&2; exit 1; }
echo "BGP EVPN sessions up; host1 reaches host2 (L2) and host3 (L3)"
