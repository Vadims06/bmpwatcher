-- Reshapes bmpwatcher's events.jsonl records into Topolograph's event
-- format, mirroring ospfwatcher's own fluentbit/parse_events.lua. bmpwatcher
-- already emits the shared field names (user, event_name, event_object,
-- event_status, object_status, event_detected_by, asn, sesid, srcid), so this
-- filter only promotes the family-independent fields flat and nests what is
-- left into one family_data subdocument -- it never renames and never
-- derives a status.
local PEER_STATE_CHANGE_MSG = 10
local L3VPN_SAFI = 128
local EVPN_SAFI = 70

-- EVPN carries the VNI in rawlabels, the value as configured on the VTEP.
-- labels holds the same number shifted into an MPLS label, which is not what
-- an operator recognises. Placement is route-type specific: RT-3 (Inclusive
-- Multicast Ethernet Tag) carries no rawlabels of its own, its VNI lives in
-- the PMSI Tunnel attribute instead (RFC 6514 S5, RFC 8365 S5.1.3 for
-- VXLAN); RT-5's single rawlabels entry is always the L3VNI (symmetric
-- IRB), never an L2VNI, so vni stays empty there and l3vni holds it.
local function pmsi_tunnel_vni(base_attrs)
    if not base_attrs or not base_attrs.pmsi_tunnel then return nil end
    return base_attrs.pmsi_tunnel.raw_label
end

-- vni/l3vni share one route_type branch so the placement rule is encoded
-- once: RT-3 carries no rawlabels of its own, its VNI lives in the PMSI
-- Tunnel attribute instead; RT-5's single rawlabels entry is always the
-- L3VNI (symmetric IRB), never an L2VNI.
local function vni_and_l3vni(msg_data)
    local route_type = msg_data["route_type"]
    local raw = msg_data["rawlabels"]
    if route_type == 3 then
        return pmsi_tunnel_vni(msg_data["base_attrs"]), nil
    end
    if route_type == 5 then
        return nil, (raw and raw[1] or nil)
    end
    return (raw and raw[1] or nil), (raw and raw[2] or nil)
end

-- community_values collects every ext_community_list entry carrying the
-- given prefix (e.g. "rt=", "macmob="), stripped of it. Mirrors
-- the watcher's own community extraction so both read the same wire data
-- the same way.
local function community_values(base_attrs, prefix)
    local values = {}
    if not base_attrs or not base_attrs.ext_community_list then
        return values
    end
    local pattern = "^" .. prefix .. "(.+)"
    for _, community in ipairs(base_attrs.ext_community_list) do
        local v = string.match(community, pattern)
        if v then table.insert(values, v) end
    end
    return values
end

-- Route Target lives inside base_attrs.ext_community_list as "rt=<value>"
-- among other communities; absent entirely on a withdrawal.
local function route_target(base_attrs)
    return community_values(base_attrs, "rt=")[1]
end

-- macmob=<flags>:<seq> (RFC 7432 7.7): the sequence number orders
-- successive moves of the same MAC.
local function mac_mobility_seq(base_attrs)
    local raw = community_values(base_attrs, "macmob=")[1]
    if not raw then return nil end
    return tonumber(string.match(raw, "^%d+:(%d+)$"))
end

function parse_events(tag, timestamp, record)
    if not record["event_name"] or not record["event_status"] then
        return -1, 0, 0
    end
    local msg_data = record["msg_data"] or {}

    local ev = {
        ["@timestamp"]        = math.floor(timestamp),
        ["watcher_time"]      = record["watcher_time"],
        ["user"]              = record["user"],
        ["event_name"]        = record["event_name"],
        ["event_object"]      = record["event_object"],
        ["event_status"]      = record["event_status"],
        ["object_status"]     = record["object_status"],
        ["event_detected_by"] = record["event_detected_by"],
        ["asn"]               = record["asn"],
        ["srcid"]             = record["srcid"],
        -- The reporting BMP speaker. Kept flat rather than nested, because a
        -- receiver filters and groups by it.
        ["bmp_source"]        = record["bmp_source"],
        ["sesid"]             = record["sesid"],
        -- Family-independent, promoted flat so a receiver never has to look
        -- inside the nested subdocument for them -- the same fields a
        -- snapshot route carries at its own top level.
        ["replay_suspect"]    = record["replay_suspect"],
        ["policy"]            = record["policy"],
        ["afi"]               = record["afi"],
        ["safi"]              = record["safi"],
        ["rd"]                = record["rd"],
        ["prefix"]            = record["prefix"],
        ["prefix_len"]        = record["prefix_len"],
        ["path_id"]           = record["path_id"],
        ["msg_type"]          = record["msg_type"],
        ["bmp_timestamp"]     = record["bmp_timestamp"]
    }

    -- family_data is the one nested family-specific subdocument -- named for
    -- its role, not for the family, because the envelope uses "prefix" twice
    -- (once as the flat address above, once as a family name) and a document
    -- mapper rejects two fields claiming the same stored name. Its base_attrs
    -- carries the attribute set a `change` event needs (as_path, local_pref,
    -- med, origin, originator_id, cluster_list, communities) verbatim -- the
    -- same object a snapshot route's data already carries, so a receiver
    -- reads both through one code path instead of two.
    if record["msg_type"] == PEER_STATE_CHANGE_MSG then
        ev["family_data"] = {
            ["peer_ip"]       = msg_data["remote_ip"],
            ["remote_bgp_id"] = record["event_object"],
            ["reason"]        = msg_data["bmp_reason"]
        }
    elseif record["safi"] == EVPN_SAFI then
        -- eth_tag comes from record.evpn_eth_tag, bmpwatcher's own decimal
        -- decode of gobmp's raw base64 bytes -- Topolograph identifies an
        -- endpoint by (L2VNI, Ethernet Tag, MAC), so it needs it as a number.
        local route_vni, route_l3vni = vni_and_l3vni(msg_data)
        ev["family_data"] = {
            ["route_type"]     = msg_data["route_type"],
            -- evpn_key is bmpwatcher's own evpnKeyOf value (record's own field,
            -- not derived here) so a receiver never re-implements route identity.
            ["key"]            = record["evpn_key"],
            ["mac"]            = msg_data["mac"],
            ["ip_address"]     = msg_data["ip_address"],
            ["eth_segment_id"] = msg_data["eth_segment_id"],
            ["eth_tag"]        = record["evpn_eth_tag"],
            ["vni"]            = route_vni,
            ["l3vni"]          = route_l3vni,
            ["route_targets"]  = community_values(msg_data["base_attrs"], "rt="),
            ["rt"]             = route_target(msg_data["base_attrs"]),
            ["mm_seq"]         = mac_mobility_seq(msg_data["base_attrs"]),
            ["nexthop"]        = msg_data["nexthop"],
            ["peer_ip"]        = msg_data["peer_ip"],
            ["base_attrs"]     = msg_data["base_attrs"]
        }
    elseif record["safi"] == L3VPN_SAFI then
        ev["family_data"] = {
            ["rt"]         = route_target(msg_data["base_attrs"]),
            ["labels"]     = msg_data["labels"],
            ["nexthop"]    = msg_data["nexthop"],
            ["peer_ip"]    = msg_data["peer_ip"],
            ["base_attrs"] = msg_data["base_attrs"]
        }
    else
        ev["family_data"] = {
            ["nexthop"]    = msg_data["nexthop"],
            ["peer_ip"]    = msg_data["peer_ip"],
            ["base_attrs"] = msg_data["base_attrs"]
        }
    end

    return 1, timestamp, ev
end
