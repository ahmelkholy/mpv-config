-- sub2clip.lua
-- Copy subtitle text to clipboard for language learning
-- Inspired by https://github.com/kelciour/mpv-scripts/blob/master/sub2clip.lua

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local platform = nil

-- Determine platform
if mp.get_property_native('options/vo-mmcss-profile', '') ~= '' then
    platform = 'windows'
elseif os.getenv('OSTYPE') and os.getenv('OSTYPE'):match('darwin') then
    platform = 'macos'
elseif os.getenv('OSTYPE') and os.getenv('OSTYPE'):match('linux') then
    platform = 'linux'
end

-- Set clipboard command based on platform
local function get_clipboard_cmd()
    if platform == 'windows' then
        return { 'powershell', '-NoProfile', '-Command', [[& {
            Trap {
                Write-Error -ErrorRecord $_
                Exit 1
            }
            Add-Type -AssemblyName PresentationCore
            [System.Windows.Clipboard]::SetText($args[0])
        }]] }
    elseif platform == 'macos' then
        return { 'pbcopy' }
    else  -- Linux
        return { 'xclip', '-selection', 'clipboard', '-i' }
    end
end

local function copy_subtitle_to_clipboard()
    local sub_text = mp.get_property("sub-text")
    if not sub_text or sub_text == "" then
        mp.osd_message("No subtitle text to copy")
        return
    end

    -- Clean subtitle text from SSA/ASS tags
    sub_text = sub_text:gsub("{\\[^}]+}", "")

    -- Process clipboard command
    local cmd = get_clipboard_cmd()

    if platform == 'windows' then
        table.insert(cmd, sub_text)
        local res = utils.subprocess({ args = cmd, cancellable = false })
        if res.status == 0 then
            mp.osd_message("Subtitle copied to clipboard", 1)
        else
            mp.osd_message("Failed to copy subtitle to clipboard", 3)
            msg.error("Error copying subtitle: " .. (res.stderr or "unknown error"))
        end
    else
        local pipe = io.popen(table.concat(cmd, ' '), 'w')
        pipe:write(sub_text)
        pipe:close()
        mp.osd_message("Subtitle copied to clipboard", 1)
    end
end

-- Replay current subtitle timeframe (useful for language learning)
local function replay_subtitle()
    local sub_start = mp.get_property_number("sub-start")
    local sub_end = mp.get_property_number("sub-end")

    if sub_start and sub_end then
        mp.commandv("seek", sub_start, "absolute")
        mp.osd_message("Replaying subtitle", 1)
    else
        mp.osd_message("No subtitle timing information available", 3)
    end
end

-- Register keybindings
mp.register_script_message("copy-subtitle", copy_subtitle_to_clipboard)
mp.register_script_message("replay-subtitle", replay_subtitle)

-- Set key bindings (these are also defined in input.conf)
mp.add_key_binding("F10", "copy-subtitle", copy_subtitle_to_clipboard)
mp.add_key_binding("F11", "replay-subtitle", replay_subtitle)

mp.register_event("file-loaded", function()
    mp.msg.info("sub2clip.lua loaded")
end)
