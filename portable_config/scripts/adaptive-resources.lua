local msg = require("mp.msg")
local options = require("mp.options")

local o = {
    auto_minimize = true,
    restore_on_unminimize = true,
    minimize_delay = 1.5,
    reload_network = true,
    audio_only_format = "ba/bestaudio/best",
    audio_readahead_secs = 3,
    audio_max_bytes = "32MiB",
    audio_max_back_bytes = "4MiB",
    video_readahead_secs = 8,
    video_max_bytes = "128MiB",
    video_max_back_bytes = "32MiB",
    start_audio_only = false,
    show_osd = true,
}

options.read_options(o, "adaptive-resources")

local audio_only_source = nil
local saved_vid = nil
local saved_ytdl_format = nil
local minimize_timer = nil

local function is_url(path)
    return type(path) == "string" and path:match("^https?://")
end

local function current_network_path()
    local path = mp.get_property("path", "")
    if is_url(path) then return path end
    return nil
end

local function osd(message)
    if o.show_osd then mp.osd_message(message, 2) end
end

local function set_adaptive_audio_flag(enabled)
    mp.set_property("user-data/adaptive-resources/audio-only", enabled and "yes" or "no")
    mp.set_property("user-data/adaptive-resources/audio-format", o.audio_only_format)
end

local function apply_audio_budget()
    mp.set_property_number("demuxer-readahead-secs", tonumber(o.audio_readahead_secs) or 3)
    mp.set_property("demuxer-max-bytes", o.audio_max_bytes)
    mp.set_property("demuxer-max-back-bytes", o.audio_max_back_bytes)
end

local function apply_video_budget()
    mp.set_property_number("demuxer-readahead-secs", tonumber(o.video_readahead_secs) or 8)
    mp.set_property("demuxer-max-bytes", o.video_max_bytes)
    mp.set_property("demuxer-max-back-bytes", o.video_max_back_bytes)
end

local function seek_after_reload(time_pos, was_paused)
    local function on_file_loaded()
        mp.unregister_event(on_file_loaded)
        mp.add_timeout(0.1, function()
            if time_pos then
                mp.commandv("seek", tostring(time_pos), "absolute", "exact")
            end
            if was_paused then
                mp.set_property_bool("pause", true)
            end
        end)
    end

    mp.register_event("file-loaded", on_file_loaded)
end

local function reload_current()
    if mp.get_property_bool("idle-active", false) then return false end

    local time_pos = mp.get_property_number("time-pos")
    local was_paused = mp.get_property_bool("pause", false)
    seek_after_reload(time_pos, was_paused)
    mp.command("playlist-play-index current")
    return true
end

local function enable_audio_only(source)
    if audio_only_source then return end

    audio_only_source = source or "manual"
    saved_vid = mp.get_property("vid", "auto")
    saved_ytdl_format = mp.get_property("ytdl-format", "")

    set_adaptive_audio_flag(true)
    apply_audio_budget()
    mp.set_property("vid", "no")
    mp.set_property("ytdl-format", o.audio_only_format)

    if o.reload_network and current_network_path() then
        reload_current()
    end

    msg.info("Adaptive audio-only mode enabled by " .. audio_only_source)
    osd("Audio-only resource mode")
end

local function restore_video(source)
    if not audio_only_source then return end
    if source == "auto" and audio_only_source ~= "auto" then return end

    local was_network = current_network_path() ~= nil
    audio_only_source = nil

    set_adaptive_audio_flag(false)
    apply_video_budget()
    mp.set_property("vid", (saved_vid and saved_vid ~= "no") and saved_vid or "auto")
    if saved_ytdl_format and saved_ytdl_format ~= "" then
        mp.set_property("ytdl-format", saved_ytdl_format)
    end

    if o.reload_network and was_network then
        reload_current()
    end

    msg.info("Adaptive video mode restored")
    osd("Video resource mode")
end

local function toggle_audio_only()
    if audio_only_source then
        restore_video("manual")
    else
        enable_audio_only("manual")
    end
end

local function handle_minimized(_, minimized)
    if not o.auto_minimize then return end

    if minimized then
        if minimize_timer then minimize_timer:kill() end
        minimize_timer = mp.add_timeout(tonumber(o.minimize_delay) or 1.5, function()
            minimize_timer = nil
            if mp.get_property_bool("window-minimized", false) then
                enable_audio_only("auto")
            end
        end)
        return
    end

    if minimize_timer then
        minimize_timer:kill()
        minimize_timer = nil
    end

    if o.restore_on_unminimize then
        restore_video("auto")
    end
end

mp.observe_property("window-minimized", "bool", handle_minimized)
mp.register_script_message("adaptive-audio-only-toggle", toggle_audio_only)
mp.register_script_message("adaptive-audio-only-on", function() enable_audio_only("manual") end)
mp.register_script_message("adaptive-audio-only-off", function() restore_video("manual") end)

mp.register_event("file-loaded", function()
    if audio_only_source then
        set_adaptive_audio_flag(true)
        apply_audio_budget()
        mp.set_property("vid", "no")
    else
        set_adaptive_audio_flag(false)
    end
end)

if o.start_audio_only then
    mp.add_timeout(0, function() enable_audio_only("manual") end)
end
