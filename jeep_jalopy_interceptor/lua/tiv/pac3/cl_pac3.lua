-- ============================================================================
-- TIV PAC3 INTEGRATION - Client
--
-- Receives stage events from the server for a target entity (vehicle or
-- player), applies the local player's per-outfit bindings (for local-owned
-- entities) or falls back to defaults (for remote observers), fires
-- pac_command_events directly on the target entity so PAC3 outfits worn
-- on the vehicle or on players play correctly.
--
-- Mapping UI: scans PAC3 parts on BOTH the local player and the TIV vehicle
-- the player is sitting in (most PAC3 dupes are worn on the vehicle),
-- provides a rotating 3D preview that shows the vehicle when seated, lets
-- you test-fire any command event and bind it to a TIV deploy stage.
-- Bindings are per-outfit (keyed by owner entity + root group name) so
-- different creations can use independent event names.
-- ============================================================================

TIV = TIV or {}
TIV.PAC3 = TIV.PAC3 or {}

local MAP_FILE = "tiv/pac3_mapping.json"

-- ---------------------------------------------------------------------------
-- PAC helpers
-- ---------------------------------------------------------------------------
local function ApplyPacEventFor(ent, cmd, on)
    if not IsValid(ent) then return end
    if not cmd or cmd == "" then return end
    ent.pac_command_events = ent.pac_command_events or {}
    ent.pac_command_events[cmd] = { name = cmd, time = pac.RealTime, on = on }

    if ent == pac.LocalPlayer and pac.camera_linked_command_events and pac.camera_linked_command_events[cmd] then
        if isfunction(pac.TryToAwakenDormantCameras) then pac.TryToAwakenDormantCameras() end
    end
end

local function ApplySequenceFor(ent, base, num)
    if not IsValid(ent) or not base or base == "" then return end
    ent.pac_command_events = ent.pac_command_events or {}
    ent.pac_command_event_sequencebases = ent.pac_command_event_sequencebases or {}

    local data = ent.pac_command_event_sequencebases[base]
    if not data then
        data = { name = base, min = 0, max = num or 1, current = 0 }
        ent.pac_command_event_sequencebases[base] = data
    end
    data.current = num or 0
    if num and num > data.max then data.max = num end

    for i = 0, math.max(100, data.max) do
        ent.pac_command_events[base .. i] = nil
    end
    if num and num > 0 then
        ApplyPacEventFor(ent, base .. num, 1)
    end
end

-- Fire an event on the given entity for local testing (preview / buttons).
local function FireLocal(ent, cmd, mode)
    if not IsValid(ent) or not cmd or cmd == "" then return end
    if mode == 1 then       ApplyPacEventFor(ent, cmd, 1)
    elseif mode == 0 then   ApplyPacEventFor(ent, cmd, 0)
    else                    ApplyPacEventFor(ent, cmd, 0) end -- one-shot
end

-- ---------------------------------------------------------------------------
-- Find which entity is the "relevant preview target": the TIV vehicle we're
-- sitting in (preferred, since that's where outfits live) or local player.
-- ---------------------------------------------------------------------------
local function GetLocalTIVVehicle()
    local lp = LocalPlayer()
    if not IsValid(lp) then return nil end
    if TIV and TIV.ResolveVehicle then return TIV.ResolveVehicle(lp) end
    local seat = lp:GetVehicle()
    if IsValid(seat) then
        if seat:GetClass():find("jeep") or seat:GetClass():find("prop_vehicle") then return seat end
        if seat.GetParent then
            local p = seat:GetParent()
            if IsValid(p) then return p end
        end
    end
    return nil
end

-- Return all entities we should scan/preview (vehicle + local player).
local function GetScanTargets()
    local list = {}
    local seen = {}
    local function add(ent)
        if IsValid(ent) and not seen[ent:EntIndex()] then
            seen[ent:EntIndex()] = true
            table.insert(list, ent)
        end
    end
    local veh = GetLocalTIVVehicle()
    if veh then add(veh) end
    add(LocalPlayer())
    return list
end

-- ---------------------------------------------------------------------------
-- NET RECEIVERS
-- ---------------------------------------------------------------------------
if not ConVarExists("tiv_pac3_enable_sequence") then
    CreateClientConVar("tiv_pac3_enable_sequence", "1", true, false,
        "Whether to fire sequenced tiv_stage0..tiv_stage4 events alongside named events.")
end

-- Outfit binding storage:
--   bindings[eid][stage] = { cmd1, cmd2, ... }
-- where eid is "veh:<rootname>" or "ply:<rootname>"
TIV.PAC3.Bindings = TIV.PAC3.Bindings or nil

local function DefaultData()
    return { bindings = {}, disableDefaults = false }
end

local function EnsureData()
    if TIV.PAC3.Bindings then return TIV.PAC3.Bindings end
    TIV.PAC3.Bindings = DefaultData()
    if not file.IsDir("tiv", "DATA") then file.CreateDir("tiv") end
    if file.Exists(MAP_FILE, "DATA") then
        local raw = file.Read(MAP_FILE, "DATA")
        if raw and raw ~= "" then
            local ok, decoded = pcall(util.JSONToTable, raw)
            if ok and istable(decoded) then
                if istable(decoded.bindings) then TIV.PAC3.Bindings.bindings = decoded.bindings end
                if decoded.disableDefaults ~= nil then
                    TIV.PAC3.Bindings.disableDefaults = decoded.disableDefaults
                end
            end
        end
    end
    return TIV.PAC3.Bindings
end

function TIV.PAC3.Save()
    local d = EnsureData()
    file.Write(MAP_FILE, util.TableToJSON({
        bindings = d.bindings,
        disableDefaults = d.disableDefaults,
    }, true))
end

local function OwnerPrefix(ent)
    if ent:IsPlayer() then return "ply" else return "veh" end
end

local function OutfitId(ent, rootName)
    return OwnerPrefix(ent) .. ":" .. (rootName or "?")
end

function TIV.PAC3.Bind(ent, rootName, cmd, stage)
    local d = EnsureData()
    local oid = OutfitId(ent, rootName)
    d.bindings[oid] = d.bindings[oid] or { name = rootName, stages = {} }
    local list = d.bindings[oid].stages[stage] or {}
    for i, n in ipairs(list) do if n == cmd then table.remove(list, i) break end end
    table.insert(list, cmd)
    d.bindings[oid].stages[stage] = list
    TIV.PAC3.Save()
end

function TIV.PAC3.Unbind(ent, rootName, cmd, stage)
    local d = EnsureData()
    local oid = OutfitId(ent, rootName)
    local outfit = d.bindings[oid]
    if not outfit or not outfit.stages then return end
    local list = outfit.stages[stage]
    if not list then return end
    for i, n in ipairs(list) do if n == cmd then table.remove(list, i) break end end
    TIV.PAC3.Save()
end

function TIV.PAC3.EventStages(ent, rootName, cmd)
    local d = EnsureData()
    local oid = OutfitId(ent, rootName)
    local outfit = d.bindings[oid]
    local res = {}
    if outfit and outfit.stages then
        for _, st in ipairs(TIV.PAC3.STAGES) do
            local list = outfit.stages[st]
            if list then
                for _, n in ipairs(list) do if n == cmd then table.insert(res, st) break end end
            end
        end
    end
    return res
end

-- Collect event names to fire for a given stage on a given entity.
local function CollectEventsFor(ent, stage)
    local list = {}
    local seen = {}
    local d = EnsureData()

    -- Per-outfit bindings for outfits owned by this entity.
    local prefix = OwnerPrefix(ent) .. ":"
    for oid, outfit in pairs(d.bindings) do
        if oid:sub(1, 4) == prefix and outfit.stages and outfit.stages[stage] then
            for _, ev in ipairs(outfit.stages[stage]) do
                if isstring(ev) and ev ~= "" and not seen[ev] then
                    seen[ev] = true
                    table.insert(list, ev)
                end
            end
        end
    end

    -- Default tiv_* names (unless user disabled them).
    if not d.disableDefaults then
        local def = TIV.PAC3.DefaultMap[stage]
        if def and def ~= "" then
            for ev in string.gmatch(def, "[^,;]+") do
                ev = string.Trim(ev)
                if ev ~= "" and not seen[ev] then
                    seen[ev] = true
                    table.insert(list, ev)
                end
            end
        end
    end

    return list
end

net.Receive("TIV_PAC3_FireEvent", function()
    local ent   = net.ReadEntity()
    local stage = net.ReadString()
    local mode  = net.ReadInt(8)
    if not IsValid(ent) then return end

    local events
    -- For entities owned by the local player (local player OR their current
    -- vehicle when driving), apply per-outfit bindings. For other entities
    -- (remote players, other peoples' vehicles) just fire default tiv_* names
    -- since we don't know their custom mapping.
    local isOurs = (ent == LocalPlayer()) or (ent == GetLocalTIVVehicle())
    if isOurs then
        events = CollectEventsFor(ent, stage)
    else
        local def = TIV.PAC3.DefaultMap[stage]
        events = def and { def } or {}
    end

    for _, ev in ipairs(events) do ApplyPacEventFor(ent, ev, mode) end
end)

net.Receive("TIV_PAC3_FireSequence", function()
    local ent  = net.ReadEntity()
    local base = net.ReadString()
    local num  = net.ReadUInt(8)
    if not IsValid(ent) then return end
    local isOurs = (ent == LocalPlayer()) or (ent == GetLocalTIVVehicle())
    if isOurs then
        local cv = GetConVar("tiv_pac3_enable_sequence")
        if cv and not cv:GetBool() then return end
    end
    ApplySequenceFor(ent, base, num)
end)

-- ---------------------------------------------------------------------------
-- OUTFIT SCANNER
-- Walks _every_ known PAC3 part (pac_all_parts is global, keyed by part.Id)
-- and groups command events by their root outfit owner. Returns outfits
-- whose owner is one of our scan targets (local player, their TIV vehicle).
-- ---------------------------------------------------------------------------
local function ScanOutfitsOnEntity(targetEnt)
    local outfits = {}
    local all = rawget(_G, "pac_all_parts")
    if not all or not IsValid(targetEnt) then return outfits end

    for id, part in pairs(all) do
        if IsValid(part) and part.ClassName == "event" then
            local owner
            local ok = pcall(function() owner = part:GetPlayerOwner() end)
            if ok and IsValid(owner) and owner == targetEnt then
                local ok2, evType = pcall(part.GetEvent, part)
                if ok2 and evType == "command" then
                    local cmd, holdTime
                    local ok3, parsed = pcall(part.GetParsedArgumentsForObject, part, part.Events and part.Events.command)
                    if ok3 and istable(parsed) then
                        cmd      = parsed[1] or parsed.find or ""
                        holdTime = tonumber(parsed[2] or parsed.time) or 0
                    end
                    if cmd and cmd ~= "" then
                        local root = part
                        if part.GetRootPart then
                            local r
                            pcall(function() r = part:GetRootPart() end)
                            if IsValid(r) then root = r end
                        end

                        local givenName = root.Name or ""
                        local oName = givenName ~= "" and givenName or ((root.GetName and root:GetName()) or "Outfit")
                        local oid = OutfitId(targetEnt, oName)

                        local entry = outfits[oid]
                        if not entry then
                            entry = { ent = targetEnt, id = oid, name = oName,
                                      ownerLabel = targetEnt:IsPlayer() and "Player" or "Vehicle",
                                      root = root, events = {} }
                            outfits[oid] = entry
                        end
                        if not entry.events[cmd] then
                            entry.events[cmd] = { part = part, name = cmd, time = holdTime or 0 }
                        end
                    end
                end
            end
        end
    end

    local list = {}
    for _, e in pairs(outfits) do table.insert(list, e) end
    table.sort(list, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
    return list
end

-- ---------------------------------------------------------------------------
-- VEHICLE ENTER/EXIT STATE SYNC
-- ---------------------------------------------------------------------------
local function ClearAllTIVStates()
    for _, ent in ipairs(GetScanTargets()) do
        for _, stage in ipairs(TIV.PAC3.STAGES) do
            for _, ev in ipairs(CollectEventsFor(ent, stage)) do
                ApplyPacEventFor(ent, ev, 0)
            end
            local def = TIV.PAC3.DefaultMap[stage]
            if def and def ~= "" then ApplyPacEventFor(ent, def, 0) end
        end
        ApplySequenceFor(ent, TIV.PAC3.DefaultSequenceBase, 0)
    end
end

local function FireIdleState()
    for _, ent in ipairs(GetScanTargets()) do
        local events = CollectEventsFor(ent, "idle")
        for _, ev in ipairs(events) do ApplyPacEventFor(ent, ev, 1) end
    end
end

hook.Add("PlayerEnteredVehicle", "TIV_PAC3_EnterVehicle", function(ply, veh)
    if ply ~= LocalPlayer() then return end
    if not (TIV.IsSupportedVehicle and TIV.IsSupportedVehicle(veh)) then return end
    timer.Simple(0.3, function()
        if not IsValid(ply) or not ply:InVehicle() then return end
        ClearAllTIVStates()
        FireIdleState()
    end)
end)

hook.Add("PlayerLeaveVehicle", "TIV_PAC3_LeaveVehicle", function(ply, veh)
    if ply ~= LocalPlayer() then return end
    ClearAllTIVStates()
end)

hook.Add("InitPostEntity", "TIV_PAC3_InitReset", function()
    timer.Simple(1, function() if IsValid(LocalPlayer()) then ClearAllTIVStates() end end)
end)

-- ---------------------------------------------------------------------------
-- THEME FALLBACK
-- ---------------------------------------------------------------------------
local function Theme()
    return THEME or {
        bg         = Color(20, 22, 26, 255),
        panelBg    = Color(28, 31, 38, 255),
        headerBg   = Color(15, 17, 21, 255),
        accent     = Color(230, 130, 35, 255),
        accentDark = Color(160, 85, 20, 255),
        text       = Color(230, 235, 240, 255),
        textDim    = Color(150, 160, 170, 255),
        border     = Color(50, 55, 65, 255),
    }
end

-- ---------------------------------------------------------------------------
-- STAGE LABELS
-- ---------------------------------------------------------------------------
local STAGE_LABELS = {
    deploy_pressed   = { label = "Deploy Press", oneshot = true },
    lowering         = { label = "Lowering",     oneshot = true },
    deploying_spikes = { label = "SpkDown",      oneshot = true },
    anchored         = { label = "Anchor",      oneshot = false },
    retract_pressed  = { label = "Retract",      oneshot = true },
    retracting       = { label = "SpkUp",        oneshot = true },
    raising          = { label = "Raising",      oneshot = true },
    idle             = { label = "Idle",        oneshot = false },
}

local STAGE_BTN_ORDER = {
    { id = "deploy_pressed",   label = "Deploy",  w = 44 },
    { id = "lowering",         label = "Lower",   w = 40 },
    { id = "deploying_spikes", label = "SpkDn",   w = 40 },
    { id = "anchored",         label = "Anchor",  w = 44 },
    { id = "retract_pressed",  label = "Retract", w = 46 },
    { id = "retracting",       label = "SpkUp",   w = 40 },
    { id = "raising",          label = "Raise",   w = 38 },
    { id = "idle",             label = "Idle",    w = 32 },
}

-- ---------------------------------------------------------------------------
-- MAPPING PANEL
-- ---------------------------------------------------------------------------
function TIV.PAC3.BuildMappingPanel(parent)
    EnsureData()

    local T = Theme()
    local accent     = T.accent
    local accentDark = T.accentDark
    local textDim    = T.textDim
    local textCol    = T.text
    local panelBg    = T.panelBg
    local border     = T.border

    local pnl = vgui.Create("DScrollPanel", parent)

    local title = vgui.Create("DLabel", pnl)
    title:SetFont("DermaLarge")
    title:SetTextColor(textCol)
    title:SetText("PAC3 Event Mapping")
    title:Dock(TOP)
    title:DockMargin(0, 0, 0, 6)

    local intro = vgui.Create("DLabel", pnl)
    intro:SetFont("DermaDefault")
    intro:SetTextColor(textDim)
    intro:SetWrap(true)
    intro:SetAutoStretchVertical(true)
    intro:SetText(
        "Scans PAC3 outfits worn on your TIV vehicle and on the local player. " ..
        "The 3D preview shows the vehicle when seated. Click Test to see what an " ..
        "event does, then click a stage button to bind it. Red = bound, " ..
        "blue = one-shot stage, green = sustained (Anchor/Idle).")
    intro:Dock(TOP)
    intro:DockMargin(0, 0, 0, 10)

    -- -- Top row: preview + options ----------------------------------------
    local topRow = vgui.Create("DPanel", pnl)
    topRow:Dock(TOP)
    topRow:DockMargin(0, 0, 0, 10)
    topRow:SetTall(220)
    topRow.Paint = function(s, w, h)
        draw.RoundedBox(4, 0, 0, w, h, panelBg)
        surface.SetDrawColor(border)
        surface.DrawOutlinedRect(0, 0, w, h)
    end

    -- Track which entity we're previewing (vehicle if present, else player).
    local previewEnt = LocalPlayer()
    local previewLbl = vgui.Create("DLabel", topRow)
    previewLbl:SetPos(8, 8)
    previewLbl:SetFont("DermaDefaultBold")
    previewLbl:SetTextColor(accent)

    local preview = vgui.Create("DPanel", topRow)
    preview:SetPos(8, 28)
    preview:SetSize(260, 184)
    preview.Paint = function(s, w, h)
        draw.RoundedBox(2, 0, 0, w, h, Color(10, 12, 16, 255))
        local ent = GetLocalTIVVehicle() or LocalPlayer()
        previewEnt = ent
        if IsValid(ent) and pac and pac.DrawEntity2D then
            local ang = Angle(8, RealTime() * 18, 0)
            local bcenter = ent:OBBCenter()
            local bradius = ent:BoundingRadius()
            local pos = ent:LocalToWorld(bcenter) - ang:Forward() * (bradius * 2.8) + Vector(0, 0, bradius * 0.15)
            pac.DrawEntity2D(ent, 0, 0, w, h, pos, ang, 50)
        else
            draw.SimpleText("(no preview)", "DermaDefault", w/2, h/2, textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        end
    end
    function previewLbl:UpdateLabel()
        local ent = previewEnt
        if IsValid(ent) then
            local label = ent:IsPlayer() and "Local player" or ("Vehicle: " .. (ent:GetModel() or "?"))
            self:SetText("Preview: " .. label)
            self:SizeToContents()
        end
    end
    hook.Add("Think", previewLbl, function()
        if not previewLbl:IsValid() then return end
        previewLbl:UpdateLabel()
    end)

    -- Options panel to the right of preview.
    local optPanel = vgui.Create("DPanel", topRow)
    optPanel:SetPos(278, 8)
    optPanel:SetSize(topRow:GetWide() - 290, 204)
    optPanel.Paint = function() end
    function optPanel:PerformLayout()
        self:SetWide(self:GetParent():GetWide() - 290)
    end

    local refreshBtn = vgui.Create("DButton", optPanel)
    refreshBtn:Dock(TOP)
    refreshBtn:DockMargin(0, 0, 0, 6)
    refreshBtn:SetTall(26)
    refreshBtn:SetText("Refresh / Rescan Outfits")
    refreshBtn:SetTextColor(color_white)
    refreshBtn.Paint = function(s, w, h)
        draw.RoundedBox(3, 0, 0, w, h, s:IsHovered() and Color(accent.r+20, accent.g+20, accent.b+20) or accentDark)
    end

    local seqBox = vgui.Create("DCheckBoxLabel", optPanel)
    seqBox:Dock(TOP)
    seqBox:DockMargin(0, 4, 0, 4)
    seqBox:SetText("Enable sequence events (tiv_stage0..tiv_stage4)")
    seqBox:SetConVar("tiv_pac3_enable_sequence")
    seqBox:SetTextColor(textCol)

    local defBox = vgui.Create("DCheckBoxLabel", optPanel)
    defBox:Dock(TOP)
    defBox:DockMargin(0, 4, 0, 4)
    defBox:SetText("Also fire default tiv_* event names in addition to bindings")
    defBox:SetTextColor(textCol)
    defBox:SetChecked(not EnsureData().disableDefaults)
    defBox.OnChange = function(_, val)
        EnsureData().disableDefaults = not val
        TIV.PAC3.Save()
    end

    local resetBtn = vgui.Create("DButton", optPanel)
    resetBtn:Dock(BOTTOM)
    resetBtn:DockMargin(0, 8, 0, 0)
    resetBtn:SetTall(24)
    resetBtn:SetText("Reset All Events OFF")
    resetBtn:SetTextColor(Color(255, 210, 210))
    resetBtn.Paint = function(s, w, h)
        draw.RoundedBox(3, 0, 0, w, h, s:IsHovered() and Color(160, 50, 50) or Color(100, 35, 35))
    end
    resetBtn.DoClick = function()
        ClearAllTIVStates()
        surface.PlaySound("buttons/button19.wav")
    end

    -- -- Outfits list -----------------------------------------------------
    local outfitsHeader = vgui.Create("DPanel", pnl)
    outfitsHeader:Dock(TOP)
    outfitsHeader:DockMargin(0, 4, 0, 4)
    outfitsHeader:SetTall(22)
    outfitsHeader.Paint = function(s, w, h)
        draw.SimpleText("Outfits and Command Events (click Test, then click a stage to bind)", "DermaDefaultBold", 0, 4, accent)
    end

    local outfitsContainer = vgui.Create("DPanel", pnl)
    outfitsContainer:Dock(TOP)
    outfitsContainer:DockMargin(0, 0, 0, 8)
    outfitsContainer:SetTall(10)
    outfitsContainer.Paint = function() end

    local function BuildOutfitRows()
        outfitsContainer:Clear()
        local targets = GetScanTargets()
        local all = {}
        local totalParts = 0
        local ap = rawget(_G, "pac_all_parts") or {}
        for _ in pairs(ap) do totalParts = totalParts + 1 end

        local perTargetCounts = {}
        for _, ent in ipairs(targets) do
            local outfits = ScanOutfitsOnEntity(ent)
            perTargetCounts[ent] = #outfits
            for _, o in ipairs(outfits) do table.insert(all, o) end
        end

        -- Debug line to diagnose empty lists.
        local dbg = vgui.Create("DLabel", outfitsContainer)
        dbg:Dock(TOP)
        dbg:DockMargin(4, 0, 4, 4)
        dbg:SetFont("DermaDefault")
        dbg:SetTextColor(textDim)
        local veh = GetLocalTIVVehicle()
        local lines = {}
        table.insert(lines, string.format("PAC3 parts known to client: %d", totalParts))
        for _, ent in ipairs(targets) do
            local label = ent:IsPlayer() and "player" or "vehicle"
            local mdl = ent:GetModel() or "?"
            local short = mdl:match("([^/\\]+)%.mdl$") or mdl:sub(-28)
            table.insert(lines, string.format("  %s (%s): %d outfits, entidx=%d",
                label, short, perTargetCounts[ent] or 0, ent:EntIndex()))
        end
        dbg:SetText(table.concat(lines, "\n"))
        function dbg:PerformLayout() self:SizeToContents() end
        dbg:InvalidateLayout(true)

        if #all == 0 then
            local empty = vgui.Create("DLabel", outfitsContainer)
            empty:Dock(TOP)
            empty:DockMargin(8, 4, 8, 8)
            empty:SetTextColor(textDim)
            empty:SetWrap(true)
            empty:SetAutoStretchVertical(true)
            if not veh then
                empty:SetText("Get in your TIV first. If you're already in it, see the debug line above — most likely the outfit isn't owned by the vehicle entity. In PAC3 editor, set the root group's OwnerName to the vehicle's entindex, or AdvDupe-paste the outfit onto the vehicle.")
            elseif totalParts == 0 then
                empty:SetText("PAC3 isn't tracking any parts yet. Open the PAC3 editor once (type 'pac3' in console) to initialize it, then wear/paste an outfit and press Refresh.")
            else
                empty:SetText("No 'command' events owned by the vehicle or player found. Check the PAC3 editor: each event part must have Event type set to 'command' and the root group must be owned by the vehicle (not you).")
            end
            empty:SizeToContents()
            outfitsContainer:SetTall(80 + dbg:GetTall())
            return
        end

        local totalH = dbg:GetTall() + 4

        for _, outfit in ipairs(all) do
            local oRow = vgui.Create("DPanel", outfitsContainer)
            oRow:Dock(TOP)
            oRow:DockMargin(0, 0, 0, 2)
            oRow:SetTall(22)
            oRow.Paint = function() end
            totalH = totalH + 24

            local oLbl = vgui.Create("DLabel", oRow)
            oLbl:SetPos(0, 3)
            oLbl:SetFont("DermaDefaultBold")
            oLbl:SetTextColor(accent)
            oLbl:SetText(string.format("▸ [%s] %s   (%d events)",
                outfit.ownerLabel, outfit.name, table.Count(outfit.events)))
            oLbl:SizeToContents()

            local eventNames = {}
            for ename in pairs(outfit.events) do table.insert(eventNames, ename) end
            table.sort(eventNames)

            for _, ename in ipairs(eventNames) do
                local ev = outfit.events[ename]
                local eRow = vgui.Create("DPanel", outfitsContainer)
                eRow:Dock(TOP)
                eRow:DockMargin(14, 0, 0, 2)
                eRow:SetTall(28)
                eRow.Paint = function(s, w, h)
                    draw.RoundedBox(2, 0, 0, w, h, Color(35, 39, 47, 255))
                    surface.SetDrawColor(border)
                    surface.DrawOutlinedRect(0, 0, w, h)
                end
                totalH = totalH + 30

                local nameLbl = vgui.Create("DLabel", eRow)
                nameLbl:SetPos(8, 6)
                nameLbl:SetFont("DermaDefault")
                nameLbl:SetTextColor(textCol)
                nameLbl:SetText(ename)
                nameLbl:SizeToContents()

                local holdLbl = vgui.Create("DLabel", eRow)
                holdLbl:SetPos(200, 7)
                holdLbl:SetFont("DermaDefault")
                holdLbl:SetTextColor(textDim)
                holdLbl:SetText(string.format("hold: %.2fs", ev.time or 0))
                holdLbl:SizeToContents()

                local testBtn = vgui.Create("DButton", eRow)
                testBtn:SetPos(300, 3)
                testBtn:SetSize(44, 22)
                testBtn:SetText("Test")
                testBtn:SetTextColor(color_white)
                testBtn.Paint = function(s, w, h)
                    draw.RoundedBox(3, 0, 0, w, h, s:IsHovered() and Color(70, 130, 200) or Color(45, 85, 140))
                end
                testBtn.DoClick = function()
                    FireLocal(outfit.ent, ename, -1)
                    surface.PlaySound("buttons/button14.wav")
                end

                local bx = 352
                local boundStages = TIV.PAC3.EventStages(outfit.ent, outfit.name, ename)
                local boundLookup = {}
                for _, s in ipairs(boundStages) do boundLookup[s] = true end

                for _, sb in ipairs(STAGE_BTN_ORDER) do
                    local st = sb.id
                    local b = vgui.Create("DButton", eRow)
                    b:SetPos(bx, 3)
                    b:SetSize(sb.w, 22)
                    b:SetText(sb.label)
                    b:SetFont("DermaDefault")
                    bx = bx + sb.w + 3

                    local isBound = boundLookup[st]
                    local info = STAGE_LABELS[st]
                    b.Paint = function(s, w, h)
                        local col
                        if isBound then
                            col = s:IsHovered() and Color(200, 80, 80) or Color(140, 50, 50)
                        elseif info.oneshot then
                            col = s:IsHovered() and Color(70, 130, 200) or Color(40, 75, 120)
                        else
                            col = s:IsHovered() and Color(70, 180, 110) or Color(40, 110, 70)
                        end
                        draw.RoundedBox(3, 0, 0, w, h, col)
                    end
                    b.DoClick = function()
                        if isBound then
                            TIV.PAC3.Unbind(outfit.ent, outfit.name, ename, st)
                        else
                            TIV.PAC3.Bind(outfit.ent, outfit.name, ename, st)
                        end
                        BuildOutfitRows()
                        surface.PlaySound(isBound and "buttons/button19.wav" or "buttons/button14.wav")
                    end
                end
            end

            totalH = totalH + 4
        end

        outfitsContainer:SetTall(math.max(totalH, 40))
    end

    refreshBtn.DoClick = function()
        BuildOutfitRows()
        surface.PlaySound("buttons/button14.wav")
    end

    function pnl.RebuildOutfits() BuildOutfitRows() end

    BuildOutfitRows()
    timer.Simple(1.5, function() if IsValid(pnl) then BuildOutfitRows() end end)

    return pnl
end

TIV.PAC3.StageLabels = STAGE_LABELS

print("[TIV] PAC3 client mapping loaded")
