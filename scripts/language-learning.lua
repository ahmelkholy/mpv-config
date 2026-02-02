-- language-learning.lua
-- Enhanced language learning features for MPV
-- Combines AB-looping with spaced repetition concepts

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

-- Configuration options
local opts = {
    -- Number of times to repeat the current subtitle in AB loop mode
    repeat_count = 3,

    -- Seconds to add before subtitle start time
    padding_start = 0.25,

    -- Seconds to add after subtitle end time
    padding_end = 0.25,

    -- Slow down factor when in repeat mode (1.0 = normal speed)
    slow_factor = 0.8,

    -- Whether to automatically enable subtitles when using language learning features
    auto_enable_subs = true,

    -- Whether to pause after each repetition
    pause_after_repeat = false
}

options.read_options(opts)

-- Script state
local state = {
    repeating = false,
    repeat_counter = 0,
    original_speed = 1.0,
    subtitle_text = ""
}

-- Enable AB loop for current subtitle with padding
local function ab_loop_current_subtitle()
    local sub_start = mp.get_property_number("sub-start")
    local sub_end = mp.get_property_number("sub-end")

    if not sub_start or not sub_end then
        mp.osd_message("No subtitle timing information available")
        return
    end

    -- Store current subtitle text
    state.subtitle_text = mp.get_property("sub-text", "")

    -- Add padding to loop points
    local loop_start = math.max(0, sub_start - opts.padding_start)
    local loop_end = sub_end + opts.padding_end

    -- Set A-B loop points
    mp.set_property_number("ab-loop-a", loop_start)
    mp.set_property_number("ab-loop-b", loop_end)

    -- Remember original speed and slow down if configured
    state.original_speed = mp.get_property_number("speed", 1.0)
    if opts.slow_factor ~= 1.0 then
        mp.set_property_number("speed", state.original_speed * opts.slow_factor)
    end

    -- Make sure we're at the start of the loop
    mp.commandv("seek", loop_start, "absolute", "exact")

    -- Enable repeating
    state.repeating = true
    state.repeat_counter = 0

    -- Make sure subtitles are visible if configured
    if opts.auto_enable_subs then
        mp.set_property_bool("sub-visibility", true)
    end

    mp.osd_message(string.format("Repeating subtitle %d times", opts.repeat_count))
end

-- Stop the AB loop repetition
local function stop_ab_loop_repeat()
    if not state.repeating then return end

    -- Clear AB loop points
    mp.set_property_number("ab-loop-a", -1)
    mp.set_property_number("ab-loop-b", -1)

    -- Restore original speed
    mp.set_property_number("speed", state.original_speed)

    -- Reset state
    state.repeating = false
    state.repeat_counter = 0

    mp.osd_message("Stopped repeating")
end

-- Handle loop iteration
local function on_playback_position_change()
    if not state.repeating then return end

    local time_pos = mp.get_property_number("time-pos", 0)
    local loop_end = mp.get_property_number("ab-loop-b", -1)

    -- Check if we're close to the end of the loop
    if time_pos > 0 and loop_end > 0 and math.abs(time_pos - loop_end) < 0.1 then
        state.repeat_counter = state.repeat_counter + 1

        -- Check if we've reached the repeat count
        if state.repeat_counter >= opts.repeat_count then
            -- Stop repeating
            stop_ab_loop_repeat()

            -- Pause if configured
            if opts.pause_after_repeat then
                mp.set_property_bool("pause", true)
            end
        end
    end
end

-- Create a word flashcard from subtitle
local function create_flashcard()
    if state.subtitle_text == "" then
        state.subtitle_text = mp.get_property("sub-text", "")
    end

    if state.subtitle_text == "" then
        mp.osd_message("No subtitle text available for flashcard")
        return
    end

    -- Clean subtitle text from SSA/ASS tags
    local clean_text = state.subtitle_text:gsub("{\\[^}]+}", "")

    -- Get current media info
    local media_title = mp.get_property("media-title", "")
    local file_path = mp.get_property("path", "")
    local time_pos = mp.get_property_number("time-pos", 0)

    -- Format time as HH:MM:SS
    local function format_time(seconds)
        local hours = math.floor(seconds / 3600)
        local minutes = math.floor((seconds % 3600) / 60)
        local secs = math.floor(seconds % 60)
        return string.format("%02d:%02d:%02d", hours, minutes, secs)
    end

    -- Create flashcard file if it doesn't exist
    local flashcard_dir = utils.join_path(mp.find_config_file("."), "language_flashcards")
    utils.mkdir(flashcard_dir)

    local flashcard_file = utils.join_path(flashcard_dir, "flashcards.txt")

    -- Append to flashcard file
    local file = io.open(flashcard_file, "a")
    if file then
        file:write("---\n")
        file:write("Phrase: " .. clean_text .. "\n")
        file:write("Source: " .. media_title .. "\n")
        file:write("Time: " .. format_time(time_pos) .. "\n")
        file:write("File: " .. file_path .. "\n")
        file:write("Added: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
        file:write("---\n\n")
        file:close()

        mp.osd_message("Flashcard created", 2)
    else
        mp.osd_message("Failed to create flashcard", 3)
    end
end

-- Register key bindings
mp.add_key_binding("Ctrl+r", "repeat-subtitle", ab_loop_current_subtitle)
mp.add_key_binding("Ctrl+t", "stop-repeat", stop_ab_loop_repeat)
mp.add_key_binding("Ctrl+f", "create-flashcard", create_flashcard)

-- Register event handlers
mp.observe_property("time-pos", "number", on_playback_position_change)

mp.register_event("file-loaded", function()
    mp.msg.info("Language learning script loaded")

    -- Reset state when loading a new file
    state.repeating = false
    state.repeat_counter = 0
    state.original_speed = 1.0
    state.subtitle_text = ""
end)
