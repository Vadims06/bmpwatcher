# BGP Topology Watcher (BMP Watcher)
BMP Watcher is a monitoring tool of BGP control-plane changes for network engineers. It works as a passive BMP station: routers open a BMP session towards it and stream their BGP tables, the watcher never peers and never connects to a router. It collects IPv4/IPv6 unicast, VPNv4/VPNv6 and EVPN routes, sends the whole table to **Topolograph** as a BGP graph beside your OSPF/IS-IS graphs, and ships every later change to Topolograph through **Fluent Bit**. Components are wrapped into containers: the collector is the published image `vadims06/bmpwatcher`, and this repository carries the compose file that runs it.

> [!NOTE]
> BGP monitoring needs [Topolograph v2.69](https://github.com/Vadims06/topolograph/releases) or later, EVPN needs Topolograph v2.73.

## Quick start
1. On a Docker host, install Topolograph:

    ```bash
    curl -O https://raw.githubusercontent.com/Vadims06/topolograph-docker/master/install.sh
    chmod +x install.sh
    sudo ./install.sh
    ```
2. Get BMP Watcher and set `TOPOLOGRAPH_HOST` (the host IP, not `localhost`), `TOPOLOGRAPH_PORT` and `TOPOLOGRAPH_API_TOKEN` in `.env`:

    ```bash
    git clone https://github.com/Vadims06/bmpwatcher.git
    cd bmpwatcher
    cp .env.example .env
    docker compose --profile collector up -d
    ```
3. Point BMP on your routers to `<host-ip>:11019`, see [Device configuration](#device-configuration).

No events on the dashboard? Start with [Troubleshooting](#troubleshooting).

## Logged BGP changes:
* BGP peer Up/Down
* Routes added, changed and withdrawn, per family:
  * IPv4 and IPv6 unicast
  * VPNv4 and VPNv6, with RD and route targets
  * EVPN route types 1-5 (RFC 7432, RFC 9136): MAC, IP, VNI, L3VNI, ESI, Ethernet Tag, VTEP
* EVPN MAC moves between VTEPs
* Pre-policy, post-policy and Loc-RIB (RFC 9069) observations are kept apart, so a route the router rejected is never shown as installed

## Architecture
```
routers --BMP (TCP 11019)--> bmpwatcher --snapshot--> Topolograph
                                  |
                                  +--events.jsonl--> Fluent Bit --events--> Topolograph
```
When a BMP session starts, the router replays its whole table. BMP Watcher collects that replay into one snapshot of the table, sends it to Topolograph, and only then reports changes as events. One watcher serves several BMP speakers, for example both route reflectors of a fabric.

In Topolograph the BGP graph is bound to your OSPF or IS-IS graph by Router ID, so BGP and EVPN questions are asked on the IGP graph: where a host is, which leaves carry a VNI, did a MAC move, what is the underlay path to a VTEP. See the [BMP Watcher guide](https://docs.topolograph.com/monitoring/bmp-watcher/#evpn).

## Quick lab
#### Containerlab
A 13-router FRR lab is placed here **containerlab/13-hosts-demo-bgp**: an OSPF underlay, a BGP EVPN/VXLAN overlay and BMP on both route reflectors to its own BMP Watcher. It needs Topolograph with an API token and Fluent Bit from this repository. It shows the EVPN table in Topolograph (VNIs, VRFs, leaves of a VNI, where a host is) and a MAC move of host1 from leaf r14 to leaf r15, marked with `moved_from_vtep`. Follow the steps and expected output in its [README](containerlab/13-hosts-demo-bgp/README.md).

## How to connect BMP watcher to real network
1. Choose a Linux host with Docker installed. Enable Docker at boot (`systemctl enable docker`): the containers restart after a crash and a reboot.
2. Setup Topolograph

    Launch your own Topolograph with [topolograph-docker](https://github.com/Vadims06/topolograph-docker) (`install.sh` above) or use the public https://topolograph.com.
    * Log in: on your own Topolograph with the user from its `.env` (`TOPOLOGRAPH_WEB_API_USERNAME_EMAIL` / `TOPOLOGRAPH_WEB_API_PASSWORD`, by default `ospf@topolograph.com` / `ospf`), on topolograph.com sign up.
    * Create a token: **API → Token → Create Token**, copy the `sk-...` value.

3. Setup BMP Watcher

    ```bash
    git clone https://github.com/Vadims06/bmpwatcher.git
    cd bmpwatcher
    cp .env.example .env
    ```
    Set variables in `.env` file:

    > [!NOTE]
    > * `TOPOLOGRAPH_HOST` - *the IP address of your host where Docker runs, do not put `localhost`, because Topolograph and BMP Watcher run in their own container networks*. For topolograph.com - `topolograph.com`
    > * `TOPOLOGRAPH_PORT` - by default `8080`, `443` for topolograph.com
    > * `WEBHOOK_TLS_ON` - `off` for your own Topolograph, `on` for topolograph.com
    > * `TOPOLOGRAPH_API_TOKEN` - the `sk-...` token
    > * `SOURCE_ID` - name of this collector in Topolograph, e.g. `dc1-rr`. Keep it stable: recreating the container with the same name keeps its data together
    > * `BMPWATCHER_LOG_DIR` - where the collector writes its files, by default `/var/log/bmpwatcher`

    Start the collector and Fluent Bit:
    ```bash
    docker compose --profile collector up -d
    ```
    Stop it with the same profile: `docker compose --profile collector down`.

    `docker compose --profile gobmp up -d` runs the raw [gobmp](https://hub.docker.com/r/vadims06/gobmp) collector instead: every BMP message as is, without the snapshot/event split.

4. Device configuration

    Point BMP on every monitored router to `<host-ip>:11019`. Enable pre- and post-policy monitoring where the platform offers it. For EVPN, enable BMP on the route reflectors: they hold every leaf's routes, while a leaf exports only what it learned.

    ### Device configuration
    **FRR** (EVPN verified). FRR loads BMP as a module: add `-M bmp` to `bgpd_options` in `/etc/frr/daemons` and restart FRR. In containerlab, edit the lab's `daemons` file and redeploy the lab instead: restarting FRR inside a running container drops its links. There, `<host-ip>` is the gateway of the lab's management network.
    ```
    router bgp <asn>
     bmp targets topolograph
      bmp connect <host-ip> port 11019 min-retry 1000 max-retry 2000
      bmp monitor ipv4 unicast pre-policy
      bmp monitor ipv4 unicast post-policy
      bmp monitor ipv6 unicast pre-policy
      bmp monitor ipv6 unicast post-policy
      bmp monitor ipv4 vpn pre-policy
      bmp monitor ipv4 vpn post-policy
      bmp monitor l2vpn evpn pre-policy
      bmp monitor l2vpn evpn post-policy
    ```
    **Cisco IOS-XR**
    ```
    bmp server 1
     host <host-ip> port 11019
     description topolograph
    !
    router bgp <asn>
     neighbor 10.0.0.2
      bmp-activate server 1
    ```
    **Juniper Junos**
    ```
    routing-options {
        bmp {
            station topolograph {
                station-address <host-ip>;
                station-port 11019;
                route-monitoring { pre-policy; post-policy; }
            }
        }
    }
    ```
    **Nokia SR OS**
    ```
    configure router bgp
        monitor
            admin-state enable
            station "topolograph"
                admin-state enable
                router-monitoring pre-policy
                router-monitoring post-policy
    ```
    The syntax for IOS-XR, Junos and SR OS is indicative; check your release notes for the exact keywords.

5. Check it on Topolograph

    The first snapshot goes out once every router finished replaying its table: about 30 seconds after its routes stop arriving, at most 5 minutes after the first one. Check that it was sent:
    ```bash
    docker logs bmpwatcher 2>&1 | grep 'topology posted'
    # topolograph topology posted to http://<host-ip>:8080/api/watcher/bgp: {"checkpoint": false, "graph_time": "...", "routes": 88}
    ```
    `routes` counts one route per router and peer: a route that is the same before and after policy is counted once. In Topolograph open your OSPF or IS-IS graph: its BGP overlay shows the sessions, and **Graph table → BGP Routes** the routes.

    For EVPN, the IGP graph must have the same Router IDs as the BGP speakers: upload the LSDB of your network or run [OSPF Watcher](https://github.com/Vadims06/ospfwatcher) / [IS-IS Watcher](https://github.com/Vadims06/isiswatcher). The same answers over the API:
    ```bash
    TOPOLOGRAPH_URL=http://<host-ip>:8080   # https://topolograph.com for the public one
    T=sk-...
    curl -s "$TOPOLOGRAPH_URL/api/graph/?protocol=bgp" -H "Authorization: Bearer $T"             # the IGP graph with BGP bound to it
    curl -s "$TOPOLOGRAPH_URL/api/graph/<graph_time>/vpns" -H "Authorization: Bearer $T"          # VNIs and VRFs
    curl -s "$TOPOLOGRAPH_URL/api/graph/<graph_time>/nodes?protocol=bgp&vni=<vni>" -H "Authorization: Bearer $T"  # leaves of a VNI
    ```
    Every Topolograph account also holds a demo BGP graph (`srcid: topolograph-demo`). Your own is the one whose `srcid` is your `SOURCE_ID` in `GET /api/bgp-graphs`.

## Troubleshooting
##### Symptoms
The router has no BMP session with the watcher.

##### Steps:
1. BMP is opened by the router. Check that the router reaches `<host-ip>:11019`, and that the watcher listens: `ss -lntp | grep 11019`.
2. FRR: `show bmp` must show the target `Up`. If the `bmp` commands are rejected, `-M bmp` is missing in `/etc/frr/daemons`.

##### Symptoms
The BMP session is up, but no BGP graph appears on Topolograph.

##### Steps:
1. `docker logs bmpwatcher`. `401` means the token is missing or wrong for this Topolograph. A connection error means `TOPOLOGRAPH_HOST`/`TOPOLOGRAPH_PORT` are not reachable from the container: use the host IP, not `localhost`.
2. No `topology posted` line yet: on FRR, `show bmp` shows `MonSent 0` until the router starts sending its table. With BMP added to a running FRR this was seen to take up to 5 minutes after the session came up.

##### Symptoms
The BGP graph is on Topolograph, but route changes do not appear.

##### Steps:
1. `docker logs bmp-fluentbit`. `HTTP status=401` means the token; a connection error means `TOPOLOGRAPH_HOST`/`TOPOLOGRAPH_PORT`/`WEBHOOK_TLS_ON`.
2. Check that the collector writes `<BMPWATCHER_LOG_DIR>/<SOURCE_ID>/artifacts/events.jsonl`: Fluent Bit reads only that layout.
3. On a quiet network the file stays empty: it carries changes only, the initial table goes to the snapshot.

### Minimum version
* Topolograph v2.69 for BGP, v2.73 for EVPN
* Fluent Bit 3.2

### Topolograph suite
* OSPF Watcher [link](https://github.com/Vadims06/ospfwatcher)
* IS-IS Watcher [link](https://github.com/Vadims06/isiswatcher)
* BMP Watcher [link](https://github.com/Vadims06/bmpwatcher)
* Topolograph [link](https://github.com/Vadims06/topolograph)
* Topolograph in docker [link](https://github.com/Vadims06/topolograph-docker)

### Community & feedback
* https://t.me/topolograph
* admin at topolograph.com
