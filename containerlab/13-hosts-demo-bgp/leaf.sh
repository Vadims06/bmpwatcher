#!/bin/sh
# Kernel devices FRR does not create for EVPN: a VXLAN device and bridge per
# VNI, VRF tenant1 with the L3VNI, anycast-gateway SVIs and the access ports.
# Usage: leaf.sh <vtep> "<VNIs with a gateway>" "<port:VNI ...>"; a port named
# bond0/<member> is an Ethernet Segment shared with another leaf.
set -eu
vtep=$1
gateway_vnis=$2
access_ports=$3

sysctl -qw net.ipv4.ip_forward=1
ip link add tenant1 type vrf table 1000
ip link set tenant1 up

add_vni() {
  ip link add "vxlan$1" type vxlan id "$1" dstport 4789 local "$vtep" nolearning
  ip link add "br$1" type bridge
  ip link set "vxlan$1" master "br$1"
  ip link set "br$1" up
  ip link set "vxlan$1" up
}

add_vni 5000
ip link set br5000 master tenant1
for vni in $gateway_vnis; do
  add_vni "$vni"
  # no BUM flood list is needed while every leaf answers ARP from EVPN
  bridge link set dev "vxlan$vni" neigh_suppress on
  # the same gateway MAC and address on every leaf, so a host keeps its gateway after a move
  ip link set "br$vni" address 00:00:5e:00:01:01
  ip link set "br$vni" master tenant1
  ip addr add "10.10.$((vni - 1000)).1/24" dev "br$vni"
  # an Ethernet Segment leaf advertises a host's MAC/IP only while its ARP entry is REACHABLE
  sysctl -qw "net.ipv4.neigh.br$vni.base_reachable_time_ms=3600000"
done

for entry in $access_ports; do
  port=${entry%%:*}
  vni=${entry##*:}
  case $port in
    bond0/*)
      ip link add bond0 type bond mode active-backup
      ip link set "${port#bond0/}" down
      ip link set "${port#bond0/}" master bond0
      ip link set "${port#bond0/}" up
      port=bond0
      ;;
  esac
  ip link set "$port" master "br$vni"
  ip link set "$port" up
done
