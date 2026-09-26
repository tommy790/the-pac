-- ============================================================================
-- TIV PAC3 INTEGRATION - Server
--
-- Fires stage events for BOTH the vehicle entity AND every seated player,
-- because PAC3 outfits can be worn on the vehicle (most common) or on the
-- driver/passengers. Each net message names the target entity; clients set
-- pac_command_events on that entity so the matching outfit's command events
-- fire.
-- ============================================================================

util.AddNetworkString("TIV_PAC3_FireEvent")
util.AddNetworkString("TIV_PAC3_FireSequence")

TIV.PAC3 = TIV.PAC3 or {}

-- Per-vehicle sustained stage tracking. [entIdx] = true/false per stage.
TIV.PAC3.ActiveSustained = TIV.PAC3.ActiveSustained or {}

-- ---------------------------------------------------------------------------
-- Collect every entity that should receive PAC3 events for this vehicle:
-- the vehicle itself (outfits worn on it via "wear on vehicle/entity") plus
-- every player seated in or on it (driver + child-seat passengers).
-- ---------------------------------------------------------------------------
local function GetTargets(veh)
    local ents = {}
    local seen = {}
    if not IsValid(veh) then return ents end

    -- The vehicle is always a target.
    table.insert(ents, veh)
    seen[veh:EntIndex()] = true

    local function Add(ply)
        if IsValid(ply) and not seen[ply:EntIndex()] then
            seen[ply:EntIndex()] = true
            table.insert(ents, ply)
        end
    end

    if veh.GetDriver then
        local driver = veh:GetDriver()
        Add(driver)
    end

    for _, ply in ipairs(player.GetAll()) do
        local seat = ply:GetVehicle()
        if IsValid(seat) then
            local parent = nil
            local base = nil
            if seat.GetParent then parent = seat:GetParent() end
            if seat.GetBase   then base   = seat:GetBase() end
            if parent == veh or base == veh then
                Add(ply)
            end
        end
    end

    return ents
end

-- ---------------------------------------------------------------------------
-- Broadcast a stage event for a target entity to ALL clients.
-- stageName = TIV stage id ("lowering", "anchored", ...)
-- mode: 1 = sustained ON, 0 = sustained OFF, -1 = one-shot pulse
-- ---------------------------------------------------------------------------
function TIV.PAC3.SendStage(ent, stageName, mode)
    if not IsValid(ent) or not stageName or stageName == "" then return end
    net.Start("TIV_PAC3_FireEvent")
        net.WriteEntity(ent)
        net.WriteString(stageName)
        net.WriteInt(mode or -1, 8)
    net.Broadcast()
end

function TIV.PAC3.SendSequence(ent, baseName, number)
    if not IsValid(ent) or not baseName or baseName == "" then return end
    net.Start("TIV_PAC3_FireSequence")
        net.WriteEntity(ent)
        net.WriteString(baseName)
        net.WriteUInt(math.Clamp(tonumber(number) or 0, 0, 255), 8)
    net.Broadcast()
end

function TIV.PAC3.FireStage(veh, stageName, mode)
    if not IsValid(veh) or not stageName or stageName == "" then return end
    for _, t in ipairs(GetTargets(veh)) do
        TIV.PAC3.SendStage(t, stageName, mode or -1)
    end
end

function TIV.PAC3.FireSequence(veh, baseName, number)
    if not IsValid(veh) or not baseName or baseName == "" then return end
    for _, t in ipairs(GetTargets(veh)) do
        TIV.PAC3.SendSequence(t, baseName, number)
    end
end

-- Turn off all active sustained stages for all targets of a vehicle.
local function ClearSustained(veh, idx)
    local active = TIV.PAC3.ActiveSustained[idx]
    if not active then return end
    for _, t in ipairs(GetTargets(veh)) do
        for stg, _ in pairs(active) do
            TIV.PAC3.SendStage(t, stg, 0)
        end
    end
    TIV.PAC3.ActiveSustained[idx] = nil
end

-- ---------------------------------------------------------------------------
-- STATE CHANGE HOOK
-- ---------------------------------------------------------------------------
local previousState = {}

hook.Add("TIV_StateChanged", "TIV_PAC3_StateHandler", function(veh, newState)
    if not IsValid(veh) then return end
    local idx = veh:EntIndex()
    local oldState = previousState[idx] or "idle"
    previousState[idx] = newState

    local sust    = TIV.PAC3.SustainedStages
    local startingDeploy  = (oldState == "idle" and newState == "lowering")
    local startingRetract = (oldState == "anchored" and newState == "retracting")

    local seqBase = TIV.PAC3.DefaultSequenceBase
    local seqStep = TIV.PAC3.SequenceSteps[newState]

    local active = TIV.PAC3.ActiveSustained[idx] or {}

    -- Turn OFF sustained stages that no longer apply.
    if newState ~= "anchored" and active.anchored then
        TIV.PAC3.FireStage(veh, "anchored", 0); active.anchored = nil
    end
    if newState ~= "idle" and active.idle then
        TIV.PAC3.FireStage(veh, "idle", 0); active.idle = nil
    end

    -- Synthetic press events.
    if startingDeploy  then TIV.PAC3.FireStage(veh, "deploy_pressed", -1) end
    if startingRetract then TIV.PAC3.FireStage(veh, "retract_pressed", -1) end

    -- Sequence step.
    if seqBase and seqStep then TIV.PAC3.FireSequence(veh, seqBase, seqStep) end

    -- Current stage.
    if sust[newState] then
        TIV.PAC3.FireStage(veh, newState, 1)
        active[newState] = true
    else
        TIV.PAC3.FireStage(veh, newState, -1)
    end

    TIV.PAC3.ActiveSustained[idx] = active

    if newState == "idle" then
        timer.Simple(0.1, function()
            if not IsValid(veh) then return end
            if seqBase then TIV.PAC3.FireSequence(veh, seqBase, 0) end
            ClearSustained(veh, idx)
        end)
    end
end)

hook.Add("EntityRemoved", "TIV_PAC3_Cleanup", function(ent)
    local idx = ent:EntIndex()
    if TIV.PAC3.ActiveSustained[idx] then
        -- Best-effort: send off for anything still active on targets.
        for _, t in ipairs(GetTargets(ent)) do
            for stg, _ in pairs(TIV.PAC3.ActiveSustained[idx]) do
                TIV.PAC3.SendStage(t, stg, 0)
            end
        end
        TIV.PAC3.ActiveSustained[idx] = nil
    end
    if previousState[idx] then previousState[idx] = nil end
end)

hook.Add("InitPostEntity", "TIV_PAC3_Init", function()
    timer.Simple(2, function()
        if not TIV.Deploy or not TIV.Deploy.Vehicles then return end
        for idx, data in pairs(TIV.Deploy.Vehicles) do
            local veh = Entity(idx)
            if IsValid(veh) then previousState[idx] = data.state or "idle" end
        end
    end)
end)

print("[TIV] PAC3 server event integration loaded")
