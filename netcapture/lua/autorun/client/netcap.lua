-- netcap.lua (GLua / Garry's Mod)
-- Drop into: lua/autorun/server/netcap.lua (server-side incoming + outgoing)
-- Optional client-side: lua/autorun/client/netcap.lua (incoming from server + SendToServer outgoing)

print("[NETCAP] Loading...")

NETCAP = NETCAP or {}
NETCAP.Version = "2.0"

local function now()
    -- High precision timer in GMod
    return SysTime()
end

local function bitsToBytes(bits)
    return math.ceil((bits or 0) / 8)
end

local function fmtBytes(n)
    n = tonumber(n) or 0
    if n < 1024 then return string.format("%d B", n) end
    if n < 1024 * 1024 then return string.format("%.2f KB", n / 1024) end
    if n < 1024 * 1024 * 1024 then return string.format("%.2f MB", n / (1024 * 1024)) end
    return string.format("%.2f GB", n / (1024 * 1024 * 1024))
end

local function safeNick(ply)
    if IsValid(ply) and ply.Nick then return ply:Nick() end
    return "<unknown>"
end

local function safeSteamKey(ply)
    if not IsValid(ply) then return "CONSOLE/UNKNOWN" end
    if ply.SteamID64 then
        local sid64 = ply:SteamID64()
        if sid64 and sid64 ~= "0" then return sid64 end
    end
    if ply.SteamID then
        local sid = ply:SteamID()
        if sid and sid ~= "NULL" then return sid end
    end
    return "ENT:" .. tostring(ply:EntIndex())
end

local function getBytesWritten()
    -- Prefer BytesWritten; fallback to BitsWritten if needed
    if net.BytesWritten then
        return net.BytesWritten()
    elseif net.BitsWritten then
        return math.ceil(net.BitsWritten() / 8)
    end
    return 0
end

local function rfCountPlayers(rf)
    if not rf then return 0 end
    if rf.GetPlayers then
        local pls = rf:GetPlayers()
        if istable(pls) then return #pls end
    end
    return 0
end

local function countTargets(target)
    if not SERVER then
        -- client net.SendToServer => always 1 hop
        return 1
    end

    if not target then return 0 end
    if IsValid(target) then return 1 end
    if istable(target) then return #target end

    -- RecipientFilter-like object
    if target.GetPlayers then
        return rfCountPlayers(target)
    end

    return 1
end

local function countOmit(omit)
    if not SERVER then return 0 end
    if not omit then return 0 end
    if IsValid(omit) then return 1 end
    if istable(omit) then return #omit end
    if omit.GetPlayers then return rfCountPlayers(omit) end
    return 0
end

local function countBroadcast()
    if not SERVER then return 0 end
    local pls = player.GetAll()
    return istable(pls) and #pls or 0
end

local function countPVS(pos)
    if not SERVER then return 0 end
    local rf = RecipientFilter()
    rf:AddPVS(pos)
    return rfCountPlayers(rf)
end

local function countPAS(pos)
    if not SERVER then return 0 end
    local rf = RecipientFilter()
    rf:AddPAS(pos)
    return rfCountPlayers(rf)
end

-- Internal state
NETCAP._orig = NETCAP._orig or {}
NETCAP._wrappedReceivers = NETCAP._wrappedReceivers or {}
NETCAP._active = NETCAP._active or false
NETCAP._startT = NETCAP._startT or 0
NETCAP._currentName = NETCAP._currentName or nil

local function resetData()
    NETCAP.data = {
        meta = {
            side = SERVER and "server" or "client",
            started_at = os.date("%Y-%m-%d %H:%M:%S"),
            started_sys = now(),
        },
        totals = {
            incoming_bytes = 0,
            incoming_count = 0,

            outgoing_payload_bytes = 0, -- sum of payload once per send-call
            outgoing_wire_bytes = 0,    -- payload * recipients (best estimate)
            outgoing_calls = 0,
            outgoing_instances = 0,     -- recipients summed (where known)
        },
        incoming = {}, -- [name] => {bytes,count,max,avg}
        outgoing = {}, -- [name] => {payload_bytes,wire_bytes,calls,instances,max,avg_payload,avg_wire, send_types = {Broadcast=...,Send=...}}
        by_player = SERVER and {} or nil, -- [steamkey] => {nick, bytes, count, msgs = {[name]={bytes,count}}}
    }
end

local function ensureEntry(tbl, name, template)
    local e = tbl[name]
    if not e then
        e = template
        tbl[name] = e
    end
    return e
end

local function recordIncoming(name, bits, ply)
    local bytes = bitsToBytes(bits)
    NETCAP.data.totals.incoming_bytes = NETCAP.data.totals.incoming_bytes + bytes
    NETCAP.data.totals.incoming_count = NETCAP.data.totals.incoming_count + 1

    local e = ensureEntry(NETCAP.data.incoming, name, { bytes = 0, count = 0, max = 0 })
    e.bytes = e.bytes + bytes
    e.count = e.count + 1
    if bytes > e.max then e.max = bytes end

    if SERVER and NETCAP.data.by_player and IsValid(ply) then
        local key = safeSteamKey(ply)
        local pe = ensureEntry(NETCAP.data.by_player, key, { nick = safeNick(ply), bytes = 0, count = 0, msgs = {} })
        pe.bytes = pe.bytes + bytes
        pe.count = pe.count + 1

        local pm = ensureEntry(pe.msgs, name, { bytes = 0, count = 0 })
        pm.bytes = pm.bytes + bytes
        pm.count = pm.count + 1
    end
end

local function recordOutgoing(name, payloadBytes, recipients, sendType)
    payloadBytes = tonumber(payloadBytes) or 0
    recipients = tonumber(recipients) or 0

    NETCAP.data.totals.outgoing_payload_bytes = NETCAP.data.totals.outgoing_payload_bytes + payloadBytes
    NETCAP.data.totals.outgoing_calls = NETCAP.data.totals.outgoing_calls + 1

    local wireBytes = payloadBytes
    if recipients > 0 then
        wireBytes = payloadBytes * recipients
        NETCAP.data.totals.outgoing_instances = NETCAP.data.totals.outgoing_instances + recipients
    else
        -- unknown recipients -> keep wireBytes = payloadBytes
        NETCAP.data.totals.outgoing_instances = NETCAP.data.totals.outgoing_instances + 0
    end
    NETCAP.data.totals.outgoing_wire_bytes = NETCAP.data.totals.outgoing_wire_bytes + wireBytes

    local e = ensureEntry(NETCAP.data.outgoing, name, {
        payload_bytes = 0,
        wire_bytes = 0,
        calls = 0,
        instances = 0,
        max_payload = 0,
        max_wire = 0,
        send_types = {}
    })

    e.payload_bytes = e.payload_bytes + payloadBytes
    e.wire_bytes = e.wire_bytes + wireBytes
    e.calls = e.calls + 1
    e.instances = e.instances + math.max(recipients, 0)

    if payloadBytes > e.max_payload then e.max_payload = payloadBytes end
    if wireBytes > e.max_wire then e.max_wire = wireBytes end

    if sendType then
        e.send_types[sendType] = (e.send_types[sendType] or 0) + 1
    end
end

local function wrapReceiver(name, fn)
    if not isfunction(fn) then return fn end

    -- avoid double wrapping
    if NETCAP._wrappedReceivers[name] and NETCAP._wrappedReceivers[name].orig == fn then
        return NETCAP._wrappedReceivers[name].wrapped
    end

    local wrapped = function(len, ply)
        if NETCAP._active then
            recordIncoming(name, len, ply)
        end

        -- Keep original behavior, but don't let NETCAP crash the receiver chain
        local ok, err = pcall(fn, len, ply)
        if not ok then
            -- Bubble error like usual (print), but don't kill net handling
            ErrorNoHalt(string.format("[NETCAP] Receiver error in '%s': %s\n", tostring(name), tostring(err)))
        end
    end

    NETCAP._wrappedReceivers[name] = { orig = fn, wrapped = wrapped }
    return wrapped
end

local function wrapExistingReceivers()
    if not net.Receivers then return end
    for name, fn in pairs(net.Receivers) do
        net.Receivers[name] = wrapReceiver(name, fn)
    end
end

local function unwrapAllReceivers()
    if not net.Receivers then return end
    for name, pair in pairs(NETCAP._wrappedReceivers) do
        if pair and pair.orig and net.Receivers[name] == pair.wrapped then
            net.Receivers[name] = pair.orig
        end
    end
    NETCAP._wrappedReceivers = {}
end

local function patchNetReceive()
    if NETCAP._orig.netReceive then return end
    NETCAP._orig.netReceive = net.Receive

    net.Receive = function(name, fn)
        -- while active: wrap immediately, so receivers added after start are tracked
        if NETCAP._active and isfunction(fn) then
            return NETCAP._orig.netReceive(name, wrapReceiver(name, fn))
        end
        return NETCAP._orig.netReceive(name, fn)
    end
end

local function restoreNetReceive()
    if NETCAP._orig.netReceive then
        net.Receive = NETCAP._orig.netReceive
        NETCAP._orig.netReceive = nil
    end
end

local function patchOutgoing()
    if NETCAP._orig.netStart then return end

    NETCAP._orig.netStart = net.Start
    net.Start = function(name, unreliable)
        NETCAP._currentName = name
        return NETCAP._orig.netStart(name, unreliable)
    end

    local function patchSendFunc(key, resolver)
        if not net[key] or NETCAP._orig[key] then return end
        NETCAP._orig[key] = net[key]

        net[key] = function(arg)
            if NETCAP._active then
                local name = NETCAP._currentName or "<unknown>"
                local payload = getBytesWritten()
                local recipients, sendType = resolver(arg)
                recordOutgoing(name, payload, recipients, sendType)
            end
            return NETCAP._orig[key](arg)
        end
    end

    if SERVER then
        patchSendFunc("Send", function(target)
            return countTargets(target), "Send"
        end)

        if net.Broadcast then
            if not NETCAP._orig.Broadcast then NETCAP._orig.Broadcast = net.Broadcast end
            net.Broadcast = function()
                if NETCAP._active then
                    local name = NETCAP._currentName or "<unknown>"
                    local payload = getBytesWritten()
                    recordOutgoing(name, payload, countBroadcast(), "Broadcast")
                end
                return NETCAP._orig.Broadcast()
            end
        end

        if net.SendOmit then
            if not NETCAP._orig.SendOmit then NETCAP._orig.SendOmit = net.SendOmit end
            net.SendOmit = function(omit)
                if NETCAP._active then
                    local name = NETCAP._currentName or "<unknown>"
                    local payload = getBytesWritten()
                    local total = countBroadcast()
                    local om = countOmit(omit)
                    recordOutgoing(name, payload, math.max(total - om, 0), "SendOmit")
                end
                return NETCAP._orig.SendOmit(omit)
            end
        end

        if net.SendPVS then
            if not NETCAP._orig.SendPVS then NETCAP._orig.SendPVS = net.SendPVS end
            net.SendPVS = function(pos)
                if NETCAP._active then
                    local name = NETCAP._currentName or "<unknown>"
                    local payload = getBytesWritten()
                    recordOutgoing(name, payload, countPVS(pos), "SendPVS")
                end
                return NETCAP._orig.SendPVS(pos)
            end
        end

        if net.SendPAS then
            if not NETCAP._orig.SendPAS then NETCAP._orig.SendPAS = net.SendPAS end
            net.SendPAS = function(pos)
                if NETCAP._active then
                    local name = NETCAP._currentName or "<unknown>"
                    local payload = getBytesWritten()
                    recordOutgoing(name, payload, countPAS(pos), "SendPAS")
                end
                return NETCAP._orig.SendPAS(pos)
            end
        end
    else
        -- CLIENT
        if net.SendToServer then
            if not NETCAP._orig.SendToServer then NETCAP._orig.SendToServer = net.SendToServer end
            net.SendToServer = function()
                if NETCAP._active then
                    local name = NETCAP._currentName or "<unknown>"
                    local payload = getBytesWritten()
                    recordOutgoing(name, payload, 1, "SendToServer")
                end
                return NETCAP._orig.SendToServer()
            end
        end
    end
end

local function restoreOutgoing()
    if NETCAP._orig.netStart then
        net.Start = NETCAP._orig.netStart
        NETCAP._orig.netStart = nil
    end

    -- restore whichever existed
    local restoreKeys = {
        "Send", "Broadcast", "SendOmit", "SendPVS", "SendPAS", "SendToServer"
    }
    for _, k in ipairs(restoreKeys) do
        if NETCAP._orig[k] then
            net[k] = NETCAP._orig[k]
            NETCAP._orig[k] = nil
        end
    end

    NETCAP._currentName = nil
end

local function buildSortedList(map, builder)
    local out = {}
    for name, e in pairs(map) do
        out[#out + 1] = builder(name, e)
    end
    table.sort(out, function(a, b) return (a.sort_key or 0) > (b.sort_key or 0) end)
    return out
end

local function printTop(limit)
    limit = tonumber(limit) or 15

    local elapsed = math.max(now() - NETCAP._startT, 0.0001)
    print(string.format("\n[NETCAP] Results (%s) | elapsed: %.2fs", SERVER and "server" or "client", elapsed))
    print(string.format("[NETCAP] Incoming: %s in %d msgs | Outgoing wire: %s (payload: %s) in %d send-calls",
        fmtBytes(NETCAP.data.totals.incoming_bytes),
        NETCAP.data.totals.incoming_count,
        fmtBytes(NETCAP.data.totals.outgoing_wire_bytes),
        fmtBytes(NETCAP.data.totals.outgoing_payload_bytes),
        NETCAP.data.totals.outgoing_calls
    ))

    local incomingList = buildSortedList(NETCAP.data.incoming, function(name, e)
        local avg = e.count > 0 and (e.bytes / e.count) or 0
        return {
            name = name,
            total_bytes = e.bytes,
            count = e.count,
            max_bytes = e.max,
            avg_bytes = avg,
            bps = e.bytes / elapsed,
            sort_key = e.bytes
        }
    end)

    local outgoingList = buildSortedList(NETCAP.data.outgoing, function(name, e)
        local avgP = e.calls > 0 and (e.payload_bytes / e.calls) or 0
        local avgW = e.calls > 0 and (e.wire_bytes / e.calls) or 0
        return {
            name = name,
            wire_bytes = e.wire_bytes,
            payload_bytes = e.payload_bytes,
            calls = e.calls,
            instances = e.instances,
            max_payload = e.max_payload,
            max_wire = e.max_wire,
            avg_payload = avgP,
            avg_wire = avgW,
            bps_wire = e.wire_bytes / elapsed,
            send_types = e.send_types,
            sort_key = e.wire_bytes
        }
    end)

    print("\n[NETCAP] Top INCOMING (by total bytes):")
    for i = 1, math.min(limit, #incomingList) do
        local m = incomingList[i]
        print(string.format("  #%02d %-40s total=%-10s count=%-6d avg=%-8s max=%-8s rate=%-8s/s",
            i, m.name, fmtBytes(m.total_bytes), m.count, fmtBytes(m.avg_bytes), fmtBytes(m.max_bytes), fmtBytes(m.bps)
        ))
    end

    print("\n[NETCAP] Top OUTGOING (by estimated WIRE bytes):")
    for i = 1, math.min(limit, #outgoingList) do
        local m = outgoingList[i]
        print(string.format("  #%02d %-40s wire=%-10s payload=%-10s calls=%-6d avgWire=%-8s maxWire=%-8s rate=%-8s/s",
            i, m.name, fmtBytes(m.wire_bytes), fmtBytes(m.payload_bytes), m.calls, fmtBytes(m.avg_wire), fmtBytes(m.max_wire), fmtBytes(m.bps_wire)
        ))
    end

    if SERVER and NETCAP.data.by_player then
        local playersList = {}
        for key, e in pairs(NETCAP.data.by_player) do
            playersList[#playersList + 1] = {
                key = key,
                nick = e.nick,
                bytes = e.bytes,
                count = e.count
            }
        end
        table.sort(playersList, function(a, b) return a.bytes > b.bytes end)

        print("\n[NETCAP] Top PLAYERS (incoming bytes):")
        for i = 1, math.min(10, #playersList) do
            local p = playersList[i]
            print(string.format("  #%02d %-30s %-20s bytes=%-10s count=%d",
                i, p.nick, p.key, fmtBytes(p.bytes), p.count
            ))
        end
    end

    return incomingList, outgoingList
end

local function writeReport(incomingList, outgoingList)
    file.CreateDir("netcap")

    local elapsed = math.max(now() - NETCAP._startT, 0.0001)

    NETCAP.data.meta.stopped_at = os.date("%Y-%m-%d %H:%M:%S")
    NETCAP.data.meta.stopped_sys = now()
    NETCAP.data.meta.elapsed_sec = elapsed

    NETCAP.data.report = {
        incoming = incomingList,
        outgoing = outgoingList,
    }

    local fileName = string.format("netcap/netcap_%s_%s.json", os.date("%Y-%m-%d_%H-%M-%S"), SERVER and "sv" or "cl")
    file.Write(fileName, util.TableToJSON(NETCAP.data, true))
    print(string.format("\n[NETCAP] Saved report to data/%s", fileName))
end

function NETCAP.Start(seconds)
    if NETCAP._active then
        print("[NETCAP] Already active.")
        return
    end

    resetData()
    NETCAP._active = true
    NETCAP._startT = now()

    patchNetReceive()
    wrapExistingReceivers()
    patchOutgoing()

    print(string.format("[NETCAP] Started (%s). Use netcap_stop. Optional: netcap_status",
        SERVER and "server" or "client"
    ))

    seconds = tonumber(seconds)
    if seconds and seconds > 0 then
        timer.Remove("NETCAP.AutoStop")
        timer.Create("NETCAP.AutoStop", seconds, 1, function()
            if NETCAP._active then
                print(string.format("[NETCAP] Auto-stopping after %.2fs", seconds))
                NETCAP.Stop()
            end
        end)
    end
end

function NETCAP.Stop()
    if not NETCAP._active then
        print("[NETCAP] Not active.")
        return
    end

    NETCAP._active = false
    timer.Remove("NETCAP.AutoStop")

    -- Restore patched stuff first
    restoreOutgoing()
    restoreNetReceive()
    unwrapAllReceivers()

    local incomingList, outgoingList = printTop(20)
    writeReport(incomingList, outgoingList)

    print("[NETCAP] Stopped.")
end

function NETCAP.Status()
    if not NETCAP._active then
        print("[NETCAP] Not active.")
        return
    end
    local elapsed = math.max(now() - NETCAP._startT, 0.0001)
    print(string.format("[NETCAP] Active for %.2fs | IN=%s (%d) | OUT(wire)=%s | OUT(payload)=%s",
        elapsed,
        fmtBytes(NETCAP.data.totals.incoming_bytes),
        NETCAP.data.totals.incoming_count,
        fmtBytes(NETCAP.data.totals.outgoing_wire_bytes),
        fmtBytes(NETCAP.data.totals.outgoing_payload_bytes)
    ))
end

function NETCAP.Shutdown()
    -- For safe reloads
    if NETCAP._active then
        NETCAP._active = false
    end
    timer.Remove("NETCAP.AutoStop")
    restoreOutgoing()
    restoreNetReceive()
    unwrapAllReceivers()
end

-- Permissions
local function isAllowed(ply)
    if not IsValid(ply) then return true end -- server console / rcon
    if ply.IsAdmin and ply:IsAdmin() then return true end
    if ply.ChatPrint then ply:ChatPrint("You must be an admin to use NETCAP.") end
    return false
end

-- Commands
concommand.Add("netcap_start", function(ply, cmd, args)
    if not isAllowed(ply) then return end
    local seconds = args and args[1]
    NETCAP.Start(seconds)
end)

concommand.Add("netcap_stop", function(ply)
    if not isAllowed(ply) then return end
    NETCAP.Stop()
end)

concommand.Add("netcap_status", function(ply)
    if not isAllowed(ply) then return end
    NETCAP.Status()
end)

print("[NETCAP] Loaded. Commands: netcap_start [seconds], netcap_status, netcap_stop")
