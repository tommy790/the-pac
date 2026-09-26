-- ============================================================================
-- TIV PAC3 INTEGRATION - Shared
--
-- When the driver presses B the TIV runs a sequence of states:
--     idle -> lowering -> deploying_spikes -> anchored
--     anchored -> retracting -> raising -> idle
--
-- PAC3 "command" events listen for pac_event calls by name. This module maps
-- each TIV state transition to one or more named pac_event commands so that
-- outfits built with matching command events play their animations in the
-- correct order automatically.
--
-- Players can override the command names (or disable individual stages) from
-- the PAC3 Mapping menu (Utilities -> TIV -> PAC3 Mapping).
-- ============================================================================

TIV = TIV or {}
TIV.PAC3 = TIV.PAC3 or {}

-- Ordered stages that run during a deploy/retract cycle. These mirror the
-- strings broadcast by TIV.Deploy.BroadcastState plus two synthetic events
-- fired around the B press itself.
TIV.PAC3.STAGES = {
    "deploy_pressed",     -- B pressed to start deploying
    "lowering",           -- chassis lowering to the ground
    "deploying_spikes",   -- hydraulic spikes driving into ground
    "anchored",           -- fully anchored (on until retract)
    "retract_pressed",    -- B pressed to start retracting
    "retracting",         -- spikes pulling up
    "raising",            -- suspension raising back to ride height
    "idle",               -- back to idle (on when idle, off during sequence)
}

-- Default command-name mapping. Build new outfits against these names
-- (tiv_lowering, tiv_anchored, etc.) for guaranteed compatibility. For
-- existing dupes, use the PAC3 Mapping menu to override names per-stage.
--
-- Entries can be:
--   string  -> the pac_event command name to fire
--   table   -> list of command names to fire together
--   false/nil -> nothing fires for this stage
TIV.PAC3.DefaultMap = {
    deploy_pressed   = "tiv_deploy",
    lowering         = "tiv_lowering",
    deploying_spikes = "tiv_spikes_down",
    anchored         = "tiv_anchored",
    retract_pressed  = "tiv_retract",
    retracting       = "tiv_spikes_up",
    raising          = "tiv_raising",
    idle             = "tiv_idle",
}

-- Hold time (seconds) for one-shot events. Sustained states (anchored, idle)
-- use on/off (1/0) instead of a hold time and so have no duration here.
TIV.PAC3.HoldTimes = {
    deploy_pressed   = 0.5,
    lowering         = 4.0,   -- covers LowerTime + settle
    deploying_spikes = 4.0,   -- covers spike drive duration
    retract_pressed  = 0.5,
    retracting       = 4.0,
    raising          = 4.0,
}

-- Sustained (toggle) stages. These are set ON when entering the stage and OFF
-- when leaving, rather than fired as a timed pulse.
TIV.PAC3.SustainedStages = {
    anchored = true,
    idle     = true,
}

-- Sequence base name for PAC3's pac_event_sequenced support. PAC3 builders who
-- set up a command sequence (tiv_stage1, tiv_stage2, ...) can use
-- pac_event_sequenced to auto-step through numbered events instead of wiring
-- each name individually.
TIV.PAC3.DefaultSequenceBase = "tiv_stage"

-- Numeric step for each stage in the deploy sequence (1..N for deploying,
-- N..1 for retracting). Steps fire alongside the named events so both styles
-- work in the same outfit.
TIV.PAC3.SequenceSteps = {
    idle             = 0,
    deploy_pressed   = 1,
    lowering         = 2,
    deploying_spikes = 3,
    anchored         = 4,
    retract_pressed  = 4,   -- stays on 4 briefly so stage4 doesn't cut out
    retracting       = 3,
    raising          = 2,
    -- returning to idle resets to 0
}

-- Client-side preference persistence key (file in DATA/tiv/).
TIV.PAC3.CONVAR_FLAGS = FCVAR_ARCHIVE
TIV.PAC3.CVAR_BASE    = "tiv_pac3_"

print("[TIV] PAC3 integration shared module loaded")
