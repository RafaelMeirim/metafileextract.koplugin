local DocSettings     = require("docsettings")
local Event           = require("ui/event")
local FileManager     = require("apps/filemanager/filemanager")
local InfoMessage     = require("ui/widget/infomessage")
local Trapper         = require("ui/trapper")
local UIManager       = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil         = require("ffi/util")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local T               = ffiUtil.template

local MetaFileExtract = WidgetContainer:extend{
    name        = "metafileextract",
    is_doc_only = false,
}

function MetaFileExtract:init()
    self.ui.menu:registerToMainMenu(self)
end

function MetaFileExtract:addToMainMenu(menu_items)
    menu_items.metafileextract = {
        text         = "Extract metadata from filenames",
        sorting_hint = "more_tools",
        callback     = function() self:onExtract() end,
    }
end

local function stripExtension(filename)
    return filename:match("^(.+)%.[^%.]+$") or filename
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function getMetadataFile(folder, meta, filename)
    local bookName = stripExtension(filename)
    local filesToTry = { folder .. "/" .. bookName .. ".meta" }
    
    if meta.title and meta.title ~= bookName then
        table.insert(filesToTry, folder .. "/" .. meta.title .. ".meta")
    end
    
    if meta.series then
        local safeSeries = meta.series:gsub("[\\/:*?\"<>|]", "_")
        table.insert(filesToTry, folder .. "/" .. safeSeries .. ".meta")
    end

    for _, path in ipairs(filesToTry) do
        local f = io.open(path, "r")
        if f then
            local content = f:read("*all")
            f:close()
            return trim(content)
        end
    end
    logger.info("MetaFileExtract: No .meta found for " .. bookName)
    return nil
end

local function parseFilename(filename)
    local base = stripExtension(filename)
    local meta = {}
    local fields = {}

    for field in (base .. " - "):gmatch("(.-)%s%-%s") do
        local f = trim(field)
        if f ~= "" then table.insert(fields, f) end
    end

    if #fields == 0 then
        meta.title = base
        return meta
    end

    meta.title = fields[1]
    local count = #fields

    if count >= 2 then
        local lastField = fields[count]
        local seriesName, seriesNum = lastField:match("^(.-)%s*#(%d+)%s*$")
        
        if seriesName then
            meta.series = trim(seriesName)
            meta.series_index = tonumber(seriesNum)
            if count == 3 then
                meta.authors = fields[2]
            elseif count == 4 then
                meta.authors = fields[2]
                meta.keywords = fields[3]
            end
        else
            meta.authors = fields[2]
            if count >= 3 then meta.keywords = fields[3] end
        end
    end
    return meta
end

local function writeMetadata(filepath, meta)
    local ok, err = pcall(function()
        local settings = DocSettings.openSettingsFile(filepath)
        if not settings then error("openSettingsFile returned nil") end

        local customProps = settings:readSetting("custom_props")
        if type(customProps) ~= "table" then customProps = {} end

        if meta.title       then customProps.title       = tostring(meta.title) end
        if meta.authors     then customProps.authors     = tostring(meta.authors) end
        if meta.keywords    then customProps.keywords    = tostring(meta.keywords) end
        if meta.series      then customProps.series      = tostring(meta.series) end
        if meta.series_index then customProps.series_index = tostring(meta.series_index) end
        if meta.description then customProps.description = tostring(meta.description) end

        local docProps = settings:readSetting("doc_props")
        if type(docProps) ~= "table" then settings:saveSetting("doc_props", {}) end

        settings:saveSetting("custom_props", customProps)
        settings:flushCustomMetadata(filepath)
    end)

    if not ok then
        logger.warn("MetaFileExtract: failed for " .. filepath .. ": " .. tostring(err))
        return false
    end
    return true
end

local SUPPORTED = {
    cbz=true, cbr=true, cbt=true, epub=true, pdf=true, 
    mobi=true, azw=true, azw3=true, fb2=true, djvu=true, zip=true,
}

local function scanFolder(folder)
    local files = {}
    for entry in lfs.dir(folder) do
        if entry ~= "." and entry ~= ".." then
            local full = folder .. "/" .. entry
            local attr = lfs.attributes(full)
            if attr and attr.mode == "file" then
                local ext = entry:match("%.([^%.]+)$")
                if ext and SUPPORTED[ext:lower()] then
                    table.insert(files, full)
                end
            end
        end
    end
    return files
end

function MetaFileExtract:onExtract()
    if not FileManager.instance then return end
    local folder = FileManager.instance.file_chooser.path

    Trapper:wrap(function()
        local go = Trapper:confirm("Extract and sync .meta metadata in:\n" .. folder, "Cancel", "Continue")
        if not go then return end

        local files = scanFolder(folder)
        if #files == 0 then
            UIManager:show(InfoMessage:new{ text = "No files found.", timeout = 4 })
            return
        end

        local success = 0
        for idx, filepath in ipairs(files) do
            local filename = filepath:match("[^/]+$") or filepath
            
            if idx % 5 == 0 or idx == 1 then
                local doNotAbort = Trapper:info(T("Processing... %1/%2", idx, #files), true)
                if not doNotAbort then Trapper:clear(); return end
            end

            local meta = parseFilename(filename)
            local desc = getMetadataFile(folder, meta, filename)
            if desc then meta.description = desc end

            if meta.title then
                local complete, ok = Trapper:dismissableRunInSubprocess(function()
                    return writeMetadata(filepath, meta)
                end)
                if complete and ok then
                    success = success + 1
                    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", filepath))
                end
            end
        end

        Trapper:clear()
        UIManager:show(InfoMessage:new{ text = success .. " files updated.", timeout = 4 })
        if FileManager.instance then FileManager.instance.file_chooser:refreshPath() end
    end)
end

return MetaFileExtract