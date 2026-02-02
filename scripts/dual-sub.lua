-- dual-sub.lua
-- Toggle secondary subtitle using the next available track (any language)

local function toggle_secondary_sub()
    local sid = mp.get_property_number("sid")
    local secondary_sid = mp.get_property_number("secondary-sid")
    local tracks = mp.get_property_native("track-list")
    
    -- Gather all subtitle track IDs
    local sub_tracks = {}
    for _, track in ipairs(tracks) do
        if track.type == "sub" then
            table.insert(sub_tracks, track.id)
        end
    end

    if #sub_tracks < 2 then
        mp.osd_message("Not enough subtitle tracks for dual subtitles")
        return
    end

    -- If secondary sub is currently active, disable it
    if secondary_sid and secondary_sid ~= 0 then
        mp.set_property("secondary-sid", "no")
        mp.osd_message("Secondary subtitle disabled")
        return
    end

    -- Find a suitable track for secondary subtitle
    -- It should be different from the primary one
    local next_sid = nil
    
    if not sid or sid == 0 then
        -- If no primary sub, set first available as primary and second as secondary
        mp.set_property_number("sid", sub_tracks[1])
        next_sid = sub_tracks[2]
    else
        -- Find the next track ID that is not the current primary one
        for _, id in ipairs(sub_tracks) do
            if id ~= sid then
                next_sid = id
                break
            end
        end
    end

    if next_sid then
        mp.set_property_number("secondary-sid", next_sid)
        mp.set_property("secondary-sub-visibility", "yes")
        mp.osd_message("Dual Subtitles Enabled")
    else
        mp.osd_message("Could not find a secondary subtitle track")
    end
end

mp.register_script_message("toggle-dual-sub", toggle_secondary_sub)