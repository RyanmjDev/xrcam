-- Flips the XRCam media source to unbuffered rendering.
--
-- OBS normally holds each decoded frame until its timestamp comes due, with
-- smoothing on top -- correct for file playback, pure latency for a live
-- camera. Unbuffered mode renders the newest frame immediately instead.
-- Device sources (webcams) expose this as a "Buffering" checkbox; the Media
-- Source does not, but libobs supports it on any async source.
--
-- Install: OBS -> Tools -> Scripts -> "+" -> select this file.
-- The flag is re-applied every few seconds, so it survives the source being
-- recreated, renamed back, or the scene collection being reloaded.

local obs = obslua

local SOURCE_NAME = "XRCam"
-- Log on state *transitions* only, so the OBS log carries proof the flag
-- actually landed on a real source -- "script loaded" alone does not
-- distinguish success from a silent name mismatch.
local state = "unknown"  -- "applied" | "missing"

local function apply()
    local source = obs.obs_get_source_by_name(SOURCE_NAME)
    if source ~= nil then
        obs.obs_source_set_async_unbuffered(source, true)
        obs.obs_source_release(source)
        if state ~= "applied" then
            state = "applied"
            obs.script_log(obs.LOG_INFO,
                "unbuffered rendering APPLIED to '" .. SOURCE_NAME .. "'")
        end
    else
        if state ~= "missing" then
            state = "missing"
            obs.script_log(obs.LOG_WARNING,
                "source '" .. SOURCE_NAME .. "' NOT FOUND -- flag not applied")
        end
    end
end

function script_description()
    return "Renders the '" .. SOURCE_NAME .. "' media source unbuffered: " ..
           "the newest decoded frame is shown immediately instead of being " ..
           "held to match its timestamp."
end

function script_load(settings)
    apply()
    obs.timer_add(apply, 3000)
end

function script_unload()
    obs.timer_remove(apply)
end
