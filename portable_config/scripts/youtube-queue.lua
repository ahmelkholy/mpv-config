local msg = require("mp.msg")
local utils = require("mp.utils")

local o = {
    queue_file = "youtube-queue.m3u",
    restore_on_start = true,
    save_all_urls = false,
}

require("mp.options").read_options(o, "youtube-queue")

local cache_dir = mp.command_native({"expand-path", "~~/cache"})
local queue_path = utils.join_path(cache_dir, o.queue_file)
local save_timer = nil
local restoring = false
local last_written = nil
local completed = {}
local current_path = nil

local function is_windows()
    return package.config:sub(1, 1) == "\\"
end

local function trim(value)
    return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function is_url(value)
    return type(value) == "string" and value:match("^https?://")
end

local function is_youtube_url(value)
    return is_url(value) and (
        value:match("://[^/]*youtube%.com/") or
        value:match("://[^/]*youtu%.be/") or
        value:match("://[^/]*music%.youtube%.com/")
    )
end

local function should_persist(value)
    if o.save_all_urls then
        return is_url(value)
    end

    return is_youtube_url(value)
end

local function ensure_cache_dir()
    if not utils.file_info(cache_dir) then
        utils.mkdir(cache_dir)
    end
end

local function executable_exists(name)
    local args = is_windows()
        and {"cmd.exe", "/d", "/c", "where.exe " .. name .. " >nul 2>nul"}
        or {"sh", "-c", "command -v " .. name .. " >/dev/null 2>&1"}
    local result = utils.subprocess({args = args, cancellable = false})
    return result and result.status == 0
end

local function clipboard_command()
    if is_windows() then
        return {"powershell.exe", "-NoProfile", "-Command", "Get-Clipboard"}
    end

    if executable_exists("pbpaste") then
        return {"pbpaste"}
    end
    if executable_exists("wl-paste") then
        return {"wl-paste", "--no-newline"}
    end
    if executable_exists("xclip") then
        return {"xclip", "-selection", "clipboard", "-o"}
    end
    if executable_exists("xsel") then
        return {"xsel", "--clipboard", "--output"}
    end

    return nil
end

local function read_queue()
    local file = io.open(queue_path, "r")
    if not file then
        return {}
    end

    local entries = {}
    for line in file:lines() do
        local value = trim(line)
        if value ~= "" and not value:match("^#") and should_persist(value) then
            entries[#entries + 1] = value
        end
    end

    file:close()
    return entries
end

local function write_queue(entries)
    ensure_cache_dir()

    local serialized = table.concat(entries, "\n")
    if serialized == last_written then
        return
    end

    last_written = serialized

    if #entries == 0 then
        os.remove(queue_path)
        return
    end

    local temp_path = queue_path .. ".tmp"
    local file, err = io.open(temp_path, "w")
    if not file then
        msg.warn("Could not write YouTube queue: " .. tostring(err))
        return
    end

    file:write("#EXTM3U\n")
    for _, entry in ipairs(entries) do
        file:write(entry, "\n")
    end
    file:close()

    os.remove(queue_path)
    local ok, rename_err = os.rename(temp_path, queue_path)
    if not ok then
        msg.warn("Could not replace YouTube queue: " .. tostring(rename_err))
    end
end

local function current_playlist_start()
    local pos = mp.get_property_number("playlist-pos", -1)
    if not pos or pos < 0 then
        return 1
    end

    return pos + 1
end

local function get_remaining_queue()
    local playlist = mp.get_property_native("playlist") or {}
    local start_index = current_playlist_start()
    local entries = {}
    local seen = {}

    if #playlist == 0 then
        local path = mp.get_property("path", "")
        if should_persist(path) and not completed[path] then
            entries[#entries + 1] = path
        end
        return entries
    end

    for index = start_index, #playlist do
        local entry = playlist[index]
        local filename = entry and entry.filename
        if should_persist(filename) and not completed[filename] and not seen[filename] then
            entries[#entries + 1] = filename
            seen[filename] = true
        end
    end

    return entries
end

local save_queue

local function schedule_save()
    if restoring then
        return
    end

    if save_timer then
        save_timer:kill()
    end

    save_timer = mp.add_timeout(0.35, function()
        save_timer = nil
        save_queue()
    end)
end

save_queue = function()
    if restoring then
        return
    end

    write_queue(get_remaining_queue())
end

local function existing_playlist_set()
    local playlist = mp.get_property_native("playlist") or {}
    local existing = {}

    for _, entry in ipairs(playlist) do
        if entry and entry.filename then
            existing[entry.filename] = true
        end
    end

    return existing
end

local function restore_queue()
    if not o.restore_on_start then
        return
    end

    local saved = read_queue()
    if #saved == 0 then
        return
    end

    restoring = true
    local existing = existing_playlist_set()
    local restored = 0

    for _, url in ipairs(saved) do
        if not existing[url] then
            mp.commandv("loadfile", url, "append-play")
            existing[url] = true
            restored = restored + 1
        end
    end

    restoring = false

    if restored > 0 then
        msg.info(("Restored %d YouTube queue item(s)"):format(restored))
        mp.osd_message(("Restored %d queued YouTube video(s)"):format(restored), 3)
    end

    mp.add_timeout(1, save_queue)
end

local function extract_first_url(text)
    for candidate in tostring(text or ""):gmatch("https?://[^%s\"'<>]+") do
        candidate = candidate:gsub("[%)%],%.]+$", "")
        if should_persist(candidate) then
            return candidate
        end
    end

    return nil
end

local function queue_url(url, show_osd)
    if not should_persist(url) then
        if show_osd then
            mp.osd_message("Clipboard does not contain a YouTube URL", 3)
        end
        return
    end

    mp.commandv("loadfile", url, "append-play")
    schedule_save()

    if show_osd then
        mp.osd_message("Added YouTube URL to queue", 2)
    end
end

local function paste_url()
    local args = clipboard_command()
    if not args then
        mp.osd_message("No clipboard reader found", 3)
        return
    end

    mp.command_native_async({
        name = "subprocess",
        playback_only = false,
        capture_stdout = true,
        capture_stderr = true,
        args = args,
    }, function(success, result)
        if not success or not result or result.status ~= 0 then
            mp.osd_message("Could not read clipboard", 3)
            return
        end

        queue_url(extract_first_url(result.stdout), true)
    end)
end

local function clear_queue()
    completed = {}
    write_queue({})
    mp.osd_message("YouTube queue cleared", 2)
end

mp.register_event("end-file", function(event)
    if event.reason ~= "eof" then
        return
    end

    local path = current_path or mp.get_property("path", "")
    if should_persist(path) then
        completed[path] = true
        save_queue()
    end
end)

mp.add_hook("on_load", 1, function()
    current_path = mp.get_property(
        "stream-open-filename",
        mp.get_property("path", "")
    )
end)

mp.register_event("shutdown", save_queue)
mp.observe_property("playlist", "native", schedule_save)
mp.observe_property("playlist-pos", "number", schedule_save)

mp.add_key_binding("CTRL+v", "paste-youtube-url", paste_url)
mp.register_script_message("queue-url", function(url) queue_url(url, true) end)
mp.register_script_message("queue-save", save_queue)
mp.register_script_message("queue-clear", clear_queue)

mp.add_timeout(0.25, restore_queue)
