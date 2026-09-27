-- Self-check for parse_events.lua. Run with: lua fluentbit/parse_events_test.lua
-- Not wired into fluent-bit; a standalone script that loads the same file
-- fluent-bit loads and calls its entry point directly.
local script_dir = arg[0]:match("(.*/)") or "./"
dofile(script_dir .. "parse_events.lua")

local function assert_eq(actual, expected, label)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)))
    end
end

-- A prefix `change` event must keep every attribute state(T) needs to fold,
-- not just peer_ip/nexthop -- this is the fix for "add/change loses BGP
-- attributes" (base_attrs was never forwarded at all before).
local prefix_change = {
    event_name = "prefix", event_status = "change", object_status = "changed",
    event_object = "203.0.113.0/24", event_detected_by = "1.1.1.1",
    bmp_source = "2.2.2.2", asn = "65000", srcid = "src1", sesid = "ses1",
    user = "bmpwatcher", watcher_time = "2026-08-16T12:00:00.000Z",
    policy = "loc-rib", afi = 1, safi = 1, prefix = "203.0.113.0", prefix_len = 24,
    path_id = 0, msg_type = 74, bmp_timestamp = "2026-08-16T11:59:59.000Z",
    replay_suspect = false,
    msg_data = {
        peer_ip = "10.20.1.1", nexthop = "10.20.1.1",
        base_attrs = { as_path = "65001 64496", local_pref = 200, med = 0,
                       origin = "igp", community_list = { "65000:100" } },
    },
}
local code, _, ev = parse_events("tag", 1755345600, prefix_change)
assert_eq(code, 1, "prefix change: return code")
assert_eq(ev.policy, "loc-rib", "prefix change: policy")
assert_eq(ev.afi, 1, "prefix change: afi")
assert_eq(ev.prefix, "203.0.113.0", "prefix change: prefix")
assert_eq(ev.prefix_len, 24, "prefix change: prefix_len")
assert_eq(ev.path_id, 0, "prefix change: path_id")
assert_eq(ev.msg_type, 74, "prefix change: msg_type")
assert_eq(ev.family_data.peer_ip, "10.20.1.1", "prefix change: family_data.peer_ip")
assert_eq(ev.family_data.base_attrs.local_pref, 200, "prefix change: base_attrs.local_pref")
assert_eq(ev.family_data.base_attrs.as_path, "65001 64496", "prefix change: base_attrs.as_path")

-- An l3vpn event carries its RD flat (not nested), so it lines up with how a
-- route's own rd is stored.
local l3vpn_add = {
    event_name = "l3vpn", event_status = "add", object_status = "up",
    event_object = "1:1:198.51.100.0/24", event_detected_by = "1.1.1.1",
    bmp_source = "2.2.2.2", srcid = "src1", sesid = "ses1", user = "bmpwatcher",
    watcher_time = "2026-08-16T12:00:01.000Z",
    policy = "post", afi = 1, safi = 128, rd = "1:1", prefix = "198.51.100.0",
    prefix_len = 24, path_id = 0, msg_type = 74,
    msg_data = { peer_ip = "10.20.1.1", nexthop = "10.20.1.1", labels = { 24001 },
                 base_attrs = { ext_community_list = { "rt=65000:100" } } },
}
local _, _, l3vpn_ev = parse_events("tag", 1755345601, l3vpn_add)
assert_eq(l3vpn_ev.rd, "1:1", "l3vpn add: rd is flat")
assert_eq(l3vpn_ev.family_data.rt, "65000:100", "l3vpn add: route target extracted")
assert_eq(l3vpn_ev.family_data.labels[1], 24001, "l3vpn add: labels forwarded")

-- A peer-down event's msg_data now always carries peer_ip (synthesized by
-- watcher.go's emit for the flush path when there is no raw BMP message
-- left) -- this is what the correlation key depends on.
local peer_down = {
    event_name = "peer", event_status = "down", object_status = "down",
    event_object = "3.3.3.3", event_detected_by = "2.2.2.2", bmp_source = "2.2.2.2",
    srcid = "src1", sesid = "ses1", user = "bmpwatcher",
    watcher_time = "2026-08-16T12:00:02.000Z", msg_type = 10,
    msg_data = { remote_ip = "10.20.1.1" },
}
local _, _, peer_ev = parse_events("tag", 1755345602, peer_down)
assert_eq(peer_ev.family_data.peer_ip, "10.20.1.1", "peer down: family_data.peer_ip")

-- An EVPN RT-2 event with an L3VNI (symmetric IRB) carries every community
-- and label a fabric overlay/underlay query needs, not just vni/rt.
local evpn_add = {
    event_name = "evpn", event_status = "add", object_status = "up",
    event_object = "2:0:aa:bb:cc:00:00:01:10.10.10.5", event_detected_by = "1.1.1.1",
    bmp_source = "2.2.2.2", srcid = "src1", sesid = "ses1", user = "bmpwatcher",
    watcher_time = "2026-09-23T12:00:03.000Z",
    policy = "post", afi = 25, safi = 70, path_id = 0, msg_type = 74,
    -- evpn_key/evpn_eth_tag are flat fields on the event record itself
    -- (the watcher's own key and Ethernet Tag decode), not re-derived here.
    evpn_key = "2:0:aa:bb:cc:00:00:01:10.10.10.5",
    evpn_eth_tag = 100,
    msg_data = {
        route_type = 2, mac = "aa:bb:cc:00:00:01", ip_address = "10.10.10.5",
        eth_segment_id = "00:00:00:00:00:00:00:00:00:00",
        rawlabels = { 1010, 5000 },
        nexthop = "10.20.1.1", peer_ip = "10.20.1.1",
        base_attrs = { ext_community_list = { "rt=100:1010", "rt=100:5000",
                                               "rmac=0c:03:00:00:1b:08", "macmob=1:42" } },
    },
}
local _, _, evpn_ev = parse_events("tag", 1755345603, evpn_add)
assert_eq(evpn_ev.family_data.key, "2:0:aa:bb:cc:00:00:01:10.10.10.5", "evpn add: key")
assert_eq(evpn_ev.family_data.eth_tag, 100, "evpn add: eth_tag")
assert_eq(evpn_ev.family_data.vni, 1010, "evpn add: vni")
assert_eq(evpn_ev.family_data.l3vni, 5000, "evpn add: l3vni")
assert_eq(evpn_ev.family_data.route_targets[1], "100:1010", "evpn add: route_targets[1]")
assert_eq(evpn_ev.family_data.route_targets[2], "100:5000", "evpn add: route_targets[2]")
assert_eq(evpn_ev.family_data.mm_seq, 42, "evpn add: mm_seq")

-- RT-3 (Inclusive Multicast Ethernet Tag) carries no rawlabels of its own -
-- its VNI lives inside base_attrs.pmsi_tunnel.raw_label (RFC 6514 S5,
-- RFC 8365 S5.1.3 for VXLAN). Without this the overlay matrix (built from
-- RT-3) has no VNI.
local evpn_rt3 = {
    event_name = "evpn", event_status = "add", object_status = "up",
    event_object = "3:0:10.0.1.2", event_detected_by = "8.8.8.8",
    bmp_source = "5.5.5.5", srcid = "src1", sesid = "ses1", user = "bmpwatcher",
    watcher_time = "2026-09-23T12:00:04.000Z",
    policy = "post", afi = 25, safi = 70, path_id = 0, msg_type = 74,
    evpn_key = "3:0:10.0.1.2",
    msg_data = {
        route_type = 3, ip_address = "10.0.1.2",
        nexthop = "10.0.1.2", peer_ip = "10.0.1.2",
        base_attrs = { pmsi_tunnel = { flags = 0, tunnel_type = 6,
                                        mpls_label = 63, raw_label = 1010,
                                        tunnel_identifier = "CgABAg==" } },
    },
}
local _, _, rt3_ev = parse_events("tag", 1755345604, evpn_rt3)
assert_eq(rt3_ev.family_data.vni, 1010, "evpn RT-3: vni from pmsi_tunnel.raw_label")
assert_eq(rt3_ev.family_data.l3vni, nil, "evpn RT-3: l3vni absent")

-- RT-5's single rawlabels entry is the L3VNI (symmetric IRB), never an
-- L2VNI - Topolograph uses vni as the L2VNI in the endpoint identity.
local evpn_rt5 = {
    event_name = "evpn", event_status = "add", object_status = "up",
    event_object = "5:...", event_detected_by = "7.7.7.7",
    bmp_source = "5.5.5.5", srcid = "src1", sesid = "ses1", user = "bmpwatcher",
    watcher_time = "2026-09-23T12:00:05.000Z",
    policy = "post", afi = 25, safi = 70, path_id = 0, msg_type = 74,
    evpn_key = "5:...",
    msg_data = {
        route_type = 5, ip_address = "192.168.10.0",
        rawlabels = { 5000 },
        nexthop = "10.0.1.1", peer_ip = "10.0.1.1",
        base_attrs = { ext_community_list = { "rt=65000:5000" } },
    },
}
local _, _, rt5_ev = parse_events("tag", 1755345605, evpn_rt5)
assert_eq(rt5_ev.family_data.vni, nil, "evpn RT-5: vni absent (rawlabels[1] is the L3VNI)")
assert_eq(rt5_ev.family_data.l3vni, 5000, "evpn RT-5: l3vni")

-- A record missing event_name/event_status must be dropped, not crash.
local dropped = parse_events("tag", 1755345603, {})
assert_eq(dropped, -1, "malformed record: dropped")

print("parse_events.lua: all checks passed")
