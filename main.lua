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

local MODES = { "filename", "alpha", "date" }

local MODE_LABELS = {
    filename = "[x] From filename  [ ] Alphabetical  [ ] Date modified",
    alpha    = "[ ] From filename  [x] Alphabetical  [ ] Date modified",
    date     = "[ ] From filename  [ ] Alphabetical  [x] Date modified",
}

-- ─────────────────────────────────────────────────────────────────────────────
-- PLUGIN
-- ─────────────────────────────────────────────────────────────────────────────

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
        sorting_hint   = "more_tools",
        sub_item_table = {
            {
                text     = "Extract Metadata From Filenames",
                callback = function() self:onExtract() end,
            },
            {
                text     = "Rename All Files in Folder",
                callback = function() self:showBatchRenameForm() end,
            },
        },
    }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PARSER / BUILDER
-- ─────────────────────────────────────────────────────────────────────────────

local function stripExtension(filename)
    return filename:match("^(.+)%.[^%.]+$") or filename
end

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

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
        local seriesName, seriesNum = lastField:match("^(.-)%s*#(%d+)%s*$")

        if seriesName then
            meta.series       = trim(seriesName)
            meta.series_index = tonumber(seriesNum)
            if count == 3 then
                meta.authors = fields[2]
            elseif count >= 4 then
                meta.authors  = fields[2]
                meta.keywords = fields[3]
            end
        else
            meta.authors = fields[2]
            if count >= 3 then meta.keywords = fields[3] end
            if count >= 4 then
                local s, n = fields[4]:match("^(.-)%s*#(%d+)%s*$")
                if s then
                    meta.series       = trim(s)
                    meta.series_index = tonumber(n)
                else
                    meta.series = trim(fields[4])
                end
            end
        end
    end

    return meta
end

local function buildFilename(meta, ext, includeNumber, seqNum)
    local parts = {}
    local title = trim(meta.title or "")
    if title == "" then return nil, nil end
    
    -- Título para o metadata (com #número sequencial se solicitado)
    local titleForMetadata = title
    if includeNumber and seqNum then
        titleForMetadata = titleForMetadata .. " #" .. seqNum
    end
    
    -- Título para o nome do arquivo
    local titleForFilename = titleForMetadata
    table.insert(parts, titleForFilename)

    local authors = trim(meta.authors or "")
    if authors ~= "" then table.insert(parts, authors) end

    local keywords = trim(meta.keywords or "")
    if keywords ~= "" then table.insert(parts, keywords) end

    local series = trim(meta.series or "")
    if series ~= "" then
        local idx = tonumber(meta.series_index)
        table.insert(parts, idx and (series .. " #" .. idx) or series)
    end

    return table.concat(parts, " - ") .. "." .. ext, titleForMetadata
end

-- ─────────────────────────────────────────────────────────────────────────────
-- NUMBERING
-- ─────────────────────────────────────────────────────────────────────────────

local function extractNumber(filename)
    local base = stripExtension(filename)
    return tonumber(base:match("(%d+)[^%d]*$"))
end

local function nextMode(mode)
    for i, m in ipairs(MODES) do
        if m == mode then return MODES[(i % #MODES) + 1] end
    end
    return MODES[1]
end

local function sortFiles(files, mode)
    local entries = {}
    for _, fp in ipairs(files) do
        local name = fp:match("[^/]+$") or fp
        local attr = lfs.attributes(fp)
        table.insert(entries, {
            path    = fp,
            name    = name,
            number  = extractNumber(name),
            modtime = attr and attr.modification or 0,
        })
    end

    if mode == "filename" then
        table.sort(entries, function(a, b)
            if a.number and b.number then return a.number < b.number end
            if a.number then return true end
            if b.number then return false end
            return a.name < b.name
        end)
    elseif mode == "date" then
        table.sort(entries, function(a, b)
            if a.modtime ~= b.modtime then return a.modtime < b.modtime end
            return a.name < b.name
        end)
    else
        table.sort(entries, function(a, b) return a.name < b.name end)
    end

    for i, e in ipairs(entries) do e.seq = i end
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
    local ok, err = os.rename(src, dst)
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

    local srcAttr = lfs.attributes(src, "size")
    local dstAttr = lfs.attributes(dst, "size")
    if not dstAttr or (srcAttr and dstAttr < srcAttr) then
        os.remove(dst)
        return false, "copy verification failed"
    end

    os.remove(src)
    return true
end

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

    local dialog
    dialog = MultiInputDialog:new{
        title  = "Rename for MetaFileExtract",
        fields = {
            { description = "Title",         text = meta.title    or "", hint = "Book title"         },
            { description = "Authors",       text = meta.authors  or "", hint = "Author 1, Author 2" },
            { description = "Keywords",      text = meta.keywords or "", hint = "Keyword1, Keyword2" },
            { description = "Series",        text = meta.series   or "", hint = "Series name"        },
            { description = "Series number",
              text        = meta.series_index and tostring(meta.series_index) or "",
              hint        = "e.g. 1", input_type = "number" },
        },
        buttons = {
            {
                { text = "Cancel", id = "close", callback = function() UIManager:close(dialog) end },
                {
                    text     = "Rename",
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)

                        local newMeta = {
                            title        = sanitize(fields[1] or ""),
                            authors      = sanitize(fields[2] or ""),
                            keywords     = sanitize(fields[3] or ""),
                            series       = sanitize(fields[4] or ""),
                            series_index = tonumber(fields[5]),
                        }

                        if newMeta.title == "" then
                            UIManager:show(InfoMessage:new{ text = "Title cannot be empty.", timeout = 3 })
                            return
                        end

                        local newFilename, titleForMeta = buildFilename(newMeta, ext, false, nil)
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
    values = values or {}
    mode   = mode   or "filename"
    includeNumber = includeNumber or false

    local numberingLabel = (includeNumber and "[x] Include #number  [ ] Don't include" or "[ ] Include #number  [x] Don't include")

    local dialog
    dialog = MultiInputDialog:new{
        title  = "Rename All Files in Folder",
        fields = {
            { description = "Title *",          text = values.title    or "", hint = "Required"                       },
            { description = "Authors *",        text = values.authors  or "", hint = "Required — Author 1, Author 2"  },
            { description = "Keywords",         text = values.keywords or "", hint = "Optional — Keyword1, Keyword2"  },
            { description = "Series *",         text = values.series   or "", hint = "Required"                       },
            { description = "Ordering",         text = MODE_LABELS[mode],     hint = "Tap [Ordering] to cycle modes"  },
            { description = "Number in Title",  text = numberingLabel,        hint = "Tap [Numbering] to toggle"      },
        },
        buttons = {
            {
                {
                    text     = "Cancel",
                    id       = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text     = "Ordering",
                    callback = function()
                        local f = dialog:getFields()
                        UIManager:close(dialog)
                        UIManager:scheduleIn(0.05, function()
                            MetaFileExtract:showBatchRenameForm(folder, {
                                title    = f[1],
                                authors  = f[2],
                                keywords = f[3],
                                series   = f[4],
                            }, nextMode(mode), includeNumber)
                        end)
                    end,
                },
            },
            {
                {
                    text     = "Numbering",
                    callback = function()
                        local f = dialog:getFields()
                        UIManager:close(dialog)
                        UIManager:scheduleIn(0.05, function()
                            MetaFileExtract:showBatchRenameForm(folder, {
                                title    = f[1],
                                authors  = f[2],
                                keywords = f[3],
                                series   = f[4],
                            }, mode, not includeNumber)
                        end)
                    end,
                },
            },
            {
                {
                    text     = "Preview",
                    callback = function()
                        local f = dialog:getFields()
                        local numberingText = f[6] or ""
                        local incNum = numberingText:match("%[x%] Include") ~= nil
                        local err = validateBatchFields(f)
                        if err then
                            UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
                            return
                        end
                        UIManager:close(dialog)
                        UIManager:scheduleIn(0.05, function()
                            MetaFileExtract:showBatchPreview(folder, {
                                title    = f[1],
                                authors  = f[2],
                                keywords = f[3],
                                series   = f[4],
                            }, mode, incNum)
                        end)
                    end,
                },
                {
                    text     = "Rename All",
                    callback = function()
                        local f = dialog:getFields()
                        local numberingText = f[6] or ""
                        local incNum = numberingText:match("%[x%] Include") ~= nil
                        local err = validateBatchFields(f)
                        if err then
                            UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
                            return
                        end
                        UIManager:close(dialog)
                        MetaFileExtract:executeBatchRename(folder, {
                            title    = f[1],
                            authors  = f[2],
                            keywords = f[3],
                            series   = f[4],
                        }, mode, incNum)
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
        title    = sanitize(fields.title or ""),
        authors  = sanitize(fields.authors or ""),
        keywords = sanitize(fields.keywords or ""),
        series   = sanitize(fields.series or ""),
    }

    local pairs_list = {}
    for _, e in ipairs(entries) do
        local ext    = e.name:match("%.([^%.]+)$") or ""
        local newMeta = {
            title        = baseMeta.title,
            authors      = baseMeta.authors,
            keywords     = baseMeta.keywords,
            series       = baseMeta.series,
            series_index = e.seq,
        }
        local newName, _ = buildFilename(newMeta, ext, includeNumber, e.seq)
        table.insert(pairs_list, {
            old = e.name,
            new = newName or e.name,
        })
    end

    local modeLabel = ({ filename="From filename", alpha="Alphabetical", date="Date modified" })[mode]
    local numLabel = includeNumber and " (with #number)" or " (no #number)"

    local PAGE_SIZE = 10
    local page = 1
    local total_pages = math.ceil(#pairs_list / PAGE_SIZE)

    Trapper:wrap(function()
        while true do
            local lines = {}
            table.insert(lines, modeLabel .. numLabel .. " | " .. #entries .. " files")
            table.insert(lines, "Page " .. page .. "/" .. total_pages)
            table.insert(lines, "")

            local from = (page - 1) * PAGE_SIZE + 1
            local to   = math.min(page * PAGE_SIZE, #pairs_list)
            for i = from, to do
                local p = pairs_list[i]
                table.insert(lines, p.old)
                table.insert(lines, "  → " .. p.new)
                if i < to then table.insert(lines, "") end
            end

            local has_next = page < total_pages
            local btn_left  = page > 1 and "← Back" or "Cancel"
            local btn_right = has_next    and "Next →" or "Rename All"

            local go = Trapper:confirm(table.concat(lines, "\n"), btn_left, btn_right, 900, 1000)

            if go then
                if has_next then
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
                        MetaFileExtract:showBatchRenameForm(folder, {
                            title    = fields.title,
                            authors  = fields.authors,
                            keywords = fields.keywords,
                            series   = fields.series,
                        }, mode, includeNumber)
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
        title    = sanitize(fields.title or ""),
        authors  = sanitize(fields.authors or ""),
        keywords = sanitize(fields.keywords or ""),
        series   = sanitize(fields.series or ""),
    }

    local files   = MetaFileExtract:scanFolder(folder)
    local entries = sortFiles(files, mode)

    Trapper:wrap(function()
        local success  = 0
        local skipped  = 0

        for idx, e in ipairs(entries) do
            local ext      = e.name:match("%.([^%.]+)$") or ""
            local newMeta  = {
                title        = baseMeta.title,
                authors      = baseMeta.authors,
                keywords     = baseMeta.keywords,
                series       = baseMeta.series,
                series_index = e.seq,
            }
            local newFilename, titleForMeta = buildFilename(newMeta, ext, includeNumber, e.seq)
            if not newFilename then skipped = skipped + 1 goto continue end

            local newFilepath = folder .. "/" .. newFilename

            local doNotAbort = Trapper:info(
                T("Renaming %1/%2\n\n%3\n\n→ %4", idx, #entries, e.name, newFilename), true)
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
-- BATCH EXTRACT
-- ─────────────────────────────────────────────────────────────────────────────

function MetaFileExtract:onExtract()
    if not FileManager.instance then return end
    local folder = FileManager.instance.file_chooser.path

    Trapper:wrap(function()
        local go = Trapper:confirm(
            "Extract and sync .meta metadata in:\n" .. folder, "Cancel", "Continue")
        if not go then return end

        local files = MetaFileExtract:scanFolder(folder)
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
        UIManager:show(InfoMessage:new{
            text    = success .. "/" .. #files .. " metadata entries extracted.",
            timeout = 4,
        })
        if FileManager.instance then FileManager.instance.file_chooser:refreshPath() end
    end)
end

return MetaFileExtract
