script_name('BattlePass Helper')
script_author('TheMY3')
script_version('1.2.0')

-- Тема на форуме (актуальная версия, обсуждение): https://www.blast.hk/threads/257000/

local imgui = require 'mimgui'
local moonloader = require 'moonloader'  -- Needed for moonloader.download_status (self-update).
local sampev = require 'samp.events'
local inicfg = require 'inicfg'
local effil = require 'effil'
local encoding = require 'encoding'
encoding.default = 'UTF-8'
local cyr = encoding.CP1251

local fa_ok, fa = pcall(require, 'fAwesome6')
local vk_ok, vkeys = pcall(require, 'vkeys')

local new = imgui.new

-- =========================================================================
-- Constants
-- =========================================================================

local TAG = '{FFD700}[TM] BattlePass Helper{FFFFFF}: '
local FORUM_URL = 'https://www.blast.hk/threads/257000/'  -- Manual fallback when self-update fails.
local API_URL = 'https://server-api.arizona.games/client/json/table/get?project=arizona&server=1&key=bp_mission_default'

-- inicfg wants a path relative to moonloader/config, io and createDirectory want an absolute one, so both are built from the same piece.
local CFG_SUB = 'TheMY3/battlepass'
local CFG_PATH = CFG_SUB .. '/config.ini'
local CFG_DIR = getWorkingDirectory() .. '\\config\\' .. (CFG_SUB:gsub('/', '\\'))
local CATALOG_PATH = CFG_DIR .. '\\catalog.json'

local REFRESH_COOLDOWN = 1
local REFRESH_TIMEOUT = 8 -- how long we wait for the data burst.
local SNAPSHOT_FRESH = 60 -- a snapshot younger than this needs no refresh on /bp.

-- Trebuchet MS Bold, the very face mimgui bakes as its default: the smallest preset is indistinguishable from having no setting at all. Bold for the descriptions too - over grass and sand a regular weight loses even with a shadow, and the hierarchy rests on size and colour anyway.
local FONT_FILE = 'trebucbd.ttf'
-- `width` is fixed rather than measured from the longest line: descriptions wrap, and a window sized to the titles alone would squeeze them into a tall narrow column.
local FONT_PRESETS = {
    { name = 'мелкий', title = 14, desc = 12, width = 360 },
    { name = 'средний', title = 17, desc = 15, width = 380 },
    { name = 'крупный', title = 20, desc = 18, width = 425 },
}

local COL_TEXT = imgui.ImVec4(1.00, 1.00, 1.00, 1.00)
local COL_PINNED = imgui.ImVec4(1.00, 0.84, 0.00, 1.00)
local COL_DONE = imgui.ImVec4(0.50, 0.80, 0.50, 1.00)
local COL_DIM = imgui.ImVec4(0.82, 0.82, 0.86, 1.00)
local COL_MUTED = imgui.ImVec4(0.66, 0.66, 0.70, 1.00)
local COL_ALERT = imgui.ImVec4(1.00, 0.42, 0.35, 1.00)
local COL_SHADOW = imgui.ImVec4(0.00, 0.00, 0.00, 0.95)
local COL_BAR = imgui.ImVec4(0.26, 0.59, 0.98, 0.90)

-- =========================================================================
-- State
-- =========================================================================

local catalog = {} -- id -> catalog entry.
local catalogCount = 0
local catalogError = nil
local catalogLoading = false

local quests = {} -- active quests, built from the last snapshot.
local sorted = {} -- display order, rebuilt on demand.
local listDirty = true

local bp = { level = 0, exp = 0, maxExp = 0, resetAt = 0, seasonEnd = 0 }
local snapshotAt = nil -- os.time() when the last progress snapshot arrived.

local lastProgress = nil -- last raw snapshot, re-applied after a catalog reload.
local weOpened = false -- true while our own refresh is in flight.
local refreshDeadline = 0
local lastRefreshAt = -math.huge

local winOn = new.bool(false) -- overlay is on at all.
local windowMode = new.bool(false) -- false = overlay, true = window.

local DESC_NONE, DESC_PINNED, DESC_ALL = 0, 1, 2
local cfgDesc = new.int(DESC_PINNED) -- descriptions shown in the overlay.
local cfgFont = new.int(1) -- index into FONT_PRESETS.
local cfgBg = new.float(0.0) -- overlay background opacity, 0 keeps it fully transparent.

local fonts = {} -- [preset] = {title = ImFont, desc = ImFont}, empty when the file is missing.
local fontDesc = nil -- description font of the mode being rendered right now.

local geomDirty = true -- window has to be repositioned on the next frame.
local bindTarget = nil -- 'toggle' or 'refresh' while waiting for a key.
local bindHeld = nil -- key whose press was spent on a binding, still held down.

local applyProgress -- forward declaration: the catalog loader re-applies snapshots.

-- =========================================================================
-- Config
-- =========================================================================

local config = inicfg.load({
    settings = {
        toggle_key = 120, -- overlay <-> window.
        refresh_key = 90, -- refresh the progress.
        overlay_desc = 1, -- 0 none, 1 pinned only, 2 all.
        overlay_font = 1, -- index into FONT_PRESETS.
        overlay_bg = 0.0, -- background opacity of the overlay, 0 = none.
        -- Window mode: centred by default, moved and resized by hand.
        win_x = -1, win_y = -1,
        win_w = 490, win_h = 560,
        -- Overlay: anchored by its top right corner. Height follows the content and width comes from the font preset, so only the position is kept here.
        ovl_x = -1, ovl_y = -1,
    },
    state = {
        cycle = 0, -- timestampMissionTime the pins/hides belong to.
        pinned = '',
        hidden = '',
        blacklist = '',
    },
}, CFG_PATH)

local pinned, hidden, blacklist = {}, {}, {}

-- Comma separated id list -> set.
local function parseIds(str)
    local set = {}
    for id in tostring(str or ''):gmatch('%d+') do set[tonumber(id)] = true end
    return set
end

-- Set -> comma separated id list, sorted for a stable diff.
local function dumpIds(set)
    local list = {}
    for id in pairs(set) do list[#list + 1] = id end
    table.sort(list)
    return table.concat(list, ',')
end

local function saveConfig()
    config.settings.overlay_desc = cfgDesc[0]
    config.settings.overlay_font = cfgFont[0]
    config.settings.overlay_bg = cfgBg[0]
    config.state.pinned = dumpIds(pinned)
    config.state.hidden = dumpIds(hidden)
    config.state.blacklist = dumpIds(blacklist)
    if not doesDirectoryExist(CFG_DIR) then createDirectory(CFG_DIR) end
    inicfg.save(config, CFG_PATH)
end

pinned = parseIds(config.state.pinned)
hidden = parseIds(config.state.hidden)
blacklist = parseIds(config.state.blacklist)
cfgDesc[0] = tonumber(config.settings.overlay_desc) or DESC_PINNED
cfgFont[0] = math.min(math.max(tonumber(config.settings.overlay_font) or 1, 1), #FONT_PRESETS)
cfgBg[0] = math.min(math.max(tonumber(config.settings.overlay_bg) or 0, 0), 1)

local function keyLabel(vk)
    if vk_ok then
        local ok, name = pcall(vkeys.id_to_name, vk)
        if ok and name and name ~= '' then return name end
    end
    return 'VK' .. tostring(vk)
end

-- =========================================================================
-- Helpers
-- =========================================================================

local function chat(msg)
    sampAddChatMessage(TAG .. cyr(msg), -1)
end

-- Whole file as a string, or nil when it is not there. Shared by the catalog cache and the self-update region.
local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

-- This fAwesome6 build knows the official names only with underscores instead of hyphens: eye-slash is dead, eye_slash works. Callers may write either.
local function icon(name, fallback)
    if not fa_ok then return fallback end
    local ok, glyph = pcall(fa, (name:gsub('-', '_')))
    if ok and glyph and glyph ~= '' then return glyph end
    return fallback
end

-- Spelled out rather than "1:51": a bare colon reads as either hours or minutes.
local function formatLeft(seconds)
    if seconds <= 0 then return nil end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then return string.format('%d ч %d мин', h, m) end
    if m > 0 then return string.format('%d мин', m) end
    return 'меньше минуты'
end

local function formatAgo(ts)
    if not ts then return nil end
    local mins = math.floor((os.time() - ts) / 60)
    if mins < 1 then return 'только что' end
    if mins < 60 then return mins .. ' мин назад' end
    return math.floor(mins / 60) .. ' ч назад'
end

local function isStale()
    return bp.resetAt > 0 and os.time() >= bp.resetAt
end

-- =========================================================================
-- Catalog: HTTP + disk cache
-- =========================================================================

-- Fills `catalog` from a raw JSON body. Returns false when it does not parse.
local function applyCatalog(body)
    local ok, list = pcall(decodeJson, body)
    if not ok or type(list) ~= 'table' or #list == 0 then return false end

    catalog, catalogCount = {}, 0
    for _, item in ipairs(list) do
        if item.id then
            catalog[item.id] = item
            catalogCount = catalogCount + 1
        end
    end
    return catalogCount > 0
end

local function saveCatalog(body)
    if not doesDirectoryExist(CFG_DIR) then createDirectory(CFG_DIR) end
    local f = io.open(CATALOG_PATH, 'wb')
    if not f then return end
    f:write(body)
    f:close()
end

local function loadCatalogFromDisk()
    local body = readFile(CATALOG_PATH)
    return body and applyCatalog(body) or false
end

-- Runs the request in a separate thread: ssl.https blocks.
local function httpRunner()
    return effil.thread(function(url)
        local https = require 'ssl.https'
        local ok, body, code = pcall(https.request, url)
        if not ok then return { false, tostring(body) } end
        if code ~= 200 then return { false, 'HTTP ' .. tostring(code) } end
        return { true, body }
    end)
end

local function downloadCatalog(onDone)
    if catalogLoading then return end
    catalogLoading = true
    catalogError = nil

    local ok, thread = pcall(httpRunner(), API_URL)
    if not ok then
        catalogLoading = false
        catalogError = 'не удалось запустить поток'
        return
    end

    lua_thread.create(function()
        local r = thread:get(0)
        while not r do
            r = thread:get(0)
            wait(0)
        end
        thread:cancel(0)
        catalogLoading = false

        if not r[1] then
            catalogError = tostring(r[2])
            chat('Каталог не скачался: ' .. catalogError)
            return
        end
        if not applyCatalog(r[2]) then
            catalogError = 'ответ не разобрался'
            chat('Каталог не разобрался')
            return
        end

        saveCatalog(r[2])
        listDirty = true
        chat('Каталог обновлён: ' .. catalogCount .. ' заданий')

        if onDone then
            onDone()
        elseif lastProgress then
            -- Rebuild the list from the snapshot we already have: no need to open the pass again just because the catalog changed.
            applyProgress(lastProgress)
        end
    end)
end

-- =========================================================================
-- Quest list
-- =========================================================================

local function isDone(q)
    return q.curr >= q.max
end

local function percent(q)
    if q.max <= 0 then return 0 end
    return math.min(q.curr / q.max, 1.0)
end

-- Same order inside any group: started first and the closest to done on top, untouched ones after in server order. Ids break ties so the list cannot shuffle between rebuilds.
local function sortGroup(list)
    local started, rest = {}, {}
    for _, q in ipairs(list) do
        if q.curr > 0 then started[#started + 1] = q else rest[#rest + 1] = q end
    end
    table.sort(started, function(a, b)
        local pa, pb = percent(a), percent(b)
        return pa > pb or (pa == pb and a.id < b.id)
    end)
    for _, q in ipairs(rest) do started[#started + 1] = q end
    return started
end

local function rebuildList()
    local pin, active, done = {}, {}, {}
    local hid, black = {}, {}

    for _, q in ipairs(quests) do
        if blacklist[q.id] then
            black[#black + 1] = q
        elseif isDone(q) then
            done[#done + 1] = q
        elseif hidden[q.id] then
            hid[#hid + 1] = q
        elseif pinned[q.id] then
            pin[#pin + 1] = q
        else
            active[#active + 1] = q
        end
    end

    sorted = { pin = sortGroup(pin), active = sortGroup(active), done = done,
        hidden = hid, black = black }

    -- Blacklisted and hidden quests drop out of the counter entirely.
    local total, complete = 0, 0
    for _, q in ipairs(quests) do
        if not blacklist[q.id] and not hidden[q.id] then
            total = total + 1
            if isDone(q) then complete = complete + 1 end
        end
    end
    sorted.total, sorted.complete = total, complete
    listDirty = false
end

-- Wipes pins and hides when the quest cycle has rolled over.
local function syncCycle()
    if bp.resetAt <= 0 then return end
    if tonumber(config.state.cycle) ~= bp.resetAt then
        pinned, hidden = {}, {}
        config.state.cycle = bp.resetAt
        saveConfig()
    end
end

-- Applies a progress snapshot. Returns true when an unknown id showed up.
function applyProgress(list)
    local unknown = false
    quests = {}
    lastProgress = list

    for _, item in ipairs(list) do
        if item.visible ~= 0 then
            local entry = catalog[item.id]
            if entry then
                quests[#quests + 1] = {
                    id = item.id,
                    title = entry.title,
                    description = entry.description,
                    curr = item.progress or 0,
                    max = entry.totalProgress or 1,
                }
            else
                unknown = true
            end
        end
    end

    snapshotAt = os.time()
    listDirty = true
    return unknown
end

-- Marks a quest done by title, taking the lowest threshold on a name clash.
local function completeByTitle(title)
    local best = nil
    for _, q in ipairs(quests) do
        if q.title == title and not isDone(q) then
            if not best or q.max < best.max then best = q end
        end
    end
    if not best then return false end
    best.curr = best.max
    pinned[best.id] = nil
    listDirty = true
    return true
end

-- =========================================================================
-- Refresh
-- =========================================================================

local function sendCef(str)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #str)
    raknetBitStreamWriteString(bs, str)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

-- A refresh only ever runs on an explicit player action, so the pass opening for a moment is the expected outcome - nothing to guard against here.
local function requestRefresh(silent)
    if os.clock() - lastRefreshAt < REFRESH_COOLDOWN then
        if not silent then
            local left = math.ceil(REFRESH_COOLDOWN - (os.clock() - lastRefreshAt))
            chat('Подожди ещё ' .. left .. ' сек')
        end
        return
    end

    lastRefreshAt = os.clock()
    weOpened = true
    refreshDeadline = os.clock() + REFRESH_TIMEOUT
    sampSendChat('/battlepass')
end

-- =========================================================================
-- Rendering helpers
-- =========================================================================

-- Draws text twice: white on a bright sky is unreadable without a shadow.
-- `wrapX` has to be passed in rather than pushed by the caller: the shadow copy starts a pixel to the right, so with a shared wrap boundary it breaks lines differently and a word
-- shows up twice, offset by one pixel.
local function shadowText(text, col, wrapX)
    local p = imgui.GetCursorPos()

    if wrapX then imgui.PushTextWrapPos(wrapX + 1) end
    imgui.SetCursorPos(imgui.ImVec2(p.x + 1, p.y + 1))
    imgui.TextColored(COL_SHADOW, text)
    if wrapX then imgui.PopTextWrapPos() end

    imgui.SetCursorPos(p)
    if wrapX then imgui.PushTextWrapPos(wrapX) end
    imgui.TextColored(col, text)
    if wrapX then imgui.PopTextWrapPos() end
end

local function pushSmall()
    if fontDesc then imgui.PushFont(fontDesc) end
end

local function popSmall()
    if fontDesc then imgui.PopFont() end
end

-- Right aligned value on the current line; `pad` reserves room on the right.
local function rightAligned(text, col, overlay, pad)
    local w = imgui.CalcTextSize(text).x
    imgui.SameLine(imgui.GetWindowContentRegionMax().x - w - (pad or 0))
    if overlay then shadowText(text, col) else imgui.TextColored(col, text) end
end

local function progressText(q)
    return string.format('%d/%d', math.min(q.curr, q.max), q.max)
end

-- =========================================================================
-- Overlay rendering
-- =========================================================================

local function renderOverlayRow(q, col)
    shadowText(q.title, col)
    rightAligned(progressText(q), col, true)

    local wantDesc = (cfgDesc[0] == DESC_ALL)
        or (cfgDesc[0] == DESC_PINNED and pinned[q.id])
    if wantDesc and q.description then
        pushSmall()
        shadowText(q.description, COL_DIM, imgui.GetWindowContentRegionMax().x)
        popSmall()
    end

    if q.curr > 0 and not isDone(q) then
        imgui.PushStyleColor(imgui.Col.PlotHistogram, COL_BAR)
        imgui.ProgressBar(percent(q), imgui.ImVec2(-1, 3), '')
        imgui.PopStyleColor()
    end
end

-- Two header lines, each a left and a right half. Built in one place because the width of the overlay is measured from them before anything is drawn.
local function overlayHead()
    local left = formatLeft(bp.resetAt - os.time())
    return {
        {
            isStale() and 'Задания сброшены, нужно обновить'
                or (left and ('Сброс через ' .. left) or ' '),
            snapshotAt and ('обновлено ' .. formatAgo(snapshotAt)) or nil,
        },
        {
            keyLabel(config.settings.toggle_key) .. ' - переключить режим',
            keyLabel(config.settings.refresh_key) .. ' - обновить',
        },
    }
end

local function renderOverlay()
    local head = overlayHead()

    -- One line: reset on the left, freshness pinned to the right edge. The counter lives at the bottom, next to the tick, so it is not said twice.
    pushSmall()
    shadowText(head[1][1], isStale() and COL_ALERT or COL_DIM)
    if head[1][2] then rightAligned(head[1][2], COL_DIM, true) end

    -- Hotkeys sit under what they affect: refresh below the freshness note.
    shadowText(head[2][1], COL_MUTED)
    rightAligned(head[2][2], COL_MUTED, true)
    popSmall()
    imgui.Separator()

    if isStale() then return end
    if #quests == 0 then
        shadowText('Нет данных. Открой БП или нажми ' .. keyLabel(config.settings.refresh_key), COL_DIM)
        return
    end

    for _, q in ipairs(sorted.pin) do renderOverlayRow(q, COL_PINNED) end
    for _, q in ipairs(sorted.active) do renderOverlayRow(q, COL_TEXT) end

    local complete, total = sorted.complete or 0, sorted.total or 0
    shadowText(string.format('%s Выполнено %d из %d', icon('check', 'v'), complete, total),
        complete > 0 and COL_DONE or COL_DIM)
end

-- =========================================================================
-- Window rendering
-- =========================================================================

local BTN_ZONE = 84 -- room reserved on the right for the three row buttons.

local function renderWindowRow(q, col)
    imgui.PushIDInt(q.id)
    local startPos = imgui.GetCursorPos()

    imgui.TextColored(col, q.title)
    rightAligned(progressText(q), col, false, BTN_ZONE)

    -- Full width: the buttons sit on the title row only, the space under them is free.
    if q.description then
        pushSmall()
        imgui.PushTextWrapPos(imgui.GetWindowContentRegionMax().x)
        imgui.TextColored(COL_MUTED, q.description)
        imgui.PopTextWrapPos()
        popSmall()
    end

    if q.curr > 0 and not isDone(q) then
        imgui.PushStyleColor(imgui.Col.PlotHistogram, COL_BAR)
        imgui.ProgressBar(percent(q), imgui.ImVec2(-1, 3), '')
        imgui.PopStyleColor()
    end

    -- Buttons are placed absolutely at the row top, so a wrapped description does not drag them down.
    local endPos = imgui.GetCursorPos()
    imgui.SetCursorPos(imgui.ImVec2(
        imgui.GetWindowContentRegionMax().x - BTN_ZONE + 6, startPos.y))

    if imgui.SmallButton(icon('thumbtack', 'P') .. '##pin') then
        pinned[q.id] = not pinned[q.id] or nil
        saveConfig()
        listDirty = true
    end
    if imgui.IsItemHovered() then imgui.SetTooltip('Закрепить наверх') end

    imgui.SameLine()
    if imgui.SmallButton(icon('eye-slash', 'H') .. '##hide') then
        hidden[q.id] = not hidden[q.id] or nil
        saveConfig()
        listDirty = true
    end
    if imgui.IsItemHovered() then imgui.SetTooltip('Скрыть до сброса заданий') end

    imgui.SameLine()
    -- "ban", not a trash can: the quest is not deleted, it stops being shown.
    if imgui.SmallButton(icon('ban', 'X') .. '##bl') then
        blacklist[q.id] = true
        pinned[q.id] = nil
        saveConfig()
        listDirty = true
    end
    if imgui.IsItemHovered() then imgui.SetTooltip('В чёрный список навсегда') end

    imgui.SetCursorPos(endPos)
    imgui.Separator()
    imgui.PopID()
end

-- Title, description and a restore button; used by both buried sections.
local function renderBuriedRow(q)
    imgui.PushIDInt(q.id)
    imgui.TextColored(COL_DIM, q.title)
    imgui.SameLine(imgui.GetWindowContentRegionMax().x - 62)
    if imgui.SmallButton('Вернуть##restore') then
        hidden[q.id] = nil
        blacklist[q.id] = nil
        saveConfig()
        listDirty = true
    end
    if q.description then
        pushSmall()
        imgui.PushTextWrapPos(imgui.GetWindowContentRegionMax().x)
        imgui.TextColored(COL_MUTED, q.description)
        imgui.PopTextWrapPos()
        popSmall()
    end
    imgui.PopID()
end

-- Collapsible section with an explanation of what "buried" means here.
local function renderBuriedSection(title, note, list)
    if #list == 0 then return end
    -- The count is in the label but not in the id: otherwise the section would collapse itself every time the number changes.
    if not imgui.CollapsingHeader(title .. ': ' .. #list .. '##sect_' .. title) then return end

    pushSmall()
    imgui.PushTextWrapPos(imgui.GetWindowContentRegionMax().x)
    imgui.TextColored(COL_MUTED, note)
    imgui.PopTextWrapPos()
    popSmall()

    imgui.Separator()
    for _, q in ipairs(list) do
        renderBuriedRow(q)
        imgui.Separator()
    end
    imgui.Spacing()
end

local REFRESH_W = 186 -- width of the refresh button and the note under it.
local LIST_BOTTOM = 116 -- room reserved below the list.

-- Icon plus a label, or the bare label when the icon font is unavailable.
local function iconLabel(names, text)
    local glyph = icon(names, '')
    return (glyph ~= '' and (glyph .. '  ') or '') .. text
end

-- Only what is set once and forgotten. Everything touched regularly - the description mode and the keys - stays in the fixed strip below the list.
local function renderOverlayLook()
    if not imgui.CollapsingHeader('Внешний вид оверлея##sect_look') then return end

    imgui.Text('Размер шрифта:')
    for i, preset in ipairs(FONT_PRESETS) do
        if i > 1 then imgui.SameLine() end
        if imgui.RadioButtonIntPtr(preset.name .. '##font' .. i, cfgFont, i) then saveConfig() end
    end
    if #fonts == 0 then
        pushSmall()
        imgui.TextColored(COL_ALERT, 'Шрифт не загрузился, размер не переключается.')
        popSmall()
    end

    imgui.Spacing()
    imgui.Text('Фон:')
    imgui.PushItemWidth(-1)
    if imgui.SliderFloat('##ovl_bg', cfgBg, 0.0, 1.0, '%.2f') then saveConfig() end
    imgui.PopItemWidth()
    pushSmall()
    imgui.TextColored(COL_MUTED, 'Ноль - фона нет вовсе, только текст с тенью.')
    popSmall()
    imgui.Spacing()
end

local function renderWindow()
    local left = formatLeft(bp.resetAt - os.time())

    imgui.BeginGroup()
    imgui.Text('Уровень боевого пропуска: ' .. bp.level)
    imgui.Text(string.format('Заданий выполнено: %d из %d',
        sorted.complete or 0, sorted.total or 0))
    pushSmall()
    if isStale() then
        imgui.TextColored(COL_ALERT, 'Задания сброшены')
    elseif left then
        imgui.TextColored(COL_DIM, 'Сброс через ' .. left)
    end
    popSmall()
    imgui.EndGroup()

    -- Refresh button and the freshness note share the right edge.
    imgui.SameLine(imgui.GetWindowContentRegionMax().x - REFRESH_W)
    imgui.BeginGroup()
    if imgui.Button(iconLabel('rotate', 'Обновить прогресс'), imgui.ImVec2(REFRESH_W, 26)) then
        requestRefresh(false)
    end
    pushSmall()
    local note = snapshotAt and ('обновлено ' .. formatAgo(snapshotAt)) or 'данных ещё нет'
    imgui.SetCursorPosX(imgui.GetWindowContentRegionMax().x - imgui.CalcTextSize(note).x)
    imgui.TextColored(COL_MUTED, note)
    popSmall()
    imgui.EndGroup()

    imgui.Separator()

    imgui.BeginChild('##list', imgui.ImVec2(0, -LIST_BOTTOM), false)

    if catalogLoading then
        imgui.TextColored(COL_DIM, 'Качаю каталог...')
    elseif catalogCount == 0 then
        imgui.TextWrapped('Каталог заданий не загружен' ..
            (catalogError and (': ' .. catalogError) or '') ..
            '. Скачать заново: /bpload')
    elseif isStale() then
        imgui.TextColored(COL_ALERT, 'Задания сброшены, нужно обновить')
    elseif #quests == 0 then
        imgui.TextWrapped('Нет данных о прогрессе. Нажми обновление или открой БП в игре.')
    else
        for _, q in ipairs(sorted.pin) do renderWindowRow(q, COL_PINNED) end
        for _, q in ipairs(sorted.active) do renderWindowRow(q, COL_TEXT) end

        if #sorted.done > 0 then
            if imgui.CollapsingHeader('Выполнено: ' .. #sorted.done .. '##sect_done') then
                for _, q in ipairs(sorted.done) do
                    imgui.TextColored(COL_DONE, q.title)
                    if q.description then
                        pushSmall()
                        imgui.PushTextWrapPos(imgui.GetWindowContentRegionMax().x)
                        imgui.TextColored(COL_MUTED, q.description)
                        imgui.PopTextWrapPos()
                        popSmall()
                    end
                end
            end
        end
        renderBuriedSection('Скрытые задания',
            'Скрываются только до обновления заданий: когда набор сменится, они вернутся в общий список сами.',
            sorted.hidden)

        renderBuriedSection('Чёрный список',
            'Эти задания не показываются в списке активных никогда, в том числе после обновления заданий.',
            sorted.black)
    end

    renderOverlayLook()

    imgui.EndChild()
    imgui.Separator()

    imgui.Text('Описание заданий в оверлее:')
    if imgui.RadioButtonIntPtr('у всех', cfgDesc, DESC_ALL) then saveConfig() end
    imgui.SameLine()
    if imgui.RadioButtonIntPtr('у закреплённых', cfgDesc, DESC_PINNED) then saveConfig() end
    imgui.SameLine()
    if imgui.RadioButtonIntPtr('не выводить', cfgDesc, DESC_NONE) then saveConfig() end

    if imgui.Button('Переключить на оверлей', imgui.ImVec2(-1, 26)) then
        windowMode[0] = false
        geomDirty = true
        saveConfig()
    end

    -- Rebinding: the button waits, the next key pressed becomes the binding.
    if imgui.Button((bindTarget == 'toggle' and 'нажми...' or keyLabel(config.settings.toggle_key))
            .. '##bind_toggle', imgui.ImVec2(84, 0)) then
        bindTarget = (bindTarget == 'toggle') and nil or 'toggle'
    end
    imgui.SameLine()
    imgui.TextColored(COL_MUTED, 'переключить режим')

    imgui.SameLine()
    if imgui.Button((bindTarget == 'refresh' and 'нажми...' or keyLabel(config.settings.refresh_key))
            .. '##bind_refresh', imgui.ImVec2(84, 0)) then
        bindTarget = (bindTarget == 'refresh') and nil or 'refresh'
    end
    imgui.SameLine()
    imgui.TextColored(COL_MUTED, 'обновить прогресс')

    if bindTarget then
        for vk = 3, 255 do
            -- Esc is skipped: it closes the window and doubles as a cancel.
            if vk ~= 27 and imgui.IsKeyPressed(vk) then
                if bindTarget == 'toggle' then
                    config.settings.toggle_key = vk
                else
                    config.settings.refresh_key = vk
                end
                bindTarget = nil
                -- This press is spent on the binding; it must not fire the hotkey as well. Released in the main loop.
                bindHeld = vk
                saveConfig()
                break
            end
        end
    end

    imgui.Dummy(imgui.ImVec2(0, 2))
end

-- =========================================================================
-- Frames
-- =========================================================================

imgui.OnInitialize(function()
    local io = imgui.GetIO()

    -- Merges the icon set into the font added last. Everything has to be built before the atlas is baked, so all sizes are prepared here in advance.
    local function mergeIcons(size)
        if not fa_ok then return end
        local cfg = imgui.ImFontConfig()
        cfg.MergeMode = true
        local ranges = new.ImWchar[3](fa.min_range, fa.max_range, 0)
        pcall(function()
            io.Fonts:AddFontFromMemoryCompressedBase85TTF(
                fa.get_font_data_base85('solid'), size, cfg, ranges)
        end)
    end

    mergeIcons(13) -- into the default font, the one the menu uses.

    pcall(function()
        local dir = (os.getenv('WINDIR') or 'C:\\Windows') .. '\\Fonts\\'
        if not doesFileExist(dir .. FONT_FILE) then return end
        local ranges = io.Fonts:GetGlyphRangesCyrillic()
        for i, preset in ipairs(FONT_PRESETS) do
            local title = io.Fonts:AddFontFromFileTTF(dir .. FONT_FILE, preset.title, nil, ranges)
            mergeIcons(preset.title) -- merges into `title`, the tick lives there.
            local desc = io.Fonts:AddFontFromFileTTF(dir .. FONT_FILE, preset.desc, nil, ranges)
            fonts[i] = { title = title, desc = desc }
        end
    end)

    local style = imgui.GetStyle()
    style.WindowRounding = 8.0
    style.ChildRounding = 6.0
    style.FrameRounding = 5.0
    style.ScrollbarSize = 10.0
    style.ItemSpacing = imgui.ImVec2(8, 4)
    style.WindowPadding = imgui.ImVec2(10, 8)
end)

imgui.OnFrame(function() return winOn[0] end, function(player)
    if listDirty then rebuildList() end

    local overlay = not windowMode[0]
    player.HideCursor = overlay
    player.LockPlayer = not overlay

    local preset = fonts[cfgFont[0]]
    local bg = overlay and cfgBg[0] or 0

    local flags = imgui.WindowFlags.NoCollapse
    if overlay then
        flags = flags
            + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
            + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoInputs
            + imgui.WindowFlags.NoNav
            + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoScrollbar
        -- Fully transparent background is cheaper as a flag than as a colour.
        if bg <= 0 then flags = flags + imgui.WindowFlags.NoBackground end
        imgui.GetIO().WantCaptureMouse = false
    end

    local sw, sh = getScreenResolution()
    local s = config.settings
    local x, y, w, h

    if overlay then
        -- Zero height means "fit the content". The top corner is the anchor:
        -- centring would shift the whole block whenever a quest leaves the list.
        w, h = FONT_PRESETS[cfgFont[0]].width, 0
        x = (s.ovl_x >= 0) and s.ovl_x or (sw - w - 20)
        y = (s.ovl_y >= 0) and s.ovl_y or math.floor(sh * 0.25)
    else
        w, h = s.win_w, s.win_h
        -- Default: screen centre.
        x = (s.win_x >= 0) and s.win_x or math.floor(sw / 2 - w / 2)
        y = (s.win_y >= 0) and s.win_y or math.floor(sh / 2 - h / 2)
    end

    -- Each mode keeps its own geometry, so a switch has to move the window.
    local cond = imgui.Cond.FirstUseEver
    if geomDirty then
        cond = imgui.Cond.Always
        geomDirty = false
    end
    imgui.SetNextWindowPos(imgui.ImVec2(x, y), cond)
    -- The overlay resizes itself with the font and the list, so its size is
    -- forced every frame, not only on a mode switch.
    imgui.SetNextWindowSize(imgui.ImVec2(w, h), overlay and imgui.Cond.Always or cond)

    if bg > 0 then
        imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.08, bg))
    end
    -- Only the overlay swaps fonts: the menu layout is tuned for the default one.
    if overlay and preset then imgui.PushFont(preset.title) end

    if imgui.Begin('BattlePass Helper v' .. thisScript().version .. '##main', winOn, flags) then
        if overlay then
            fontDesc = preset and preset.desc or nil
            renderOverlay()
        else
            fontDesc = fonts[1] and fonts[1].desc or nil
            -- Only this mode can be moved and resized, so only it is saved.
            local pos, size = imgui.GetWindowPos(), imgui.GetWindowSize()
            config.settings.win_x, config.settings.win_y = pos.x, pos.y
            config.settings.win_w, config.settings.win_h = size.x, size.y
            renderWindow()
        end
    end
    imgui.End()

    if overlay and preset then imgui.PopFont() end
    if bg > 0 then imgui.PopStyleColor() end
end)

local WM_KEYDOWN, WM_KEYUP = 0x100, 0x101
local VK_ESCAPE = 0x1B

-- Esc closes the window mode. Handled through window messages rather than by polling the key, because only here the message can be hidden from the game - otherwise Esc would close
-- the window and open the pause menu at once. The overlay is not affected: it takes no input at all.
function onWindowMessage(msg, wparam, lparam)
    if not winOn[0] or not windowMode[0] then return end
    if wparam ~= VK_ESCAPE or (msg ~= WM_KEYDOWN and msg ~= WM_KEYUP) then return end
    if isPauseMenuActive() or sampIsChatInputActive() or sampIsDialogActive() then return end

    -- Both messages are swallowed, the window closes on release: if imgui never sees the key go up it keeps believing Esc is held down.
    consumeWindowMessage(true, false)
    if msg == WM_KEYUP then
        winOn[0] = false
        saveConfig()
    end
end

-- =========================================================================
-- Packets and chat
-- =========================================================================

function onReceivePacket(id, bs)
    if id ~= 220 then return end

    -- Start from the beginning: another script may have moved the read cursor.
    raknetBitStreamResetReadPointer(bs)

    pcall(function()
        raknetBitStreamIgnoreBits(bs, 8)
        if raknetBitStreamReadInt8(bs) ~= 17 then return end
        raknetBitStreamIgnoreBits(bs, 32)
        local length = raknetBitStreamReadInt16(bs)
        local encoded = raknetBitStreamReadInt8(bs)
        local str = (encoded ~= 0)
            and raknetBitStreamDecodeString(bs, length + encoded)
            or raknetBitStreamReadString(bs, length)
        if not str then return end

        if str:find('event.battlePass.initializeBattlePassData', 1, true) then
            local payload = str:match('`(.+)`')
            local ok, data = pcall(decodeJson, payload or '')
            if ok and type(data) == 'table' and data[1] then
                local d = data[1]
                bp.level = d.level or 0
                bp.exp = d.exp or 0
                bp.maxExp = d.maxExp or 0
                bp.resetAt = d.timestampMissionTime or 0
                bp.seasonEnd = d.timestampTaskTime or 0
                syncCycle()
            end

        elseif str:find('event.battlePass.updateQuestsProgress', 1, true) then
            local inner = str:match('%[%[(.-)%]%]')
            local ok, list = pcall(decodeJson, '[' .. tostring(inner) .. ']')
            if ok and type(list) == 'table' then
                if catalogCount == 0 then
                    -- No catalog yet: fetch it, then apply the same snapshot.
                    downloadCatalog(function() applyProgress(list) end)
                elseif applyProgress(list) then
                    chat('Появились незнакомые задания, качаю каталог заново')
                    downloadCatalog(function() applyProgress(list) end)
                end
            end

            -- Close the pass only if we opened it ourselves.
            if weOpened and os.clock() < refreshDeadline then
                weOpened = false
                sendCef('battlePass.exit')
            end
        end
    end)

    -- Restore the cursor for the game and for other scripts.
    raknetBitStreamResetReadPointer(bs)
end

-- Completion is the most fragile path in the whole script: the wording has already changed once. Every attempt goes to the console.
local function logDone(stage, detail)
    print('[BP done] ' .. stage .. (detail and (': ' .. tostring(detail)) or ''))
end

function sampev.onServerMessage(color, rawText)
    local text = cyr:decode(rawText)
    if not text:find('успешно выполнили задание') then return end

    -- No checks on the prefix: may be flaky.
    local title = text:match("выполнили задание[^']*'(.-)'")
    if not title then
        logDone('название не разобралось', text)
        return
    end

    if #quests == 0 then
        logDone('активных заданий нет, засчитывать некуда', title)
        return
    end

    -- Silent on success: only a failure is worth reading in the log.
    if not completeByTitle(title) then
        logDone('не нашлось среди активных', title)
        for _, q in ipairs(quests) do
            logDone('  активное', string.format('%s  %d/%d', q.title, q.curr, q.max))
        end
    end
end

-- =========================================================================
-- Self-update
-- =========================================================================

local UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/manifest.json'
local UPDATE_BASE_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/'
local UPDATE_SCRIPT_ID = 'battlepass-helper'
local UPDATE_MANIFEST_TIMEOUT = 10 -- seconds.
local UPDATE_FILE_TIMEOUT = 30 -- seconds, file is bigger than the manifest.

-- "2.10.0" -> 2010000, so remote/local compare numerically instead of lexicographically. Nothing to keep in sync manually, unlike a stored version_num.
local function versionNum(v)
    local a, b, c = tostring(v or ''):match('^(%d+)%.(%d+)%.(%d+)$')
    if not a then return nil end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
end

-- os.remove is called unguarded on purpose: with doesFileExist in front leftovers survived the cleanup on a real client, and removing a file that is not there is a harmless no-op.
local function removeIfExists(path)
    return os.remove(path)
end

-- Guards an async downloadUrlToFile callback with a timeout: whichever of {the real callback, the timeout} fires first wins and calls its own logic; the loser is a silent no-op.
-- downloadUrlToFile has no cancel API, so a late callback after a timeout isn't stopped - it just finds the claim already taken and does nothing.
local function withTimeout(seconds, onTimeout)
    local done = false
    lua_thread.create(function()
        wait(seconds * 1000)
        if not done then
            done = true
            onTimeout()
        end
    end)
    return function()
        if done then return false end
        done = true
        return true
    end
end

-- current -> current.old, tmp -> current; rolls back on failure so a broken rename never leaves neither file in place. current.old is left behind on success as a manual-recovery copy.
local function atomicReplace(targetPath, tempPath)
    local oldPath = targetPath .. '.old'
    removeIfExists(oldPath)
    if not os.rename(targetPath, oldPath) then
        return false, 'не смог отложить текущий файл в сторону'
    end
    if not os.rename(tempPath, targetPath) then
        os.rename(oldPath, targetPath) -- rollback
        return false, 'не смог поставить новый файл на место, откатил обратно'
    end
    return true
end

local function finishUpdate(entry, tempPath)
    local content = readFile(tempPath)
    local gotVersion = content and content:match("script_version%(['\"]([%d%.]+)['\"]%)")

    if not gotVersion then
        removeIfExists(tempPath)
        chat('Обновление не удалось: скачанный файл не похож на скрипт. Скачайте вручную: {5CC9FF}' .. (entry.topic or FORUM_URL))
        return
    end
    if gotVersion == thisScript().version then
        -- Manifest already points at the new version but the raw.githubusercontent.com CDN edge is still serving the previous file - a stale-cache race, not a real failure.
        removeIfExists(tempPath)
        chat('CDN ещё отдаёт старую версию, попробуйте через пару минут: {5CC9FF}/bpupdate')
        return
    end
    if gotVersion ~= entry.version then
        removeIfExists(tempPath)
        chat('Обновление не удалось: версия в файле (' .. gotVersion .. ') не совпадает с манифестом (' .. entry.version .. ').')
        return
    end

    local ok, err = atomicReplace(thisScript().path, tempPath)
    if not ok then
        removeIfExists(tempPath)
        chat('Обновление не удалось: ' .. err .. '. Скачайте вручную: {5CC9FF}' .. (entry.topic or FORUM_URL))
        return
    end

    chat('Обновлено до {5CC9FF}v' .. entry.version .. '{FFFFFF}, перезагружаю скрипт...')
    lua_thread.create(function()
        wait(300)
        thisScript():reload()
    end)
end

local function downloadUpdate(entry)
    -- Called from inside the manifest downloadUrlToFile's own callback - calling downloadUrlToFile again immediately (same tick) throws "device or resource busy", the native
    -- downloader hasn't released its handle yet. A tick of delay in its own thread fixes it.
    lua_thread.create(function()
        wait(250)
        local tempPath = thisScript().path .. '.tmp'
        removeIfExists(tempPath)
        local dl_status = moonloader.download_status
        local claim = withTimeout(UPDATE_FILE_TIMEOUT, function()
            removeIfExists(tempPath)
            chat('Обновление не удалось: таймаут скачивания. Скачайте вручную: {5CC9FF}' .. (entry.topic or FORUM_URL))
        end)
        downloadUrlToFile(UPDATE_BASE_URL .. entry.path, tempPath, function(_, status)
            if status == dl_status.STATUS_ENDDOWNLOADDATA then
                if claim() then finishUpdate(entry, tempPath) end
            elseif status == dl_status.STATUSEX_ENDDOWNLOAD then
                if claim() then
                    removeIfExists(tempPath)
                    chat('Не удалось скачать обновление. Скачайте вручную: {5CC9FF}' .. (entry.topic or FORUM_URL))
                end
            end
        end)
    end)
end

-- Fetches manifest.json and hands the entry for UPDATE_SCRIPT_ID to onEntry(entry). onError(why) covers everything else (fetch failure, timeout, bad JSON, missing entry) - exactly one fires.
local function fetchManifestEntry(onEntry, onError)
    local manifestPath = thisScript().path .. '.manifest.tmp'
    removeIfExists(manifestPath)
    local dl_status = moonloader.download_status
    local claim = withTimeout(UPDATE_MANIFEST_TIMEOUT, function()
        removeIfExists(manifestPath)
        onError('таймаут')
    end)

    downloadUrlToFile(UPDATE_MANIFEST_URL, manifestPath, function(_, status)
        if status == dl_status.STATUS_ENDDOWNLOADDATA then
            if not claim() then return end
            local content = readFile(manifestPath)
            removeIfExists(manifestPath)
            local ok, data = pcall(decodeJson, content or '')
            if not ok or not data or not data.scripts then
                onError('битый список версий')
                return
            end

            local entry
            for _, item in ipairs(data.scripts) do
                if item.id == UPDATE_SCRIPT_ID then entry = item break end
            end
            if not entry then
                onError('скрипт не найден в списке версий')
                return
            end
            onEntry(entry)
        elseif status == dl_status.STATUSEX_ENDDOWNLOAD then
            if not claim() then return end
            removeIfExists(manifestPath)
            onError('нет соединения')
        end
    end)
end

local function checkForUpdate()
    chat('Проверяю обновления...')
    fetchManifestEntry(
        function(entry)
            -- Strictly "remote > local", not "remote ~= local" - downgrade is intentionally unsupported (a manifest rollback would otherwise fight a newer local dev build).
            local remote, current = versionNum(entry.version), versionNum(thisScript().version)
            if not remote or not current or remote <= current then
                chat('У вас последняя версия (v' .. thisScript().version .. ').')
                return
            end
            chat('Найдено обновление: v' .. entry.version .. '. Скачиваю...')
            downloadUpdate(entry)
        end,
        function(reason)
            chat('Не удалось проверить обновления (' .. reason .. ').')
        end
    )
end

-- Passive check fired once at load: silent when there's nothing to report (up to date, manifest unreachable, whatever) - one line when an update actually exists. Never downloads
-- anything itself, just points at the update command.
local function checkForUpdateSilently()
    fetchManifestEntry(
        function(entry)
            local remote, current = versionNum(entry.version), versionNum(thisScript().version)
            if remote and current and remote > current then
                chat('Доступна новая версия {5CC9FF}v' .. entry.version .. '{FFFFFF}! Обновить: {5CC9FF}/bpupdate')
            end
        end,
        function() end
    )
end

-- =========================================================================
-- Main
-- =========================================================================

function main()
    while not isSampAvailable() do wait(100) end

    -- Remnants of an interrupted update (game closed mid-download etc.) - clean before anything else.
    -- .old is deliberately not touched: it is the previous build, the only way back from an update that turned out broken. One generation at most - atomicReplace overwrites it every time. MoonLoader will not pick it up, the extension is not .lua.
    removeIfExists(thisScript().path .. '.tmp')
    removeIfExists(thisScript().path .. '.manifest.tmp')

    chat('Загружен {5CC9FF}v' .. thisScript().version .. '{FFFFFF}. Список: {5CC9FF}/bp'
        .. '{FFFFFF}. Режим: {5CC9FF}' .. keyLabel(config.settings.toggle_key)
        .. '{FFFFFF}. Обновить: {5CC9FF}' .. keyLabel(config.settings.refresh_key)
        .. '{FFFFFF}. Каталог: {5CC9FF}/bpload{FFFFFF}. Новая версия: {5CC9FF}/bpupdate')

    -- Catalog first: without it a snapshot has nothing to join against.
    if not loadCatalogFromDisk() then
        chat('Каталога нет, качаю...')
        downloadCatalog()
    end

    -- /bp always means "show me the window": from nothing it opens it, from the overlay it brings the window up instead of hiding everything, and only from the window itself it
    -- closes. Esc closes too.
    sampRegisterChatCommand('bp', function()
        if winOn[0] and windowMode[0] then
            winOn[0] = false
            saveConfig()
            return
        end

        winOn[0] = true
        windowMode[0] = true
        geomDirty = true

        -- Refresh unless the snapshot is fresh enough to be worth showing.
        local age = snapshotAt and (os.time() - snapshotAt) or math.huge
        if age > SNAPSHOT_FRESH or isStale() then requestRefresh(false) end
    end)

    -- Kept as a command rather than a button: needed roughly once a season, when the quest pool changes and ids stop resolving.
    sampRegisterChatCommand('bpload', function()
        chat('Качаю каталог заданий...')
        downloadCatalog()
    end)

    sampRegisterChatCommand('bpupdate', checkForUpdate)

    checkForUpdateSilently()

    while true do
        wait(0)

        -- A press already spent on a binding stays swallowed until the key is physically released, otherwise it fires the hotkey it just became.
        if bindHeld and not isKeyDown(bindHeld) then bindHeld = nil end

        -- Hotkeys are dead while typing, in a dialog, in the pause menu, and while a key is being rebound - otherwise binding F9 would toggle it.
        local keysLive = winOn[0] and not bindTarget and not bindHeld
            and not sampIsChatInputActive() and not sampIsDialogActive()
            and not isPauseMenuActive()

        if keysLive and isKeyJustPressed(config.settings.toggle_key) then
            windowMode[0] = not windowMode[0]
            geomDirty = true
            if not windowMode[0] then saveConfig() end
        end

        if keysLive and isKeyJustPressed(config.settings.refresh_key) then
            requestRefresh(false)
        end

        -- Our refresh never got its data: drop the flag so we do not close a window the player opens later.
        if weOpened and os.clock() > refreshDeadline then
            weOpened = false
            chat('Данные не пришли, попробуй ещё раз')
        end
    end
end
