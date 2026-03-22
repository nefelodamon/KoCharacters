-- main.lua
-- KoCharacters Plugin for KOReader (Gemini AI, manual trigger)

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local TextViewer      = require("ui/widget/textviewer")
local ConfirmBox      = require("ui/widget/confirmbox")
local Menu            = require("ui/widget/menu")
local Screen          = require("device").screen
local logger          = require("logger")
local _               = require("gettext")

local Dispatcher   = require("dispatcher")
local GeminiClient = require("gemini_client")
local CharacterDB  = require("character_db")

local function portraitSafeName(name)
    return (name:gsub("[^%w%-]", "_"):lower())
end

-- ---------------------------------------------------------------------------
-- Duplicate detection helpers
-- ---------------------------------------------------------------------------
local function levenshtein(a, b)
    a, b = a:lower(), b:lower()
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prev = {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        local curr = { [0] = i }
        for j = 1, lb do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            curr[j] = math.min(curr[j-1] + 1, prev[j] + 1, prev[j-1] + cost)
        end
        prev = curr
    end
    return prev[lb]
end

-- Compare incoming (new) characters against an existing list; return conflict pairs.
-- Exact name matches are intentional updates handled by merge() — skip them here.
local function findIncomingConflicts(existing, incoming)
    local conflicts = {}
    for _, new_c in ipairs(incoming) do
        local new_low = (new_c.name or ""):lower()
        if #new_low >= 4 then
            for _, ex_c in ipairs(existing) do
                local ex_low = (ex_c.name or ""):lower()
                if #ex_low >= 4 and new_low ~= ex_low then
                    local dist      = levenshtein(new_low, ex_low)
                    local threshold = math.min(#new_low, #ex_low) <= 6 and 1 or 2
                    local substring = new_low:find(ex_low, 1, true) or ex_low:find(new_low, 1, true)
                    if dist <= threshold or substring then
                        table.insert(conflicts, { new_char = new_c, existing_char = ex_c })
                        break
                    end
                end
            end
        end
    end
    return conflicts
end

-- Collapse near-duplicate names within a single incoming batch before DB insertion.
-- Merges the second into the first (fills in missing fields), returns deduped list.
local function deduplicateIncoming(chars)
    if #chars < 2 then return chars end
    local removed = {}
    for i = 1, #chars do
        if not removed[i] then
            local a = chars[i]
            local a_low = (a.name or ""):lower()
            for j = i + 1, #chars do
                if not removed[j] then
                    local b = chars[j]
                    local b_low = (b.name or ""):lower()
                    if #a_low >= 4 and #b_low >= 4 then
                        local dist      = levenshtein(a_low, b_low)
                        local threshold = math.min(#a_low, #b_low) <= 6 and 1 or 2
                        local substring = a_low:find(b_low, 1, true) or b_low:find(a_low, 1, true)
                        if dist <= threshold or substring then
                            -- Merge b's non-empty fields into a
                            if (a.role == nil or a.role == "") and b.role and b.role ~= "" then a.role = b.role end
                            if (a.physical_description == nil or a.physical_description == "") and b.physical_description and b.physical_description ~= "" then a.physical_description = b.physical_description end
                            if (a.personality == nil or a.personality == "") and b.personality and b.personality ~= "" then a.personality = b.personality end
                            removed[j] = true
                        end
                    end
                end
            end
        end
    end
    local result = {}
    for i, c in ipairs(chars) do
        if not removed[i] then table.insert(result, c) end
    end
    return result
end

local function findDuplicatePairs(characters)
    local pairs_found = {}
    for i = 1, #characters do
        for j = i + 1, #characters do
            local a = characters[i].name or ""
            local b = characters[j].name or ""
            if #a >= 4 and #b >= 4 then
                local dist      = levenshtein(a, b)
                local threshold = math.min(#a, #b) <= 6 and 1 or 2
                local a_low     = a:lower()
                local b_low     = b:lower()
                local substring = a_low:find(b_low, 1, true) or b_low:find(a_low, 1, true)
                if dist <= threshold or (substring and a_low ~= b_low) then
                    table.insert(pairs_found, { a, b })
                end
            end
        end
    end
    return pairs_found
end

-- ---------------------------------------------------------------------------
-- Plugin definition
-- ---------------------------------------------------------------------------
local KoCharacters = WidgetContainer:extend{
    name        = "kocharacters",
    is_doc_only = true,
}

function KoCharacters:onDispatcherRegisterActions()
    Dispatcher:registerAction("kochar_page", {
        category = "none",
        event    = "CharExtractPage",
        title    = _("KoCharacters: Extract from page"),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_chapter", {
        category = "none",
        event    = "CharScanChapter",
        title    = _("KoCharacters: Scan chapter"),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_view", {
        category = "none",
        event    = "CharViewCharacters",
        title    = _("KoCharacters: View characters"),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_reanalyze", {
        category = "none",
        event    = "CharReanalyze",
        title    = _("KoCharacters: Re-analyze character..."),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_usage", {
        category = "none",
        event    = "CharViewUsage",
        title    = _("KoCharacters: View API usage"),
        reader   = true,
    })
    Dispatcher:registerAction("kochar_relmap", {
        category = "none",
        event    = "CharRelationshipMap",
        title    = _("KoCharacters: View relationship map"),
        reader   = true,
    })
end

function KoCharacters:onCharExtractPage()      self:onExtractCurrentPage() end
function KoCharacters:onCharScanChapter()      self:onScanChapter() end
function KoCharacters:onCharViewCharacters()   self:onViewCharacters() end
function KoCharacters:onCharReanalyze()        self:onReanalyzeCharacterPicker() end
function KoCharacters:onCharViewUsage()        self:onViewUsage() end
function KoCharacters:onCharRelationshipMap()  self:onViewRelationshipMap() end

function KoCharacters:init()
    self.db               = CharacterDB
    self._auto_extracting = false
    self._pending_extract = nil
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)

    -- Add "Find character" option to the word selection / highlight popup
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        local self_ref = self
        self.ui.highlight:addToHighlightDialog("kocharacters_lookup", function(highlight_instance)
            return {
                text = "Find character",
                callback = function()
                    local selected = highlight_instance.selected_text
                    local word = selected and (selected.text or selected.word or "") or ""
                    word = word:match("^%s*(.-)%s*$") or ""
                    if highlight_instance.highlight_dialog then
                        UIManager:close(highlight_instance.highlight_dialog)
                    end
                    self_ref:onWordCharacterLookup(word)
                end,
            }
        end)
    end

    self:_runOnTimeMigrations()
    logger.info("KoCharacters: plugin initialised")
end

-- One-time migration: assign IDs to existing characters and rename portrait files to <id>.png
function KoCharacters:_runOnTimeMigrations()
    if G_reader_settings:readSetting("kocharacters_id_migration_v3") then return end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then ok_lfs, lfs = pcall(require, "lfs") end
    if not ok_lfs or not lfs then
        G_reader_settings:saveSetting("kocharacters_id_migration_v3", true)
        return
    end

    local DataStorage = require("datastorage")
    local base_dir    = DataStorage:getDataDir() .. "/kocharacters"
    local attr        = lfs.attributes(base_dir)
    if not attr or attr.mode ~= "directory" then
        G_reader_settings:saveSetting("kocharacters_id_migration_v3", true)
        return
    end

    local total_chars, total_portraits = 0, 0

    for entry in lfs.dir(base_dir) do
        if entry ~= "." and entry ~= ".." then
            local book_dir = base_dir .. "/" .. entry
            local ba = lfs.attributes(book_dir)
            if ba and ba.mode == "directory" then
                -- load() backfills IDs for any character missing one and saves automatically
                local chars = self.db:load(entry)
                total_chars = total_chars + #chars

                -- Rename portrait files from name-based to id-based
                local portraits_dir = book_dir .. "/portraits"
                local changed = false
                for _, c in ipairs(chars) do
                    if c.id and c.id ~= "" then
                        local expected = c.id .. ".png"
                        -- Current portrait_file already correct
                        if c.portrait_file == expected then
                            -- nothing to do
                        else
                            -- Determine the old filename: stored portrait_file or name-based fallback
                            local old_filename = (c.portrait_file and c.portrait_file ~= "")
                                and c.portrait_file
                                or (portraitSafeName(c.name or "") .. ".png")
                            local old_path = portraits_dir .. "/" .. old_filename
                            local fcheck = io.open(old_path, "r")
                            if fcheck then
                                fcheck:close()
                                os.rename(old_path, portraits_dir .. "/" .. expected)
                                c.portrait_file = expected
                                changed = true
                                total_portraits = total_portraits + 1
                            end
                        end
                    end
                end
                if changed then self.db:save(entry, chars) end
            end
        end
    end

    G_reader_settings:saveSetting("kocharacters_id_migration_v3", true)
    logger.info(string.format(
        "KoCharacters: migration complete — %d character(s) assigned IDs, %d portrait(s) renamed",
        total_chars, total_portraits
    ))
end

function KoCharacters:_getChapterStartForPage(pageno)
    local doc = self.ui and self.ui.document
    if not doc then return pageno end
    local ok, toc = pcall(function() return doc:getToc() end)
    if not ok or type(toc) ~= "table" or #toc == 0 then return 1 end
    local chapter_start = 1
    for _, entry in ipairs(toc) do
        local ep = tonumber(entry.page) or 0
        if ep <= pageno and ep > chapter_start then chapter_start = ep end
    end
    return chapter_start
end

function KoCharacters:_onPageChanged(pageno)
    if not G_reader_settings:readSetting("kocharacters_auto_extract") then return end

    -- Cancel any pending extraction scheduled for a previous page
    if self._pending_extract then
        UIManager:unschedule(self._pending_extract)
        self._pending_extract = nil
    end

    if self._auto_extracting then return end

    local book_id = self:getBookID()
    if not book_id then return end
    if self.db:isPageScanned(book_id, pageno) then return end

    -- Debounce: wait N seconds before extracting so rapid page flips don't
    -- trigger a cascade of blocking API calls
    local delay = G_reader_settings:readSetting("kocharacters_auto_extract_delay") or 10
    self._pending_extract = function()
        self._pending_extract = nil
        if self._auto_extracting then return end
        -- Only extract if the user is still on this page
        if self:getCurrentPage() ~= pageno then return end
        self:autoExtract(pageno)
    end
    UIManager:scheduleIn(delay, self._pending_extract)
end

function KoCharacters:onPageUpdate(pageno)
    self:_onPageChanged(pageno)
end

function KoCharacters:onPosUpdate()
    local pageno
    pcall(function() pageno = self.ui.view.state.page end)
    if pageno then self:_onPageChanged(pageno) end
end

function KoCharacters:onReaderReady()
    local book_id = self:getBookID()
    if not book_id then return end

    -- Only prompt once per book
    local greeted = G_reader_settings:readSetting("kocharacters_greeted_books") or {}
    if greeted[book_id] then return end
    greeted[book_id] = true
    G_reader_settings:saveSetting("kocharacters_greeted_books", greeted)

    local auto_on = G_reader_settings:readSetting("kocharacters_auto_extract") and true or false
    local msg, ok_text, cancel_text
    if auto_on then
        msg         = "KoCharacters: auto-extract is ON.\nKeep it enabled for this book?"
        ok_text     = "Keep ON"
        cancel_text = "Turn OFF"
    else
        msg         = "KoCharacters: auto-extract is OFF.\nEnable it for this book?"
        ok_text     = "Enable"
        cancel_text = "Keep OFF"
    end

    UIManager:show(ConfirmBox:new{
        text            = msg,
        ok_text         = ok_text,
        cancel_text     = cancel_text,
        ok_callback     = function()
            G_reader_settings:saveSetting("kocharacters_auto_extract", true)
        end,
        cancel_callback = function()
            G_reader_settings:saveSetting("kocharacters_auto_extract", false)
        end,
    })
end

function KoCharacters:autoExtract(page_num)
    if self._auto_extracting then return end
    local api_key = self:getApiKey()
    if api_key == "" then return end
    local book_id = self:getBookID()
    if not book_id then return end

    local page_text, err = self:getCurrentPageText(page_num)
    if not page_text then
        logger.warn("KoCharacters: autoExtract getText failed: " .. tostring(err))
        -- Mark as scanned anyway so we don't retry a page that can't be read
        if page_num then self.db:markPageScanned(book_id, page_num) end
        return
    end

    self._auto_extracting = true
    self:showScanIndicator()

    local existing   = self.db:load(book_id)
    local page_lower = page_text:lower()
    local skip_names, chars_in_text = {}, {}
    for _, c in ipairs(existing) do
        local found = page_lower:find((c.name or ""):lower(), 1, true)
        if not found and c.aliases then
            for _, alias in ipairs(c.aliases) do
                if alias ~= "" and page_lower:find(alias:lower(), 1, true) then
                    found = true; break
                end
            end
        end
        if found then table.insert(chars_in_text, c) else table.insert(skip_names, c.name) end
    end

    local client = GeminiClient:new(api_key)
    local characters, api_err, usage, book_context
    local ok, call_err = pcall(function()
        characters, api_err, usage, book_context = client:extractCharacters(
            page_text, skip_names, chars_in_text, self:getExtractionPrompt(),
            self.db:loadBookContext(book_id))
    end)
    if ok and not api_err then self:recordUsage(usage) end
    if ok and book_context and book_context ~= "" then
        self.db:saveBookContext(book_id, book_context)
    end

    if not ok or api_err then
        self:hideScanIndicator()
        self._auto_extracting = false
        local is_network = not ok or (type(api_err) == "string" and api_err:find("Network error"))
        if is_network then
            -- Offline: save page to retry later
            if page_num then self.db:markPagePending(book_id, page_num) end
        else
            -- Other API error (quota, bad response): don't retry
            if page_num then self.db:markPageScanned(book_id, page_num) end
        end
        return
    end

    -- Success (even if no characters found — page was readable)
    if page_num then self.db:markPageScanned(book_id, page_num) end

    if not characters or #characters == 0 then
        self:hideScanIndicator()
        self._auto_extracting = false
        return
    end

    local cur_page = page_num or self:getCurrentPage()
    self:handleIncomingConflicts(book_id, characters, function(resolved)
        if #resolved > 0 then self.db:merge(book_id, resolved, cur_page) end
        self:hideScanIndicator()
        self._auto_extracting = false
        self:showExtractedCount(#characters)
        self:_checkAndPromptPendingPages(book_id)
    end, cur_page, true)
end

function KoCharacters:_checkAndPromptPendingPages(book_id)
    if self._pending_notified then return end
    if not self.db:hasPendingPages(book_id) then return end
    self._pending_notified = true
    local pages = self.db:loadPendingPages(book_id)
    UIManager:show(ConfirmBox:new{
        text    = #pages .. " page(s) couldn't be scanned while offline.\nScan them now?",
        ok_text = "Scan",
        ok_callback = function() self:onScanPendingPages(book_id) end,
    })
end

function KoCharacters:onScanPendingPages(book_id)
    book_id = book_id or self:getBookID()
    if not book_id then return end

    local pages = self.db:loadPendingPages(book_id)
    if #pages == 0 then self:showMsg("No offline-pending pages."); return end
    table.sort(pages)

    local client      = GeminiClient:new(self:getApiKey())
    local scanned_ok  = {}
    local total_found = 0
    local total       = #pages
    local self_ref    = self
    local progress_msg

    local function finish(stopped_early)
        if progress_msg then UIManager:close(progress_msg); progress_msg = nil end
        self_ref.db:removePendingPages(book_id, scanned_ok)
        for _, p in ipairs(scanned_ok) do self_ref.db:markPageScanned(book_id, p) end
        local remaining = self_ref.db:loadPendingPages(book_id)
        local msg = "Offline scan complete.\n"
            .. #scanned_ok .. "/" .. total .. " pages scanned.\n"
            .. "Characters found/updated: " .. total_found
        if #remaining > 0 then
            msg = msg .. "\n" .. #remaining .. " page(s) still pending."
        end
        if stopped_early then
            msg = "Network error during scan.\n"
                .. #scanned_ok .. " page(s) scanned before failure.\n"
                .. (total - #scanned_ok) .. " page(s) still pending."
        end
        self_ref:showMsg(msg, 6)
    end

    local function processPage(idx)
        if idx > total then finish(false); return end

        local page_num = pages[idx]
        if progress_msg then UIManager:close(progress_msg) end
        progress_msg = InfoMessage:new{
            text = "Scanning offline pages...\n" .. idx .. "/" .. total
                   .. " (page " .. page_num .. ")",
        }
        UIManager:show(progress_msg)
        UIManager:forceRePaint()

        local page_text = self_ref:getCurrentPageText(page_num)
        if not page_text or #page_text < 20 then
            table.insert(scanned_ok, page_num)
            UIManager:scheduleIn(0.1, function() processPage(idx + 1) end)
            return
        end

        local all_chars  = self_ref.db:load(book_id)
        local page_lower = page_text:lower()
        local chars_in_text, skip_names = {}, {}
        for _, c in ipairs(all_chars) do
            local found = c.name and page_lower:find(c.name:lower(), 1, true)
            if not found and c.aliases then
                for _, alias in ipairs(c.aliases) do
                    if alias ~= "" and page_lower:find(alias:lower(), 1, true) then found = true; break end
                end
            end
            if found then table.insert(chars_in_text, c)
            else table.insert(skip_names, c.name) end
        end

        local characters, api_err, usage, book_context
        local ok, call_err = pcall(function()
            characters, api_err, usage, book_context = client:extractCharacters(
                page_text, skip_names, chars_in_text, self_ref:getExtractionPrompt(),
                self_ref.db:loadBookContext(book_id))
        end)
        if ok and not api_err then self_ref:recordUsage(usage) end
        if ok and book_context and book_context ~= "" then
            self_ref.db:saveBookContext(book_id, book_context)
        end

        local is_network = not ok or (type(api_err) == "string" and api_err:find("Network error"))
        if is_network then
            finish(true)
            return
        end

        if api_err then
            logger.warn("KoCharacters: pending scan p" .. page_num .. ": " .. tostring(api_err))
            table.insert(scanned_ok, page_num)
        elseif characters and #characters > 0 then
            local ex_chars = self_ref.db:load(book_id)
            local ic = findIncomingConflicts(ex_chars, characters)
            local conflict_set = {}
            for _, c in ipairs(ic) do
                conflict_set[(c.new_char.name or ""):lower()] = true
                self_ref.db:enrichCharacter(book_id, c.existing_char.name, c.new_char, page_num)
            end
            local remaining_chars = {}
            for _, c in ipairs(characters) do
                if not conflict_set[(c.name or ""):lower()] then table.insert(remaining_chars, c) end
            end
            if #remaining_chars > 0 then self_ref.db:merge(book_id, remaining_chars, page_num) end
            total_found = total_found + #characters
            table.insert(scanned_ok, page_num)
        else
            table.insert(scanned_ok, page_num)
        end

        UIManager:scheduleIn(4, function() processPage(idx + 1) end)
    end

    processPage(1)
end

function KoCharacters:addToMainMenu(menu_items)
    menu_items.ko_characters = {
        text_func = function()
            local book_id = self:getBookID()
            local n = book_id and #self.db:load(book_id) or 0
            local base = n == 0 and _("KoCharacters") or (_("KoCharacters") .. " (" .. n .. ")")
            if book_id and self.db:hasPendingCleanup(book_id) then
                base = base .. " — cleanup needed"
            end
            return base
        end,
        sub_item_table = {
            {
                text     = _("Extract characters from this page"),
                callback = function() self:onExtractCurrentPage() end,
            },
            {
                text     = _("Scan current chapter"),
                callback = function() self:onScanChapter() end,
            },
            {
                text     = _("Scan specific chapter"),
                callback = function() self:onScanSpecificChapter() end,
            },
            {
                text     = _("View saved characters"),
                callback = function() self:onViewCharacters() end,
            },
            {
                text     = _("Re-analyze character"),
                callback = function() self:onReanalyzeCharacterPicker() end,
            },
            {
                text     = _("View relationship map"),
                callback = function() self:onViewRelationshipMap() end,
            },
            {
                text     = _("Cleanup all characters"),
                callback = function() self:onCleanupAllCharacters() end,
            },
            {
                text     = _("Detect & merge duplicates"),
                callback = function() self:onMergeDetection() end,
            },
            {
                text     = _("Generate portraits"),
                callback = function() self:onBatchGeneratePortraits() end,
            },
            {
                text     = _("Export..."),
                callback = function()
                    local self_ref = self
                    local export_menu
                    export_menu = Menu:new{
                        title      = "Export",
                        item_table = {
                            {
                                text     = "Export character list",
                                callback = function() UIManager:close(export_menu); self_ref:onExportCharacters() end,
                            },
                            {
                                text     = "Export as ZIP (HTML + portraits)",
                                callback = function() UIManager:close(export_menu); self_ref:onExportZip() end,
                            },
                            {
                                text     = "Upload to server",
                                callback = function() UIManager:close(export_menu); self_ref:onUploadToServer() end,
                            },
                        },
                        width       = Screen:getWidth(),
                        show_parent = self.ui,
                    }
                    UIManager:show(export_menu)
                end,
            },
            {
                text     = _("Settings..."),
                callback = function() self:onOpenSettings() end,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
function KoCharacters:showScanIndicator()
    if G_reader_settings:readSetting("kocharacters_scan_indicator") == false then return end
    if self._scan_indicator then return end
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget    = require("ui/widget/imagewidget")
    local Blitbuffer     = require("ffi/blitbuffer")
    local icon_path      = debug.getinfo(1, "S").source:sub(2):match("(.+/)") .. "assets/scanning.svg"
    self._scan_indicator = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 4,
        ImageWidget:new{
            file   = icon_path,
            width  = 40,
            height = 40,
        },
    }
    UIManager:show(self._scan_indicator)
    UIManager:setDirty(self._scan_indicator, "fast")
    UIManager:forceRePaint()
end

function KoCharacters:hideScanIndicator()
    if self._scan_indicator then
        UIManager:close(self._scan_indicator)
        self._scan_indicator = nil
        UIManager:setDirty(nil, "fast")
        UIManager:forceRePaint()
    end
end

function KoCharacters:showExtractedCount(count)
    if self._count_indicator then
        UIManager:close(self._count_indicator)
        if self._count_indicator_timer then
            UIManager:unschedule(self._count_indicator_timer)
        end
    end
    local FrameContainer   = require("ui/widget/container/framecontainer")
    local HorizontalGroup  = require("ui/widget/horizontalgroup")
    local ImageWidget      = require("ui/widget/imagewidget")
    local TextWidget       = require("ui/widget/textwidget")
    local Font             = require("ui/font")
    local Blitbuffer       = require("ffi/blitbuffer")
    local plugin_dir       = debug.getinfo(1, "S").source:sub(2):match("(.+/)")
    self._count_indicator = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding    = 4,
        HorizontalGroup:new{
            ImageWidget:new{
                file   = plugin_dir .. "assets/characters.svg",
                width  = 40,
                height = 40,
            },
            TextWidget:new{
                text = tostring(count),
                face = Font:getFace("cfont", 20),
            },
        },
    }
    UIManager:show(self._count_indicator)
    UIManager:setDirty(self._count_indicator, "fast")
    UIManager:forceRePaint()
    self._count_indicator_timer = function()
        self._count_indicator_timer = nil
        if self._count_indicator then
            UIManager:close(self._count_indicator)
            UIManager:setDirty(nil, "fast")
            UIManager:forceRePaint()
            self._count_indicator = nil
        end
    end
    UIManager:scheduleIn(4, self._count_indicator_timer)
end

function KoCharacters:showMsg(text, timeout)
    UIManager:show(InfoMessage:new{
        text    = text,
        timeout = timeout or 4,
    })
end

function KoCharacters:checkAndWarnDuplicates(book_id, on_continue)
    local characters = self.db:load(book_id)
    if #characters < 2 then on_continue(); return end
    local dup_pairs = findDuplicatePairs(characters)
    if #dup_pairs == 0 then on_continue(); return end

    local self_ref = self

    local function processPairs(remaining)
        if #remaining == 0 then on_continue(); return end

        local p    = remaining[1]
        local rest = { table.unpack(remaining, 2) }
        local a, b = p[1], p[2]

        local viewer
        viewer = TextViewer:new{
            title  = "Possible duplicate " .. (#dup_pairs - #remaining + 1) .. "/" .. #dup_pairs,
            text   = '"' .. a .. '" and "' .. b .. '" look like the same character.\n\nMerge them?',
            width  = math.floor(Screen:getWidth() * 0.9),
            height = math.floor(Screen:getHeight() * 0.6),
            buttons_table = {{
                {
                    text     = 'Merge into "' .. b .. '"',
                    callback = function()
                        UIManager:close(viewer)
                        self_ref.db:mergeCharacters(book_id, a, b)
                        processPairs(rest)
                    end,
                },
                {
                    text     = 'Merge into "' .. a .. '"',
                    callback = function()
                        UIManager:close(viewer)
                        self_ref.db:mergeCharacters(book_id, b, a)
                        processPairs(rest)
                    end,
                },
                {
                    text     = "Skip",
                    callback = function()
                        UIManager:close(viewer)
                        processPairs(rest)
                    end,
                },
            }},
        }
        UIManager:show(viewer)
    end

    processPairs(dup_pairs)
end

function KoCharacters:handleIncomingConflicts(book_id, new_chars, on_done, page_num, skip_cleanup)
    new_chars = deduplicateIncoming(new_chars)
    local existing  = self.db:load(book_id)
    local conflicts = findIncomingConflicts(existing, new_chars)
    if #conflicts == 0 then on_done(new_chars); return end

    -- Auto-accept mode: enrich all conflicts silently, show a toast summary
    if G_reader_settings:readSetting("kocharacters_auto_enrich") then
        local enriched_names = {}
        local conflict_set   = {}
        for _, conflict in ipairs(conflicts) do
            local new_c = conflict.new_char
            local ex_c  = conflict.existing_char
            self.db:enrichCharacter(book_id, ex_c.name, new_c, page_num)
            table.insert(enriched_names, ex_c.name)
            conflict_set[(new_c.name or ""):lower()] = true
        end
        local resolved = {}
        for _, c in ipairs(new_chars) do
            if not conflict_set[(c.name or ""):lower()] then
                table.insert(resolved, c)
            end
        end
        if #enriched_names > 0 then
            if skip_cleanup then self.db:markPendingCleanup(book_id) end
            self:showMsg("Enriched: " .. table.concat(enriched_names, ", "), 3)
        end
        on_done(resolved)
        return
    end

    local self_ref  = self
    local to_enrich = {}   -- new_char_name_lower -> existing_char_name

    local function finalize(resolved)
        -- Collect existing chars that were just enriched
        local enriched_names = {}
        for _, ex_name in pairs(to_enrich) do enriched_names[ex_name] = true end

        local enriched_chars = {}
        for _, c in ipairs(self_ref.db:load(book_id)) do
            if enriched_names[c.name] then table.insert(enriched_chars, c) end
        end

        if #enriched_chars == 0 then
            on_done(resolved)
            return
        end

        if skip_cleanup then
            self_ref.db:markPendingCleanup(book_id)
            on_done(resolved)
            return
        end

        -- One Gemini call to clean up all enriched profiles
        local enriched_names_list = {}
        for _, ec in ipairs(enriched_chars) do table.insert(enriched_names_list, ec.name or "?") end
        local working_msg = InfoMessage:new{
            text = "Cleaning up " .. #enriched_chars .. " enriched character(s):\n"
                   .. table.concat(enriched_names_list, ", ")
        }
        UIManager:show(working_msg)
        UIManager:forceRePaint()

        local client = GeminiClient:new(self_ref:getApiKey())
        local cleaned, err, usage1
        local ok, call_err = pcall(function()
            cleaned, err, usage1 = client:cleanCharacters(enriched_chars)
        end)
        UIManager:close(working_msg)
        if ok and not err then self_ref:recordUsage(usage1) end

        if ok and not err and cleaned and type(cleaned) == "table" then
            local all_chars = self_ref.db:load(book_id)
            local changed   = false
            for i, cc in ipairs(cleaned) do
                if cc.name then
                    local apply_msg = InfoMessage:new{
                        text = "Applying cleanup " .. i .. "/" .. #cleaned .. ": " .. cc.name .. "..."
                    }
                    UIManager:show(apply_msg)
                    UIManager:forceRePaint()
                    for _, orig in ipairs(all_chars) do
                        if orig.name == cc.name then
                            if cc.physical_description ~= nil then orig.physical_description = cc.physical_description end
                            if cc.personality          ~= nil then orig.personality          = cc.personality          end
                            if cc.role and cc.role ~= ""      then orig.role                 = cc.role                 end
                            if type(cc.relationships) == "table" then orig.relationships     = cc.relationships        end
                            orig.needs_cleanup = nil
                            changed = true
                            break
                        end
                    end
                    UIManager:close(apply_msg)
                end
            end
            if changed then self_ref.db:save(book_id, all_chars) end
        else
            logger.warn("KoCharacters: batch cleanup failed: " .. tostring(call_err or err))
        end

        on_done(resolved)
    end

    local function processConflicts(remaining)
        if #remaining == 0 then
            -- Apply all enrichments, then clean
            for new_name_low, ex_name in pairs(to_enrich) do
                for _, c in ipairs(new_chars) do
                    if (c.name or ""):lower() == new_name_low then
                        self_ref.db:enrichCharacter(book_id, ex_name, c, page_num)
                        break
                    end
                end
            end
            local resolved = {}
            for _, c in ipairs(new_chars) do
                if not to_enrich[(c.name or ""):lower()] then
                    table.insert(resolved, c)
                end
            end
            finalize(resolved)
            return
        end

        local conflict = remaining[1]
        local rest     = { table.unpack(remaining, 2) }
        local new_c    = conflict.new_char
        local ex_c     = conflict.existing_char

        local lines = { 'New:      "' .. new_c.name .. '"', 'Existing: "' .. ex_c.name .. '"', "" }
        if new_c.role and new_c.role ~= ""                              then table.insert(lines, "New role: "        .. new_c.role)                 end
        if new_c.physical_description and new_c.physical_description ~= "" then table.insert(lines, "New appearance: " .. new_c.physical_description) end
        if ex_c.role and ex_c.role ~= ""                                then table.insert(lines, "Existing role: "   .. ex_c.role)                  end

        local viewer
        viewer = TextViewer:new{
            title  = "Match " .. (#conflicts - #remaining + 1) .. " / " .. #conflicts .. ": same person?",
            text   = table.concat(lines, "\n"),
            width  = math.floor(Screen:getWidth() * 0.9),
            height = math.floor(Screen:getHeight() * 0.85),
            buttons_table = {{
                {
                    text     = 'Enrich "' .. ex_c.name .. '"',
                    callback = function()
                        UIManager:close(viewer)
                        to_enrich[(new_c.name or ""):lower()] = ex_c.name
                        processConflicts(rest)
                    end,
                },
                {
                    text     = "Add as new",
                    callback = function()
                        UIManager:close(viewer)
                        processConflicts(rest)
                    end,
                },
            }},
        }
        UIManager:show(viewer)
    end

    processConflicts(conflicts)
end

-- Key for Gemini text calls (character extraction, cleanup, etc.)
function KoCharacters:getApiKey()
    return G_reader_settings:readSetting("kocharacters_extraction_api_key") or ""
end

-- Key for Imagen image generation
function KoCharacters:getImagenApiKey()
    return G_reader_settings:readSetting("kocharacters_imagen_api_key") or ""
end

function KoCharacters:getCurrentPage()
    local page
    pcall(function() page = self.ui.view.state.page end)
    return page
end

function KoCharacters:getExtractionPrompt()
    return G_reader_settings:readSetting("kocharacters_extraction_prompt")
        or GeminiClient.DEFAULT_EXTRACTION_PROMPT
end

function KoCharacters:getCleanupPrompt()
    return G_reader_settings:readSetting("kocharacters_cleanup_prompt")
        or GeminiClient.DEFAULT_CLEANUP_PROMPT
end

function KoCharacters:getMergeDetectionPrompt()
    return G_reader_settings:readSetting("kocharacters_merge_detection_prompt")
        or GeminiClient.DEFAULT_MERGE_DETECTION_PROMPT
end

function KoCharacters:getReanalyzePrompt()
    return G_reader_settings:readSetting("kocharacters_reanalyze_prompt")
        or GeminiClient.DEFAULT_REANALYZE_PROMPT
end

function KoCharacters:getRelationshipMapPrompt()
    return G_reader_settings:readSetting("kocharacters_relationship_map_prompt")
        or GeminiClient.DEFAULT_RELATIONSHIP_MAP_PROMPT
end

local DEFAULT_PORTRAIT_PROMPT = [[Oil painting portrait of a fictional {{role}} character. Square composition, 1024x1024. No text. No words. No letters. No labels. No watermarks. No inscriptions. Pure image only. Appearance: {{appearance}} Personality expressed through posture and expression: {{personality}} Occupation: {{occupation}} — the character's clothing, accessories, tools, and background environment must authentically reflect this occupation and social standing (e.g. a blacksmith wears a leather apron near a forge, a physician carries instruments in a study, a soldier wears armour or uniform). Book setting: {{book_context}} Use historically accurate clothing, hairstyle, and background consistent with the character's era, occupation, and the book setting. Paint in the style of a master portrait painter from that same era — matching the composition, lighting, brushwork, color palette, and aesthetic conventions of period-authentic portraiture (e.g. Renaissance, Baroque, Victorian, etc. as appropriate). Fine detail in fabric, face, and any occupation-relevant objects or surroundings.]]

function KoCharacters:getPortraitPrompt()
    return G_reader_settings:readSetting("kocharacters_portrait_prompt")
        or DEFAULT_PORTRAIT_PROMPT
end

function KoCharacters:recordUsage(usage)
    local json        = require("dkjson")
    local DataStorage = require("datastorage")
    local util        = require("util")
    local dir         = DataStorage:getDataDir() .. "/kocharacters"
    util.makePath(dir)
    local path = dir .. "/usage_stats.json"

    local stats = {}
    local f = io.open(path, "r")
    if f then
        stats = json.decode(f:read("*all")) or {}
        f:close()
    end

    local date = os.date("%Y-%m-%d")
    if not stats[date] then
        stats[date] = { calls = 0, prompt_tokens = 0, output_tokens = 0, images = 0 }
    end
    stats[date].calls         = (stats[date].calls         or 0) + 1
    stats[date].prompt_tokens = (stats[date].prompt_tokens or 0) + (usage and usage.prompt_tokens or 0)
    stats[date].output_tokens = (stats[date].output_tokens or 0) + (usage and usage.output_tokens or 0)
    if usage and usage.images then
        stats[date].images = (stats[date].images or 0) + usage.images
    end

    local fw = io.open(path, "w")
    if fw then fw:write(json.encode(stats)); fw:close() end
end

function KoCharacters:onViewRelationshipMap()
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end

    local characters = self.db:load(book_id)
    if #characters < 2 then
        self:showMsg("Need at least 2 saved characters to build a relationship map.")
        return
    end

    local working_msg = InfoMessage:new{ text = "Building relationship map..." }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local map_text, err, usage
    local ok, call_err = pcall(function()
        map_text, err, usage = client:buildRelationshipMap(characters, self:getRelationshipMapPrompt())
    end)

    UIManager:close(working_msg)
    if ok and not err then self:recordUsage(usage) end

    if not ok then
        self:showMsg("Plugin error:\n" .. tostring(call_err), 8)
        return
    end
    if err then
        self:showMsg("Gemini error:\n" .. tostring(err), 8)
        return
    end

    UIManager:show(TextViewer:new{
        title  = "Relationship Map — " .. self:getBookTitle(),
        text   = map_text,
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

function KoCharacters:onViewUsage()
    local json        = require("dkjson")
    local DataStorage = require("datastorage")
    local path        = DataStorage:getDataDir() .. "/kocharacters/usage_stats.json"

    local stats = {}
    local f = io.open(path, "r")
    if f then
        stats = json.decode(f:read("*all")) or {}
        f:close()
    end

    local dates = {}
    for date in pairs(stats) do table.insert(dates, date) end
    table.sort(dates, function(a, b) return a > b end)

    if #dates == 0 then
        self:showMsg("No API usage recorded yet.", 3)
        return
    end

    local lines = { "Date            Calls  Prompt     Output     Images" }
    table.insert(lines, string.rep("-", 52))
    local tot_calls, tot_prompt, tot_output, tot_images = 0, 0, 0, 0
    for _, date in ipairs(dates) do
        local d = stats[date]
        local c = d.calls         or 0
        local p = d.prompt_tokens or 0
        local o = d.output_tokens or 0
        local i = d.images        or 0
        tot_calls  = tot_calls  + c
        tot_prompt = tot_prompt + p
        tot_output = tot_output + o
        tot_images = tot_images + i
        table.insert(lines, string.format("%-16s %-6d %-10d %-10d %d", date, c, p, o, i))
    end
    table.insert(lines, string.rep("-", 52))
    table.insert(lines, string.format("%-16s %-6d %-10d %-10d %d", "TOTAL", tot_calls, tot_prompt, tot_output, tot_images))

    UIManager:show(TextViewer:new{
        title  = "API Usage (Gemini + Imagen)",
        text   = table.concat(lines, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

-- Derive a stable book ID purely from the file path — no document API calls
function KoCharacters:getBookID()
    if self.ui and self.ui.document and self.ui.document.file then
        local path = self.ui.document.file
        -- Hash for uniqueness (two books can share a title)
        local sum = #path
        for i = 1, #path do sum = sum + string.byte(path, i) end

        -- Prefer metadata title, fall back to filename without extension
        local title = ""
        if self.ui.doc_settings then
            local ok, props = pcall(function() return self.ui.doc_settings:readSetting("doc_props") end)
            if ok and props and props.title and props.title ~= "" then
                title = props.title
            end
        end
        if title == "" then
            local fname = path:match("([^/]+)$") or "book"
            title = fname:gsub("%.[^%.]+$", "")  -- strip extension
        end

        -- Sanitize: keep letters, digits, spaces, hyphens; collapse whitespace to underscore
        title = title:gsub("[^%w%s%-]", ""):gsub("%s+", "_"):gsub("_+", "_")
        title = title:match("^_*(.-)_*$") or title  -- trim leading/trailing underscores
        if title == "" then title = "book" end

        return title .. "_" .. tostring(sum)
    end
    return nil
end

function KoCharacters:getBookTitle()
    if self.ui and self.ui.doc_settings then
        local ok, props = pcall(function()
            return self.ui.doc_settings:readSetting("doc_props")
        end)
        if ok and props and props.title and props.title ~= "" then
            return props.title
        end
    end
    if self.ui and self.ui.document and self.ui.document.file then
        return self.ui.document.file:match("([^/]+)$") or "Unknown Book"
    end
    return "Unknown Book"
end

function KoCharacters:getCurrentPageText(override_page)
    if not self.ui or not self.ui.document then
        return nil, "No document open"
    end

    local doc = self.ui.document
    local page
    if override_page then
        page = override_page
    else
        pcall(function() page = self.ui.view.state.page end)
    end
    if not page then return nil, "Could not get page number" end

    -- CreDocument (EPUB): getPageXPointer works, getPosFromXPointer works
    -- Use these to get integer position range, then getTextBoxesFromPositions
    if type(doc.getPageXPointer) == "function" then
        logger.info("KoCharacters: using getPageXPointer+getPosFromXPointer strategy")

        local ok1, xp_cur  = pcall(function() return doc:getPageXPointer(page) end)
        local ok2, xp_next = pcall(function() return doc:getPageXPointer(page + 1) end)

        if not ok1 or not xp_cur then
            return nil, "getPageXPointer failed: " .. tostring(xp_cur)
        end

        local ok3, pos_start = pcall(function() return doc:getPosFromXPointer(xp_cur) end)
        if not ok3 then return nil, "getPosFromXPointer failed: " .. tostring(pos_start) end

        local pos_end
        if ok2 and xp_next then
            local ok4, p = pcall(function() return doc:getPosFromXPointer(xp_next) end)
            if ok4 then pos_end = p end
        end
        if not pos_end then pos_end = pos_start + 5000 end

        logger.info("KoCharacters: pos=" .. tostring(pos_start) .. "-" .. tostring(pos_end))

        -- Try getTextBoxesFromPositions (some builds have this)
        local ok5, boxes = pcall(function()
            return doc:getTextBoxesFromPositions(pos_start, pos_end)
        end)
        if ok5 and boxes and type(boxes) == "table" and #boxes > 0 then
            local words = {}
            for _, line in ipairs(boxes) do
                if type(line) == "table" then
                    for _, word in ipairs(line) do
                        if type(word) == "table" and word.word and word.word ~= "" then
                            table.insert(words, word.word)
                        end
                    end
                end
            end
            if #words > 0 then return table.concat(words, " ") end
        end

        -- Use getDocumentFileContent — confirmed working
        local frag_idx = tostring(xp_cur):match("DocFragment%[(%d+)%]")
        logger.info("KoCharacters: frag_idx=" .. tostring(frag_idx))
        -- Get fragment start AND end position from TOC for accurate slicing
        local frag_start_pos = 0
        local frag_end_pos = 0
        local ok_toc, toc = pcall(function() return doc:getToc() end)
        if ok_toc and type(toc) == "table" then
            local best_page = 0
            local best_idx = 0
            for i, entry in ipairs(toc) do
                local ep = tonumber(entry.page) or 0
                if ep <= page and ep > best_page then
                    best_page = ep
                    best_idx = i
                    if entry.xpointer then
                        local ok_xp, p = pcall(function()
                            return doc:getPosFromXPointer(entry.xpointer)
                        end)
                        if ok_xp and p then frag_start_pos = p end
                    end
                end
            end
            -- Get next TOC entry position as fragment end
            local next_entry = toc[best_idx + 1]
            if next_entry and next_entry.xpointer then
                local ok_xp, p = pcall(function()
                    return doc:getPosFromXPointer(next_entry.xpointer)
                end)
                if ok_xp and p then frag_end_pos = p end
            end
        end
        logger.info("KoCharacters: frag_start=" .. frag_start_pos .. " frag_end=" .. frag_end_pos)

        -- Read epub as zip directly — most reliable approach
        local function stripAndSlice(raw)
            local text = raw
            text = text:gsub("<[^>]+>", " ")
            text = text:gsub("&nbsp;",  " ")
            text = text:gsub("&amp;",   "&")
            text = text:gsub("&lt;",    "<")
            text = text:gsub("&gt;",    ">")
            text = text:gsub("&quot;",  '"')
            text = text:gsub("&#%d+;",  " ")
            text = text:gsub("%s+",     " ")
            text = text:gsub("^%s+",    "")
            text = text:gsub("%s+$",    "")
            if #text < 50 then text = raw:sub(1, 4000) end
            local MAX = 2500
            if #text <= MAX then return text end
            -- Use fragment-relative position for accurate slicing
            local frag_span = math.max(
                (frag_end_pos > 0 and frag_end_pos or pos_start + 50000) - frag_start_pos, 1)
            local page_offset = math.max(pos_start - frag_start_pos, 0)
            local ratio = math.min(page_offset / frag_span, 1.0)
            local centre = math.floor(ratio * #text)
            local s = math.max(1, centre - 500)
            local e = math.min(#text, s + MAX)
            logger.info("KoCharacters: ratio=" .. string.format("%.2f", ratio) .. " slice=" .. s .. "-" .. e .. "/" .. #text)
            local slice = text:sub(s, e)
            if #slice < 200 then return text:sub(1, math.min(#text, MAX)) end
            return slice
        end

        local epub_path = doc.file
        logger.info("KoCharacters: epub_path=" .. tostring(epub_path))
        if epub_path then
            logger.info("KoCharacters: starting popen unzip")
            local ok_p, result = pcall(function()
                local h = io.popen("unzip -l '" .. epub_path .. "' 2>/dev/null", "r")
                if not h then return nil, "popen failed" end
                local listing = h:read("*a")
                h:close()
                return listing
            end)
            logger.info("KoCharacters: popen ok=" .. tostring(ok_p) .. " type=" .. type(result) .. " len=" .. (type(result)=="string" and #result or 0))

            if ok_p and type(result) == "string" and #result > 10 then
                local n = tonumber(frag_idx) or 1
                -- Find OPF path in listing
                local opf_path = result:match("([^%s]+%.opf)")
                logger.info("KoCharacters: opf_path=" .. tostring(opf_path))

                if opf_path then
                    local ok2, opf = pcall(function()
                        local h = io.popen("unzip -p '" .. epub_path .. "' '" .. opf_path .. "' 2>/dev/null", "r")
                        if not h then return nil end
                        local s = h:read("*a"); h:close(); return s
                    end)
                    logger.info("KoCharacters: opf ok=" .. tostring(ok2) .. " len=" .. (type(opf)=="string" and #opf or 0))

                    if ok2 and type(opf) == "string" and #opf > 50 then
                        -- Find nth spine itemref
                        local count, item_id = 0, nil
                        for idref in opf:gmatch([[itemref[^>]+idref="([^"]+)"]]) do
                            count = count + 1
                            if count == n then item_id = idref; break end
                        end
                        logger.info("KoCharacters: spine#" .. n .. " id=" .. tostring(item_id))

                        if item_id then
                            local pat1 = [[item[^>]+href="([^"]+)"[^>]+id="]] .. item_id .. [["]]
                            local pat2 = [[item[^>]+id="]] .. item_id .. [["[^>]+href="([^"]+)"]]
                            local href = opf:match(pat2) or opf:match(pat1)
                            logger.info("KoCharacters: chapter href=" .. tostring(href))

                            if href then
                                local base = opf_path:match("^(.*/)") or ""
                                local full = base .. href
                                local ok3, chapter = pcall(function()
                                    local h = io.popen("unzip -p '" .. epub_path .. "' '" .. full .. "' 2>/dev/null", "r")
                                    if not h then return nil end
                                    local s = h:read("*a"); h:close(); return s
                                end)
                                logger.info("KoCharacters: chapter ok=" .. tostring(ok3) .. " len=" .. (type(chapter)=="string" and #chapter or 0))

                                if ok3 and type(chapter) == "string" and #chapter > 100 then
                                    return stripAndSlice(chapter)
                                end
                            end
                        end
                    end
                end
            end
        end

        return nil, "All extraction methods failed for page " .. tostring(page)
    end

    -- Fallback: getTextBoxes
    local boxes
    local ok, err = pcall(function() boxes = doc:getTextBoxes(page) end)
    if not ok then return nil, "getTextBoxes error: " .. tostring(err) end
    if not boxes or #boxes == 0 then return nil, "No text found on this page" end
    local words = {}
    for _, line in ipairs(boxes) do
        if type(line) == "table" then
            for _, word in ipairs(line) do
                if type(word) == "table" and word.word and word.word ~= "" then
                    table.insert(words, word.word)
                end
            end
        end
    end
    if #words == 0 then return nil, "Text boxes empty" end
    return table.concat(words, " ")
end

function KoCharacters:getCurrentChapterPageRange()
    if not self.ui or not self.ui.document then
        return nil, nil, "No document open"
    end

    local doc = self.ui.document
    local current_page
    pcall(function() current_page = self.ui.view.state.page end)
    if not current_page then return nil, nil, "Could not get page number" end

    local total_pages
    pcall(function() total_pages = doc:getPageCount() end)
    total_pages = total_pages or current_page

    local ok_toc, toc = pcall(function() return doc:getToc() end)
    if not ok_toc or type(toc) ~= "table" or #toc == 0 then
        return 1, total_pages, nil
    end

    local chapter_start = 1
    local chapter_idx   = 0
    for i, entry in ipairs(toc) do
        local ep = tonumber(entry.page) or 0
        if ep <= current_page and ep >= chapter_start then
            chapter_start = ep
            chapter_idx   = i
        end
    end

    local chapter_end = total_pages
    local next_entry  = toc[chapter_idx + 1]
    if next_entry then
        local np = tonumber(next_entry.page) or 0
        if np > chapter_start then
            chapter_end = np - 1
        end
    end

    return chapter_start, chapter_end, nil
end

function KoCharacters:formatCharacter(c)
    local lines = {}

    table.insert(lines, "NAME")
    table.insert(lines, c.name or "Unknown")

    if c.aliases and #c.aliases > 0 then
        table.insert(lines, "")
        table.insert(lines, "ALIASES")
        table.insert(lines, table.concat(c.aliases, ", "))
    end

    if c.role and c.role ~= "" then
        table.insert(lines, "")
        table.insert(lines, "ROLE")
        table.insert(lines, c.role)
    end

    if c.occupation and c.occupation ~= "" then
        table.insert(lines, "")
        table.insert(lines, "OCCUPATION")
        table.insert(lines, c.occupation)
    end

    if c.physical_description and c.physical_description ~= "" then
        table.insert(lines, "")
        table.insert(lines, "APPEARANCE")
        table.insert(lines, c.physical_description)
    end

    if c.personality and c.personality ~= "" then
        table.insert(lines, "")
        table.insert(lines, "PERSONALITY")
        table.insert(lines, c.personality)
    end

    if c.relationships and #c.relationships > 0 then
        table.insert(lines, "")
        table.insert(lines, "RELATIONSHIPS")
        table.insert(lines, table.concat(c.relationships, "\n"))
    end

    if c.first_appearance_quote and c.first_appearance_quote ~= "" then
        table.insert(lines, "")
        table.insert(lines, "FIRST SEEN")
        table.insert(lines, '"' .. c.first_appearance_quote .. '"')
    end

    if c.user_notes and c.user_notes ~= "" then
        table.insert(lines, "")
        table.insert(lines, "NOTES")
        table.insert(lines, c.user_notes)
    end

    if c.source_page then
        table.insert(lines, "")
        table.insert(lines, "LAST UPDATED")
        table.insert(lines, "Page " .. c.source_page)
    end

    return table.concat(lines, "\n")
end

-- Returns CSS string and body HTML string separately, so the caller can
-- pass css via ScrollHtmlWidget's css= parameter (MuPDF requires this).
function KoCharacters:formatCharacterHTML(char, portrait_path, container_w)
    local function esc(s)
        s = tostring(s or "")
        s = s:gsub("&",  "&amp;")
        s = s:gsub("<",  "&lt;")
        s = s:gsub(">",  "&gt;")
        s = s:gsub('"',  "&quot;")
        return s
    end
    local css = table.concat({
        "@page{margin:0;}",
        "html,body{margin:0;padding:0;}",
        "body{font-family:Georgia,serif;padding:12px 14px;background:#fff;color:#111;line-height:1.3;}",
        "table{border-collapse:collapse;border-spacing:0;width:100%;}",
        "td{padding:0;vertical-align:top;}",
        "img.portrait{display:block;width:100%;height:auto;border-radius:3px;}",
        "h1{font-size:1.45em;color:#000;margin:0 0 3px;font-weight:bold;}",
        ".role{color:#444;font-style:italic;margin:0;font-size:0.87em;}",
        ".section{margin-top:16px;padding-top:12px;border-top:1px solid #ccc;}",
        ".label{font-size:0.76em;text-transform:uppercase;letter-spacing:.09em;color:#333;font-weight:bold;margin:0 0 5px;}",
        "p{margin:0;font-size:0.87em;text-align:justify;}",
        "ul{margin:4px 0 0 0;padding-left:36px;font-size:0.87em;}",
        "ul li{margin-bottom:3px;}",
        ".quote{border-left:2px solid #888;padding-left:10px;color:#444;font-style:italic;}",
        ".foot{font-size:.72em;color:#aaa;margin-top:16px;}",
    })
    local p = {}

    local name_html = '<h1>' .. esc(char.name or "Unknown") .. '</h1>'
    local role_html = ""
    if char.role and char.role ~= "" and char.role ~= "unknown" then
        role_html = '<p class="role">' .. esc(char.role) .. '</p>'
    end
    local aliases_html = ""
    if char.aliases and #char.aliases > 0 then
        local items = {}
        for _, a in ipairs(char.aliases) do items[#items+1] = '<li>' .. esc(a) .. '</li>' end
        local styled_items = {}
        for _, a in ipairs(char.aliases) do
            styled_items[#styled_items+1] = '<li style="font-family:Georgia,serif;">' .. esc(a) .. '</li>'
        end
        aliases_html = '<div style="margin-top:8px;font-family:Georgia,serif;"><div class="label">Also known as</div><ul>' .. table.concat(styled_items) .. '</ul></div>'
    end
    p[#p+1] = name_html
    p[#p+1] = role_html
    if portrait_path then
        local body_w   = (container_w or 300) - 28  -- subtract body padding (14px each side)
        local img_w    = math.floor(body_w * 0.4)
        local text_w   = body_w - img_w - 12
        p[#p+1] = '<div style="display:table;width:' .. body_w .. 'px;">'
        p[#p+1] = '<div style="display:table-row;">'
        p[#p+1] = '<div style="display:table-cell;width:' .. img_w .. 'px;vertical-align:top;padding-right:8px;"><img width="' .. (img_w-8) .. '" src="' .. portrait_path .. '"></div>'
        p[#p+1] = '<div style="display:table-cell;width:' .. text_w .. 'px;vertical-align:top;font-family:Georgia,serif;">' .. aliases_html .. '</div>'
        p[#p+1] = '</div></div>'
    else
        p[#p+1] = aliases_html
    end

    -- Body sections
    if char.physical_description and char.physical_description ~= "" then
        p[#p+1] = '<div class="section"><div class="label">Appearance</div><p>' .. esc(char.physical_description) .. '</p></div>'
    end
    if char.personality and char.personality ~= "" then
        p[#p+1] = '<div class="section"><div class="label">Personality</div><p>' .. esc(char.personality) .. '</p></div>'
    end
    if char.relationships and #char.relationships > 0 then
        local items = {}
        for _, r in ipairs(char.relationships) do items[#items+1] = '<li>' .. esc(r) .. '</li>' end
        p[#p+1] = '<div class="section"><div class="label">Relationships</div><ul>' .. table.concat(items) .. '</ul></div>'
    end
    if char.first_appearance_quote and char.first_appearance_quote ~= "" then
        p[#p+1] = '<div class="section"><div class="label">First seen</div><p class="quote">&ldquo;' .. esc(char.first_appearance_quote) .. '&rdquo;</p></div>'
    end
    if char.user_notes and char.user_notes ~= "" then
        p[#p+1] = '<div class="section"><div class="label">My notes</div><p style="white-space:pre-wrap;">' .. esc(char.user_notes) .. '</p></div>'
    end
    if char.source_page then
        p[#p+1] = '<p class="foot">Last updated: page ' .. tostring(char.source_page) .. '</p>'
    end
    return css, table.concat(p)
end

-- ---------------------------------------------------------------------------
-- Edit character
-- ---------------------------------------------------------------------------
function KoCharacters:onEditCharacter(book_id, char, refresh_browser_fn, show_viewer_fn)
    local self_ref   = self
    -- Track the name used to look up the record (changes if the user renames)
    local lookup_name = char.name

    local function save()
        self_ref.db:updateCharacter(book_id, lookup_name, char)
        lookup_name = char.name   -- keep in sync if name was changed
    end

    local edit_menu          -- forward reference so callbacks can close+reopen it
    local closing_for_save = false  -- guard: suppress close_callback during after_save
    local function showEditMenu()
        local ok, Menu = pcall(require, "ui/widget/menu")
        if not ok or not Menu then return end

        local function after_save()
            closing_for_save = true
            UIManager:close(edit_menu)
            closing_for_save = false
            if refresh_browser_fn then refresh_browser_fn() end
            showEditMenu()
        end

        local function editTextField(label, current, multiline, on_save)
            local dialog
            dialog = InputDialog:new{
                title         = "Edit " .. label,
                input         = current or "",
                input_type    = multiline and "text" or "string",
                allow_newline = multiline,
                buttons       = {{
                    { text = "Cancel", callback = function() UIManager:close(dialog) end },
                    {
                        text             = "Save",
                        is_enter_default = not multiline,
                        callback         = function()
                            UIManager:close(dialog)
                            on_save(dialog:getInputText() or "")
                        end,
                    },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end

        local items = {
            {
                text     = "Name: " .. (char.name or ""),
                callback = function()
                    editTextField("Name", char.name, false, function(val)
                        if val ~= "" then char.name = val; save(); after_save() end
                    end)
                end,
            },
            {
                text     = "Aliases: " .. table.concat(char.aliases or {}, ", "),
                callback = function()
                    editTextField("Aliases (comma-separated)", table.concat(char.aliases or {}, ", "), false, function(val)
                        local t = {}
                        for a in val:gmatch("[^,]+") do
                            local s = a:match("^%s*(.-)%s*$")
                            if s ~= "" then table.insert(t, s) end
                        end
                        char.aliases = t; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Role: " .. (char.role or "unknown"),
                callback = function()
                    local role_menu
                    local role_items = {}
                    for _, r in ipairs({"protagonist","antagonist","supporting","unknown"}) do
                        local role = r
                        table.insert(role_items, {
                            text     = role,
                            callback = function()
                                char.role = role; save()
                                UIManager:close(role_menu)
                                after_save()
                            end,
                        })
                    end
                    role_menu = Menu:new{
                        title      = "Select Role",
                        item_table = role_items,
                        width      = Screen:getWidth(),
                        show_parent = self_ref.ui,
                    }
                    UIManager:show(role_menu)
                end,
            },
            {
                text     = "Occupation",
                callback = function()
                    editTextField("Occupation", char.occupation, false, function(val)
                        char.occupation = val ~= "" and val or nil; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Appearance",
                callback = function()
                    editTextField("Appearance", char.physical_description, true, function(val)
                        char.physical_description = val; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Personality",
                callback = function()
                    editTextField("Personality", char.personality, true, function(val)
                        char.personality = val; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Relationships (one per line)",
                callback = function()
                    editTextField("Relationships", table.concat(char.relationships or {}, "\n"), true, function(val)
                        local t = {}
                        for r in val:gmatch("[^\n]+") do
                            local s = r:match("^%s*(.-)%s*$")
                            if s ~= "" then table.insert(t, s) end
                        end
                        char.relationships = t; save(); after_save()
                    end)
                end,
            },
            {
                text     = "First appearance quote",
                callback = function()
                    editTextField("First Appearance Quote", char.first_appearance_quote, true, function(val)
                        char.first_appearance_quote = val; save(); after_save()
                    end)
                end,
            },
            {
                text     = "Notes" .. ((char.user_notes and char.user_notes ~= "") and " ✎" or ""),
                callback = function()
                    editTextField("Notes", char.user_notes, true, function(val)
                        char.user_notes = val ~= "" and val or nil; save(); after_save()
                    end)
                end,
            },
        }

        edit_menu = Menu:new{
            title          = "Edit: " .. (char.name or ""),
            item_table     = items,
            width          = Screen:getWidth(),
            show_parent    = self_ref.ui,
            close_callback = function()
                if not closing_for_save and show_viewer_fn then show_viewer_fn() end
            end,
        }
        edit_menu.onReturn = function()
            UIManager:close(edit_menu)  -- close_callback handles show_viewer_fn
        end
        UIManager:show(edit_menu)
    end

    showEditMenu()
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------
function KoCharacters:onExtractCurrentPage()
    logger.info("KoCharacters: onExtractCurrentPage called")

    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end

    self:checkAndWarnDuplicates(book_id, function()
        local page_text, text_err = self:getCurrentPageText()
        if not page_text then
            self:showMsg("Could not read page text:\n" .. tostring(text_err))
            return
        end
        if #page_text < 20 then
            self:showMsg("Page text too short (" .. #page_text .. " chars).\nTry a page with more text.")
            return
        end

        logger.info("KoCharacters: page text length=" .. #page_text .. " preview=" .. page_text:sub(1,150))

        local working_msg = InfoMessage:new{
            text = "Contacting Gemini AI...\nThis may take a few seconds."
        }
        UIManager:show(working_msg)
        UIManager:forceRePaint()

        local all_chars     = self.db:load(book_id)
        local chars_in_text = {}
        local skip_names    = {}
        local page_lower    = page_text:lower()
        for _, c in ipairs(all_chars) do
            local found = c.name and page_lower:find(c.name:lower(), 1, true)
            if not found and c.aliases then
                for _, alias in ipairs(c.aliases) do
                    if alias ~= "" and page_lower:find(alias:lower(), 1, true) then
                        found = true; break
                    end
                end
            end
            if found then table.insert(chars_in_text, c)
            else table.insert(skip_names, c.name) end
        end
        logger.info("KoCharacters: chars_in_text=" .. #chars_in_text .. " skip=" .. #skip_names)

        local client = GeminiClient:new(api_key)
        local characters, err, usage, book_context
        local ok, call_err = pcall(function()
            characters, err, usage, book_context = client:extractCharacters(
                page_text, skip_names, chars_in_text, self:getExtractionPrompt(),
                self.db:loadBookContext(book_id))
        end)

        UIManager:close(working_msg)
        if ok and not err then self:recordUsage(usage) end

        -- Save book context returned alongside characters (no extra API call)
        if ok and book_context and book_context ~= "" then
            self.db:saveBookContext(book_id, book_context)
        end

        if not ok then
            logger.warn("KoCharacters: pcall error: " .. tostring(call_err))
            self:showMsg("Plugin error:\n" .. tostring(call_err), 8)
            return
        end
        if err then
            logger.warn("KoCharacters: API error: " .. tostring(err))
            self:showMsg("Gemini error:\n" .. tostring(err), 8)
            return
        end
        if not characters or #characters == 0 then
            self:showMsg("No new characters found on this page.", 3)
            return
        end

        local cur_page = self:getCurrentPage()
        self:handleIncomingConflicts(book_id, characters, function(resolved)
            if #resolved > 0 then
                self.db:merge(book_id, resolved, cur_page)
            end
            local parts = { "Extracted " .. #characters .. " character(s):\n" }
            for _, c in ipairs(characters) do
                table.insert(parts, self:formatCharacter(c))
                table.insert(parts, "")
            end
            UIManager:show(TextViewer:new{
                title  = "Extracted Characters",
                text   = table.concat(parts, "\n"),
                width  = math.floor(Screen:getWidth() * 0.9),
                height = math.floor(Screen:getHeight() * 0.85),
            })
        end)
    end)
end

function KoCharacters:onScanChapter()
    logger.info("KoCharacters: onScanChapter called")

    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end

    local start_page, end_page, range_err = self:getCurrentChapterPageRange()
    if range_err then
        self:showMsg("Could not determine chapter range:\n" .. tostring(range_err))
        return
    end

    local page_count   = end_page - start_page + 1
    local scanned      = self.db:loadScannedPages(book_id)
    local unscanned    = 0
    for p = start_page, end_page do if not scanned[p] then unscanned = unscanned + 1 end end
    local skip_note    = unscanned < page_count
        and "\n(" .. (page_count - unscanned) .. " already-scanned page(s) will be skipped)" or ""
    UIManager:show(ConfirmBox:new{
        text    = "Scan chapter from page " .. start_page .. " to " .. end_page
                  .. " (" .. unscanned .. "/" .. page_count .. " page(s) to scan)?" .. skip_note,
        ok_text = "Scan",
        ok_callback = function()
            self:checkAndWarnDuplicates(book_id, function()
                self:doChapterScan(book_id, start_page, end_page)
            end)
        end,
    })
end

function KoCharacters:onScanSpecificChapter()
    logger.info("KoCharacters: onScanSpecificChapter called")

    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end

    local doc = self.ui and self.ui.document
    if not doc then
        self:showMsg("No document open.")
        return
    end

    local ok_toc, toc = pcall(function() return doc:getToc() end)
    if not ok_toc or type(toc) ~= "table" or #toc == 0 then
        self:showMsg("No table of contents found in this book.")
        return
    end

    local total_pages
    pcall(function() total_pages = doc:getPageCount() end)
    total_pages = total_pages or 9999

    -- Build chapter list with page ranges
    local chapters = {}
    for i, entry in ipairs(toc) do
        local start_p = tonumber(entry.page) or 1
        local end_p
        local next_entry = toc[i + 1]
        if next_entry then
            end_p = math.max(start_p, (tonumber(next_entry.page) or start_p + 1) - 1)
        else
            end_p = total_pages
        end
        table.insert(chapters, {
            title    = entry.title or ("Chapter " .. i),
            start_p  = start_p,
            end_p    = end_p,
        })
    end

    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok or not Menu then return end

    local scanned = self.db:loadScannedPages(book_id)

    local self_ref = self
    local items = {}
    for _, ch in ipairs(chapters) do
        local ch_ref = ch
        local total_pages = ch_ref.end_p - ch_ref.start_p + 1
        local scanned_count = 0
        for p = ch_ref.start_p, ch_ref.end_p do
            if scanned[p] then scanned_count = scanned_count + 1 end
        end
        local scan_label = ""
        if scanned_count == total_pages then
            scan_label = " [✓ done]"
        elseif scanned_count > 0 then
            scan_label = " [~ " .. scanned_count .. "/" .. total_pages .. " pages]"
        end
        table.insert(items, {
            text = ch_ref.title .. "  (pp. " .. ch_ref.start_p .. "–" .. ch_ref.end_p .. ")" .. scan_label,
            callback = function()
                local page_count = ch_ref.end_p - ch_ref.start_p + 1
                local ch_scanned = self_ref.db:loadScannedPages(book_id)
                local unscanned  = 0
                for p = ch_ref.start_p, ch_ref.end_p do if not ch_scanned[p] then unscanned = unscanned + 1 end end
                local skip_note  = unscanned < page_count
                    and "\n(" .. (page_count - unscanned) .. " already-scanned page(s) will be skipped)" or ""
                UIManager:show(ConfirmBox:new{
                    text    = 'Scan "' .. ch_ref.title .. '"\n'
                              .. "Pages " .. ch_ref.start_p .. "–" .. ch_ref.end_p
                              .. " (" .. unscanned .. "/" .. page_count .. " page(s) to scan)?" .. skip_note,
                    ok_text = "Scan",
                    ok_callback = function()
                        self_ref:checkAndWarnDuplicates(book_id, function()
                            self_ref:doChapterScan(book_id, ch_ref.start_p, ch_ref.end_p)
                        end)
                    end,
                })
            end,
        })
    end

    UIManager:show(Menu:new{
        title      = "Select Chapter to Scan",
        item_table = items,
        width      = Screen:getWidth(),
        show_parent = self.ui,
    })
end

function KoCharacters:doChapterScan(book_id, start_page, end_page)
    local PAGES_PER_BATCH = 4

    local client         = GeminiClient:new(self:getApiKey())
    local scanned        = self.db:loadScannedPages(book_id)
    local page_count     = end_page - start_page + 1
    local total_batches  = math.ceil(page_count / PAGES_PER_BATCH)
    local total_found    = 0
    local enriched_names = {}
    local progress_msg
    local self_ref       = self

    local function doCleanup()
        if progress_msg then UIManager:close(progress_msg); progress_msg = nil end

        local enriched_list = {}
        for _, c in ipairs(self_ref.db:load(book_id)) do
            if enriched_names[c.name] then table.insert(enriched_list, c) end
        end
        if #enriched_list > 0 then
            local enriched_name_strs = {}
            for _, ec in ipairs(enriched_list) do table.insert(enriched_name_strs, ec.name or "?") end
            local cleanup_msg = InfoMessage:new{
                text = "Cleaning up " .. #enriched_list .. " enriched character(s)..."
            }
            UIManager:show(cleanup_msg)
            UIManager:forceRePaint()

            local cleaned, cerr, cusage
            local cok, ccall_err = pcall(function()
                cleaned, cerr, cusage = client:cleanCharacters(enriched_list)
            end)
            UIManager:close(cleanup_msg)
            if cok and not cerr then self_ref:recordUsage(cusage) end

            if cok and not cerr and cleaned and type(cleaned) == "table" then
                local all_chars = self_ref.db:load(book_id)
                local changed   = false
                for i, cc in ipairs(cleaned) do
                    if cc.name then
                        local apply_msg = InfoMessage:new{
                            text = "Applying cleanup " .. i .. "/" .. #cleaned .. "..."
                        }
                        UIManager:show(apply_msg)
                        UIManager:forceRePaint()
                        for _, orig in ipairs(all_chars) do
                            if orig.name == cc.name then
                                if cc.physical_description ~= nil       then orig.physical_description = cc.physical_description end
                                if cc.personality          ~= nil       then orig.personality          = cc.personality          end
                                if cc.role and cc.role ~= ""            then orig.role                 = cc.role                 end
                                if type(cc.relationships) == "table"    then orig.relationships        = cc.relationships        end
                                changed = true; break
                            end
                        end
                        UIManager:close(apply_msg)
                    end
                end
                if changed then self_ref.db:save(book_id, all_chars) end
            else
                logger.warn("KoCharacters: scan cleanup failed: " .. tostring(ccall_err or cerr))
            end
        end

        self_ref.db:clearPendingCleanup(book_id)
        self_ref:showMsg(
            "Chapter scan complete.\n"
            .. "Batches: " .. total_batches .. " (".. page_count .. " pages, " .. PAGES_PER_BATCH .. " per batch)\n"
            .. "Characters found/updated: " .. total_found,
            6
        )
    end

    -- processBatch collects text from up to PAGES_PER_BATCH pages, sends one
    -- API call, then schedules the next batch via UIManager:scheduleIn to keep
    -- the UI responsive.
    local function processBatch(batch_start)
        if batch_start > end_page then
            doCleanup()
            return
        end

        local batch_end  = math.min(batch_start + PAGES_PER_BATCH - 1, end_page)
        local batch_num  = math.floor((batch_start - start_page) / PAGES_PER_BATCH) + 1

        if progress_msg then UIManager:close(progress_msg) end
        progress_msg = InfoMessage:new{
            text = "Scanning chapter...\nBatch " .. batch_num .. "/" .. total_batches
                   .. " (pages " .. batch_start .. "–" .. batch_end .. ")",
        }
        UIManager:show(progress_msg)
        UIManager:forceRePaint()

        -- Collect text from unscanned pages in this batch
        local texts = {}
        for p = batch_start, batch_end do
            if not scanned[p] then
                local page_text = self_ref:getCurrentPageText(p)
                if page_text and #page_text >= 20 then
                    table.insert(texts, page_text)
                end
                scanned[p] = true  -- update local set so re-used batches stay consistent
            end
        end

        -- Mark all pages in batch as scanned
        self_ref.db:markPagesScanned(book_id, batch_start, batch_end)

        if #texts == 0 then
            logger.info("KoCharacters: batch " .. batch_num .. " had no readable pages, skipping")
            UIManager:scheduleIn(0.5, function() processBatch(batch_end + 1) end)
            return
        end

        local combined_text  = table.concat(texts, "\n---\n")
        local combined_lower = combined_text:lower()
        local all_chars      = self_ref.db:load(book_id)
        local chars_in_text  = {}
        local skip_names     = {}
        for _, c in ipairs(all_chars) do
            local found = c.name and combined_lower:find(c.name:lower(), 1, true)
            if not found and c.aliases then
                for _, alias in ipairs(c.aliases) do
                    if alias ~= "" and combined_lower:find(alias:lower(), 1, true) then
                        found = true; break
                    end
                end
            end
            if found then table.insert(chars_in_text, c)
            else table.insert(skip_names, c.name) end
        end

        local characters, err, usage, book_context
        local ok, call_err = pcall(function()
            characters, err, usage, book_context = client:extractCharacters(
                combined_text, skip_names, chars_in_text, self_ref:getExtractionPrompt(),
                self_ref.db:loadBookContext(book_id))
        end)
        if ok and not err then self_ref:recordUsage(usage) end

        -- Save book context returned alongside characters (no extra API call)
        if ok and book_context and book_context ~= "" then
            self_ref.db:saveBookContext(book_id, book_context)
        end

        if not ok then
            logger.warn("KoCharacters: batch " .. batch_num .. " pcall: " .. tostring(call_err))
        elseif err then
            logger.warn("KoCharacters: batch " .. batch_num .. " api: " .. tostring(err))
        elseif characters and #characters > 0 then
            local ex_chars     = self_ref.db:load(book_id)
            local ic           = findIncomingConflicts(ex_chars, characters)
            local conflict_set = {}
            for _, c in ipairs(ic) do
                conflict_set[(c.new_char.name or ""):lower()] = true
                self_ref.db:enrichCharacter(book_id, c.existing_char.name, c.new_char, batch_end)
                enriched_names[c.existing_char.name] = true
                logger.info("KoCharacters: batch auto-enriched '" .. c.existing_char.name .. "'")
            end
            local remaining = {}
            for _, c in ipairs(characters) do
                if not conflict_set[(c.name or ""):lower()] then table.insert(remaining, c) end
            end
            if #remaining > 0 then self_ref.db:merge(book_id, remaining, batch_end) end
            total_found = total_found + #characters
        end

        UIManager:scheduleIn(3, function() processBatch(batch_end + 1) end)
    end

    processBatch(start_page)
end

function KoCharacters:showCharacterViewer(book_id, char, sort_mode, query, refresh_browser_fn)
    local self_ref = self
    local name     = char.name or "Unknown"

    -- Shared button rows for both viewers
    local function make_buttons(close_fn)
        local others_for_merge = {}
        for _, other in ipairs(self_ref.db:load(book_id)) do
            if other.name ~= name then
                local other_name = other.name
                table.insert(others_for_merge, {
                    text     = other_name,
                    callback = function()
                        UIManager:show(ConfirmBox:new{
                            text        = 'Merge "' .. name .. '" into "' .. other_name .. '"?\n'
                                          .. '"' .. name .. '" will be removed.',
                            ok_text     = "Merge",
                            ok_callback = function()
                                self_ref.db:mergeCharacters(book_id, name, other_name)
                                self_ref:showMsg('"' .. name .. '" merged into "' .. other_name .. '".', 3)
                            end,
                        })
                    end,
                })
            end
        end
        local function do_merge()
            close_fn()
            local ok_m, Menu2 = pcall(require, "ui/widget/menu")
            if ok_m and Menu2 then
                UIManager:show(Menu2:new{
                    title       = 'Merge "' .. name .. '" into...',
                    item_table  = others_for_merge,
                    width       = Screen:getWidth(),
                    show_parent = self_ref.ui,
                })
            end
        end
        local function do_delete()
            close_fn()
            UIManager:show(ConfirmBox:new{
                text        = 'Delete "' .. name .. '" from the character list?',
                ok_text     = "Delete",
                ok_callback = function()
                    self_ref.db:deleteCharacter(book_id, name)
                    self_ref:showMsg(name .. " deleted.", 2)
                end,
            })
        end
        return {
            {
                { text = "Re-analyze", callback = function() close_fn(); self_ref:onReanalyzeCharacter(book_id, char) end },
                { text = "Clean up",   callback = function() close_fn(); self_ref:onCleanCharacter(book_id, char.name) end },
                { text = "Edit",       callback = function()
                    close_fn()
                    local function show_viewer_fn()
                        self_ref:showCharacterViewer(book_id, char, sort_mode, query, refresh_browser_fn)
                    end
                    self_ref:onEditCharacter(book_id, char, refresh_browser_fn, show_viewer_fn)
                end },
            },
            {
                { text = "Gen. portrait", callback = function()
                    close_fn()
                    self_ref:onGeneratePortrait(book_id, char)
                    self_ref:showCharacterViewer(book_id, char, sort_mode, query, refresh_browser_fn)
                end },
                { text = "Merge into...", callback = do_merge },
                { text = "Delete",        callback = do_delete },
            },
        }
    end

    -- HTML viewer using ScrollHtmlWidget
    do
        local ok_s, ScrollHtmlWidget = pcall(require, "ui/widget/scrollhtmlwidget")
        local ok_f, FrameContainer   = pcall(require, "ui/widget/container/framecontainer")
        local ok_c, CenterContainer  = pcall(require, "ui/widget/container/centercontainer")
        local ok_v, VerticalGroup    = pcall(require, "ui/widget/verticalgroup")
        local ok_b, ButtonTable      = pcall(require, "ui/widget/buttontable")
        local Size                   = require("ui/size")
        local Blitbuffer             = require("ffi/blitbuffer")
        local Geom                   = require("ui/geometry")

        if ok_s and ok_f and ok_c and ok_v and ok_b then
            local DataStorage   = require("datastorage")
            local portraits_dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits"

            local portrait_filename = nil
            local portrait_path = self:portraitPath(book_id, char)
            local pf = io.open(portrait_path, "rb")
            if pf then pf:close(); portrait_filename = portrait_path:match("([^/]+)$") end

            local w = Screen:getWidth()  - 8
            local h = Screen:getHeight() - 8
            local border   = 2
            local inner_w  = w - 2*border

            local html_css, html_body = self:formatCharacterHTML(char, portrait_filename, inner_w)

            local dialog_ref = {}
            local function close_fn()
                if dialog_ref[1] then UIManager:close(dialog_ref[1]) end
            end

            local rows = make_buttons(close_fn)
            table.insert(rows[#rows], { text = "Close", callback = function()
                close_fn()
                if refresh_browser_fn then refresh_browser_fn() end
            end })

            local btable   = ButtonTable:new{ width = inner_w, buttons = rows }
            local btable_h = btable:getSize().h
            local inner_h  = h - 2*border

            local html_widget = ScrollHtmlWidget:new{
                html_body               = html_body,
                css                     = html_css,
                html_resource_directory = portraits_dir,
                width                   = inner_w,
                height                  = inner_h - btable_h,
            }

            local frame = FrameContainer:new{
                radius     = Size.radius.window,
                padding    = 0,
                bordersize = border,
                background = Blitbuffer.COLOR_WHITE,
                VerticalGroup:new{
                    align = "left",
                    html_widget,
                    btable,
                },
            }

            local center = CenterContainer:new{
                dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
                frame,
            }

            html_widget.dialog = center
            dialog_ref[1]      = center
            UIManager:show(center)
            return
        end
    end
end

function KoCharacters:onViewCharacters()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end
    if #self.db:load(book_id) == 0 then
        self:showMsg("No characters saved yet for this book.\nUse 'Extract characters from this page' first.")
        return
    end
    self:showCharacterBrowser(book_id, "default", "")
end

function KoCharacters:showCharacterBrowser(book_id, sort_mode, query)
    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok or not Menu then return end

    local all_chars = self.db:load(book_id)
    local self_ref  = self

    -- Filter
    local q = query:lower()
    local filtered = {}
    for _, c in ipairs(all_chars) do
        if q == "" then
            table.insert(filtered, c)
        else
            local hay = table.concat({
                c.name or "", c.role or "",
                c.physical_description or "", c.personality or "",
                c.user_notes or "",
                table.concat(c.aliases or {}, " "),
                table.concat(c.relationships or {}, " "),
            }, " "):lower()
            if hay:find(q, 1, true) then table.insert(filtered, c) end
        end
    end

    -- Spoiler protection: mask characters whose first_seen_page is ahead of current page
    if G_reader_settings:readSetting("kocharacters_spoiler_protection") then
        local cur_page = self:getCurrentPage() or 0
        local masked = {}
        for _, c in ipairs(filtered) do
            if not c.unlocked and c.first_seen_page and c.first_seen_page > cur_page then
                table.insert(masked, { name = "Unknown character (page " .. c.first_seen_page .. ")", _spoiler = true, _real_name = c.name })
            else
                table.insert(masked, c)
            end
        end
        filtered = masked
    end

    -- Sort
    local sorted = {}
    for _, c in ipairs(filtered) do table.insert(sorted, c) end
    if sort_mode == "name" then
        table.sort(sorted, function(a, b)
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    elseif sort_mode == "role" then
        local order = { protagonist = 1, antagonist = 2, supporting = 3, unknown = 4 }
        table.sort(sorted, function(a, b)
            local ra = order[a.role or "unknown"] or 4
            local rb = order[b.role or "unknown"] or 4
            if ra ~= rb then return ra < rb end
            return (a.name or ""):lower() < (b.name or ""):lower()
        end)
    end

    -- Control items (search + sort) pinned at the top
    local items = {}
    local sort_labels = { default = "Added order", name = "Name A→Z", role = "Role" }
    local sort_cycle  = { default = "name", name = "role", role = "default" }

    local search_text = query ~= ""
        and ("Search: \"" .. query .. "\" (" .. #filtered .. "/" .. #all_chars .. ")")
        or  "Search..."
    table.insert(items, {
        text     = "[ " .. search_text .. " ]",
        callback = function()
            local dialog
            dialog = InputDialog:new{
                title      = "Search characters",
                input      = query,
                input_type = "string",
                buttons    = {{
                    {
                        text     = "Clear",
                        callback = function()
                            UIManager:close(dialog)
                            self_ref:showCharacterBrowser(book_id, sort_mode, "")
                        end,
                    },
                    {
                        text     = "Cancel",
                        callback = function() UIManager:close(dialog) end,
                    },
                    {
                        text             = "Search",
                        is_enter_default = true,
                        callback         = function()
                            local q2 = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                            UIManager:close(dialog)
                            self_ref:showCharacterBrowser(book_id, sort_mode, q2)
                        end,
                    },
                }},
            }
            UIManager:show(dialog)
            dialog:onShowKeyboard()
        end,
    })

    table.insert(items, {
        text     = "[ Sort: " .. (sort_labels[sort_mode] or sort_mode) .. " — tap to change ]",
        callback = function()
            self_ref:showCharacterBrowser(book_id, sort_cycle[sort_mode] or "default", query)
        end,
    })

    -- Character items
    for _, c in ipairs(sorted) do
        local name    = c.name or "Unknown"
        local role    = (c.role and c.role ~= "" and c.role ~= "unknown")
                        and (" [" .. c.role .. "]") or ""
        local cleanup = c.needs_cleanup and " *" or ""
        local char = c
        if c._spoiler then
            local real_name = c._real_name
            table.insert(items, {
                text = name,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text        = "Unlock this character and reveal their details?",
                        ok_text     = "Unlock",
                        ok_callback = function()
                            local chars = self_ref.db:load(book_id)
                            for _, ch in ipairs(chars) do
                                if ch.name == real_name then
                                    ch.unlocked = true
                                    self_ref.db:updateCharacter(book_id, real_name, ch)
                                    break
                                end
                            end
                            self_ref:showCharacterBrowser(book_id, sort_mode, query)
                        end,
                    })
                end,
            })
        else
        table.insert(items, {
            text     = name .. role .. cleanup,
            callback = function()
                if not char.unlocked then
                    char.unlocked = true
                    self_ref.db:updateCharacter(book_id, char.name, char)
                end
                self_ref:showCharacterViewer(book_id, char, sort_mode, query, refresh_browser)
            end,
        })
        end  -- else (not spoiler)
    end

    local count_str = query ~= "" and (#filtered .. "/" .. #all_chars) or tostring(#all_chars)
    local browser_menu
    local function refresh_browser()
        UIManager:close(browser_menu)
        self_ref:showCharacterBrowser(book_id, sort_mode, query)
    end
    browser_menu = Menu:new{
        title       = count_str .. " character(s) — " .. self:getBookTitle(),
        item_table  = items,
        width       = Screen:getWidth(),
        show_parent = self.ui,
    }
    UIManager:show(browser_menu)
end

-- Return a safe filename component for a character name
-- Return the full filesystem path to a character's portrait PNG
function KoCharacters:portraitPath(book_id, char)
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits"
    local util = require("util")
    util.makePath(dir)
    local filename = (char.id and char.id ~= "") and (char.id .. ".png")
                     or (portraitSafeName(char.name or "unknown") .. ".png")
    return dir .. "/" .. filename
end

-- Generate and save a portrait using Imagen
-- Core portrait generation logic. Returns nil on success, error string on failure.
function KoCharacters:generatePortraitForChar(book_id, char)
    local DataStorage = require("datastorage")
    local json        = require("dkjson")
    local util        = require("util")
    local portraits_dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits"
    util.makePath(portraits_dir)

    local name  = char.name or "Unknown"
    local role  = (char.role and char.role ~= "" and char.role ~= "unknown") and (char.role) or ""
    local occ   = char.occupation or ""
    local phys  = char.physical_description or ""
    local pers  = char.personality or ""
    local quote = char.first_appearance_quote or ""
    local rels  = (char.relationships and #char.relationships > 0)
                  and table.concat(char.relationships, "; ") or ""

    local function sub(s, key, val)
        return (s:gsub("{{" .. key .. "}}", function() return val end))
    end
    local book_context = CharacterDB:loadBookContext(book_id)
    local tmpl   = self:getPortraitPrompt()
    local prompt = sub(sub(sub(sub(sub(sub(sub(sub(tmpl,
        "name", name), "role", role), "occupation", occ),
        "appearance", phys), "personality", pers),
        "relationships", rels), "context", quote),
        "book_context", book_context)

    local api_key   = self:getImagenApiKey()
    local out_path  = self:portraitPath(book_id, char)
    local req_file  = portraits_dir .. "/.imagen_req.json"
    local resp_file = portraits_dir .. "/.imagen_resp.json"

    local fq = io.open(req_file, "w")
    if not fq then return "Could not write request file." end
    fq:write(json.encode({
        instances  = {{ prompt = prompt }},
        parameters = { sampleCount = 1, aspectRatio = "1:1" },
    }))
    fq:close()

    local imagen_model = G_reader_settings:readSetting("kocharacters_imagen_model") or "imagen-4.0-fast-generate-001"
    local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. imagen_model .. ":predict?key=" .. api_key
    os.execute(string.format(
        'curl -s --max-time 120 -X POST -H "Content-Type: application/json" -d @"%s" "%s" -o "%s"',
        req_file, url, resp_file
    ))
    os.remove(req_file)

    local f = io.open(resp_file, "r")
    if not f then return "No response from Imagen API." end
    local raw = f:read("*a")
    f:close()
    os.remove(resp_file)

    local parsed = json.decode(raw)
    if not parsed then return "Could not parse Imagen response:\n" .. raw:sub(1, 200) end
    if parsed.error then return "Imagen error:\n" .. (parsed.error.message or json.encode(parsed.error)) end

    local b64 = parsed.predictions and parsed.predictions[1] and parsed.predictions[1].bytesBase64Encoded
    if not b64 or b64 == "" then return "Imagen returned no image.\n" .. raw:sub(1, 200) end

    local tmp_b64 = portraits_dir .. "/.tmp_b64"  -- temp file inside the book's portraits dir
    local fb = io.open(tmp_b64, "w")
    if not fb then return "Could not write temp file." end
    fb:write(b64)
    fb:close()

    local ret = os.execute('base64 -d "' .. tmp_b64 .. '" > "' .. out_path .. '"')
    os.remove(tmp_b64)
    if ret ~= 0 then return "Failed to decode portrait image." end

    local portrait_filename = (char.id and char.id ~= "") and (char.id .. ".png")
                              or (portraitSafeName(char.name) .. ".png")
    char.portrait_file = portrait_filename
    self.db:updateCharacter(book_id, char.name, char)
    self:recordUsage({ images = 1 })
    return nil
end

function KoCharacters:onGeneratePortrait(book_id, char)
    local msg = InfoMessage:new{ text = "Generating portrait for " .. (char.name or "character") .. "…" }
    UIManager:show(msg)
    UIManager:forceRePaint()
    local err = self:generatePortraitForChar(book_id, char)
    UIManager:close(msg)
    if err then
        self:showMsg(err, 8)
    else
        self:showMsg("Portrait saved for " .. (char.name or "character") .. ".", 3)
    end
end

-- Check whether a portrait file exists for a character
function KoCharacters:hasPortrait(book_id, char)
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits/"
    if char.portrait_file and char.portrait_file ~= "" then
        local f = io.open(dir .. char.portrait_file, "r")
        if f then f:close(); return true end
    end
    local safe = portraitSafeName(char.name or "")
    for _, ext in ipairs({ ".jpg", ".png" }) do
        local f = io.open(dir .. safe .. ext, "r")
        if f then f:close(); return true end
    end
    return false
end

function KoCharacters:onBatchGeneratePortraits()
    local book_id = self:getBookID()
    if not book_id then self:showMsg("No book open."); return end

    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters saved yet.")
        return
    end

    local ok, Menu = pcall(require, "ui/widget/menu")
    if not ok then return end

    local selected  = {}
    local self_ref  = self
    local menu_ref

    local function showSelectionMenu()
        local n = 0
        for _ in pairs(selected) do n = n + 1 end

        local items = {}
        table.insert(items, {
            text = n > 0 and ("Generate portraits for " .. n .. " character(s)") or "(tap characters to select)",
            callback = function()
                if n == 0 then return end
                UIManager:close(menu_ref)

                local to_gen = {}
                for i, c in ipairs(characters) do
                    if selected[i] then table.insert(to_gen, c) end
                end

                local succeeded, failed = 0, {}
                for idx, char in ipairs(to_gen) do
                    local prog = InfoMessage:new{
                        text = "Generating portrait " .. idx .. "/" .. #to_gen .. "\n" .. (char.name or "")
                    }
                    UIManager:show(prog)
                    UIManager:forceRePaint()
                    local gen_err = self_ref:generatePortraitForChar(book_id, char)
                    UIManager:close(prog)
                    if gen_err then
                        table.insert(failed, (char.name or "?") .. ": " .. gen_err)
                    else
                        succeeded = succeeded + 1
                    end
                end

                local summary = "Done. " .. succeeded .. "/" .. #to_gen .. " portrait(s) saved."
                if #failed > 0 then
                    summary = summary .. "\n\nFailed:\n" .. table.concat(failed, "\n")
                end
                self_ref:showMsg(summary, 6)
            end,
        })

        for i, c in ipairs(characters) do
            local has_img = self_ref:hasPortrait(book_id, c)
            local check   = selected[i] and "[x] " or "[ ] "
            local img_tag = has_img and " [img]" or ""
            local idx     = i
            table.insert(items, {
                text = check .. (c.name or "Unknown") .. img_tag,
                callback = function()
                    selected[idx] = not selected[idx] or nil
                    UIManager:close(menu_ref)
                    showSelectionMenu()
                end,
            })
        end

        menu_ref = Menu:new{
            title       = "Select characters — [img] = portrait exists",
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = self_ref.ui,
        }
        UIManager:show(menu_ref)
    end

    showSelectionMenu()
end

function KoCharacters:onExportCharacters()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book.")
        return
    end
    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters to export yet.")
        return
    end
    local title = self:getBookTitle()
    local DataStorage = require("datastorage")
    local export_path = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/characters.html"

    local function esc(s)
        s = tostring(s or "")
        s = s:gsub("&", "&amp;")
        s = s:gsub("<", "&lt;")
        s = s:gsub(">", "&gt;")
        s = s:gsub('"', "&quot;")
        return s
    end

    local parts = {}
    local function p(s) table.insert(parts, s) end

    p('<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">')
    p('<meta name="viewport" content="width=device-width,initial-scale=1">')
    p('<title>' .. esc(title) .. '</title>')
    p('<style>')
    p('body{font-family:Georgia,serif;max-width:860px;margin:40px auto;padding:0 20px;background:#fdf6e3;color:#333;}')
    p('h1{font-size:1.6em;border-bottom:2px solid #c9a84c;padding-bottom:8px;color:#5a3e1b;}')
    p('.character{display:flex;align-items:stretch;background:#fff;border:1px solid #ddd;border-radius:8px;margin:24px 0;box-shadow:0 2px 8px rgba(0,0,0,.1);overflow:hidden;}')
    p('.char-portrait{flex:0 0 240px;background:#1c1812;border-right:1px solid #e0d8cc;}')
    p('.char-portrait a{display:block;height:100%;}')
    p('.char-portrait img{width:240px;height:100%;object-fit:cover;object-position:top center;display:block;cursor:zoom-in;transition:opacity .15s;}')
    p('.char-portrait img:hover{opacity:.88;}')
    p('.char-info{flex:1;padding:22px 26px;min-width:0;}')
    p('.char-name{font-size:1.35em;font-weight:bold;color:#5a3e1b;margin:0 0 2px;}')
    p('.char-role{font-size:.88em;color:#aaa;font-style:italic;margin:0 0 16px;}')
    p('.field{margin-bottom:12px;}')
    p('.field label{display:block;font-weight:bold;font-size:.78em;text-transform:uppercase;letter-spacing:.07em;color:#bbb;margin-bottom:2px;}')
    p('.field p{margin:0;line-height:1.6;color:#444;}')
    p('.quote{border-left:3px solid #c9a84c;padding-left:12px;color:#888;font-style:italic;}')
    p('#lb{display:none;position:fixed;inset:0;background:rgba(0,0,0,.92);z-index:999;align-items:center;justify-content:center;cursor:zoom-out;}')
    p('#lb.on{display:flex;}')
    p('#lb img{max-width:92vw;max-height:92vh;object-fit:contain;border-radius:4px;box-shadow:0 8px 40px rgba(0,0,0,.7);}')
    p('@media(max-width:580px){.character{flex-direction:column;}.char-portrait{flex:none;width:100%;border-right:none;border-bottom:1px solid #e0d8cc;}.char-portrait img{width:100%;height:260px;}.char-info{padding:16px;}}')
    p('</style></head><body>')
    p('<div id="lb" onclick="this.classList.remove(\'on\')"><img id="lb-img" src="" alt=""></div>')
    p('<h1>' .. esc(title) .. '</h1>')
    p('<p style="color:#888;font-size:.85em;">' .. #characters .. ' character(s)</p>')
    p('<nav style="background:#fff;border:1px solid #ddd;border-radius:6px;padding:16px 20px;margin-bottom:24px;">')
    p('<div style="font-weight:bold;font-size:.85em;text-transform:uppercase;letter-spacing:.05em;color:#999;margin-bottom:8px;">Characters</div>')
    p('<ol style="margin:0;padding-left:20px;column-count:2;column-gap:2em;">')
    for _, c in ipairs(characters) do
        local anchor = esc(c.name or "Unknown"):gsub("%s+", "-"):lower()
        local role = (c.role and c.role ~= "") and (' <span style="color:#aaa;font-size:.85em;">— ' .. esc(c.role) .. '</span>') or ""
        p('<li style="margin-bottom:4px;"><a href="#' .. anchor .. '" style="color:#5a3e1b;text-decoration:none;">' .. esc(c.name or "Unknown") .. '</a>' .. role .. '</li>')
    end
    p('</ol></nav>')

    for _, c in ipairs(characters) do
        local anchor = esc(c.name or "Unknown"):gsub("%s+", "-"):lower()
        p('<div class="character" id="' .. anchor .. '">')
        -- Embed portrait if one has been generated
        -- Prefer the stored portrait_file (survives renames), fall back to name-based lookup
        local portrait_rel
        local portraits_base = "portraits/"
        local portraits_abs  = DataStorage:getDataDir() .. "/kocharacters/" .. book_id .. "/portraits/"
        if c.portrait_file and c.portrait_file ~= "" then
            local pf = io.open(portraits_abs .. c.portrait_file, "r")
            if pf then pf:close(); portrait_rel = portraits_base .. c.portrait_file end
        end
        if not portrait_rel then
            local safe_name = portraitSafeName(c.name or "Unknown")
            for _, ext in ipairs({ ".jpg", ".png" }) do
                local pf = io.open(portraits_abs .. safe_name .. ext, "r")
                if pf then pf:close(); portrait_rel = portraits_base .. safe_name .. ext; break end
            end
        end
        -- Portrait (left column) — emitted first in DOM so it appears on the left in the flex row
        if portrait_rel then
            local img_src = portrait_rel
            local alt     = esc(c.name or "Unknown")
            p('<div class="char-portrait">')
            p('<a href="' .. img_src .. '" onclick="event.preventDefault();document.getElementById(\'lb-img\').src=this.href;document.getElementById(\'lb\').classList.add(\'on\');">')
            p('<img src="' .. img_src .. '" alt="Portrait of ' .. alt .. '">')
            p('</a>')
            p('</div>')
        end
        -- Info (right column)
        p('<div class="char-info">')
        p('<div class="char-name">' .. esc(c.name or "Unknown") .. '</div>')
        if c.role and c.role ~= "" then
            p('<div class="char-role">' .. esc(c.role) .. '</div>')
        end
        if c.occupation and c.occupation ~= "" then
            p('<div class="field"><label>Occupation</label><p>' .. esc(c.occupation) .. '</p></div>')
        end
        if c.aliases and #c.aliases > 0 then
            p('<div class="field aliases"><label>Also known as</label><p>' .. esc(table.concat(c.aliases, ", ")) .. '</p></div>')
        end
        if c.physical_description and c.physical_description ~= "" then
            p('<div class="field"><label>Appearance</label><p>' .. esc(c.physical_description) .. '</p></div>')
        end
        if c.personality and c.personality ~= "" then
            p('<div class="field"><label>Personality</label><p>' .. esc(c.personality) .. '</p></div>')
        end
        if c.relationships and #c.relationships > 0 then
            local rel_parts = {}
            for _, r in ipairs(c.relationships) do table.insert(rel_parts, esc(r)) end
            p('<div class="field relationships"><label>Relationships</label><p>' .. table.concat(rel_parts, "<br>") .. '</p></div>')
        end
        if c.first_appearance_quote and c.first_appearance_quote ~= "" then
            p('<div class="field"><label>First seen</label><p class="quote">&ldquo;' .. esc(c.first_appearance_quote) .. '&rdquo;</p></div>')
        end
        if c.user_notes and c.user_notes ~= "" then
            p('<div class="field" style="border-top:1px dashed #e0c97a;margin-top:10px;padding-top:10px;"><label>My notes</label><p style="white-space:pre-wrap;">' .. esc(c.user_notes) .. '</p></div>')
        end
        if c.source_page then
            p('<div style="margin-top:10px;font-size:.8em;color:#bbb;">Last updated: page ' .. esc(tostring(c.source_page)) .. '</div>')
        end
        p('</div>')
        p('</div>')
    end

    p('</body></html>')

    local f = io.open(export_path, "w")
    if not f then
        self:showMsg("Could not write file:\n" .. export_path)
        return
    end
    f:write(table.concat(parts, "\n"))
    f:close()
    self:showMsg("Exported to:\n" .. export_path, 5)
end

function KoCharacters:onExportZip()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book.")
        return
    end
    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters to export yet.")
        return
    end

    local msg = InfoMessage:new{ text = "Building ZIP…" }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local DataStorage = require("datastorage")
    local base_dir    = DataStorage:getDataDir() .. "/kocharacters/" .. book_id
    local html_path   = base_dir .. "/characters.html"
    local zip_path    = base_dir .. "/characters.zip"

    -- Generate the HTML (same as onExportCharacters but silent)
    self:onExportCharacters()  -- writes characters.html inside base_dir

    -- Remove old zip if present
    os.remove(zip_path)

    -- Build zip: HTML + portraits folder, paths relative to base_dir
    -- BusyBox zip: zip -r <zipfile> <files...> from inside base_dir
    local cmd = string.format(
        'cd "%s" && zip -r "characters.zip" "characters.html" "portraits" 2>/dev/null; echo $?',
        base_dir
    )
    local handle = io.popen(cmd)
    local result = handle and handle:read("*a") or ""
    if handle then handle:close() end

    UIManager:close(msg)

    local exit_code = tonumber(result:match("%d+$") or "1")
    if exit_code ~= 0 then
        -- portraits dir might not exist (no images yet) — try without it
        cmd = string.format(
            'cd "%s" && zip "characters.zip" "characters.html" 2>/dev/null; echo $?',
            base_dir
        )
        handle = io.popen(cmd)
        result = handle and handle:read("*a") or ""
        if handle then handle:close() end
        exit_code = tonumber(result:match("%d+$") or "1")
    end

    if exit_code ~= 0 then
        self:showMsg("ZIP creation failed.\nIs 'zip' available on this device?", 6)
        return
    end

    self:showMsg("ZIP saved to:\n" .. zip_path, 6)
end

function KoCharacters:onUploadToServer()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book.")
        return
    end
    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters to upload yet.")
        return
    end

    local endpoint = G_reader_settings:readSetting("kocharacters_upload_endpoint") or ""
    local api_key  = G_reader_settings:readSetting("kocharacters_upload_api_key") or ""
    if endpoint == "" then
        self:showMsg("No upload endpoint configured.\nGo to Settings → Export settings.")
        return
    end

    local msg = InfoMessage:new{ text = "Preparing upload…" }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local DataStorage = require("datastorage")
    local json        = require("dkjson")
    local util        = require("util")
    local base_dir    = DataStorage:getDataDir() .. "/kocharacters/" .. book_id
    local archive_name = (book_id:match("^(.-)_%d+$") or book_id) .. ".tar.gz"
    local archive_path = base_dir .. "/" .. archive_name

    local function fileExists(path)
        local f = io.open(path, "r")
        if f then f:close(); return true end
        return false
    end

    -- -----------------------------------------------------------------------
    -- Step 1: Build book_meta.json from doc_settings
    -- -----------------------------------------------------------------------
    local meta = {}
    if self.ui and self.ui.doc_settings then
        local ok, props = pcall(function() return self.ui.doc_settings:readSetting("doc_props") end)
        if ok and props then
            meta.title        = props.title or ""
            meta.authors      = props.authors or ""
            meta.series       = props.series or ""
            meta.series_index = props.series_index
            meta.language     = props.language or ""
            -- Strip HTML tags from description
            if props.description then
                meta.description = props.description:gsub("<[^>]+>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
            end
            -- Parse identifiers string into a table
            if props.identifiers then
                local ids = {}
                for line in (props.identifiers .. "\n"):gmatch("([^\n]+)\n") do
                    local k, v = line:match("^([^:]+):(.+)$")
                    if k and v then ids[k:lower()] = v end
                end
                if next(ids) then meta.identifiers = ids end
            end
            -- Keywords into array
            if props.keywords then
                local kw = {}
                for line in (props.keywords .. "\n"):gmatch("([^\n]+)\n") do
                    local w = line:match("^%s*(.-)%s*$")
                    if w ~= "" then table.insert(kw, w) end
                end
                if #kw > 0 then meta.keywords = kw end
            end
        end
        local ok2, pages = pcall(function() return self.ui.doc_settings:readSetting("doc_pages") end)
        if ok2 and pages then meta.total_pages = pages end
        local ok3, pct = pcall(function() return self.ui.doc_settings:readSetting("percent_finished") end)
        if ok3 and pct then meta.percent_finished = math.floor(pct * 1000 + 0.5) / 10 end
        local ok4, summary = pcall(function() return self.ui.doc_settings:readSetting("summary") end)
        if ok4 and summary then
            meta.reading_status = summary.status
            meta.last_read      = summary.modified
        end
        local ok5, stats = pcall(function() return self.ui.doc_settings:readSetting("stats") end)
        if ok5 and stats then
            meta.highlights = stats.highlights or 0
            meta.notes      = stats.notes or 0
        end
    end
    meta.book_context = self.db:loadBookContext(book_id)

    -- Partial MD5 used by KOReader progress sync (KOSync)
    if self.ui then
        local ok_md5, md5val = pcall(function()
            return self.ui.doc_settings and self.ui.doc_settings:readSetting("partial_md5_checksum")
        end)
        if ok_md5 and md5val and md5val ~= "" then
            meta.partial_md5 = md5val
        else
            local ok_fd, digest = pcall(function()
                return self.ui.document and self.ui.document:fastDigest()
            end)
            if ok_fd and digest and digest ~= "" then meta.partial_md5 = digest end
        end
    end

    local meta_path = base_dir .. "/book_meta.json"

    -- -----------------------------------------------------------------------
    -- Step 2: Extract cover image from epub (meta.cover set here, then written)
    -- -----------------------------------------------------------------------
    local cover_path = base_dir .. "/cover.jpg"
    os.remove(cover_path)
    local epub_path = (self.ui and self.ui.document and self.ui.document.file) or ""
    if epub_path ~= "" then
        -- Find cover image path in OPF manifest
        local opf_raw = ""
        local h = io.popen(string.format('unzip -p "%s" "*.opf" 2>/dev/null', epub_path))
        if h then opf_raw = h:read("*a") or ""; h:close() end

        -- Try properties="cover-image" first, then <meta name="cover">
        local cover_item = opf_raw:match('<item[^>]+properties="cover%-image"[^>]+href="([^"]+)"')
                        or opf_raw:match('<item[^>]+href="([^"]+)"[^>]+properties="cover%-image"')
        if not cover_item then
            local cover_id = opf_raw:match('<meta[^>]+name="cover"[^>]+content="([^"]+)"')
                          or opf_raw:match('<meta[^>]+content="([^"]+)"[^>]+name="cover"')
            if cover_id then
                -- Escape Lua pattern magic chars in cover_id (e.g. "-" is a pattern quantifier)
                local cover_id_pat = cover_id:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
                cover_item = opf_raw:match('<item[^>]+id="' .. cover_id_pat .. '"[^>]+href="([^"]+)"')
                          or opf_raw:match('<item[^>]+href="([^"]+)"[^>]+id="' .. cover_id_pat .. '"')
            end
        end

        -- If no OPF match, pick the largest jpg in the epub as a fallback
        if not cover_item then
            local list_h = io.popen(string.format('unzip -l "%s" 2>/dev/null | grep -i "\\.jpg"', epub_path))
            if list_h then
                local best_size, best_name = 0, nil
                for line in list_h:lines() do
                    -- Format: "  <size>  <date> <time>   <filename>"
                    -- Capture size and the trailing filename (no spaces in between at end)
                    local size, name = line:match("^%s*(%d+)%s+%S+%s+%S+%s+(.+%.jpg)%s*$")
                    size = tonumber(size) or 0
                    if size > best_size then best_size = size; best_name = name end
                end
                list_h:close()
                if best_name then cover_item = best_name end
            end
        end

        if cover_item then
            -- Try to read the cover image via io.popen (avoids shell redirection issues)
            local function extractCover(path_in_zip)
                local ph = io.popen(string.format(
                    'unzip -p "%s" "%s" 2>/dev/null', epub_path, path_in_zip), "r")
                if not ph then return false end
                local data = ph:read("*a"); ph:close()
                if not data or #data < 4 then return false end
                -- Validate magic bytes before writing
                local b1, b2, b3 = data:byte(1), data:byte(2), data:byte(3)
                local is_jpeg = (b1 == 0xFF and b2 == 0xD8)
                local is_png  = (b1 == 0x89 and b2 == 0x50 and b3 == 0x4E)
                if not is_jpeg and not is_png then return false end
                local wf = io.open(cover_path, "wb")
                if not wf then return false end
                wf:write(data); wf:close()
                return true
            end

            local ok_cover = extractCover(cover_item)
            logger.info("KoCharacters: upload cover_item=" .. tostring(cover_item) .. " ok=" .. tostring(ok_cover))
            -- If cover_item was relative (no directory component), try with OEBPS/ prefix
            if not ok_cover and not cover_item:find("/") then
                ok_cover = extractCover("OEBPS/" .. cover_item)
                logger.info("KoCharacters: upload cover OEBPS fallback ok=" .. tostring(ok_cover))
            end
            if ok_cover then meta.cover = "cover.jpg" end
        else
            logger.info("KoCharacters: upload cover_item not found in OPF")
        end
    end

    local mf = io.open(meta_path, "w")
    if mf then mf:write(json.encode(meta, { indent = true })); mf:close() end

    -- -----------------------------------------------------------------------
    -- Step 3: Build tar.gz with all files
    -- -----------------------------------------------------------------------
    os.remove(archive_path)
    local files = '"characters.json" "book_meta.json"'
    if fileExists(cover_path)                             then files = files .. ' "cover.jpg"' end
    if fileExists(base_dir .. "/portraits")               then files = files .. ' "portraits"' end
    logger.info("KoCharacters: upload tar files=" .. files)

    os.execute(string.format('cd "%s" && tar -czf "%s" %s 2>/dev/null', base_dir, archive_name, files))
    if not fileExists(archive_path) then
        os.execute(string.format('cd "%s" && tar -czf "%s" "characters.json" "book_meta.json" 2>/dev/null', base_dir, archive_name))
    end

    -- Clean up temp files
    os.remove(meta_path)
    os.remove(cover_path)

    if not fileExists(archive_path) then
        UIManager:close(msg)
        self:showMsg("Failed to create upload archive.", 5)
        return
    end

    -- Upload via curl
    UIManager:close(msg)
    msg = InfoMessage:new{ text = "Uploading to server…" }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local code_file = base_dir .. "/.curl_code"
    local curl_cmd
    if api_key ~= "" then
        curl_cmd = string.format(
            'curl -s -k --tlsv1.2 --ciphers DEFAULT -o /dev/null -w "%%{http_code}" --max-time 60 -F "file=@%s" -H "X-Api-Key: %s" "%s" > "%s"',
            archive_path, api_key, endpoint, code_file
        )
    else
        curl_cmd = string.format(
            'curl -s -k --tlsv1.2 --ciphers DEFAULT -o /dev/null -w "%%{http_code}" --max-time 60 -F "file=@%s" "%s" > "%s"',
            archive_path, endpoint, code_file
        )
    end

    os.execute(curl_cmd)
    os.remove(archive_path)

    local http_code = "0"
    local fc = io.open(code_file, "r")
    if fc then http_code = fc:read("*a") or "0"; fc:close() end
    os.remove(code_file)

    UIManager:close(msg)

    local code = tonumber(http_code:match("%d+") or "0") or 0
    if code >= 200 and code < 300 then
        self:showMsg("Upload successful. (" .. tostring(code) .. ")", 4)
    elseif code == 0 then
        self:showMsg("Upload failed: no response.\nCheck the endpoint URL and network.", 6)
    else
        self:showMsg("Upload failed: HTTP " .. tostring(code) .. ".\nCheck endpoint and API key.", 6)
    end
end

function KoCharacters:onCleanupAllCharacters()
    local book_id = self:getBookID()
    if not book_id then return end
    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters to clean up.", 3)
        return
    end

    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    -- Count flagged characters
    local flagged = {}
    for _, c in ipairs(characters) do
        if c.needs_cleanup then table.insert(flagged, c) end
    end
    local n_flagged = #flagged
    local n_all     = #characters

    local self_ref = self

    -- Step 2: after text cleanup, optionally run merge detection
    local function runMergeDetection() self_ref:onMergeDetection() end

    local BATCH_SIZE = G_reader_settings:readSetting("kocharacters_cleanup_batch_size") or 5

    local function runCleanup(chars_to_clean)
        local client    = GeminiClient:new(api_key)
        local all_chars = self.db:load(book_id)
        local changed   = false
        local total     = #chars_to_clean

        local i = 1
        while i <= total do
            local batch = {}
            for j = i, math.min(i + BATCH_SIZE - 1, total) do
                table.insert(batch, chars_to_clean[j])
            end

            local batch_end = math.min(i + BATCH_SIZE - 1, total)
            local working_msg = InfoMessage:new{
                text = "Cleaning up characters " .. i .. "–" .. batch_end .. " of " .. total .. "..."
            }
            UIManager:show(working_msg)
            UIManager:forceRePaint()

            local cleaned, err, usage
            local ok, call_err = pcall(function()
                cleaned, err, usage = client:cleanCharacters(batch)
            end)
            UIManager:close(working_msg)
            if ok and not err then self_ref:recordUsage(usage) end

            if not ok then
                self_ref:showMsg("Plugin error:\n" .. tostring(call_err), 8)
                return
            end
            if err then
                self_ref:showMsg("Gemini error:\n" .. tostring(err), 8)
                return
            end

            if cleaned and type(cleaned) == "table" then
                for idx, cc in ipairs(cleaned) do
                    if cc.name then
                        local apply_msg = InfoMessage:new{
                            text = "Applying cleanup " .. (i + idx - 1) .. "/" .. total .. ": " .. cc.name .. "..."
                        }
                        UIManager:show(apply_msg)
                        UIManager:forceRePaint()
                        for _, orig in ipairs(all_chars) do
                            if orig.name == cc.name then
                                if cc.physical_description ~= nil    then orig.physical_description = cc.physical_description end
                                if cc.personality          ~= nil    then orig.personality          = cc.personality          end
                                if cc.role and cc.role ~= ""         then orig.role                 = cc.role                 end
                                if type(cc.relationships) == "table" then orig.relationships        = cc.relationships        end
                                orig.needs_cleanup = nil
                                changed = true; break
                            end
                        end
                        UIManager:close(apply_msg)
                    end
                end
            end

            i = i + BATCH_SIZE
            if i <= total then
                os.execute("sleep 3")
            end
        end

        if changed then self_ref.db:save(book_id, all_chars) end
        self_ref.db:clearPendingCleanup(book_id)
        if G_reader_settings:readSetting("kocharacters_detect_dupes_after_cleanup") then
            runMergeDetection()
        else
            self_ref:showMsg("Cleanup complete.", 4)
        end
    end

    -- Ask the user which characters to clean up
    local dialog
    local flagged_label = n_flagged > 0
        and ("Flagged only (" .. n_flagged .. ")")
        or  "Flagged only (none)"
    dialog = TextViewer:new{
        title  = "Cleanup scope",
        text   = n_flagged .. " of " .. n_all .. " character(s) flagged for cleanup.",
        width  = math.floor(Screen:getWidth() * 0.85),
        height = math.floor(Screen:getHeight() * 0.4),
        buttons_table = {{
            {
                text     = flagged_label,
                enabled  = n_flagged > 0,
                callback = function()
                    UIManager:close(dialog)
                    runCleanup(flagged)
                end,
            },
            {
                text     = "All (" .. n_all .. ")",
                callback = function()
                    UIManager:close(dialog)
                    runCleanup(characters)
                end,
            },
            {
                text     = "Cancel",
                callback = function() UIManager:close(dialog) end,
            },
        }},
    }
    UIManager:show(dialog)
end

function KoCharacters:onMergeDetection()
    local book_id = self:getBookID()
    if not book_id then return end

    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local all_chars = self.db:load(book_id)
    if #all_chars < 2 then
        self:showMsg("Not enough characters to merge.", 3)
        return
    end

    local self_ref = self

    local detect_msg = InfoMessage:new{ text = "Checking for duplicate characters..." }
    UIManager:show(detect_msg)
    UIManager:forceRePaint()

    local slim_chars = {}
    for _, c in ipairs(all_chars) do
        table.insert(slim_chars, {
            name                 = c.name,
            aliases              = c.aliases,
            physical_description = c.physical_description,
            personality          = c.personality,
            role                 = c.role,
            occupation           = c.occupation,
            relationships        = c.relationships,
        })
    end

    local client = GeminiClient:new(api_key)
    local groups, derr, dusage
    local dok, dcall_err = pcall(function()
        groups, derr, dusage = client:detectMergeGroups(slim_chars, self_ref:getMergeDetectionPrompt())
    end)
    UIManager:close(detect_msg)
    if dok and not derr then self_ref:recordUsage(dusage) end

    if not dok then
        self_ref:showMsg("Plugin error:\n" .. tostring(dcall_err), 8)
        return
    end
    if derr then
        self_ref:showMsg("Gemini error:\n" .. tostring(derr), 8)
        return
    end
    if not groups or #groups == 0 then
        self_ref:showMsg("No duplicate characters detected.", 4)
        return
    end

    -- Filter out groups where any name no longer exists in the DB
    local valid_groups = {}
    local name_set = {}
    for _, c in ipairs(all_chars) do name_set[c.name] = true end
    for _, g in ipairs(groups) do
        if g.keep and name_set[g.keep] and type(g.absorb) == "table" then
            local valid = true
            for _, a in ipairs(g.absorb) do
                if not name_set[a] then valid = false; break end
            end
            if valid and #g.absorb > 0 then
                table.insert(valid_groups, g)
            end
        end
    end

    if #valid_groups == 0 then
        self_ref:showMsg("No duplicate characters detected.", 4)
        return
    end

    local group_idx = 1
    local merged_count = 0

    local function applyNext()
        if group_idx > #valid_groups then
            local msg = merged_count > 0
                and (merged_count .. " character(s) merged.")
                or  "No characters merged."
            self_ref:showMsg(msg, 4)
            return
        end

        local g = valid_groups[group_idx]
        group_idx = group_idx + 1

        local absorb_names = table.concat(g.absorb, ", ")
        local reason = g.reason or "similar profiles"
        local confirm_text = string.format(
            'Merge %d of %d\n\n"%s" and "%s" appear to be the same character.\n\nReason: %s\n\nMerge into "%s"?',
            group_idx - 1, #valid_groups,
            g.keep, absorb_names,
            reason, g.keep
        )

        UIManager:show(ConfirmBox:new{
            text        = confirm_text,
            ok_text     = "Merge",
            cancel_text = "Skip",
            ok_callback = function()
                for _, src in ipairs(g.absorb) do
                    self_ref.db:mergeCharacters(book_id, src, g.keep)
                    merged_count = merged_count + 1
                end
                applyNext()
            end,
            cancel_callback = function()
                applyNext()
            end,
        })
    end

    applyNext()
end

function KoCharacters:onClearDatabase()
    local book_id = self:getBookID()
    if not book_id then return end
    UIManager:show(ConfirmBox:new{
        text        = "Delete all saved characters for this book?",
        ok_text     = "Delete",
        ok_callback = function()
            self.db:clear(book_id)
            self.db:clearScannedPages(book_id)
            self.db:clearPendingCleanup(book_id)
            self:showMsg("Character database cleared.", 3)
        end,
    })
end

function KoCharacters:onOpenSettings()
    local self_ref = self

    local function openAISettings()
        local ai_menu
        ai_menu = Menu:new{
            title      = "AI Settings",
            item_table = {
                {
                    text     = "Gemini Character Extraction key",
                    callback = function() self_ref:onSetExtractionApiKey() end,
                },
                {
                    text     = "Gemini Image Generation key",
                    callback = function() self_ref:onSetApiKey() end,
                },
                {
                    text_func = function()
                        local m = G_reader_settings:readSetting("kocharacters_imagen_model") or "imagen-4.0-fast-generate-001"
                        return "Imagen model: " .. m
                    end,
                    callback = function()
                        local model_menu
                        local items = {}
                        for _, m in ipairs({
                            "imagen-4.0-fast-generate-001",
                            "imagen-4.0-generate-001",
                            "imagen-4.0-ultra-generate-001",
                        }) do
                            local model = m
                            table.insert(items, {
                                text     = model,
                                callback = function()
                                    G_reader_settings:saveSetting("kocharacters_imagen_model", model)
                                    UIManager:close(model_menu)
                                    UIManager:close(ai_menu)
                                    openAISettings()
                                end,
                            })
                        end
                        model_menu = Menu:new{
                            title       = "Select Imagen Model",
                            item_table  = items,
                            width       = Screen:getWidth(),
                            show_parent = self_ref.ui,
                        }
                        UIManager:show(model_menu)
                    end,
                },
                {
                    text     = "Edit extraction prompt",
                    callback = function() self_ref:onEditPrompt(
                        "Extraction Prompt", "kocharacters_extraction_prompt",
                        GeminiClient.DEFAULT_EXTRACTION_PROMPT) end,
                },
                {
                    text     = "Edit cleanup prompt",
                    callback = function() self_ref:onEditPrompt(
                        "Cleanup Prompt", "kocharacters_cleanup_prompt",
                        GeminiClient.DEFAULT_CLEANUP_PROMPT) end,
                },
                {
                    text     = "Edit re-analyze prompt",
                    callback = function() self_ref:onEditPrompt(
                        "Re-analyze Prompt", "kocharacters_reanalyze_prompt",
                        GeminiClient.DEFAULT_REANALYZE_PROMPT) end,
                },
                {
                    text     = "Edit relationship map prompt",
                    callback = function() self_ref:onEditPrompt(
                        "Relationship Map Prompt", "kocharacters_relationship_map_prompt",
                        GeminiClient.DEFAULT_RELATIONSHIP_MAP_PROMPT) end,
                },
                {
                    text     = "Edit portrait prompt",
                    callback = function() self_ref:onEditPrompt(
                        "Portrait Prompt", "kocharacters_portrait_prompt",
                        DEFAULT_PORTRAIT_PROMPT) end,
                },
                {
                    text     = "Edit merge detection prompt",
                    callback = function() self_ref:onEditPrompt(
                        "Merge Detection Prompt", "kocharacters_merge_detection_prompt",
                        GeminiClient.DEFAULT_MERGE_DETECTION_PROMPT) end,
                },
                {
                    text     = "View book context (auto-built)",
                    callback = function()
                        local bid = self_ref:getBookID()
                        if not bid then self_ref:showMsg("No book open."); return end
                        local ctx = self_ref.db:loadBookContext(bid)
                        if not ctx or ctx == "" then
                            self_ref:showMsg("No book context yet.\nScan pages or chapters to build it automatically.")
                            return
                        end
                        UIManager:show(ConfirmBox:new{
                            text        = "Book context:\n\n" .. ctx .. "\n\nClear this context?",
                            ok_text     = "Clear",
                            cancel_text = "Keep",
                            ok_callback = function()
                                os.remove(self_ref.db:bookContextPath(bid))
                                self_ref:showMsg("Book context cleared.", 2)
                            end,
                        })
                    end,
                },
            },
            width       = Screen:getWidth(),
            show_parent = self_ref.ui,
        }
        UIManager:show(ai_menu)
    end

    local settings_menu
    settings_menu = Menu:new{
        title      = "KoCharacters Settings",
        item_table = {
            {
                text     = "AI Settings",
                callback = function() openAISettings() end,
            },
            {
                text_func = function()
                    return "Auto-extract on page turn: "
                        .. (G_reader_settings:readSetting("kocharacters_auto_extract") and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_auto_extract")
                    G_reader_settings:saveSetting("kocharacters_auto_extract", not on)
                    UIManager:close(settings_menu)
                    self_ref:onOpenSettings()
                end,
            },
            {
                text_func = function()
                    return "Auto-extract delay: "
                        .. (G_reader_settings:readSetting("kocharacters_auto_extract_delay") or 10) .. "s"
                end,
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        title      = "Auto-extract delay (seconds)",
                        input      = tostring(G_reader_settings:readSetting("kocharacters_auto_extract_delay") or 10),
                        input_type = "number",
                        buttons    = {{
                            { text = "Cancel", callback = function() UIManager:close(dialog) end },
                            {
                                text             = "Save",
                                is_enter_default = true,
                                callback         = function()
                                    local val = tonumber(dialog:getInputText())
                                    UIManager:close(dialog)
                                    if val and val > 0 then
                                        G_reader_settings:saveSetting("kocharacters_auto_extract_delay", val)
                                        UIManager:close(settings_menu)
                                        self_ref:onOpenSettings()
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
            {
                text_func = function()
                    return "Cleanup batch size: "
                        .. (G_reader_settings:readSetting("kocharacters_cleanup_batch_size") or 5)
                end,
                callback = function()
                    local dialog
                    dialog = InputDialog:new{
                        title      = "Characters per cleanup batch",
                        input      = tostring(G_reader_settings:readSetting("kocharacters_cleanup_batch_size") or 5),
                        input_type = "number",
                        buttons    = {{
                            { text = "Cancel", callback = function() UIManager:close(dialog) end },
                            {
                                text             = "Save",
                                is_enter_default = true,
                                callback         = function()
                                    local val = tonumber(dialog:getInputText())
                                    UIManager:close(dialog)
                                    if val and val >= 1 then
                                        G_reader_settings:saveSetting("kocharacters_cleanup_batch_size", math.floor(val))
                                        UIManager:close(settings_menu)
                                        self_ref:onOpenSettings()
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
            {
                text_func = function()
                    return "Detect duplicates after cleanup: "
                        .. (G_reader_settings:readSetting("kocharacters_detect_dupes_after_cleanup") and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_detect_dupes_after_cleanup")
                    G_reader_settings:saveSetting("kocharacters_detect_dupes_after_cleanup", not on)
                    UIManager:close(settings_menu)
                    self_ref:onOpenSettings()
                end,
            },
            {
                text_func = function()
                    return "Scan indicator icon: "
                        .. (G_reader_settings:readSetting("kocharacters_scan_indicator") ~= false and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_scan_indicator") ~= false
                    G_reader_settings:saveSetting("kocharacters_scan_indicator", not on)
                    UIManager:close(settings_menu)
                    self_ref:onOpenSettings()
                end,
            },
            {
                text_func = function()
                    return "Auto-accept enrichments: "
                        .. (G_reader_settings:readSetting("kocharacters_auto_enrich") and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_auto_enrich")
                    G_reader_settings:saveSetting("kocharacters_auto_enrich", not on)
                    UIManager:close(settings_menu)
                    self_ref:onOpenSettings()
                end,
            },
            {
                text_func = function()
                    return "Spoiler protection: "
                        .. (G_reader_settings:readSetting("kocharacters_spoiler_protection") and "ON" or "OFF")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_spoiler_protection")
                    G_reader_settings:saveSetting("kocharacters_spoiler_protection", not on)
                    UIManager:close(settings_menu)
                    self_ref:onOpenSettings()
                end,
            },
            {
                text_func = function()
                    return "Character detail view: "
                        .. (G_reader_settings:readSetting("kocharacters_html_viewer") and "HTML (with portrait)" or "Text")
                end,
                callback = function()
                    local on = G_reader_settings:readSetting("kocharacters_html_viewer")
                    G_reader_settings:saveSetting("kocharacters_html_viewer", not on)
                    UIManager:close(settings_menu)
                    self_ref:onOpenSettings()
                end,
            },
            {
                text     = "View API usage",
                callback = function() self:onViewUsage() end,
            },
            {
                text     = "Clear character database",
                callback = function() self:onClearDatabase() end,
            },
            {
                text     = "Reset prompts to default",
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text        = "Reset all prompts to their built-in defaults?",
                        ok_text     = "Reset",
                        ok_callback = function()
                            G_reader_settings:delSetting("kocharacters_extraction_prompt")
                            G_reader_settings:delSetting("kocharacters_cleanup_prompt")
                            G_reader_settings:delSetting("kocharacters_reanalyze_prompt")
                            G_reader_settings:delSetting("kocharacters_relationship_map_prompt")
                            G_reader_settings:delSetting("kocharacters_portrait_prompt")
                            G_reader_settings:delSetting("kocharacters_merge_detection_prompt")
                            self:showMsg("Prompts reset to defaults.", 2)
                        end,
                    })
                end,
            },
            {
                text     = "Export settings",
                callback = function()
                    local self_ref = self
                    local function inputDialog(title, setting_key, hint, on_save)
                        local dialog
                        dialog = InputDialog:new{
                            title      = title,
                            input      = G_reader_settings:readSetting(setting_key) or "",
                            input_hint = hint,
                            buttons    = {{
                                { text = "Cancel", callback = function() UIManager:close(dialog) end },
                                {
                                    text = "Save", is_enter_default = true,
                                    callback = function()
                                        local val = (dialog:getInputText() or ""):match("^%s*(.-)%s*$") or ""
                                        G_reader_settings:saveSetting(setting_key, val)
                                        UIManager:close(dialog)
                                        if on_save then on_save(val) end
                                    end,
                                },
                            }},
                        }
                        UIManager:show(dialog)
                        dialog:onShowKeyboard()
                    end
                    local export_settings_menu
                    export_settings_menu = Menu:new{
                        title      = "Export Settings",
                        item_table = {
                            {
                                text     = "Upload endpoint URL",
                                callback = function()
                                    inputDialog(
                                        "Upload endpoint URL",
                                        "kocharacters_upload_endpoint",
                                        "https://example.com/api/upload",
                                        function() self_ref:showMsg("Endpoint saved.", 2) end
                                    )
                                end,
                            },
                            {
                                text     = "Upload API key",
                                callback = function()
                                    inputDialog(
                                        "Upload API key",
                                        "kocharacters_upload_api_key",
                                        "your-secret-key",
                                        function() self_ref:showMsg("API key saved.", 2) end
                                    )
                                end,
                            },
                        },
                        width       = Screen:getWidth(),
                        show_parent = self_ref.ui,
                    }
                    UIManager:show(export_settings_menu)
                end,
            },
            {
                text     = "About",
                callback = function()
                    local meta = require("_meta")
                    UIManager:show(TextViewer:new{
                        title = "About KoCharacters",
                        text  = "KoCharacters v" .. (meta.version or "?") .. "\n\n"
                             .. "Automatically extract, track, and enrich character profiles from your books using Google Gemini AI. "
                             .. "Generate portraits with Google Imagen. Runs on KOReader on Kindle and other supported devices.\n\n"
                             .. "\xC2\xA9 2026\nNefelodamon\n\n"
                             .. "https://github.com/nefelodamon/KoCharacters",
                        width  = math.floor(Screen:getWidth() * 0.9),
                        height = math.floor(Screen:getHeight() * 0.6),
                    })
                end,
            },
        },
        width       = Screen:getWidth(),
        show_parent = self.ui,
    }
    UIManager:show(settings_menu)
end

function KoCharacters:onSetExtractionApiKey()
    local current_key = G_reader_settings:readSetting("kocharacters_extraction_api_key") or ""
    local dialog
    dialog = InputDialog:new{
        title       = "Gemini Character Extraction Key",
        input       = current_key,
        input_hint  = "AIza...",
        description = "API key used for character extraction, cleanup,\nand relationship mapping.\nGet a free key at aistudio.google.com",
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(dialog) end },
            {
                text = "Save", is_enter_default = true,
                callback = function()
                    local key = (dialog:getInputText() or ""):match("^%s*(.-)%s*$") or ""
                    G_reader_settings:saveSetting("kocharacters_extraction_api_key", key)
                    UIManager:close(dialog)
                    self:showMsg("Character extraction key saved.", 2)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KoCharacters:onSetApiKey()
    local current_key = G_reader_settings:readSetting("kocharacters_imagen_api_key") or ""
    local dialog
    dialog = InputDialog:new{
        title       = "Gemini Image Generation Key",
        input       = current_key,
        input_hint  = "AIza...",
        description = "API key used for portrait generation (Imagen).\nGet a key at aistudio.google.com",
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(dialog) end },
            {
                text = "Save", is_enter_default = true,
                callback = function()
                    local key = (dialog:getInputText() or ""):match("^%s*(.-)%s*$") or ""
                    G_reader_settings:saveSetting("kocharacters_imagen_api_key", key)
                    UIManager:close(dialog)
                    self:showMsg("Image generation key saved.", 2)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KoCharacters:onSetHFToken()
    local current = G_reader_settings:readSetting("kocharacters_hf_token") or ""
    local dialog
    dialog = InputDialog:new{
        title       = "HuggingFace Token",
        input       = current,
        input_hint  = "hf_...",
        description = "Enter your HuggingFace access token.\nFree at huggingface.co — used for portrait generation.",
        buttons = {
            {
                { text = "Cancel", callback = function() UIManager:close(dialog) end },
                {
                    text             = "Save",
                    is_enter_default = true,
                    callback         = function()
                        local token = (dialog:getInputText() or ""):match("^%s*(.-)%s*$")
                        G_reader_settings:saveSetting("kocharacters_hf_token", token)
                        UIManager:close(dialog)
                        self:showMsg("HuggingFace token saved.", 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KoCharacters:onEditPrompt(title, setting_key, default_prompt)
    local current = G_reader_settings:readSetting(setting_key) or default_prompt
    local is_custom = G_reader_settings:readSetting(setting_key) ~= nil
    local label = is_custom and "Custom prompt active" or "Using default prompt"
    local dialog
    dialog = InputDialog:new{
        title       = title,
        input       = current,
        description = label .. "\nExtraction: {{existing}} {{skip}} {{text}}\nRe-analyze/Cleanup: {{character}} {{text}}\nPortrait: {{name}} {{role}} {{appearance}} {{personality}} {{relationships}} {{context}}",
        allow_newline = true,
        buttons = {
            {
                {
                    text     = "Cancel",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text     = "Reset",
                    callback = function()
                        UIManager:close(dialog)
                        G_reader_settings:delSetting(setting_key)
                        self:showMsg("Prompt reset to default.", 2)
                    end,
                },
                {
                    text             = "Save",
                    is_enter_default = true,
                    callback         = function()
                        local text = dialog:getInputText() or ""
                        G_reader_settings:saveSetting(setting_key, text)
                        UIManager:close(dialog)
                        self:showMsg("Prompt saved.", 2)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function KoCharacters:onDebugPageText()
    if not self.ui or not self.ui.document then
        self:showMsg("No document open.")
        return
    end

    local lines = {}

    -- Document type
    table.insert(lines, "Doc file: " .. tostring(self.ui.document.file))
    table.insert(lines, "Doc type: " .. tostring(self.ui.document.dc_language or self.ui.document.ext or "?"))

    -- Page number
    local page
    pcall(function() page = self.ui.view.state.page end)
    table.insert(lines, "Page: " .. tostring(page))

    -- Try getPageText
    local ok1, result1 = pcall(function()
        return self.ui.document:getPageText(page)
    end)
    table.insert(lines, "getPageText ok=" .. tostring(ok1))
    if ok1 then
        table.insert(lines, "getPageText type=" .. type(result1))
        if type(result1) == "string" then
            table.insert(lines, "getPageText len=" .. #result1)
            table.insert(lines, "preview: " .. result1:sub(1, 80))
        elseif type(result1) == "table" then
            table.insert(lines, "getPageText #=" .. #result1)
            -- Show first entry structure
            local first = result1[1]
            if first then
                table.insert(lines, "first entry type=" .. type(first))
                if type(first) == "table" then
                    table.insert(lines, "first[1] type=" .. type(first[1]))
                    if type(first[1]) == "table" then
                        table.insert(lines, "first[1].word=" .. tostring(first[1].word))
                        table.insert(lines, "first[1].text=" .. tostring(first[1].text))
                    end
                end
            end
        else
            table.insert(lines, "value=" .. tostring(result1))
        end
    else
        table.insert(lines, "error: " .. tostring(result1))
    end

    -- Try getTextBoxes on current page and neighbors
    for _, p in ipairs({page, page-1, page+1}) do
        local ok2, result2 = pcall(function()
            return self.ui.document:getTextBoxes(p)
        end)
        local tag = "getTextBoxes[p=" .. tostring(p) .. "] ok=" .. tostring(ok2)
        if ok2 and type(result2) == "table" then
            tag = tag .. " #lines=" .. #result2
            -- Count words and show sample
            local word_count = 0
            local sample = {}
            for _, line in ipairs(result2) do
                if type(line) == "table" then
                    for _, w in ipairs(line) do
                        if type(w) == "table" and w.word then
                            word_count = word_count + 1
                            if #sample < 5 then table.insert(sample, w.word) end
                        end
                    end
                end
            end
            tag = tag .. " #words=" .. word_count
            if #sample > 0 then
                tag = tag .. "\nsample: " .. table.concat(sample, " ")
            end
        elseif not ok2 then
            tag = tag .. " err=" .. tostring(result2):sub(1,60)
        end
        table.insert(lines, tag)
    end

    -- EPUB uses CreDocument engine - probe its specific methods
    local cre_methods = {
        "getTextFromPositions",
        "getPageLinks",
        "drawCurrentViewByPage",
        "getVisiblePageCount",
        "getPageFromXPointer",
        "getCurrentPos",
        "getXPointer",
        "getPosFromXPointer",
        "getDocumentFileContent",
    }
    for _, m in ipairs(cre_methods) do
        local has = type(self.ui.document[m]) == "function"
        if has then table.insert(lines, "has method: " .. m) end
    end

    -- Test full strategy: getPageXPointer -> getPosFromXPointer -> getTextBoxesFromPositions
    local ok_xp1, xp_cur  = pcall(function() return self.ui.document:getPageXPointer(page or 114) end)
    local ok_xp2, xp_next = pcall(function() return self.ui.document:getPageXPointer((page or 114) + 1) end)
    table.insert(lines, "getPageXPointer(cur) ok=" .. tostring(ok_xp1) .. " val=" .. tostring(xp_cur):sub(1,35))
    table.insert(lines, "getPageXPointer(next) ok=" .. tostring(ok_xp2) .. " val=" .. tostring(xp_next):sub(1,35))

    local pos_s, pos_e
    if ok_xp1 then
        local ok3, p = pcall(function() return self.ui.document:getPosFromXPointer(xp_cur) end)
        table.insert(lines, "getPosFromXPointer(cur) ok=" .. tostring(ok3) .. " val=" .. tostring(p))
        if ok3 then pos_s = p end
    end
    if ok_xp2 then
        local ok4, p = pcall(function() return self.ui.document:getPosFromXPointer(xp_next) end)
        table.insert(lines, "getPosFromXPointer(next) ok=" .. tostring(ok4) .. " val=" .. tostring(p))
        if ok4 then pos_e = p end
    end

    if pos_s then
        local ok5, boxes = pcall(function()
            return self.ui.document:getTextBoxesFromPositions(pos_s, pos_e or pos_s + 5000)
        end)
        table.insert(lines, "getTextBoxesFromPositions ok=" .. tostring(ok5))
        if ok5 and type(boxes) == "table" then
            table.insert(lines, "#boxes=" .. #boxes)
        elseif not ok5 then
            table.insert(lines, "err=" .. tostring(boxes):sub(1,60))
        end
    end

    -- Probe getDocumentFileContent with various arg types
    local frag_idx = tostring(xp_cur or ""):match("DocFragment%[(%d+)%]")
    table.insert(lines, "frag_idx=" .. tostring(frag_idx))

    -- Try with number
    local ok_a, r_a = pcall(function() return self.ui.document:getDocumentFileContent(tonumber(frag_idx)) end)
    table.insert(lines, "getDocFC(number) ok=" .. tostring(ok_a) .. " type=" .. type(r_a))

    -- Try with string index
    local ok_b, r_b = pcall(function() return self.ui.document:getDocumentFileContent(frag_idx) end)
    table.insert(lines, "getDocFC(string) ok=" .. tostring(ok_b) .. " type=" .. type(r_b))

    -- Try getDocumentFilePath or similar
    for _, m in ipairs({"getDocumentFilePath","getFilePath","getImageContent","getToc","getMetadata"}) do
        local has = type(self.ui.document[m]) == "function"
        if has then table.insert(lines, "has: " .. m) end
    end

    -- Try getToc to see structure
    local ok_t, toc = pcall(function() return self.ui.document:getToc() end)
    table.insert(lines, "getToc ok=" .. tostring(ok_t))
    if ok_t and type(toc) == "table" then
        table.insert(lines, "toc #=" .. #toc)
        if toc[1] then
            local keys = {}
            for k,v in pairs(toc[1]) do table.insert(keys, k.."="..tostring(v):sub(1,20)) end
            table.insert(lines, "toc[1]: " .. table.concat(keys, " "))
        end
    end

    -- Try getPageLinks which might reveal file paths
    local ok_l, links = pcall(function() return self.ui.document:getPageLinks(page or 114) end)
    table.insert(lines, "getPageLinks ok=" .. tostring(ok_l))
    if ok_l and type(links) == "table" then
        table.insert(lines, "links #=" .. #links)
        if links[1] then
            local keys = {}
            for k,v in pairs(links[1]) do table.insert(keys, k.."="..tostring(v):sub(1,20)) end
            table.insert(lines, "link[1]: " .. table.concat(keys, " "))
        end
    end

    UIManager:show(TextViewer:new{
        title  = "Debug Info",
        text   = table.concat(lines, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

function KoCharacters:onReanalyzeCharacter(book_id, char)
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local page_text, perr = self:getCurrentPageText()
    if not page_text then
        self:showMsg("Could not get page text:\n" .. tostring(perr))
        return
    end

    local working_msg = InfoMessage:new{ text = 'Re-analyzing "' .. char.name .. '"...' }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local characters, api_err, usage
    local ok, call_err = pcall(function()
        characters, api_err, usage = client:reanalyzeCharacter(
            page_text, char, self:getReanalyzePrompt())
    end)

    UIManager:close(working_msg)
    if ok and not api_err then self:recordUsage(usage) end

    if not ok then
        self:showMsg("Plugin error:\n" .. tostring(call_err), 8)
        return
    end
    if api_err then
        self:showMsg("Gemini error:\n" .. tostring(api_err), 8)
        return
    end
    if not characters or #characters == 0 then
        self:showMsg('"' .. char.name .. '" was not found on this page.', 4)
        return
    end

    self.db:merge(book_id, characters, self:getCurrentPage())
    self:showMsg('"' .. char.name .. '" updated.', 3)
end

function KoCharacters:onReanalyzeCharacterPicker()
    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end
    local characters = self.db:load(book_id)
    if #characters == 0 then
        self:showMsg("No characters saved yet.")
        return
    end

    local self_ref = self
    local items = {}
    for _, c in ipairs(characters) do
        local char = c
        local role = (c.role and c.role ~= "") and (" [" .. c.role .. "]") or ""
        table.insert(items, {
            text     = (c.name or "Unknown") .. role,
            callback = function()
                self_ref:onReanalyzeCharacter(book_id, char)
            end,
        })
    end

    local ok, Menu = pcall(require, "ui/widget/menu")
    if ok and Menu then
        UIManager:show(Menu:new{
            title       = "Re-analyze which character?",
            item_table  = items,
            width       = Screen:getWidth(),
            show_parent = self.ui,
        })
    end
end

function KoCharacters:onCleanCharacter(book_id, char_name)
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local characters = self.db:load(book_id)
    local char = nil
    for _, c in ipairs(characters) do
        if c.name == char_name then char = c; break end
    end
    if not char then self:showMsg("Character not found.", 3); return end

    local working_msg = InfoMessage:new{ text = 'Cleaning up "' .. char_name .. '"...' }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local result, err, usage
    local ok, call_err = pcall(function()
        result, err, usage = client:cleanCharacter(char, self:getCleanupPrompt())
    end)

    UIManager:close(working_msg)
    if ok and not err then self:recordUsage(usage) end

    if not ok then self:showMsg("Error:\n" .. tostring(call_err), 6); return end
    if err    then self:showMsg("Gemini error:\n" .. tostring(err), 6); return end

    -- Apply cleaned fields back to the character
    if result.physical_description then char.physical_description = result.physical_description end
    if result.personality          then char.personality          = result.personality          end
    if result.role and result.role ~= "" then char.role = result.role end
    if result.relationships and type(result.relationships) == "table" then
        char.relationships = result.relationships
    end
    char.needs_cleanup = nil

    self.db:updateCharacter(book_id, char_name, char)
    self:showMsg('"' .. char_name .. '" cleaned up.', 3)
end

function KoCharacters:onShowLimits()
    local api_key = self:getApiKey()
    if api_key == "" then
        self:showMsg("No Gemini API key set.\nGo to KoCharacters > Settings.")
        return
    end

    local working_msg = InfoMessage:new{ text = "Fetching model info from Gemini..." }
    UIManager:show(working_msg)
    UIManager:forceRePaint()

    local client = GeminiClient:new(api_key)
    local info, err
    local ok, call_err = pcall(function()
        info, err = client:fetchModelInfo()
    end)

    UIManager:close(working_msg)

    if not ok then
        self:showMsg("Error:\n" .. tostring(call_err), 6)
        return
    end
    if err then
        self:showMsg("API error:\n" .. tostring(err), 6)
        return
    end

    local lines = {}
    table.insert(lines, "Model")
    table.insert(lines, "  Name:    " .. (info.displayName or info.name or "unknown"))
    table.insert(lines, "  Version: " .. (info.name or ""):match("models/(.+)$") or "?")
    table.insert(lines, "")
    table.insert(lines, "Per-request token limits")
    table.insert(lines, "  Input:   " .. tostring(info.inputTokenLimit  or "?"))
    table.insert(lines, "  Output:  " .. tostring(info.outputTokenLimit or "?"))
    table.insert(lines, "")
    table.insert(lines, "Free tier rate limits")
    table.insert(lines, "  15   requests / minute  (RPM)")
    table.insert(lines, "  500  requests / day     (RPD)")
    table.insert(lines, "  250,000  tokens / minute  (TPM)")
    table.insert(lines, "")
    table.insert(lines, "Note: live usage is not exposed by the API.")
    table.insert(lines, "Check aistudio.google.com to monitor usage.")

    UIManager:show(TextViewer:new{
        title  = "Gemini API Limits",
        text   = table.concat(lines, "\n"),
        width  = math.floor(Screen:getWidth() * 0.9),
        height = math.floor(Screen:getHeight() * 0.85),
    })
end

-- ---------------------------------------------------------------------------
-- Word-selection character lookup (called from highlight popup)
-- ---------------------------------------------------------------------------
function KoCharacters:onWordCharacterLookup(word)
    if not word or word == "" then
        self:showMsg("No word selected.")
        return
    end

    local book_id = self:getBookID()
    if not book_id then
        self:showMsg("Cannot identify book — is a document open?")
        return
    end

    local all_chars = self.db:load(book_id)
    if #all_chars == 0 then
        self:showMsg("No characters saved yet for this book.\nUse 'Extract characters from this page' first.")
        return
    end

    -- Build a list of search tokens from the selected text:
    -- always include the full phrase, plus each individual word (3+ chars, skip stopwords)
    local stop = { the=1, a=1, an=1, of=1, ["in"]=1, at=1, to=1, ["and"]=1, ["or"]=1, ["for"]=1,
                   with=1, by=1, on=1, from=1, is=1, was=1, he=1, she=1, his=1, her=1 }
    local word_lower = word:lower()
    local tokens = { word_lower }
    for w in word_lower:gmatch("%a+") do
        if #w >= 3 and not stop[w] then
            table.insert(tokens, w)
        end
    end

    local function charMatches(c)
        local name_l = (c.name or ""):lower()
        for _, tok in ipairs(tokens) do
            if name_l:find(tok, 1, true) then return true end
        end
        for _, alias in ipairs(c.aliases or {}) do
            local alias_l = alias:lower()
            for _, tok in ipairs(tokens) do
                if alias_l:find(tok, 1, true) then return true end
            end
        end
        return false
    end

    local matches = {}
    for _, c in ipairs(all_chars) do
        if charMatches(c) then table.insert(matches, c) end
    end

    if #matches == 0 then
        self:showMsg('"' .. word .. '" not found in character database.')
        return
    end

    if #matches == 1 then
        local char = matches[1]
        local self_ref = self
        local viewer
        viewer = TextViewer:new{
            title  = char.name,
            text   = self:formatCharacter(char),
            width  = math.floor(Screen:getWidth() * 0.9),
            height = math.floor(Screen:getHeight() * 0.85),
            buttons_table = {
                {
                    {
                        text     = "Generate Portrait",
                        callback = function()
                            UIManager:close(viewer)
                            self_ref:onGeneratePortrait(book_id, char)
                        end,
                    },
                    {
                        text     = "Merge into...",
                        callback = function()
                            UIManager:close(viewer)
                            local others = {}
                            for _, other in ipairs(self_ref.db:load(book_id)) do
                                if other.name ~= char.name then
                                    local other_name = other.name
                                    table.insert(others, {
                                        text     = other_name,
                                        callback = function()
                                            UIManager:show(ConfirmBox:new{
                                                text        = 'Merge "' .. char.name .. '" into "' .. other_name .. '"?\n'
                                                              .. 'Their info will be combined and "' .. char.name .. '" removed.',
                                                ok_text     = "Merge",
                                                ok_callback = function()
                                                    self_ref.db:mergeCharacters(book_id, char.name, other_name)
                                                    self_ref:showMsg('"' .. char.name .. '" merged into "' .. other_name .. '".', 3)
                                                end,
                                            })
                                        end,
                                    })
                                end
                            end
                            UIManager:show(Menu:new{
                                title       = 'Merge "' .. char.name .. '" into...',
                                item_table  = others,
                                width       = Screen:getWidth(),
                                show_parent = self_ref.ui,
                            })
                        end,
                    },
                    {
                        text     = "Delete Character",
                        callback = function()
                            UIManager:close(viewer)
                            UIManager:show(ConfirmBox:new{
                                text        = 'Delete "' .. char.name .. '" from the character list?',
                                ok_text     = "Delete",
                                ok_callback = function()
                                    self_ref.db:deleteCharacter(book_id, char.name)
                                    self_ref:showMsg(char.name .. " deleted.", 2)
                                end,
                            })
                        end,
                    },
                },
                {
                    {
                        text     = "Re-analyze",
                        callback = function()
                            UIManager:close(viewer)
                            self_ref:onReanalyzeCharacter(book_id, char)
                        end,
                    },
                    {
                        text     = "Clean up",
                        callback = function()
                            UIManager:close(viewer)
                            self_ref:onCleanCharacter(book_id, char.name)
                        end,
                    },
                    {
                        text     = "Edit",
                        callback = function()
                            UIManager:close(viewer)
                            self_ref:onEditCharacter(book_id, char)
                        end,
                    },
                },
            },
        }
        UIManager:show(viewer)
        return
    end

    -- Multiple matches — open browser pre-filtered by the selected word
    self:showCharacterBrowser(book_id, "default", word)
end

return KoCharacters
