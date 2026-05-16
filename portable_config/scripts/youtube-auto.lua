local msg = require("mp.msg")
local utils = require("mp.utils")

local o = {
    max_height = 2160,
    fallback_height = 1080,
    audio_only_format = "ba/bestaudio/best",
    normal_readahead_secs = 8,
    normal_max_bytes = "128MiB",
    normal_max_back_bytes = "32MiB",
    audio_readahead_secs = 3,
    audio_max_bytes = "32MiB",
    audio_max_back_bytes = "4MiB",
    auto_update = true,
    update_interval_days = 7,
    cookies_from_browser = "",
    extractor_args = "",
}

require("mp.options").read_options(o, "youtube-auto")

local config_dir = mp.command_native({"expand-path", "~~/"})
local cache_dir = mp.command_native({"expand-path", "~~/cache"})
local ytdlp_path = mp.command_native({"expand-path", "~~/yt-dlp.exe"})
local last_check_path = utils.join_path(cache_dir, "youtube-auto.lastcheck")
local retried = {}
local current_url = nil
local update_running = false
local js_runtime = nil
local selected_height = nil
local next_load_height = nil
local internally_set_ytdl_format = nil

local function is_windows()
    return package.config:sub(1, 1) == "\\"
end

local function file_exists(path)
    local info = path and utils.file_info(path)
    return info and info.is_file
end

local function mkdir(path)
    if not path or utils.file_info(path) then
        return
    end

    local function quote_cmd_arg(value)
        return '"' .. tostring(value):gsub('"', '""') .. '"'
    end

    local args = is_windows()
        and {"cmd.exe", "/d", "/c", "mkdir " .. quote_cmd_arg(path)}
        or {"mkdir", "-p", path}
    local result = utils.subprocess({args = args, cancellable = false})
    if result.status ~= 0 then
        msg.warn("Could not create directory: " .. path)
    end
end

local function is_url(path)
    return type(path) == "string" and path:match("^https?://")
end

local function is_youtube_url(path)
    return is_url(path) and (
        path:match("://[^/]*youtube%.com/") or
        path:match("://[^/]*youtu%.be/") or
        path:match("://[^/]*googlevideo%.com/")
    )
end

local function format_for_height(height)
    height = tonumber(height) or o.max_height
    return ("bv*[height<=%d]+ba/b[height<=%d]/bv*+ba/b"):format(height, height)
end

local function normalize_height(height)
    height = tonumber(height)
    if not height or height < 1 then return nil end
    return math.floor(height)
end

local function height_from_format(format)
    if type(format) ~= "string" then return nil end

    local height = format:match("height%s*<=%??%s*(%d+)")
    return normalize_height(height)
end

local function adaptive_audio_only()
    return mp.get_property("user-data/adaptive-resources/audio-only", "no") == "yes"
end

local function adaptive_audio_format()
    local format = mp.get_property("user-data/adaptive-resources/audio-format", "")
    return format ~= "" and format or o.audio_only_format
end

local function write_last_check()
    local file = io.open(last_check_path, "w")
    if file then
        file:write(tostring(os.time()))
        file:close()
    end
end

local function should_check_update()
    if not o.auto_update then return false end

    local file = io.open(last_check_path, "r")
    if not file then return true end

    local value = tonumber(file:read("*a"))
    file:close()

    local interval = math.max(1, tonumber(o.update_interval_days) or 7) * 86400
    return not value or os.time() - value >= interval
end

local function subprocess(args, callback)
    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, callback)
end

local function find_ytdlp()
    if file_exists(ytdlp_path) then return ytdlp_path end

    local finder = is_windows() and {"where.exe", "yt-dlp"} or {"sh", "-c", "command -v yt-dlp"}
    local result = utils.subprocess({args = finder, cancellable = false})
    if result.status == 0 then
        local path = (result.stdout or ""):match("([^\r\n]+)")
        if file_exists(path) then return path end
    end

    return nil
end

local function find_executable(name)
    local args = is_windows()
        and {"cmd.exe", "/d", "/c", "where.exe " .. name .. " 2>nul"}
        or {"sh", "-c", "command -v " .. name .. " 2>/dev/null"}
    local result = utils.subprocess({args = args, cancellable = false})
    if result.status ~= 0 then return nil end

    local path = (result.stdout or ""):match("([^\r\n]+)")
    if file_exists(path) then return path:gsub("\\", "/") end
    return nil
end

local function find_js_runtime()
    if js_runtime ~= nil then return js_runtime or nil end

    for _, name in ipairs({"deno", "node", "bun", "qjs", "quickjs"}) do
        local path = find_executable(name)
        if path then
            js_runtime = ("%s:%s"):format(name, path)
            msg.info("Using JavaScript runtime for yt-dlp: " .. js_runtime)
            return js_runtime
        end
    end

    js_runtime = false
    msg.warn("No JavaScript runtime found for yt-dlp. YouTube may provide fewer formats.")
    return nil
end

local function update_ytdlp(show_osd)
    if update_running then return end

    local exe = find_ytdlp()
    if not exe then
        mp.osd_message("yt-dlp not found. Run mpv-update.bat.", 5)
        msg.error("yt-dlp was not found in " .. ytdlp_path .. " or PATH")
        return
    end

    update_running = true
    if show_osd then mp.osd_message("Checking yt-dlp update...", 2) end

    subprocess({exe, "-U"}, function(success, result, error)
        update_running = false
        write_last_check()

        if not success or (result and result.status ~= 0) then
            local detail = error or (result and result.stderr) or "unknown error"
            msg.error("yt-dlp update failed: " .. detail)
            if show_osd then mp.osd_message("yt-dlp update failed", 4) end
            return
        end

        local output = ((result.stdout or "") .. (result.stderr or "")):gsub("^%s+", ""):gsub("%s+$", "")
        if output ~= "" then msg.info(output) end

        if show_osd or output:match("Updated yt%-dlp") then
            mp.osd_message(output:match("Updated yt%-dlp[^\r\n]*") or "yt-dlp is up to date", 4)
        end
    end)
end

local function apply_network_defaults(height)
    height = normalize_height(height) or o.max_height
    local raw_options = mp.get_property_native("ytdl-raw-options") or {}
    local runtime = find_js_runtime()

    if runtime then
        raw_options["js-runtimes"] = runtime
    end

    if o.cookies_from_browser ~= "" then
        raw_options["cookies-from-browser"] = o.cookies_from_browser
    end

    if o.extractor_args ~= "" then
        raw_options["extractor-args"] = o.extractor_args
    end

    mp.set_property_native("ytdl-raw-options", raw_options)

    local audio_only = adaptive_audio_only()

    mp.set_property("ytdl", "yes")
    internally_set_ytdl_format = audio_only and adaptive_audio_format() or format_for_height(height)
    mp.set_property("ytdl-format", internally_set_ytdl_format)
    mp.set_property("cache", "yes")
    mp.set_property("cache-on-disk", "no")
    mp.set_property("demuxer-seekable-cache", "yes")
    mp.set_property_number(
        "demuxer-readahead-secs",
        audio_only and o.audio_readahead_secs or o.normal_readahead_secs
    )
    mp.set_property("demuxer-max-bytes", audio_only and o.audio_max_bytes or o.normal_max_bytes)
    mp.set_property("demuxer-max-back-bytes", audio_only and o.audio_max_back_bytes or o.normal_max_back_bytes)
    mp.set_property_number("network-timeout", 30)
end

local function repair_dirs()
    mkdir(cache_dir)
    mkdir(utils.join_path(cache_dir, "watch_later"))
    mkdir(utils.join_path(cache_dir, "shaders_cache"))
    mkdir(mp.command_native({"expand-path", "~~/subtitles"}))
end

local function reload_current_url()
    if not current_url then return false end

    local duration = mp.get_property_native("duration")
    local time_pos = mp.get_property("time-pos")

    mp.command("playlist-play-index current")

    if duration and duration > 0 and time_pos then
        local function seeker()
            mp.commandv("seek", time_pos, "absolute")
            mp.unregister_event(seeker)
        end
        mp.register_event("file-loaded", seeker)
    end

    return true
end

local function remember_quality(height, show_osd)
    height = normalize_height(height)
    if not height then
        if show_osd then mp.osd_message("Invalid YouTube quality", 3) end
        return false
    end

    selected_height = height
    apply_network_defaults(selected_height)

    if show_osd then
        mp.osd_message(("YouTube quality: %dp"):format(selected_height), 2)
    end

    return true
end

mp.observe_property("ytdl-format", "string", function(_, value)
    if not current_url or not value or value == internally_set_ytdl_format then
        return
    end

    local height = height_from_format(value)
    if height then
        selected_height = height
        msg.info(("Remembered manual YouTube quality: %dp"):format(height))
    end
end)

mp.add_hook("on_load", 5, function()
    local path = mp.get_property("stream-open-filename", mp.get_property("path", ""))
    local url = is_url(path) and path or nil
    local is_reloading_current_url = current_url and url == current_url
    current_url = url

    if current_url then
        local height = next_load_height or selected_height
        if not height and is_reloading_current_url then
            height = height_from_format(mp.get_property("ytdl-format", ""))
            selected_height = height or selected_height
        end
        next_load_height = nil

        apply_network_defaults(height or o.max_height)
        if is_youtube_url(current_url) and not find_ytdlp() then
            mp.osd_message("yt-dlp missing. Run mpv-update.bat.", 5)
        end
    end
end)

mp.register_event("file-loaded", function()
    repair_dirs()
    if should_check_update() then
        mp.add_timeout(5, function() update_ytdlp(false) end)
    end
end)

mp.register_event("end-file", function(event)
    if event.reason ~= "error" or not current_url or not is_youtube_url(current_url) then
        return
    end

    if not find_ytdlp() then
        mp.osd_message("YouTube failed: yt-dlp missing. Run mpv-update.bat.", 6)
        return
    end

    if not retried[current_url] then
        retried[current_url] = true
        next_load_height = normalize_height(o.fallback_height) or o.max_height
        apply_network_defaults(next_load_height)
        update_ytdlp(false)
        mp.osd_message(("YouTube failed. Retrying at %dp and checking yt-dlp..."):format(next_load_height), 5)
        mp.add_timeout(1, function() mp.commandv("loadfile", current_url, "replace") end)
    else
        mp.osd_message("YouTube still failed. Run mpv-update.bat, then reopen the URL.", 6)
    end
end)

mp.add_key_binding("F9", "update-ytdlp", function() update_ytdlp(true) end)
mp.register_script_message("update-ytdlp", function() update_ytdlp(true) end)
mp.register_script_message("remember-quality", function(height)
    remember_quality(height, false)
end)
mp.register_script_message("set-quality", function(height)
    if remember_quality(height, true) then
        reload_current_url()
    end
end)
