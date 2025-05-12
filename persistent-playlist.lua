--[[
persistent-playlist.lua

This script automatically saves and loads playlists across mpv sessions:
- When the playlist changes, it saves the playlist to a file
- When mpv exits, it saves the playlist to a file
- When mpv starts, it loads the saved playlist and appends to the current playlist

Version: 1.0.0
Author: tsukasa
License: MIT
]]

local mp = require('mp')
local utils = require('mp.utils')
local msg = require('mp.msg')

-- Configuration
local options = {
    -- File path for storing the playlist
    -- Will be stored in the mpv config directory by default
    playlist_file = "~~/persistent_playlist.txt",
    
    -- Whether to save the playlist when it changes
    save_on_playlist_change = true,
    
    -- Whether to save the playlist when mpv exits
    save_on_exit = true,
    
    -- Whether to load the saved playlist when mpv starts
    load_on_start = true,
    
    -- Whether to append or replace the playlist when loading
    -- "append" will add the saved playlist entries to any existing playlist
    -- "replace" will discard any existing playlist and load only the saved entries
    load_mode = "append" 
}

-- Read options from script configuration
-- (allows user to change settings by editing script-opts/persistent_playlist.conf)
mp.options = require('mp.options')
mp.options.read_options(options, "persistent_playlist")

-- Fully expand the playlist file path
options.playlist_file = mp.command_native({"expand-path", options.playlist_file})

-- Flag to track if playlist has been loaded
local load_done = false

-- Flag to temporarily disable saving during loading operations
local suppress_save = false

-- Function to convert a relative path to absolute path if needed
function ensure_absolute_path(path)
    -- If path is already absolute or is a URL/protocol, return it as is
    if path:match("^%a+://") or path:match("^/") or path:match("^%a:\\") then
        return path
    end
    
    -- Get mpv's current working directory
    local cwd = mp.get_property("working-directory", "")
    if cwd == "" then
        -- Fallback if working-directory is not available
        cwd = utils.getcwd()
    end
    
    -- Combine current directory with the relative path
    local abs_path
    if package.config:sub(1,1) == '\\' then
        -- Windows
        abs_path = utils.join_path(cwd, path)
    else
        -- Unix-like systems
        abs_path = cwd .. "/" .. path
    end
    
    return abs_path
end

-- Function to save the current playlist to a file
function save_playlist()
    -- Don't save if saving is temporarily suppressed (during loading)
    if suppress_save then
        msg.debug("Save suppressed during loading operation")
        return
    end
    
    -- Get the current playlist
    local playlist = mp.get_property_native("playlist")
    if not playlist or #playlist == 0 then
        msg.info("Playlist is empty, nothing to save")
        return
    end
    
    -- If this is a shutdown and we haven't loaded the playlist yet, 
    -- don't overwrite the existing playlist file...
    if mp.get_script_name() == "shutdown" and not load_done then
        msg.info("Skipping playlist save on shutdown because playlist wasn't loaded")
        return
    end
      -- Check if at least one file in the playlist exists or is a URL.
    -- This prevents saving playlists with only non-existent files...
    local has_valid_entry = false
    for _, item in ipairs(playlist) do
        local path = item.filename
        if file_exists(path) then
            has_valid_entry = true
            break
        end
    end
    
    if not has_valid_entry then
        msg.info("Playlist contains only non-existent files, skipping save")
        return
    end
    
    msg.info("Saving playlist to " .. options.playlist_file)
    
    -- Open the file for writing
    local file, err = io.open(options.playlist_file, "w")
    if not file then
        msg.error("Failed to open playlist file for writing: " .. (err or "unknown error"))
        return
    end
    
    -- Write each playlist entry to the file
    for _, item in ipairs(playlist) do
        -- Convert to absolute path if it's a local file
        local path = item.filename
        if not path:match("^%a+://") then 
            path = ensure_absolute_path(path)
        end
        file:write(path .. "\n")
    end
    
    file:close()
    msg.info("Playlist saved with " .. #playlist .. " entries")
end

-- Function to normalize paths for comparison
function normalize_path(path)
    -- Convert backslashes to forward slashes for consistent comparison
    path = path:gsub("\\", "/")

    -- Remove trailing slashes
    path = path:gsub("/*$", "")
    return path:lower()  -- Case-insensitive comparison
end

-- Function to check if a file exists on disk
function file_exists(path)
    -- If it's a URL or protocol, always return true
    if path:match("^%a+://") then
        return true
    end
    
    -- Convert to absolute path if needed
    local file_path = ensure_absolute_path(path)
    
    -- Check if the file exists on disk
    local file_info = utils.file_info(file_path)
    
    -- Return true if file exists, false otherwise
    return file_info ~= nil
end

-- Function to check if a file exists in the current playlist
function file_exists_in_playlist(filename)
    local normalized_filename = normalize_path(filename)
    local playlist = mp.get_property_native("playlist")
    
    for _, item in ipairs(playlist) do
        local item_path = item.filename
        if not item_path:match("^%a+://") then
            item_path = ensure_absolute_path(item_path)
        end
        
        if normalize_path(item_path) == normalized_filename then
            return true
        end
    end
    return false
end

-- Function to load the playlist from a file
function load_playlist()
    msg.info("Loading playlist from " .. options.playlist_file)
      -- Check if the file exists
    if not file_exists(options.playlist_file) then
        msg.info("Playlist file does not exist, skipping load")
        return
    end
    
    -- Open the file for reading
    local file, err = io.open(options.playlist_file, "r")
    if not file then
        msg.error("Failed to open playlist file for reading: " .. (err or "unknown error"))
        return
    end
    
    -- Temporarily suppress saving during loading
    suppress_save = true
    
    -- Get the current state before we start adding files
    local initial_count = mp.get_property_native("playlist-count") or 0
    local first_added = true
    
    -- Read each line and add it to the playlist
    local count = 0
    for line in file:lines() do
        if line and line ~= "" then
            -- Skip duplicates to prevent the same item from being added multiple times
            if not file_exists_in_playlist(line) then
                -- Append or replace based on options
                local mode = "append"
                if options.load_mode == "replace" and first_added then
                    mode = "replace"
                    first_added = false
                end
                
                -- Workaround for when mpv gets passed an invalid file
                -- Otherwise the player closes?
                if file_exists(line) then
                    mp.commandv("loadfile", line, mode)
                    count = count + 1
                else
                    msg.warn("File does not exist: " .. line)
                end
            else
                msg.debug("Skipping duplicate playlist item: " .. line)
            end
        end
    end
    
    file:close()
    
    -- Re-enable saving after a short delay to allow all playlist operations to complete
    mp.add_timeout(1, function()
        suppress_save = false
    end)
    
    msg.info("Loaded " .. count .. " entries from saved playlist")
end

-- Register event to save playlist when it changes
if options.save_on_playlist_change then
    mp.observe_property("playlist", "native", function(_, playlist)
        -- Skip if playlist is empty or unchanged
        if not playlist or #playlist == 0 then
            return
        end
        
        -- Small delay to avoid excessive writes when multiple changes happen quickly
        mp.add_timeout(1, save_playlist)
    end)
end

-- Register event to save playlist when mpv exits
if options.save_on_exit then
    mp.register_event("shutdown", save_playlist)
end

-- Load playlist only once when mpv starts
if options.load_on_start then
    -- Run once after a short delay to ensure mpv is fully initialized
    mp.add_timeout(0.5, function()
        if not load_done then
            load_playlist()
            load_done = true
        end
    end)
end

msg.info("Persistent playlist script loaded")
