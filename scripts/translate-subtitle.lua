-- translate-subtitle.lua
-- Translate current subtitle using Google Translate
-- Usage: press F12 or use the menu button to translate

local utils = require 'mp.utils'
local msg = require 'mp.msg'
local options = require 'mp.options'

-- User configuration
local o = {
    -- Target language for translation (two-letter code)
    target_lang = "en",  -- Change to your preferred language: en, ar, ru

    -- Source language (set to "auto" for automatic detection, or use language code)
    source_lang = "auto",

    -- Display mode: "osd" (on-screen display) or "terminal"
    display_mode = "osd",

    -- OSD display duration in seconds
    osd_duration = 5,

    -- URL template for translation
    url_template = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=%s&tl=%s&dt=t&q=%s",

    -- Maximum length of text to translate at once
    max_length = 200
}

options.read_options(o)

-- Function to URL encode a string
local function url_encode(str)
    if str == nil then
        return ""
    end
    str = string.gsub(str, "\n", " ")
    str = string.gsub(str, "([^%w %-%_%.%~])",
        function(c) return string.format("%%%02X", string.byte(c)) end)
    str = string.gsub(str, " ", "+")
    return str
end

-- Function to make a web request
local function make_request(url)
    local command = {}

    if package.config:sub(1,1) == '\\' then  -- Windows
        command = { 'powershell', '-Command', 'Invoke-WebRequest', '-UseBasicParsing', '-Uri', url, '| Select-Object -ExpandProperty Content' }
    else  -- Unix/Linux/MacOS
        command = { 'curl', '-s', '-L', url }
    end

    local result = utils.subprocess({ args = command, cancellable = false })

    if result.status == 0 then
        return result.stdout
    else
        msg.error("Failed to make web request: " .. (result.stderr or "unknown error"))
        return nil
    end
end

-- Simple JSON parser for translation response
local function extract_translation(json_str)
    local translation = ""

    -- Extract the translation from the response
    for match in string.gmatch(json_str, '%[%[%["(.-)",".-",".-"%]') do
        translation = translation .. match
    end

    return translation
end

-- Function to translate text
local function translate_text(text)
    if not text or text == "" then
        return ""
    end

    -- Clean the text from formatting tags
    text = text:gsub("{\\[^}]+}", "")

    -- Limit text length to avoid URL length issues
    if #text > o.max_length then
        text = string.sub(text, 1, o.max_length) .. "..."
    end

    local url = string.format(o.url_template, o.source_lang, o.target_lang, url_encode(text))
    local response = make_request(url)

    if response then
        return extract_translation(response)
    else
        return "Translation failed"
    end
end

-- Function to translate current subtitle
local function translate_subtitle()
    local sub_text = mp.get_property("sub-text")
    if not sub_text or sub_text == "" then
        mp.osd_message("No subtitle text to translate")
        return
    end

    -- Translate the subtitle
    local translation = translate_text(sub_text)

    -- Display the translation
    if o.display_mode == "osd" then
        mp.osd_message(string.format("Original: %s\nTranslation: %s", sub_text, translation), o.osd_duration)
    else
        msg.info("Original: " .. sub_text)
        msg.info("Translation: " .. translation)
    end
end

-- Register key binding
mp.register_script_message("translate-subtitle", translate_subtitle)
mp.add_key_binding("F12", "translate-subtitle", translate_subtitle)

mp.register_event("file-loaded", function()
    mp.msg.info("translate-subtitle.lua loaded")
end)
