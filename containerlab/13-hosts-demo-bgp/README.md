# BMP watcher. Tracking BGP EVPN changes in Topolograph

This lab consists of 13 FRR routers, 3 hosts and a single BMP Watcher. The OSPF underlay is the one of Topolograph's
[13-hosts-demo-ospf](https://github.com/Vadims06/topolograph/tree/master/containerlab/13-hosts-demo-ospf)
lab (same links, addresses and router IDs), with a BGP EVPN / VXLAN overlay on top. Both route reflectors stream
their EVPN tables over BMP to BMP Watcher, which sends the table to Topolograph as a BGP graph and writes every change
to `artifacts/events.jsonl`; Fluent Bit ships those changes to Topolograph.

### What this lab shows
* The EVPN fabric in Topolograph: which VNIs and VRFs it has, which leaves carry a VNI, behind which leaf a host is,
  a host attached to two leaves, the subnets of a VRF.
* A MAC move: host1 moves from leaf r14 to leaf r15. Topolograph records the withdraw on VTEP `123.14.14.14`,
  the add on VTEP `123.15.15.15`, and marks the add with `moved_from_vtep: 123.14.14.14`.

### Requirements
| What | Why |
|---|---|
| Linux host with Docker, [containerlab](https://containerlab.dev/install/) and the `vxlan` kernel module | runs the lab |
| Topolograph: [topolograph-docker](https://github.com/Vadims06/topolograph-docker) or https://topolograph.com | receives the BGP graph and the events |
| Topolograph API token | the collector and Fluent Bit authenticate with it |
| Fluent Bit from the root of this repository | ships the route events, including the MAC move. Without it only the table reaches Topolograph |

No OSPF Watcher is needed: every Topolograph account already has the 13-router OSPF demo graph with the same router IDs,
and the BGP graph of the lab is bound to it.

### Topology
| Role | Routers |
|---|---|
| Route reflectors | r100 `123.123.100.100` (RR1), r101 `123.123.101.101` (RR2) |
| Leaves (VTEP = router ID) | r14 `123.14.14.14`, r15 `123.15.15.15`, r130 `123.123.30.30`, r131 `123.123.31.31` |
| Underlay only | r10, r11, r13, r30, r31, r110, r111 |

- r131 peers with RR1 only.
- Both reflectors export `l2vpn evpn` over BMP to BMP Watcher: RR1 pre- and post-policy, RR2 also Loc-RIB.
- L2VNI 1010 (10.10.10.0/24) on every leaf, L2VNI 1020 (10.10.20.0/24) on r130 and r131.
- Symmetric IRB in VRF `tenant1`, L3VNI 5000, anycast gateway `.1` on every leaf.

| Host | Address | MAC | Attached to |
|---|---|---|---|
| host1 | 10.10.10.11 | 00:c1:ab:00:00:01 | r14 (eth2 to r15 starts down) |
| host2 | 10.10.10.12 | 00:c1:ab:00:00:02 | Ethernet Segment on r130 and r131 |
| host3 | 10.10.20.13 | 00:c1:ab:00:00:03 | r131 |

## Quickstart
> [!NOTE]
> To connect to a router use `sudo docker exec -it clab-13-hosts-demo-bgp-r100 vtysh`.

1. Log in to Topolograph and create a token: **API → Token → Create Token**, copy the `sk-...` value. On your own
   Topolograph the user is in its `.env` (by default `ospf@topolograph.com` / `ospf`).

2. Create `.env` in the root of this repository. The lab's BMP Watcher and Fluent Bit both read it.
    ```
    cp .env.example .env
    ```
    Set in `.env`:
    > [!NOTE]
    > * `TOPOLOGRAPH_HOST` - *the IP address of the host where Topolograph runs, not `localhost`*. For topolograph.com - `topolograph.com`
    > * `TOPOLOGRAPH_PORT` - by default `8080`, `443` for topolograph.com
    > * `WEBHOOK_TLS_ON` - `off` for your own Topolograph, `on` for topolograph.com
    > * `TOPOLOGRAPH_API_TOKEN` - the `sk-...` token
    > * `BMPWATCHER_LOG_DIR=./containerlab` - where Fluent Bit finds the lab's `artifacts/events.jsonl`

3. Start the lab
    ```
    lsmod | grep -q '^vxlan' || sudo modprobe vxlan
    cd containerlab/13-hosts-demo-bgp
    sudo containerlab deploy -t 13-hosts-demo-bgp.clab.yml
    ./verify.sh
    ```
    Expected output:
    ```
    BGP EVPN sessions up; host1 reaches host2 (L2) and host3 (L3)
    ```

4. Check that the BGP table reached Topolograph (about a minute after the deploy)
    ```
    sudo docker logs clab-13-hosts-demo-bgp-bmpwatcher 2>&1 | grep -A4 'topology posted' | tail -5
    ```
    Expected output:
    ```
    2026/09/27 10:46:58 topolograph topology posted to http://<host-ip>:8080/api/watcher/bgp: {
      "checkpoint": true,
      "drift": 0,
      "graph_time": "27Sep2026_10h46m08s_4_hosts_af57b2"
    }
    ```
    A `401` instead means the token is wrong, a connection error means `TOPOLOGRAPH_HOST`/`TOPOLOGRAPH_PORT`.

5. Start Fluent Bit from the root of this repository. The lab has its own BMP Watcher, so start it without the
   `collector` profile:
    ```
    cd ../..
    sudo docker compose up -d
    sudo docker logs bmp-fluentbit 2>&1 | grep events.jsonl
    ```
    Expected output:
    ```
    [ info] [input:tail:tail.0] inotify_fs_add(): inode=5640563 watch_fd=1 name=/labs/13-hosts-demo-bgp/artifacts/events.jsonl
    ```

6. Find the IGP graph the lab's BGP is bound to. `TOPOLOGRAPH_URL` is the address you open Topolograph at:
   `http://<host-ip>:8080` for your own, `https://topolograph.com` for the public one.
    ```
    TOPOLOGRAPH_URL=http://<host-ip>:8080
    T=sk-...
    curl -s "$TOPOLOGRAPH_URL/api/graph/?protocol=bgp" -H "Authorization: Bearer $T"
    ```
    Expected output (trimmed): the 13-router OSPF demo graph with BGP bound to it
    ```
    [{"graph_time": "25Sep2026_07h31m51s_13_hosts", "hosts": {"count": 13}, "protocols": ["ospf", "bgp"], ...}, ...]
    ```
    Save its `graph_time`:
    ```
    G=25Sep2026_07h31m51s_13_hosts
    ```
    The account also holds a demo BGP graph captured on this lab (`srcid: topolograph-demo`), bound to the same graph;
    yours is the one with `srcid: 13-hosts-demo-bgp` in `GET /api/bgp-graphs`.

7. Ask Topolograph about the fabric. The outputs below are trimmed to the fields that answer the question.

    7.1 Which VNIs and VRFs does the fabric have?
    ```
    curl -s "$TOPOLOGRAPH_URL/api/graph/$G/vpns" -H "Authorization: Bearer $T"
    ```
    Expected output: L2VNI 1010 and 1020, both routed through VRF `tenant1` with L3VNI 5000
    ```
    {"vni": 1010, "l3vni": 5000, "route_targets": ["65000:1010", "65000:5000"], ...}
    {"vni": 1020, "l3vni": 5000, "route_targets": ["65000:1020", "65000:5000"], ...}
    {"name": "tenant1", "vni": null, "l3vni": 5000, "route_targets": ["65000:5000"], ...}
    ```

    7.2 Which leaves carry VNI 1020?
    ```
    curl -s "$TOPOLOGRAPH_URL/api/graph/$G/nodes?protocol=bgp&vni=1020" -H "Authorization: Bearer $T"
    ```
    Expected output: r130 and r131
    ```
    {"items": [{"can_build_path": true, "node_id": "123.123.30.30"}, {"can_build_path": false, "node_id": "123.123.31.31"}], ...}
    ```

    7.3 Behind which leaf is host 10.10.20.13?
    ```
    curl -s "$TOPOLOGRAPH_URL/api/graph/$G/routes?prefix=10.10.20.13" -H "Authorization: Bearer $T"
    ```
    Expected output: the host route (route type 2) terminates on VTEP `123.123.31.31` (r131) in VNI 1020; the
    subnet 10.10.20.0/24 (route type 5) is also reachable through r130
    ```
    {"prefix": "10.10.20.13/32", "evpn": {"route_type": 2, "mac": "00:c1:ab:00:00:03", "ip": "10.10.20.13", "vni": 1020, "l3vni": 5000, "vtep": "123.123.31.31", ...}, ...}
    {"prefix": "10.10.20.0/24", "evpn": {"route_type": 5, "l3vni": 5000, "vtep": "123.123.30.30", ...}, ...}
    {"prefix": "10.10.20.0/24", "evpn": {"route_type": 5, "l3vni": 5000, "vtep": "123.123.31.31", ...}, ...}
    ```

    7.4 Is host2 multihomed?
    ```
    curl -s "$TOPOLOGRAPH_URL/api/graph/$G/routes?mac=00:c1:ab:00:00:02" -H "Authorization: Bearer $T"
    ```
    Expected output: the same MAC on two VTEPs with one non-zero ESI - one Ethernet Segment on r130 and r131, not a move
    ```
    {"evpn": {"mac": "00:c1:ab:00:00:02", "ip": "10.10.10.12", "vni": 1010, "vtep": "123.123.30.30", "esi": "03:44:38:39:ff:00:01:00:00:01", ...}, ...}
    {"evpn": {"mac": "00:c1:ab:00:00:02", "ip": "10.10.10.12", "vni": 1010, "vtep": "123.123.31.31", "esi": "03:44:38:39:ff:00:01:00:00:01", ...}, ...}
    ```

    7.5 Which subnets does VRF tenant1 route?
    ```
    curl -s "$TOPOLOGRAPH_URL/api/graph/$G/routes?vrf=tenant1" -H "Authorization: Bearer $T"
    ```
    Expected output: 10.10.10.0/24 from all four leaves, 10.10.20.0/24 from r130 and r131, each with L3VNI 5000
    ```
    {"prefix": "10.10.10.0/24", "evpn": {"route_type": 5, "l3vni": 5000, "vtep": "123.14.14.14", ...}, ...}
    {"prefix": "10.10.10.0/24", "evpn": {"route_type": 5, "l3vni": 5000, "vtep": "123.15.15.15", ...}, ...}
    {"prefix": "10.10.10.0/24", "evpn": {"route_type": 5, "l3vni": 5000, "vtep": "123.123.30.30", ...}, ...}
    {"prefix": "10.10.10.0/24", "evpn": {"route_type": 5, "l3vni": 5000, "vtep": "123.123.31.31", ...}, ...}
    {"prefix": "10.10.20.0/24", "evpn": {"route_type": 5, "l3vni": 5000, "vtep": "123.123.30.30", ...}, ...}
    {"prefix": "10.10.20.0/24", "evpn": {"route_type": 5, "l3vni": 5000, "vtep": "123.123.31.31", ...}, ...}
    ```

    The same answers, and the underlay path to a host's VTEP, are in the Topolograph UI: **BGP / VPN** path mode on the
    OSPF demo graph, see the [BGP how-to](https://topolograph.com/how-to/bgp), section 11.

8. Move host1 from r14 to r15
    ```
    cd containerlab/13-hosts-demo-bgp
    ./move-host1.sh
    ```
    Expected output:
    ```
    host1 now sits behind r15 (VTEP 123.15.15.15)
    ```
    Fluent Bit sends the changes within a few seconds:
    ```
    sudo docker logs bmp-fluentbit 2>&1 | grep -A2 accepted | tail -3
    ```
    Expected output:
    ```
      "accepted": 18,
      "duplicates": 0
    }
    ```

9. Check the MAC move in Topolograph

    9.1 Did MAC 00:c1:ab:00:00:01 move?
    ```
    curl -s "$TOPOLOGRAPH_URL/api/events/$G/routes?mac=00:c1:ab:00:00:01&last_minutes=5" -H "Authorization: Bearer $T"
    ```
    Expected output: withdraws on VTEP `123.14.14.14`, then adds on VTEP `123.15.15.15`; the first add carries the move
    ```
    {"at": "2026-09-27T10:49:02.874000Z", "event": "withdraw", "evpn": {"mac": "00:c1:ab:00:00:01", "vni": 1010, "vtep": "123.14.14.14", ...}, ...}
    ...
    {"at": "2026-09-27T10:49:03.349000Z", "event": "add", "evpn": {"mac": "00:c1:ab:00:00:01", "vni": 1010, "vtep": "123.15.15.15", ...}, "moved_from_vtep": "123.14.14.14", ...}
    ```

    9.2 Where is host1 now?
    ```
    curl -s "$TOPOLOGRAPH_URL/api/graph/$G/routes?mac=00:c1:ab:00:00:01" -H "Authorization: Bearer $T"
    ```
    Expected output: every route of the MAC is on VTEP `123.15.15.15` (r15)
    ```
    {"evpn": {"mac": "00:c1:ab:00:00:01", "ip": null, "vni": 1010, "vtep": "123.15.15.15", ...}, ...}
    {"evpn": {"mac": "00:c1:ab:00:00:01", "ip": "10.10.10.11", "vni": 1010, "l3vni": 5000, "vtep": "123.15.15.15", ...}, ...}
    ```

10. Stop the lab
    ```
    cd ../..
    sudo docker compose down
    cd containerlab/13-hosts-demo-bgp
    sudo containerlab destroy -t 13-hosts-demo-bgp.clab.yml --cleanup
    ```

The lab runs `vadims06/bmpwatcher:latest`; set `BMPWATCHER_IMAGE` to use another image.
