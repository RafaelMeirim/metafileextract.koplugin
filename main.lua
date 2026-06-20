local DocSettings      = require("docsettings")
local Event            = require("ui/event")
local FileManager      = require("apps/filemanager/filemanager")
local InfoMessage      = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Trapper          = require("ui/trapper")
local UIManager        = require("ui/uimanager")
local WidgetContainer  = require("ui/widget/container/widgetcontainer")
local ffiUtil          = require("ffi/util")
local lfs              = require("libs/libkoreader-lfs")
local logger           = require("logger")
local T                = ffiUtil.template

-- ─────────────────────────────────────────────────────────────────────────────
-- CONSTANTS
-- ─────────────────────────────────────────────────────────────────────────────

local SUPPORTED = {
    cbz=true, cbr=true, cbt=true, epub=true, pdf=true,
    mobi=true, azw=true, azw3=true, fb2=true, djvu=true, zip=true,
}

local MODE_LABELS = {
    filename = "[x] From filename  [ ] Date modified",
    date     = "[ ] From filename  [x] Date modified",
}

-- ─────────────────────────────────────────────────────────────────────────────
-- NUMBER EXTRACTOR
-- ─────────────────────────────────────────────────────────────────────────────

local function stripExtension(filename)
    return filename:match("^(.+)%.[^%.]+$") or filename
end

local function trim(s)
    return s:match("^%s*(.-)%s*$") or ""
end

local function extractDecimalNumber(filename)
    local base = stripExtension(filename)

    -- Strip Mihon-style trailing hash: 6-8 hex chars preceded by _ - or space.
    -- e.g. "ArinVale_Capítulo 72_024a46" → "ArinVale_Capítulo 72"
    --      "#0.2 - O Retorno)a1a7f7"    → "#0.2 - O Retorno)"
    -- Lua has no {n,m} quantifier: match 6 fixed + up to 2 optional hex chars.
    local h = "[0-9a-fA-F]"
    local search = base:match("^(.+)[_%- ]" .. h..h..h..h..h..h .. h.."?".. h.."?$") or base

    -- KOReader runs LuaJIT which treats strings as raw bytes, so UTF-8 multi-byte
    -- chars like í (0xC3 0xAD) don't match inside [...] char classes.
    -- Use the literal UTF-8 byte sequence "\xC3\xAD" instead of 'í' in patterns.
    local i_utf8 = "\xC3\xAD"
    local patterns = {
        "[Cc]ap" .. i_utf8 .. "tulo%s+(%d+[.,]%d+)",
        "[Cc]ap" .. i_utf8 .. "tulo%s+(%d+)",
        "[Cc]apitulo%s+(%d+[.,]%d+)",
        "[Cc]apitulo%s+(%d+)",
        "[Cc]hapter%s+(%d+[.,]%d+)",
        "[Cc]hapter%s+(%d+)",
        "#(%d+[.,]%d+)",
        "#(%d+)",
        "(%d+[.,]%d+)[^%d]*$",
        "(%d+[.,]%d+)",
        "(%d+)[^%d]*$",
        "(%d+)"
    }

    for _, pattern in ipairs(patterns) do
        local match = search:match(pattern)
        if match then
            local normalized = match:gsub(",", ".")
            local num = tonumber(normalized)
            if num and num < 10000 then
                return {
                    full       = num,
                    integer    = math.floor(num),
                    original   = match,
                    normalized = normalized,
                }
            end
        end
    end

    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- METADATA EXTRACTION FOR AUTO-FILL
-- ─────────────────────────────────────────────────────────────────────────────

local function extractMetadataFromFilename(filename)
    local base = stripExtension(filename)
    local fields = {}
    
    for field in (base .. " - "):gmatch("(.-)%s%-%s") do
        local f = trim(field)
        if f ~= "" then table.insert(fields, f) end
    end
    
    if #fields >= 2 then
        local result = {
            title = fields[1],
            authors = fields[2],
            keywords = nil,
            series = nil,
            series_index = nil
        }
        
        local titleWithoutNumber = result.title:gsub("%s*#%d+[.,]?%d*%s*$", "")
        if titleWithoutNumber ~= result.title then
            result.title = titleWithoutNumber
        end
        
        if #fields >= 3 then
            local thirdField = fields[3]
            local seriesName, seriesNum = thirdField:match("^(.-)%s*#(%d+[.,]?%d*)%s*$")
            
            if seriesName then
                result.series = trim(seriesName)
                local normalized = seriesNum:gsub(",", ".")
                result.series_index = tonumber(normalized)
            else
                result.keywords = thirdField
                
                if #fields >= 4 then
                    local fourthField = fields[4]
                    local seriesName2, seriesNum2 = fourthField:match("^(.-)%s*#(%d+[.,]?%d*)%s*$")
                    if seriesName2 then
                        result.series = trim(seriesName2)
                        local normalized = seriesNum2:gsub(",", ".")
                        result.series_index = tonumber(normalized)
                    else
                        result.series = fourthField
                    end
                end
            end
        end
        
        return result
    end
    
    return nil
end

local function inferFolderMetadata(folder)
    local files = {}
    for entry in lfs.dir(folder) do
        if entry ~= "." and entry ~= ".." then
            local full = folder .. "/" .. entry
            local attr = lfs.attributes(full)
            if attr and attr.mode == "file" then
                local ext = entry:match("%.([^%.]+)$")
                if ext and SUPPORTED[ext:lower()] then
                    table.insert(files, entry)
                end
            end
        end
    end
    
    table.sort(files)
    
    for _, file in ipairs(files) do
        local meta = extractMetadataFromFilename(file)
        if meta and meta.title and meta.authors and meta.series then
            return meta
        end
    end
    
    for _, file in ipairs(files) do
        local meta = extractMetadataFromFilename(file)
        if meta and meta.title and meta.authors then
            return meta
        end
    end
    
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PARSER / BUILDER
-- ─────────────────────────────────────────────────────────────────────────────

local function sanitize(s)
    return trim(s):gsub('[\\/:*?"<>|]', "_")
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
        local seriesName, seriesNum = lastField:match("^(.-)%s*#(%d+[.,]?%d*)%s*$")

        if seriesName then
            meta.series = trim(seriesName)
            local normalized = seriesNum:gsub(",", ".")
            meta.series_index = tonumber(normalized)
            if count == 3 then
                meta.authors = fields[2]
            elseif count >= 4 then
                meta.authors = fields[2]
                meta.keywords = fields[3]
            end
        else
            meta.authors = fields[2]
            if count >= 3 then meta.keywords = fields[3] end
            if count >= 4 then
                local s, n = fields[4]:match("^(.-)%s*#(%d+[.,]?%d*)%s*$")
                if s then
                    meta.series = trim(s)
                    local normalized = n:gsub(",", ".")
                    meta.series_index = tonumber(normalized)
                else
                    meta.series = trim(fields[4])
                end
            end
        end
    end

    return meta
end

local function buildFilename(meta, ext, includeNumberInTitle, fileNumber)
    local title = trim(meta.title or "")
    if title == "" then return nil, nil end

    local titleForMeta = title
    local titleDisplay = title
    
    if includeNumberInTitle and fileNumber and fileNumber.full then
        local num = fileNumber.full + 0
        titleDisplay = title .. " #" .. num
        titleForMeta = title .. " #" .. num
    end

    local parts = { titleDisplay }

    local authors = trim(meta.authors or "")
    if authors ~= "" then table.insert(parts, authors) end

    local keywords = trim(meta.keywords or "")
    if keywords ~= "" then table.insert(parts, keywords) end

    local series = trim(meta.series or "")
    if series ~= "" then
        if meta.series_index then
            local num = meta.series_index + 0
            table.insert(parts, series .. " #" .. num)
        elseif fileNumber and fileNumber.full then
            local num = fileNumber.full + 0
            table.insert(parts, series .. " #" .. num)
        else
            table.insert(parts, series)
        end
    end

    return table.concat(parts, " - ") .. "." .. ext, titleForMeta
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SORTING
-- ─────────────────────────────────────────────────────────────────────────────

local function sortFiles(files, mode)
    local entries = {}
    for _, fp in ipairs(files) do
        local name = fp:match("[^/]+$") or fp
        local numInfo = nil
        
        xpcall(function()
            numInfo = extractDecimalNumber(name)
        end, function(err)
            logger.warn("extractDecimalNumber error: " .. tostring(err))
        end)
        
        local attr = lfs.attributes(fp)
        table.insert(entries, {
            path    = fp,
            name    = name,
            num_info = numInfo,
            sort_key = numInfo and numInfo.full or nil,
            modtime = attr and attr.modification or 0,
        })
    end

    if mode == "filename" then
        table.sort(entries, function(a, b)
            if a.sort_key and b.sort_key then
                return a.sort_key < b.sort_key
            end
            if a.sort_key then return true end
            if b.sort_key then return false end
            return a.name < b.name
        end)
    elseif mode == "date" then
        table.sort(entries, function(a, b)
            if a.modtime ~= b.modtime then return a.modtime < b.modtime end
            return a.name < b.name
        end)
    else
        table.sort(entries, function(a, b)
            if a.sort_key and b.sort_key then
                return a.sort_key < b.sort_key
            end
            if a.sort_key then return true end
            if b.sort_key then return false end
            return a.name < b.name
        end)
    end

    for i, e in ipairs(entries) do
        e.seq = i
        if not e.num_info then
            e.num_info = {
                full = i,
                integer = i,
                original = tostring(i),
                normalized = tostring(i)
            }
        end
    end

    return entries
end

-- ─────────────────────────────────────────────────────────────────────────────
-- METADATA WRITER
-- ─────────────────────────────────────────────────────────────────────────────

local function writeMetadata(filepath, meta)
    local ok, err = pcall(function()
        local settings = DocSettings.openSettingsFile(filepath)
        if not settings then error("openSettingsFile returned nil") end

        local customProps = settings:readSetting("custom_props")
        if type(customProps) ~= "table" then customProps = {} end

        if meta.title        then customProps.title        = tostring(meta.title)        end
        if meta.authors      then customProps.authors      = tostring(meta.authors)      end
        if meta.keywords     then customProps.keywords     = tostring(meta.keywords)     end
        if meta.series       then customProps.series       = tostring(meta.series)       end
        if meta.series_index then customProps.series_index = tostring(meta.series_index) end
        if meta.description  then customProps.description  = tostring(meta.description)  end

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

-- ─────────────────────────────────────────────────────────────────────────────
-- SAFE RENAME
-- ─────────────────────────────────────────────────────────────────────────────

local function safeRename(src, dst)
    local ok = os.rename(src, dst)
    if ok and lfs.attributes(dst, "mode") == "file" then
        return true
    end

    local fin, ferr = io.open(src, "rb")
    if not fin then
        return false, "cannot open source: " .. tostring(ferr)
    end

    local fout, oerr = io.open(dst, "wb")
    if not fout then
        fin:close()
        return false, "cannot open dest: " .. tostring(oerr)
    end

    local CHUNK = 64 * 1024
    while true do
        local data = fin:read(CHUNK)
        if not data then break end
        fout:write(data)
    end
    fin:close()
    fout:close()

    local srcSize = lfs.attributes(src, "size")
    local dstSize = lfs.attributes(dst, "size")
    if not dstSize or (srcSize and dstSize < srcSize) then
        os.remove(dst)
        return false, "copy verification failed"
    end

    os.remove(src)
    return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PLUGIN
-- ─────────────────────────────────────────────────────────────────────────────

local function isRealFolder(path)
    if type(path) ~= "string" or path == "" then return false end
    return lfs.attributes(path, "mode") == "directory"
end

local MetaFileExtract = WidgetContainer:extend{
    name        = "metafileextract",
    is_doc_only = false,
}

function MetaFileExtract:init()
    self.ui.menu:registerToMainMenu(self)

    FileManager.addFileDialogButtons(FileManager, "metafileextract_rename",
        function(file, is_file)
            if not is_file then return nil end
            local ext = file:lower():match("%.([^%.]+)$")
            if not ext or not SUPPORTED[ext:lower()] then return nil end
            return {
                {
                    text     = "Rename for MetaFileExtract",
                    callback = function()
                        local ctx_dialog = nil
                        local stack = UIManager._window_stack
                        if stack and #stack > 0 then
                            ctx_dialog = stack[#stack].widget
                        end
                        UIManager:scheduleIn(0.3, function()
                            if ctx_dialog then UIManager:close(ctx_dialog) end
                            MetaFileExtract:showRenameForm(file)
                        end)
                    end,
                },
            }
        end
    )
end

function MetaFileExtract:addToMainMenu(menu_items)
    menu_items.metafileextract = {
        text           = "MetaFile Extract",
        sorting_hint   = "tools",
        sub_item_table = {
            {
                text     = "Extract Metadata From Filenames",
                callback = function() self:showExtractPreview() end,
            },
            {
                text     = "Rename All Files in Folder",
                callback = function() self:showBatchRenameForm() end,
            },
        },
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- VALIDATION
-- ─────────────────────────────────────────────────────────────────────────────

local function validateBatchFields(fields)
    local missing = {}
    if sanitize(fields[1] or "") == "" then table.insert(missing, "Title")   end
    if sanitize(fields[2] or "") == "" then table.insert(missing, "Authors") end
    if sanitize(fields[4] or "") == "" then table.insert(missing, "Series")  end
    if #missing > 0 then
        return "Required: " .. table.concat(missing, ", ")
    end
    return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- SINGLE FILE RENAME
-- ─────────────────────────────────────────────────────────────────────────────

function MetaFileExtract:showRenameForm(filepath)
    local filename = filepath:match("[^/]+$") or filepath
    local folder   = filepath:match("^(.*)/[^/]+$") or ""
    local ext      = filename:match("%.([^%.]+)$") or ""
    local meta     = parseFilename(filename)
    local numInfo  = extractDecimalNumber(filename)

    local dialog
    dialog = MultiInputDialog:new{
        title  = "Rename for MetaFileExtract",
        fields = {
            { description = "Title",         text = meta.title    or "", hint = "Book title (can include #number if desired)" },
            { description = "Authors",       text = meta.authors  or "", hint = "Author 1, Author 2" },
            { description = "Keywords",      text = meta.keywords or "", hint = "Keyword1, Keyword2" },
            { description = "Series",        text = meta.series   or "", hint = "Series name" },
            { description = "Series number",
              text        = meta.series_index and tostring(meta.series_index) or (numInfo and tostring(numInfo.full) or ""),
              hint        = "For series sorting (e.g., 1 or 6.5)", input_type = "text" },
        },
        buttons = {
            {
                { text = "Cancel", id = "close", callback = function() UIManager:close(dialog) end },
                {
                    text     = "Rename",
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)

                        local seriesNumRaw = trim(fields[5] or "")
                        local seriesNum = nil
                        
                        if seriesNumRaw ~= "" then
                            local normalized = seriesNumRaw:gsub(",", ".")
                            local num = tonumber(normalized)
                            if num then
                                seriesNum = num
                            end
                        end

                        local newMeta = {
                            title        = sanitize(fields[1] or ""),
                            authors      = sanitize(fields[2] or ""),
                            keywords     = sanitize(fields[3] or ""),
                            series       = sanitize(fields[4] or ""),
                            series_index = seriesNum,
                        }

                        if newMeta.title == "" then
                            UIManager:show(InfoMessage:new{ text = "Title cannot be empty.", timeout = 3 })
                            return
                        end

                        local fileNumber = seriesNum and { full = seriesNum, integer = math.floor(seriesNum) } or nil
                        local newFilename, titleForMeta = buildFilename(newMeta, ext, false, fileNumber)
                        if not newFilename then
                            UIManager:show(InfoMessage:new{ text = "Failed to build filename.", timeout = 3 })
                            return
                        end
                        local newFilepath = folder .. "/" .. newFilename

                        if newFilepath == filepath then
                            UIManager:show(InfoMessage:new{ text = "Filename unchanged.", timeout = 3 })
                            return
                        end

                        if lfs.attributes(newFilepath, "mode") == "file" then
                            UIManager:show(InfoMessage:new{ text = "A file with this name already exists." })
                            return
                        end

                        local ok, renameErr = safeRename(filepath, newFilepath)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = "Rename failed: " .. tostring(renameErr) })
                            return
                        end

                        local oldSdr = DocSettings:getSidecarDir(filepath)
                        local newSdr = DocSettings:getSidecarDir(newFilepath)
                        if lfs.attributes(oldSdr, "mode") == "directory" then
                            os.rename(oldSdr, newSdr)
                        end

                        newMeta.title = titleForMeta
                        writeMetadata(newFilepath, newMeta)
                        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", newFilepath))
                        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))

                        UIManager:show(InfoMessage:new{
                            text = "Renamed to:\n" .. newFilename, timeout = 4
                        })

                        if FileManager.instance and FileManager.instance.file_chooser then
                            FileManager.instance.file_chooser:changeToPath(folder, newFilepath)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- BATCH RENAME FORM
-- ─────────────────────────────────────────────────────────────────────────────

function MetaFileExtract:showBatchRenameForm(folder, values, mode, includeNumber)
    if not folder then
        if not FileManager.instance then return end
        folder = FileManager.instance.file_chooser.path
    end

    if not isRealFolder(folder) then
        UIManager:show(InfoMessage:new{
            text    = "This is not a real folder.\nPlease navigate to a folder first.",
            timeout = 4,
        })
        return
    end
    
    if not values or not values.title then
        local inferred = inferFolderMetadata(folder)
        if inferred then
            values = {
                title = inferred.title or "",
                authors = inferred.authors or "",
                keywords = inferred.keywords or "",
                series = inferred.series or "",
            }
        else
            values = values or {}
        end
    end
    
    mode          = mode          or "filename"
    includeNumber = (includeNumber == nil) and true or includeNumber

    local numberLabel = includeNumber
        and "[x] Include #number  [ ] Don't include"
        or  "[ ] Include #number  [x] Don't include"

    local function getNextMode(current)
        if current == "filename" then return "date"
        else return "filename" end
    end

    local function getModeLabel(m)
        return MODE_LABELS[m] or MODE_LABELS.filename
    end

    local dialog
    dialog = MultiInputDialog:new{
        title  = "Rename All Files in Folder",
        fields = {
            { description = "Title *",         text = values.title    or "", hint = "Required"                      },
            { description = "Authors *",       text = values.authors  or "", hint = "Required — Author 1, Author 2" },
            { description = "Keywords",        text = values.keywords or "", hint = "Optional — Keyword1, Keyword2" },
            { description = "Series *",        text = values.series   or "", hint = "Required"                      },
            { description = "Ordering",        text = getModeLabel(mode), hint = "Tap [Ordering] to cycle"         },
            { description = "Number in Title", text = numberLabel,       hint = "Tap [Numbering] to toggle"         },
        },
        buttons = {
            {
                {
                    text     = "Cancel",
                    id       = "close",
                    callback = function() 
                        UIManager:close(dialog)
                    end,
                },
                {
                    text     = "Ordering",
                    callback = function()
                        local f = dialog:getFields()
                        local newMode = getNextMode(mode)
                        local newInclude = (f[6] or ""):match("%[x%] Include") ~= nil
                        UIManager:close(dialog)
                        UIManager:scheduleIn(0.1, function()
                            MetaFileExtract:showBatchRenameForm(folder, {
                                title=f[1], authors=f[2], keywords=f[3], series=f[4]
                            }, newMode, newInclude)
                        end)
                    end,
                },
            },
            {
                {
                    text     = "Numbering",
                    callback = function()
                        local f = dialog:getFields()
                        local newInclude = not ((f[6] or ""):match("%[x%] Include") ~= nil)
                        UIManager:close(dialog)
                        UIManager:scheduleIn(0.1, function()
                            MetaFileExtract:showBatchRenameForm(folder, {
                                title=f[1], authors=f[2], keywords=f[3], series=f[4]
                            }, mode, newInclude)
                        end)
                    end,
                },
            },
            {
                {
                    text     = "Preview",
                    callback = function()
                        local f = dialog:getFields()
                        local err = validateBatchFields(f)
                        if err then
                            UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
                            return
                        end
                        local incNum = (f[6] or ""):match("%[x%] Include") ~= nil
                        UIManager:close(dialog)
                        UIManager:scheduleIn(0.1, function()
                            MetaFileExtract:showBatchPreview(folder, {
                                title=f[1], authors=f[2], keywords=f[3], series=f[4]
                            }, mode, incNum)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ─────────────────────────────────────────────────────────────────────────────
-- BATCH PREVIEW
-- ─────────────────────────────────────────────────────────────────────────────

function MetaFileExtract:showBatchPreview(folder, fields, mode, includeNumber)
    local files = MetaFileExtract:scanFolder(folder)
    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = "No supported files found.", timeout = 3 })
        return
    end

    local entries = sortFiles(files, mode)
    local baseMeta = {
        title    = sanitize(fields.title    or ""),
        authors  = sanitize(fields.authors  or ""),
        keywords = sanitize(fields.keywords or ""),
        series   = sanitize(fields.series   or ""),
    }

    local pairs_list = {}
    for _, e in ipairs(entries) do
        local ext = e.name:match("%.([^%.]+)$") or ""
        local seriesIndex = e.num_info and e.num_info.full or e.seq
        if type(seriesIndex) == "string" then
            seriesIndex = tonumber(seriesIndex)
        end
        if seriesIndex then
            seriesIndex = seriesIndex + 0
        end
        local newMeta = {
            title        = baseMeta.title,
            authors      = baseMeta.authors,
            keywords     = baseMeta.keywords,
            series       = baseMeta.series,
            series_index = seriesIndex,
        }
        local newName = buildFilename(newMeta, ext, includeNumber, e.num_info) or e.name
        table.insert(pairs_list, { old = e.name, new = newName })
    end

    local modeLabel = ({ filename="From filename", date="Date modified" })[mode] or "From filename"
    local numLabel  = includeNumber and " · #number on" or " · #number off"
    local PAGE_SIZE = 8
    local total_pages = math.ceil(#pairs_list / PAGE_SIZE)
    local page = 1

    Trapper:wrap(function()
        while true do
            local lines = {}
            table.insert(lines, modeLabel .. numLabel .. "  [" .. #entries .. " files]")
            table.insert(lines, "Page " .. page .. "/" .. total_pages)
            table.insert(lines, "")

            local from = (page - 1) * PAGE_SIZE + 1
            local to   = math.min(page * PAGE_SIZE, #pairs_list)
            for i = from, to do
                local e = entries[i]
                local p = pairs_list[i]
                table.insert(lines, p.old)
                table.insert(lines, "  Title:  " .. baseMeta.title
                    .. (e and e.num_info and (" #" .. e.num_info.full) or ""))
                if baseMeta.authors ~= "" then
                    table.insert(lines, "  Author: " .. baseMeta.authors)
                end
                if baseMeta.keywords ~= "" then
                    table.insert(lines, "  Tags:   " .. baseMeta.keywords)
                end
                if baseMeta.series ~= "" then
                    local s = baseMeta.series
                    if e and e.num_info then s = s .. " #" .. e.num_info.full end
                    table.insert(lines, "  Series: " .. s)
                end
                if i < to then table.insert(lines, "") end
            end

            local btn_left  = page > 1           and "← Back" or "Cancel"
            local btn_right = page < total_pages  and "Next →" or "Rename All"

            local go = Trapper:confirm(table.concat(lines, "\n"), btn_left, btn_right)

            if go then
                if page < total_pages then
                    page = page + 1
                else
                    MetaFileExtract:executeBatchRename(folder, fields, mode, includeNumber)
                    return
                end
            else
                if page > 1 then
                    page = page - 1
                else
                    UIManager:scheduleIn(0.05, function()
                        MetaFileExtract:showBatchRenameForm(folder, fields, mode, includeNumber)
                    end)
                    return
                end
            end
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- BATCH EXECUTE
-- ─────────────────────────────────────────────────────────────────────────────

function MetaFileExtract:executeBatchRename(folder, fields, mode, includeNumber)
    local baseMeta = {
        title    = sanitize(fields.title    or ""),
        authors  = sanitize(fields.authors  or ""),
        keywords = sanitize(fields.keywords or ""),
        series   = sanitize(fields.series   or ""),
    }

    local files   = MetaFileExtract:scanFolder(folder)
    local entries = sortFiles(files, mode)

    Trapper:wrap(function()
        local success = 0
        local skipped = 0

        for idx, e in ipairs(entries) do
            local ext = e.name:match("%.([^%.]+)$") or ""
            local seriesIndex = e.num_info and e.num_info.full or e.seq
            if type(seriesIndex) == "string" then
                seriesIndex = tonumber(seriesIndex)
            end
            if seriesIndex then
                seriesIndex = seriesIndex + 0
            end
            local newMeta = {
                title        = baseMeta.title,
                authors      = baseMeta.authors,
                keywords     = baseMeta.keywords,
                series       = baseMeta.series,
                series_index = seriesIndex,
            }

            local newFilename, titleForMeta = buildFilename(newMeta, ext, includeNumber, e.num_info)
            if not newFilename then skipped = skipped + 1 goto continue end

            local newFilepath = folder .. "/" .. newFilename

            local doNotAbort = Trapper:info(
                T("Renaming %1/%2\n\n%3\n→ %4", idx, #entries, e.name, newFilename), true)
            if not doNotAbort then Trapper:clear(); return end

            if newFilepath == e.path then
                skipped = skipped + 1
            elseif lfs.attributes(newFilepath, "mode") == "file" then
                logger.warn("MetaFileExtract batch: target exists, skipping " .. e.name)
                skipped = skipped + 1
            else
                local ok = safeRename(e.path, newFilepath)
                if ok then
                    local oldSdr = DocSettings:getSidecarDir(e.path)
                    local newSdr = DocSettings:getSidecarDir(newFilepath)
                    if lfs.attributes(oldSdr, "mode") == "directory" then
                        os.rename(oldSdr, newSdr)
                    end
                    newMeta.title = titleForMeta
                    writeMetadata(newFilepath, newMeta)
                    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", newFilepath))
                    success = success + 1
                else
                    skipped = skipped + 1
                end
            end

            ::continue::
        end

        Trapper:clear()
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))

        local msg = success .. "/" .. #entries .. " files renamed."
        if skipped > 0 then msg = msg .. "\n" .. skipped .. " skipped." end
        UIManager:show(InfoMessage:new{ text = msg })

        if FileManager.instance and FileManager.instance.file_chooser then
            FileManager.instance.file_chooser:refreshPath()
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- FOLDER SCANNER
-- ─────────────────────────────────────────────────────────────────────────────

local function getMetadataFile(folder, meta, filename)
    local bookName   = stripExtension(filename)
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
    return nil
end

function MetaFileExtract:scanFolder(folder)
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

-- ─────────────────────────────────────────────────────────────────────────────
-- EXTRACT PREVIEW
-- ─────────────────────────────────────────────────────────────────────────────

function MetaFileExtract:showExtractPreview()
    if not FileManager.instance then return end
    local folder = FileManager.instance.file_chooser.path

    if not isRealFolder(folder) then
        UIManager:show(InfoMessage:new{
            text    = "This is not a real folder.\nPlease navigate to a folder first.",
            timeout = 4,
        })
        return
    end

    local files = MetaFileExtract:scanFolder(folder)
    if #files == 0 then
        UIManager:show(InfoMessage:new{ text = "No supported files found.", timeout = 3 })
        return
    end

    -- Parse all filenames upfront (no writes yet)
    local parsed_list = {}
    for _, filepath in ipairs(files) do
        local filename = filepath:match("[^/]+$") or filepath
        local meta     = parseFilename(filename)
        local numInfo  = extractDecimalNumber(filename)
        local desc     = getMetadataFile(folder, meta, filename)
        if desc    then meta.description  = desc      end
        if numInfo and not meta.series_index then
            meta.series_index = numInfo.full
        end
        table.insert(parsed_list, {
            filepath = filepath,
            filename = filename,
            meta     = meta,
            has_desc = desc ~= nil,
        })
    end

    local PAGE_SIZE   = 8
    local total_pages = math.max(1, math.ceil(#parsed_list / PAGE_SIZE))
    local page        = 1

    Trapper:wrap(function()
        while true do
            local lines = {}
            table.insert(lines, "Extract Metadata Preview  [" .. #parsed_list .. " files]")
            table.insert(lines, "Page " .. page .. "/" .. total_pages)
            table.insert(lines, "")

            local from = (page - 1) * PAGE_SIZE + 1
            local to   = math.min(page * PAGE_SIZE, #parsed_list)

            for i = from, to do
                local entry = parsed_list[i]
                local meta  = entry.meta

                table.insert(lines, entry.filename)
                table.insert(lines, "  Title:  " .. (meta.title or "?"))
                if meta.authors and meta.authors ~= "" then
                    table.insert(lines, "  Author: " .. meta.authors)
                end
                if meta.keywords and meta.keywords ~= "" then
                    table.insert(lines, "  Tags:   " .. meta.keywords)
                end
                if meta.series and meta.series ~= "" then
                    local s = meta.series
                    if meta.series_index then s = s .. " #" .. meta.series_index end
                    table.insert(lines, "  Series: " .. s)
                end

                if i < to then table.insert(lines, "") end
            end

            local btn_left  = page > 1          and "← Back" or "Cancel"
            local btn_right = page < total_pages and "Next →" or "Extract All"

            local go = Trapper:confirm(table.concat(lines, "\n"), btn_left, btn_right)

            if go then
                if page < total_pages then
                    page = page + 1
                else
                    MetaFileExtract:executeExtract(parsed_list)
                    return
                end
            else
                if page > 1 then
                    page = page - 1
                else
                    return  -- Cancel
                end
            end
        end
    end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- EXTRACT EXECUTE
-- ─────────────────────────────────────────────────────────────────────────────

function MetaFileExtract:executeExtract(parsed_list)
    Trapper:wrap(function()
        local success = 0
        local total   = #parsed_list

        for idx, entry in ipairs(parsed_list) do
            if idx % 5 == 0 or idx == 1 then
                local keep_going = Trapper:info(T("Processing... %1/%2", idx, total), true)
                if not keep_going then Trapper:clear(); return end
            end

            if entry.meta.title then
                local complete, ok = Trapper:dismissableRunInSubprocess(function()
                    return writeMetadata(entry.filepath, entry.meta)
                end)
                if complete and ok then
                    success = success + 1
                    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", entry.filepath))
                end
            end
        end

        Trapper:clear()
        UIManager:show(InfoMessage:new{
            text    = success .. "/" .. total .. " metadata entries extracted.",
            timeout = 4,
        })
        if FileManager.instance then
            FileManager.instance.file_chooser:refreshPath()
        end
    end)
end

return MetaFileExtract
