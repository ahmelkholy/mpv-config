-- autosubsync.lua
-- Automatically synchronize subtitles with audio
-- Based on https://github.com/smacke/ffsubsync

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    -- Path to ffsubsync executable
    -- Change this to match the actual path on your system
    ffsubsync_path = "",

    -- Maximum time to wait for sync to complete (in seconds)
    timeout = 300,

    -- Show OSD messages during sync
    osd_messages = true,

    -- Set to 'yes' to auto sync subtitles when loading a file
    auto_sync = "no",

    -- Set to 'yes' to overwrite the original subtitle file
    -- Otherwise, a new file will be created
    overwrite_original = "no"
}

options.read_options(o)

-- Determine default ffsubsync path based on platform
if o.ffsubsync_path == "" then
    if package.config:sub(1,1) == '\\' then  -- Windows
        -- Try to find ffsubsync in PATH
        local result = utils.subprocess({
            args = {'where', 'ffsubsync'},
            cancellable = false
        })

        if result.status == 0 then
            o.ffsubsync_path = string.gsub(result.stdout, "[\r\n]+$", "")
        else
            o.ffsubsync_path = "ffsubsync"  -- Hope it's in PATH
        end
    else  -- Unix/Linux/MacOS
        local result = utils.subprocess({
            args = {'which', 'ffsubsync'},
            cancellable = false
        })

        if result.status == 0 then
            o.ffsubsync_path = string.gsub(result.stdout, "[\r\n]+$", "")
        else
            o.ffsubsync_path = "ffsubsync"  -- Hope it's in PATH
        end
    end
end

-- Show OSD message if enabled
local function show_message(message)
    if o.osd_messages then
        mp.osd_message(message)
    end
    msg.info(message)
end

-- Function to synchronize subtitles
local function sync_subtitles()
    local video_path = mp.get_property("path")
    local sub_path = mp.get_property("sub-file")

    if not video_path or video_path == "" then
        show_message("No video file loaded")
        return
    end

    if not sub_path or sub_path == "" then
        show_message("No subtitle file loaded")
        return
    end

    -- Get directory and filename for output
    local sub_dir, sub_name = utils.split_path(sub_path)
    local sub_base, sub_ext = string.match(sub_name, "(.+)%.([^%.]+)$")
    local output_path

    if o.overwrite_original == "yes" then
        output_path = sub_path
    else
        output_path = utils.join_path(sub_dir, sub_base .. ".synced." .. sub_ext)
    end

    show_message("Synchronizing subtitles...")

    -- Prepare command-line arguments
    local args = {
        o.ffsubsync_path,
        video_path,
        "-i", sub_path,
        "-o", output_path
    }

    -- Execute ffsubsync
    local result = utils.subprocess({
        args = args,
        cancellable = true,
        max_size = 0,
        timeout = o.timeout
    })

    if result.status == 0 then
        if o.overwrite_original ~= "yes" then
            -- Load the synchronized subtitles
            mp.commandv("sub-add", output_path)
            mp.commandv("sub-reload")
        else
            mp.commandv("sub-reload")
        end

        show_message("Subtitle synchronization complete")
    else
        show_message("Subtitle synchronization failed")
        msg.error("Error: " .. (result.stderr or "unknown error"))
    end
end

-- Register key binding
mp.add_key_binding("Ctrl+y", "autosubsync", sync_subtitles)

-- Auto sync subtitles on file load if enabled
if o.auto_sync == "yes" then
    mp.register_event("file-loaded", function()
        -- Delay sync operation to ensure subtitles are properly loaded
        mp.add_timeout(5, sync_subtitles)
    end)
end
