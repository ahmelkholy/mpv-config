-- dictionary.lua
-- This script looks up currently displayed subtitle text in an online dictionary
-- Excellent for language learning

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = {
    -- Default source language
    source_lang = "ru", -- Change this to the language you're learning

    -- Default target language
    target_lang = "en", -- Your native language

    -- Dictionary service to use
    -- Options: "google", "reverso", "linguee"
    service = "google",

    -- Browser to open URLs in
    -- Leave empty to use system default
    browser = "",
}

options.read_options(o)

-- URL templates for dictionary services
local url_templates = {
    google = "https://translate.google.com/?sl=%s&tl=%s&text=%s&op=translate",
    reverso = "https://context.reverso.net/translation/%s-%s/%s",
    linguee = "https://www.linguee.com/%s-%s/search?source=auto&query=%s"
}

-- Function to URL encode a string
local function url_encode(str)
    if not str then return "" end
    str = string.gsub(str, "\n", " ")
    str = string.gsub(str, "([^%w %-%_%.%~])",
        function(c) return string.format("%%%02X", string.byte(c)) end)
    str = string.gsub(str, " ", "+")
    return str
end

-- Open URL in browser
local function open_url(url)
    msg.info("Opening URL: " .. url)

    local command = {}

    if o.browser and o.browser ~= "" then
        if package.config:sub(1,1) == '\\' then  -- Windows
            command = { 'cmd', '/c', 'start', o.browser, url }
        else  -- Unix/Linux/MacOS
            command = { o.browser, url }
        end
    else
        if package.config:sub(1,1) == '\\' then  -- Windows
            command = { 'cmd', '/c', 'start', '', url }
        elseif os.getenv('OSTYPE') and os.getenv('OSTYPE'):match('darwin') then  -- MacOS
            command = { 'open', url }
        else  -- Linux/Unix
            command = { 'xdg-open', url }
        end
    end

    local result = utils.subprocess({
        args = command,
        cancellable = false,
    })

    if result.status ~= 0 then
        msg.error("Failed to open URL: " .. (result.stderr or "unknown error"))
        mp.osd_message("Failed to open dictionary", 3)
    end
end

-- Function to look up current subtitle text in dictionary
local function lookup_in_dictionary()
    local sub_text = mp.get_property("sub-text")
    if not sub_text or sub_text == "" then
        mp.osd_message("No subtitle text to look up")
        return
    end

    -- Clean subtitle text from SSA/ASS tags
    sub_text = sub_text:gsub("{\\[^}]+}", "")

    -- Select dictionary URL template
    local url_template = url_templates[o.service] or url_templates.google

    -- Handle different dictionary service requirements
    local source_lang = o.source_lang
    local target_lang = o.target_lang

    if o.service == "reverso" then
        -- Reverso uses language pairs like "english-russian"
        source_lang = (source_lang == "en") and "english" or
                     (source_lang == "ru") and "russian" or
                     (source_lang == "fr") and "french" or
                     (source_lang == "de") and "german" or
                     (source_lang == "es") and "spanish" or
                     (source_lang == "ar") and "arabic" or source_lang

        target_lang = (target_lang == "en") and "english" or
                     (target_lang == "ru") and "russian" or
                     (target_lang == "fr") and "french" or
                     (target_lang == "de") and "german" or
                     (target_lang == "es") and "spanish" or
                     (target_lang == "ar") and "arabic" or target_lang
    end

    -- Construct dictionary URL
    local url = string.format(url_template, source_lang, target_lang, url_encode(sub_text))

    -- Show OSD message
    mp.osd_message(string.format("Looking up: %s", sub_text), 2)

    -- Open URL in browser
    open_url(url)
end

-- Register key binding
mp.add_key_binding("Alt+d", "dictionary", lookup_in_dictionary)
mp.register_script_message("lookup", lookup_in_dictionary)

-- Show a message when the script is loaded
mp.register_event("file-loaded", function()
    mp.msg.info("Dictionary script loaded")
end)