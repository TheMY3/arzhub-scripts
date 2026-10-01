script_name('Case Opener')
script_author('TheMY3')
script_version('1.9.0')


local moonloader = require 'moonloader' -- download_status for self-update.
local imgui = require 'mimgui'
local sampev = require 'samp.events'
local inicfg = require 'inicfg'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'UTF-8'
local cyr = encoding.CP1251

local vk_ok, vkeys = pcall(require, 'vkeys')

local new = imgui.new

-- =========================================================================
-- Constants
-- =========================================================================

local TAG = '{FFD700}[TM] Case Opener{FFFFFF}: '

-- inicfg wants a path relative to moonloader/config, io and createDirectory want an absolute one, so both are built from the same piece.
local CFG_SUB = 'TheMY3/caseopener'
local CFG_PATH = CFG_SUB .. '/config.ini'
local CFG_DIR = getWorkingDirectory() .. '\\config\\' .. (CFG_SUB:gsub('/', '\\'))
local HISTORY_PATH = CFG_DIR .. '\\history.json'
local ITEMS_PATH = CFG_DIR .. '\\items.json'

-- Shards and money arrive as ordinary prizes but are counted differently.
local ITEM_SHARDS = 9294

-- For money and AZ coins `count` is an amount, not a number of pieces.
-- The pool lists such prizes under a variant id (picture id = id * 10000 + variant: 731 -> 7310001, 9296 -> 92960002) while the reward carries the base id, so the scanned dictionary never matches them.
-- Labels are built here rather than looked up, and they copy the in-game card: «50 AZ-коинов», «$ 1.000.000» with dots.
local CURRENCY_LABEL = {
    [731] = function(n) return n .. ' AZ-коинов' end,
    -- The card separates thousands with dots, not spaces.
    [9296] = function(n)
        local out = tostring(math.floor(n)):reverse():gsub('(%d%d%d)', '%1.'):reverse()
        return '$ ' .. (out:gsub('^%.', ''))
    end,
}
CURRENCY_LABEL[92960002] = CURRENCY_LABEL[9296]


-- Taken from the «Похожие кейсы» block: the case id sits in the picture path.
local CASE_NAMES = {
    [0] = 'Фэнтезийный кейс',
    [1] = 'Особый кейс',
    [2] = 'Маскарад ужасов',
    [3] = 'Кейс Дня Мертвых',
    [4] = 'Кейс Страха и Пламени',
    [6] = 'Код 26',
    [7] = 'Кейс Нового Сезона',
    [8] = 'Кейс 12CILINDRI',
    [9] = 'Кейс Frame',
    [10] = 'CASE CAPTURE',
}

-- Some prizes bypass CEF entirely: no card, only a SAMP dialog. The condition is external (a character skin), but people grind cases exactly for those, so they are recorded as an ordinary drop of the case being opened.
-- Keyed by a fragment of the dialog text: neither id, name nor rarity is in the dialog,
-- and such a prize never appears in the case pool either, so all three are set here.
local DIALOG_BONUSES = {
    { find = 'Монету Новой Мафии', item = 10098, count = 1,
      name = 'Монета Новой Мафии (Вечная)', rarity = 'gold' },
}

-- Two independent markers of such a dialog, either of which is accepted: with a single sample we cannot tell which one is stable - the title states the occasion, the body states the substance.
local BONUS_TITLE = 'УРА! УРА!' -- the occasion
local BONUS_MARK = 'Предмет уже у вас в инвентаре' -- the substance: nothing to choose

local SKIP_TRIES = 12 -- how many times the injected script looks for the skip button.
local SKIP_STEP = 150 -- ms between those attempts.
local OPENALL_TRIES = 40 -- «Открыть всё» waits longer: the video has to go first.
local OPENALL_STEP = 200
local DECOR_TRIES = 40 -- how long the decorator waits for the window to mount.
local DECOR_STEP = 250
-- The game's own item effect: a transparent square with the digit in the top-left corner, stretched over the whole card.
local DIGIT_URL = 'https://cdn.azresources.cloud/projects/arizona-rp/assets/images/inventory/effects/digit_'
local FLUSH_DELAY = 1.5 -- seconds to wait for trailing informers before writing history.

local COL_TEXT = imgui.ImVec4(1.00, 1.00, 1.00, 1.00)
local COL_DIM = imgui.ImVec4(0.82, 0.82, 0.86, 1.00)
local COL_MUTED = imgui.ImVec4(0.66, 0.66, 0.70, 1.00)
local COL_SHADOW = imgui.ImVec4(0.00, 0.00, 0.00, 0.95)
local COL_SHARD = imgui.ImVec4(0.72, 0.45, 1.00, 1.00)
local COL_OVL_BG = imgui.ImVec4(0.02, 0.02, 0.03, 0.92)

local RARITY_COL = {
    gold = imgui.ImVec4(1.00, 0.84, 0.00, 1.00),
    purple = imgui.ImVec4(0.64, 0.21, 0.93, 1.00),
    green = imgui.ImVec4(0.35, 0.85, 0.25, 1.00),
    common = imgui.ImVec4(0.78, 0.78, 0.82, 1.00),
}

-- =========================================================================
-- State
-- =========================================================================

local history = {} -- date -> {opens, prizes, shards, money}
local items = {} -- itemId (string) -> {name, rarity, shards}

-- One whole opening. Lives from initializeRewards until it is written to history.
local pending = nil

local caseInfo = { id = 0, count = 0, current = 0, total = 0 }
local inCase = false
local autoOpenAt = nil -- when we press «ОТКРЫТЬ» ourselves.

local AUTO_OPEN_DELAY = 0.6 -- pause before auto-opening, long enough to leave with Esc.

local winOn = new.bool(false)
local windowMode = new.bool(false) -- false = overlay, true = window.

-- Setting checkboxes: imgui wants a bool reference, inicfg stores 0/1.
local cfgSkip = new.bool(true)
local cfgOpenAll = new.bool(true)
local cfgAutoOpen = new.bool(false)

local searchBuf = new.char[64]('')
local selectedDate = '' -- empty means all time.
local selectedCase = '' -- empty means all cases.
local viewCache = nil -- aggregate, recomputed on demand.
local viewRev = -1
local dataRev = 0 -- bumped on every change to the history.

local fontSmall = nil
local geomDirty = true
local cfgSaveAt = nil -- deferred config write while the overlay is dragged.

-- =========================================================================
-- Config
-- =========================================================================

local config = inicfg.load({
    settings = {
        auto_skip = 1, -- skip the opening animation.
        auto_open_all = 1, -- press «Открыть всё» on the cards screen right away.
        action_key = 32, -- space: presses whatever fits the current case screen.
        take_key = 81, -- Q: «Забрать» on the reward screen, 0 turns it off.
        shard_key = 69, -- E: «Расколоть» on the reward screen, 0 turns it off.
        auto_open = 0, -- presses «ОТКРЫТЬ» by itself. Spends cases, hence off by default.
        ovl_collapsed = 0,
        win_x = -1, win_y = -1,
        win_w = 900, win_h = 520,
        ovl_x = -1, ovl_y = -1,
        ovl_w = 340, -- height is fitted to content.
    },
}, CFG_PATH)

config.settings.auto_skip = tonumber(config.settings.auto_skip) or 1
config.settings.auto_open_all = tonumber(config.settings.auto_open_all) or 1
config.settings.action_key = tonumber(config.settings.action_key) or 32
config.settings.take_key = tonumber(config.settings.take_key) or 81
config.settings.shard_key = tonumber(config.settings.shard_key) or 69
config.settings.auto_open = tonumber(config.settings.auto_open) or 0
config.settings.ovl_collapsed = tonumber(config.settings.ovl_collapsed) or 0

cfgSkip[0] = config.settings.auto_skip == 1
cfgOpenAll[0] = config.settings.auto_open_all == 1
cfgAutoOpen[0] = config.settings.auto_open == 1

local function saveConfig()
    if not doesDirectoryExist(CFG_DIR) then createDirectory(CFG_DIR) end
    inicfg.save(config, CFG_PATH)
end

local function keyLabel(vk)
    if vk == 32 then return 'Пробел' end
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

-- The moonloader console expects CP1251 while the source is UTF-8.
local function logDebug(msg)
    print('[CaseOpener] ' .. cyr(tostring(msg)))
end

-- For strings that came from the server: they are CP1251 already, converting them twice corrupts them.
local function logRaw(msg)
    print('[CaseOpener] ' .. tostring(msg))
end

-- string.lower only knows ASCII while item names are UTF-8 (А-П at D0 90..D0 9F, Р-Я at D0 A0..D0 AF), so without this a search for «монета» misses «Монета».
local function lowerUtf8(str)
    str = str:lower()
    local out, i = {}, 1
    while i <= #str do
        local b1 = str:byte(i)
        if b1 == 0xD0 then
            local b2 = str:byte(i + 1)
            if b2 and b2 >= 0x90 and b2 <= 0x9F then
                out[#out + 1] = string.char(0xD0, b2 + 0x20)
            elseif b2 and b2 >= 0xA0 and b2 <= 0xAF then
                out[#out + 1] = string.char(0xD1, b2 - 0x20)
            elseif b2 == 0x81 then -- Ё
                out[#out + 1] = string.char(0xD1, 0x91)
            else
                out[#out + 1] = str:sub(i, i + 1)
            end
            i = i + 2
        elseif b1 >= 0xC0 then
            local len = (b1 >= 0xF0 and 4) or (b1 >= 0xE0 and 3) or 2
            out[#out + 1] = str:sub(i, i + len - 1)
            i = i + len
        else
            out[#out + 1] = str:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

local function today()
    return os.date('%Y-%m-%d')
end

local function caseName(id)
    return CASE_NAMES[tonumber(id) or -1] or ('Кейс #' .. tostring(id))
end

-- Look up the exact variant (id plus count) first, then the plain item: name and rarity are per-variant in the pool, while the informer and the chat only know the base name.
local function itemRec(id, count)
    if count then
        local rec = items[tostring(id) .. 'x' .. tostring(count)]
        if rec then return rec end
    end
    return items[tostring(id)]
end

-- Show exactly what the player sees on the card: the pool label is stored as is, quantity suffix included.
local function itemName(id, count)
    local currency = CURRENCY_LABEL[tonumber(id) or -1]
    if currency then return currency(count or 0) end

    local exact = count and items[tostring(id) .. 'x' .. tostring(count)]
    if exact and exact.name and exact.name ~= '' then return exact.name end

    -- No exact label for this count: build one from the base name.
    local base = items[tostring(id)]
    if base and base.name and base.name ~= '' then
        if count and count > 1 then return base.name .. ' ' .. count .. ' шт.' end
        return base.name
    end
    return '#' .. tostring(id)
end

local function itemColor(id, count)
    local rec = itemRec(id, count)
    return RARITY_COL[rec and rec.rarity or ''] or COL_TEXT
end

-- «1 234 567»: spaces rather than commas, the way the game does it.
local function formatNum(n)
    n = math.floor(tonumber(n) or 0)
    local s = tostring(math.abs(n))
    s = s:reverse():gsub('(%d%d%d)', '%1 '):reverse():gsub('^%s+', '')
    return (n < 0 and '-' or '') .. s
end

-- Percentages read well while they are large; for a rare prize 0.4% says nothing and «1 из 250» says everything, hence two scales.
local function formatChance(events, opens)
    if events <= 0 or opens <= 0 then return '-' end
    local pct = events / opens * 100
    if pct >= 1 then return string.format('%.1f%%', pct) end
    return string.format('1 из %d', math.floor(opens / events + 0.5))
end

local function formatDate(date)
    if date == today() then return 'Сегодня' end
    if date == os.date('%Y-%m-%d', os.time() - 86400) then return 'Вчера' end
    local y, m, d = date:match('(%d+)-(%d+)-(%d+)')
    if not d then return date end
    local months = { 'янв', 'фев', 'мар', 'апр', 'май', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек' }
    local label = tonumber(d) .. ' ' .. (months[tonumber(m)] or m)
    if y ~= os.date('%Y') then label = label .. ' ' .. y end
    return label
end

-- =========================================================================
-- Storage
-- =========================================================================

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local body = f:read('*a')
    f:close()
    return body
end

-- A crash between remove and rename in saveJson leaves only the temp file, so it is the fallback.
local function loadJson(path, fallback)
    local from = path
    local body = readFile(from)
    if not body then
        from = path .. '.tmp'
        body = readFile(from)
    end
    if not body or body == '' then return fallback end
    local ok, data = pcall(decodeJson, body)
    if ok and type(data) == 'table' then return data end

    -- Move the unreadable file aside so the next save does not overwrite what is left of it.
    local name = path:match('[^\\/]+$')
    os.remove(path .. '.bad')
    os.rename(from, path .. '.bad')
    chat('Файл ' .. name .. ' повреждён и сохранён как ' .. name .. '.bad, начат заново.')
    return fallback
end

-- Write to a temp file first so a crash mid-write cannot leave a torn file behind.
local function saveJson(path, data)
    if not doesDirectoryExist(CFG_DIR) then createDirectory(CFG_DIR) end
    local tmp = path .. '.tmp'
    local f = io.open(tmp, 'w')
    if not f then return false end
    f:write(encodeJson(data))
    f:close()
    os.remove(path)
    return os.rename(tmp, path) and true or false
end

local function loadAll()
    history = loadJson(HISTORY_PATH, {})
    items = loadJson(ITEMS_PATH, {})
end

local function saveHistory()
    saveJson(HISTORY_PATH, history)
    dataRev = dataRev + 1
end

-- A pool scan teaches the dictionary dozens of items in a row: no need to write the file for each one.
local itemsDeferred = false
local itemsRev = 0 -- bumped on every change to the dictionary, so the prize table knows its names went stale.

local function saveItems()
    if itemsDeferred then return end
    saveJson(ITEMS_PATH, items)
end

-- The name arrives from three sources (informer, chat, pool scan): whoever got there first fills it in.
local function learnItem(id, name, rarity, shards, count)
    local key = tostring(id)
    if count then key = key .. 'x' .. tostring(count) end
    local rec = items[key]
    if not rec then
        rec = {}
        items[key] = rec
    end
    local changed = false
    if name and name ~= '' and rec.name ~= name then
        rec.name = name
        changed = true
    end
    if rarity and rarity ~= '' and rec.rarity ~= rarity then
        rec.rarity = rarity
        changed = true
    end
    if shards and shards > 0 and rec.shards ~= shards then
        rec.shards = shards
        changed = true
    end
    if changed then
        itemsRev = itemsRev + 1
        saveItems()
    end
end

-- The game itself treats item plus count as distinct prizes: «Монета x2» is a separate pool entry from «Монета x1» and their rarity differs. Merging them into one row would hide how often a single piece dropped versus a stack.
local function prizeKey(item, count)
    return tostring(item) .. 'x' .. tostring(count)
end

-- Older records predate the key: for them the key is the id and the count is one.
local function keyParts(key, rec)
    if rec and rec.item then return rec.item, rec.count or 1 end
    local id, count = tostring(key):match('^(%d+)x(%d+)$')
    if id then return tonumber(id), tonumber(count) end
    return tonumber(key) or 0, 1
end

-- Prizes live inside their own case, otherwise the chance gets a foreign denominator: events would be divided by every opening, including openings of other case types.
local function ensureCase(date, caseId)
    local day = history[date]
    if not day then
        day = { cases = {} }
        history[date] = day
    end
    day.cases = day.cases or {}

    local key = tostring(caseId)
    local bucket = day.cases[key]
    if not bucket then
        bucket = { opens = 0, shards = 0, prizes = {} }
        day.cases[key] = bucket
    end
    bucket.opens = bucket.opens or 0
    bucket.shards = bucket.shards or 0
    bucket.prizes = bucket.prizes or {}
    return bucket
end

-- =========================================================================
-- Aggregation
-- =========================================================================

-- date nil or empty means all time; caseKey empty means all cases.
local function aggregate(date, caseKey)
    local out = { prizes = {}, shards = 0, totalOpens = 0, cases = {}, caseCount = 0 }

    local days = {}
    if date and date ~= '' then
        if history[date] then days[date] = history[date] end
    else
        days = history
    end

    for _, day in pairs(days) do
        for cid, bucket in pairs(day.cases or {}) do
            if caseKey == nil or caseKey == '' or cid == caseKey then
                if out.cases[cid] == nil then out.caseCount = out.caseCount + 1 end
                out.cases[cid] = (out.cases[cid] or 0) + (bucket.opens or 0)
                out.totalOpens = out.totalOpens + (bucket.opens or 0)
                out.shards = out.shards + (bucket.shards or 0)

                for key, rec in pairs(bucket.prizes or {}) do
                    local acc = out.prizes[key]
                    if not acc then
                        local item, count = keyParts(key, rec)
                        acc = { item = item, count = count,
                                events = 0, taken = 0, sharded = 0 }
                        out.prizes[key] = acc
                    end
                    acc.events = acc.events + (rec.events or 0)
                    acc.taken = acc.taken + (rec.taken or 0)
                    acc.sharded = acc.sharded + (rec.sharded or 0)
                end
            end
        end
    end

    return out
end

local function view()
    if viewRev ~= dataRev or not viewCache then
        viewCache = aggregate(selectedDate, selectedCase)
        viewRev = dataRev
    end
    return viewCache
end

-- The overlay is drawn every frame and a full pass over the history is wasteful there: it only needs the opening counters of the current case.
local overlayCache = nil

local function overlayCounts(caseId)
    local key = tostring(caseId)
    local date = today()
    if overlayCache and overlayCache.rev == dataRev
        and overlayCache.key == key and overlayCache.date == date then
        return overlayCache
    end

    local day = history[date]
    local todayBucket = day and day.cases and day.cases[key]
    local todayOpens = todayBucket and todayBucket.opens or 0

    local allOpens = 0
    for _, rec in pairs(history) do
        local bucket = rec.cases and rec.cases[key]
        allOpens = allOpens + (bucket and bucket.opens or 0)
    end

    overlayCache = { key = key, date = date, rev = dataRev,
        today = todayOpens, all = allOpens }
    return overlayCache
end

-- Cases that were actually opened: the filter must not offer empty ones.
local function openedCases()
    local seen = {}
    for _, day in pairs(history) do
        for key, bucket in pairs(day.cases or {}) do
            seen[key] = (seen[key] or 0) + (bucket.opens or 0)
        end
    end
    local list = {}
    for key in pairs(seen) do list[#list + 1] = key end
    table.sort(list, function(a, b) return seen[a] > seen[b] end)
    return list
end

local function sortedDates()
    local list = {}
    for date in pairs(history) do list[#list + 1] = date end
    table.sort(list, function(a, b) return a > b end)
    return list
end

-- =========================================================================
-- CEF
-- =========================================================================

-- Inject queue. raknetEmulRpcReceiveBitStream runs the packet through script handlers synchronously, so calling it from a packet hook or from inside a coroutine kills the script with "cannot resume non-suspended coroutine".
-- Everything bound for CEF piles up here and leaves from main().
local injectQueue = {}

local function queueInject(js)
    injectQueue[#injectQueue + 1] = js
end

-- Inject JS into CEF (incoming sub-type 17, «run this JS on your side»).
local function evalcef(js)
    if type(js) ~= 'string' or js == '' or #js > 32767 then return false end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)
    raknetBitStreamWriteInt32(bs, 0)
    raknetBitStreamWriteInt16(bs, #js)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteString(bs, js)
    raknetEmulRpcReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
    return true
end

-- The video overlay does not mount instantly, so the injected script retries; if the button never shows up it fast-forwards the <video> itself.
local function skipVideo()
    local js = ([[
(function () {
    var left = %d;
    var timer = setInterval(function () {
        var btn = document.querySelector('.open-case-video__button-skip .kit-button')
               || document.querySelector('.open-case-video__button-skip');
        if (btn) { clearInterval(timer); btn.click(); return; }
        if (--left <= 0) {
            clearInterval(timer);
            var v = document.querySelector('.open-case-video__player');
            if (v) { try { v.currentTime = 1e9; } catch (e) {} }
        }
    }, %d);
})();
]]):format(SKIP_TRIES, SKIP_STEP)
    queueInject(js)
end

-- The button is found by its text, never by counting: a single-prize case has «Открыть всё» too, but nothing guarantees exactly one button, and the reward screen puts «Забрать» and «Расколоть» in the same container with the same class. A blind click would decide the fate of the prizes for the player.
-- Needles are \uXXXX escaped so parsing does not depend on the source encoding. Long brackets rather than quotes: Lua 5.1 knows no \u and JS must receive a literal backslash.
local JS_OPEN = [[\u043e\u0442\u043a\u0440\u044b\u0442\u044c]] -- открыть
local JS_TAKE = [[\u0437\u0430\u0431\u0440\u0430\u0442\u044c]] -- забрать
local JS_SHARD = [[\u0440\u0430\u0441\u043a\u043e\u043b\u043e\u0442\u044c]] -- расколоть

local function openAllCards()
    local js = ([[
(function () {
    var OPEN = '%s', TAKE = '%s', SHARD = '%s';
    var left = %d;
    var timer = setInterval(function () {
        var box = document.querySelector('.open-case-inside__buttons');
        if (box) {
            var btns = box.querySelectorAll('.open-case-inside__button');
            var target = null;
            for (var i = 0; i < btns.length; i++) {
                var kit = btns[i].querySelector('.kit-button');
                var label = btns[i].textContent.toLowerCase();
                // The player decides the fate of the prizes: seeing these buttons, back off.
                if (label.indexOf(TAKE) !== -1 || label.indexOf(SHARD) !== -1) {
                    clearInterval(timer);
                    return;
                }
                if (kit && label.indexOf(OPEN) !== -1
                        && kit.className.indexOf('disabled') === -1) {
                    target = kit;
                }
            }
            if (target) { clearInterval(timer); target.click(); return; }
        }
        if (--left <= 0) clearInterval(timer);
    }, %d);
})();
]]):format(JS_OPEN, JS_TAKE, JS_SHARD, OPENALL_TRIES, OPENALL_STEP)
    queueInject(js)
end

-- Hint text for a JS string literal: anything outside plain ASCII, quotes and backslashes go as \uXXXX, so DOM text does not depend on the source encoding.
-- The backslash is built with string.char so the escape survives any tooling between here and the file.
local function jsText(str)
    local out, i = {}, 1
    while i <= #str do
        local b = str:byte(i)
        local cp, len
        if b < 0x80 then cp, len = b, 1
        elseif b < 0xE0 then cp, len = (b % 0x20) * 0x40 + (str:byte(i + 1) or 0) % 0x40, 2
        else
            cp = ((b % 0x10) * 0x40 + (str:byte(i + 1) or 0) % 0x40) * 0x40 + (str:byte(i + 2) or 0) % 0x40
            len = 3
        end
        if cp < 0x80 and cp ~= 39 and cp ~= 92 and cp ~= 60 then
            out[#out + 1] = string.char(cp)
        else
            out[#out + 1] = string.char(92) .. 'u' .. string.format('%04x', cp)
        end
        i = i + len
    end
    return table.concat(out)
end

-- What every case screen says about the keys. Empty when the key is turned off.
local function hintTexts()
    local act = keyLabel(config.settings.action_key)
    return jsText(act .. ' - открыть'),
        jsText(act .. ' - пропустить'),
        jsText('Используйте цифры или ' .. act .. ' - открыть все'),
        jsText('Используйте цифры или ' .. act .. ' - выбрать все')
end

-- Key name for a hint inside the CEF window: plain ASCII only, an exotic name is dropped rather than broken.
local function jsKeyName(vk)
    if not vk or vk <= 0 or not vk_ok then return '' end
    local ok, name = pcall(vkeys.id_to_name, vk)
    if not ok or type(name) ~= 'string' then return '' end
    return (name:gsub('[^%w%+%-]', ''))
end

-- Shared by every inject that touches the reward cards. Cards are matched by position: it is the order of initializeRewards and of the sell/save indexes.
local function prizeLib()
    return ([[
    var TAKE = '%s', SHARD = '%s', DIGIT = '%s';
    var TAKE_KEY = '%s', SHARD_KEY = '%s';
    var HINT_MAIN = '%s', HINT_SKIP = '%s', HINT_HIDDEN = '%s', HINT_OPEN = '%s';
    // The game's own gray captions use HeadingNowRegular; the rest of the stack only matters if a build renames it.
    var HINT_FONT = '"HeadingNowRegular", sans-serif';
    var HINT_CSS = 'color:rgba(255,255,255,.55);font-size:14px;text-align:center;pointer-events:none;'
        + 'font-family:' + HINT_FONT + ';';
    // The page sets no default font: should HeadingNowRegular vanish, the button caption's font beats a serif fallback.
    function borrowFont(hint, scope) {
        var label = scope && scope.querySelector('.kit-button__text');
        var ls = label && window.getComputedStyle ? window.getComputedStyle(label) : null;
        if (ls) hint.style.fontFamily = '"HeadingNowRegular", ' + ls.fontFamily;
    }
    function hintNode(cls, text) {
        var d = document.createElement('div');
        d.className = 'tm-case-hint ' + cls;
        d.textContent = text;
        d.style.cssText = HINT_CSS;
        return d;
    }
    // One gray line per screen, the same wording style as the game's own «Осталось N шт.».
    function screenHints() {
        var count = document.querySelector('.open-case-main__main-count');
        if (count && count.parentNode && !document.querySelector('.tm-case-hint-main')) {
            var h = hintNode('tm-case-hint-main', HINT_MAIN);
            // Copied from the counter so the line looks native at any interface scale.
            var cs = window.getComputedStyle ? window.getComputedStyle(count) : null;
            // Above the counter, taking over its gap from the button; the negative bottom margin cancels the counter's own top one, leaving 4px.
            if (cs) {
                h.style.color = cs.color;
                h.style.fontSize = cs.fontSize;
                h.style.fontFamily = cs.fontFamily;
                h.style.marginTop = cs.marginTop;
                h.style.marginBottom = 'calc(4px - ' + cs.marginTop + ')';
            }
            count.parentNode.insertBefore(h, count);
        }
        var skip = document.querySelector('.open-case-video__button-skip');
        if (skip && !skip.querySelector('.tm-case-hint')) {
            // Hangs under the button without moving it, whatever layout the overlay uses.
            if (window.getComputedStyle && window.getComputedStyle(skip).position === 'static') {
                skip.style.position = 'relative';
            }
            var k = hintNode('tm-case-hint-skip', HINT_SKIP);
            borrowFont(k, skip);
            k.style.cssText += 'position:absolute;left:-50%%;right:-50%%;top:100%%;margin-top:6px;white-space:nowrap;';
            skip.appendChild(k);
        }
        var box = document.querySelector('.open-case-inside__buttons');
        if (box && box.parentNode) {
            var text = fateScreen() ? HINT_OPEN : HINT_HIDDEN;
            var c = document.querySelector('.tm-case-hint-cards');
            if (!c) {
                c = hintNode('tm-case-hint-cards', text);
                c.style.marginBottom = '12px';
                c.style.width = '100%%';
                borrowFont(c, box);
                box.parentNode.insertBefore(c, box);
            }
            if (c.textContent !== text) c.textContent = text;
        }
    }
    function cards() {
        return document.querySelectorAll('.open-case-inside__prizes .open-case-inside__prize');
    }
    function hasClass(el, cls) {
        return (' ' + el.className + ' ').indexOf(' ' + cls + ' ') !== -1;
    }
    // A card already taken or shattered carries a caption and takes no part in the choice.
    function done(card) {
        return !!card.querySelector('.open-case-inside__prize-caption');
    }
    // The inner card is clicked so the event bubbles through the wrapper, wherever Svelte hung the handler.
    function hit(card) {
        (card.querySelector('.open-case-prize') || card).click();
    }
    function fateButton(needle) {
        var box = document.querySelector('.open-case-inside__buttons');
        if (!box) return null;
        var btns = box.querySelectorAll('.open-case-inside__button');
        for (var i = 0; i < btns.length; i++) {
            if (btns[i].textContent.toLowerCase().indexOf(needle) !== -1) {
                return btns[i].querySelector('.kit-button');
            }
        }
        return null;
    }
    function fateScreen() {
        return !!(fateButton(TAKE) || fateButton(SHARD));
    }
    // Selects every card still in play; once all of them are selected, clears the selection instead.
    function toggleAll() {
        var list = cards(), live = [], allOn = true;
        for (var i = 0; i < list.length; i++) {
            if (done(list[i])) continue;
            live.push(list[i]);
            if (!hasClass(list[i], 'open-case-inside__prize--checked')) allOn = false;
        }
        for (var j = 0; j < live.length; j++) {
            if (allOn || !hasClass(live[j], 'open-case-inside__prize--checked')) hit(live[j]);
        }
    }
    // The hotkey sits inside the button caption: Svelte updates only its own text node, the span stays.
    function keyHint(needle, key) {
        var kit = key && fateButton(needle);
        var text = kit && kit.querySelector('.kit-button__text');
        if (!text || text.querySelector('.tm-case-key')) return;
        var span = document.createElement('span');
        span.className = 'tm-case-key';
        span.textContent = key;
        span.style.cssText = 'display:inline-block;margin-left:8px;padding:0 6px;'
            + 'border:1px solid currentColor;border-radius:4px;opacity:.75;font-size:.85em;';
        text.appendChild(span);
    }
    // Falls back to a plain CSS badge if the CDN picture does not load.
    // The picture is shrunk rather than stretched over the whole card: the digit stays in the corner, only smaller.
    function badges() {
        keyHint(TAKE, TAKE_KEY);
        keyHint(SHARD, SHARD_KEY);
        var list = cards();
        for (var i = 0; i < list.length && i < 9; i++) {
            if (list[i].querySelector('.tm-case-digit')) continue;
            var img = document.createElement('img');
            img.className = 'tm-case-digit';
            img.src = DIGIT + (i + 1) + '.webp';
            img.style.cssText = 'position:absolute;left:0;top:0;width:60%%;height:60%%;'
                + 'pointer-events:none;z-index:5;';
            img.onerror = (function (n) {
                return function () {
                    var div = document.createElement('div');
                    div.className = 'tm-case-digit';
                    div.textContent = String(n);
                    div.style.cssText = 'position:absolute;left:5px;top:5px;padding:0 5px;font-size:12px;'
                        + 'border-radius:5px;background:#00A8EC;color:#fff;font-weight:bold;'
                        + 'pointer-events:none;z-index:5;';
                    if (this.parentNode) this.parentNode.replaceChild(div, this);
                };
            })(i + 1);
            list[i].appendChild(img);
        }
        return list.length;
    }
]]):format(JS_TAKE, JS_SHARD, DIGIT_URL,
        jsKeyName(config.settings.take_key), jsKeyName(config.settings.shard_key), hintTexts())
end

-- One key for all three screens. What to press is decided by the DOM rather than by our idea of the server state, so a mismatch in event order cannot make it miss.
local function pressActionButton()
    local js = ([[
(function () {
    var OPEN = '%s';
%s

    // 1. The video is playing: skip it.
    var skip = document.querySelector('.open-case-video__button-skip');
    if (skip) { (skip.querySelector('.kit-button') || skip).click(); return; }

    // 2. The reward cards screen.
    var box = document.querySelector('.open-case-inside__buttons');
    if (box) {
        // The fate buttons are up: the key only selects, the player still decides.
        if (fateScreen()) { toggleAll(); return; }
        var btns = box.querySelectorAll('.open-case-inside__button');
        for (var j = 0; j < btns.length; j++) {
            var kit = btns[j].querySelector('.kit-button');
            if (kit && btns[j].textContent.toLowerCase().indexOf(OPEN) !== -1
                    && kit.className.indexOf('disabled') === -1) {
                kit.click();
                return;
            }
        }
        return;
    }

    // 3. The main screen: open one more case.
    var main = document.querySelector('.open-case-main__main-button-purchase .kit-button');
    if (main && main.className.indexOf('disabled') === -1) { main.click(); }
})();
]]):format(JS_OPEN, prizeLib())
    queueInject(js)
end

-- A digit picks a card the way a click does: reveals a hidden one, toggles the selection on an open one.
-- Q and E press «Забрать» and «Расколоть» once, only when the button is live.
local function pressPrizeKey(action, n)
    local js = ([[
(function () {
%s
    badges();
    var ACTION = '%s', N = %d;
    if (ACTION === 'card') {
        var card = cards()[N - 1];
        if (card && !done(card)) hit(card);
        return;
    }
    var kit = fateButton(ACTION === 'take' ? TAKE : SHARD);
    if (kit && kit.className.indexOf('disabled') === -1) kit.click();
})();
]]):format(prizeLib(), action, n or 0)
    queueInject(js)
end

-- Card numbers, key captions and hint lines live as long as the case window: Svelte redraws screens freely, so everything is checked again on every tick.
local function decorate()
    local js = ([[
(function () {
%s
    if (window.__tmCaseDecor) clearInterval(window.__tmCaseDecor);
    var seen = false, left = %d;
    window.__tmCaseDecor = setInterval(function () {
        if (document.querySelector('.open-case')) {
            seen = true;
            badges();
            screenHints();
            return;
        }
        if (seen || --left <= 0) {
            clearInterval(window.__tmCaseDecor);
            window.__tmCaseDecor = null;
        }
    }, %d);
})();
]]):format(prizeLib(), DECOR_TRIES, DECOR_STEP)
    queueInject(js)
end

-- =========================================================================
-- Opening state machine
-- =========================================================================

local function flushPending()
    if not pending then return end

    local bucket = ensureCase(pending.date or today(), pending.caseId)
    bucket.opens = bucket.opens + 1


    for _, prize in ipairs(pending.prizes) do
        local fate = prize.fate or 'take'

        -- Everything lands in the common list, currencies included: the drop chance is meaningful for them too.
        local key = prizeKey(prize.item, prize.count or 0)
        local rec = bucket.prizes[key]
            or { item = prize.item, count = prize.count or 0,
                 events = 0, taken = 0, sharded = 0 }
        rec.events = rec.events + 1

        if fate == 'shard' then
            rec.sharded = rec.sharded + 1
            bucket.shards = bucket.shards + (prize.shards or 0)
        else
            rec.taken = rec.taken + 1
        end

        bucket.prizes[key] = rec

    end

    pending = nil
    saveHistory()
end

local function markReadyIfComplete()
    if not pending then return end
    for _, prize in ipairs(pending.prizes) do
        if not prize.fate then return end
    end
    pending.readyAt = os.clock() + FLUSH_DELAY
end

local function onRewards(list, caseId)
    -- The previous opening never closed: write it down as is rather than lose it.
    if pending then flushPending() end

    pending = {
        caseId = caseId,
        date = today(),
        prizes = {},
        shardOrder = {},
        shardAmountAt = 1,
        shardNameAt = 1,
        readyAt = nil,
    }
    for _, entry in ipairs(list) do
        pending.prizes[#pending.prizes + 1] = {
            item = tonumber(entry.item) or 0,
            count = tonumber(entry.count) or 0,
            fate = nil,
            shards = 0,
        }
    end
end

-- '[0,2]' -> {1, 3}: the server counts from zero, Lua from one.
local function parseIndices(payload)
    local out = {}
    for num in tostring(payload or ''):gmatch('%-?%d+') do
        out[#out + 1] = tonumber(num) + 1
    end
    return out
end

local function setFate(indices, fate)
    if not pending then return end
    for _, idx in ipairs(indices) do
        local prize = pending.prizes[idx]
        if prize and not prize.fate then
            prize.fate = fate
            if fate == 'shard' then
                pending.shardOrder[#pending.shardOrder + 1] = idx
            end
        end
    end
    markReadyIfComplete()
end

-- Closing the window makes the server take everything left over by itself, with no outgoing packet.
local function autoTakeRemaining()
    if not pending then return end
    local changed = false
    for _, prize in ipairs(pending.prizes) do
        if not prize.fate then
            prize.fate = 'take'
            changed = true
        end
    end
    if changed then markReadyIfComplete() end
end

-- One shard informer arrives per broken item, in the order they were broken.
local function takeShardAmount(amount)
    if not pending then return end
    local idx = pending.shardOrder[pending.shardAmountAt]
    if not idx then return end
    pending.shardAmountAt = pending.shardAmountAt + 1
    local prize = pending.prizes[idx]
    if not prize then return end
    prize.shards = amount
    learnItem(prize.item, nil, nil, amount)
end

-- The chat line about breaking is the only source of a broken item's name.
local function takeShardName(name)
    if not pending then return end
    local idx = pending.shardOrder[pending.shardNameAt]
    if not idx then return end
    pending.shardNameAt = pending.shardNameAt + 1
    local prize = pending.prizes[idx]
    if not prize then return end
    learnItem(prize.item, name)
end

-- =========================================================================
-- Prize pool scan
-- =========================================================================

-- The inject answers with one window.cef.SendMessage: it lands in onSendPacket, which swallows it so the server never sees it.
local SCAN_MSG = 'tmCaseScan|'
local SCAN_MAX_BYTES = 30000 -- the outgoing string length is an Int16, so the answer stays below 32767.

local function scanJs(caseId)
    return ([[
(function () {
    var HEAD = '%s' + %d + '|', MAX = %d;
    var list = [], body = '[]';
    var nodes = document.querySelectorAll('.open-case-prize');
    for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        var img = el.querySelector('.open-case-prize__image');
        var txt = el.querySelector('.open-case-prize__text');
        if (!img || !txt) continue;
        var m = (img.getAttribute('src') || '').match(/\/(\d+)\.webp/);
        if (!m) continue;
        var r = (el.className.match(/open-case-prize--(\w+)/) || [])[1] || '';
        list.push([m[1], r, txt.textContent.replace(/\s+/g, ' ').trim()]);
        // URI-encoded JSON: Cyrillic and separators become plain ASCII whatever encoding CEF uses for the packet.
        var next = encodeURIComponent(JSON.stringify(list));
        if (HEAD.length + next.length > MAX) { list.pop(); break; }
        body = next;
    }
    try { window.cef.SendMessage(HEAD + body, 0); } catch (e) {}
})();
]]):format(SCAN_MSG, caseId, SCAN_MAX_BYTES)
end

-- Once per case type per session: no need to repeat the inject on every visit.
-- A case is marked only by its answer, so a lost answer simply means the next visit to the main screen scans again.
local scannedCases = {}

-- The inject waits for Svelte to draw the pool; it leaves from main(), so there are no coroutines here at all.
local scan = { at = nil, caseId = nil }

local SCAN_MIN = 5 -- fewer means we hit the wrong screen, so the case stays unmarked.

local function requestScan(caseId, delay)
    if scan.at then return end
    scan.at = os.clock() + (delay or 0)
    scan.caseId = caseId
end

local function uriDecode(str)
    return (str:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

-- '<caseId>|<URI-encoded JSON>', the JSON being [[id, rarity, label], ...].
local function onScanAnswer(body)
    local caseId, encoded = body:match('^(%d+)|(.*)$')
    if not caseId then return end
    caseId = tonumber(caseId)

    local ok, list = pcall(decodeJson, uriDecode(encoded))
    if not ok or type(list) ~= 'table' then return logDebug('pool scan: unreadable answer') end

    local found = 0
    itemsDeferred = true
    for _, card in ipairs(list) do
        local id, rarity, name = tonumber(card[1]), card[2], card[3]
        if id and type(name) == 'string' and name ~= '' then
            rarity = (type(rarity) == 'string' and rarity ~= '') and rarity or nil

            -- Every count is its own pool entry with its own rarity: «Монета x2» is purple, «Монета x1» is green. The count lives in the label, so pull it out.
            local bare, num = name:match('^(.-)%s*(%d+)%s*шт%.?$')
            local count = tonumber(num) or 1

            -- The variant keeps the pool label verbatim: that is the text on the card.
            learnItem(id, name, rarity, nil, count)
            -- The base one drops the quantity suffix and covers counts the pool never showed.
            learnItem(id, (bare and bare ~= '') and bare or name)
            found = found + 1
        end
    end
    itemsDeferred = false
    if found > 0 then saveItems() end

    -- Even a partial scan is not junk: it honestly learns whatever cards are revealed.
    if found >= SCAN_MIN then
        scannedCases[caseId] = true
        logDebug(('case %d pool scanned: %d items'):format(caseId, found))
    elseif found == 0 then
        logDebug('pool came back empty, prizes not drawn yet?')
    end
end

-- Called from main(): here and only here does the inject leave.
local function pumpScan()
    if not scan.at or os.clock() < scan.at then return end
    scan.at = nil
    queueInject(scanJs(scan.caseId))
end

-- The case main screen is the only place where the whole pool sits in the DOM, and Svelte finishes drawing the list with a delay, hence the pause.
local function autoScan(caseId)
    if not caseId or caseId <= 0 or scannedCases[caseId] then return end
    requestScan(caseId, 0.8)
end

-- =========================================================================
-- Rendering helpers
-- =========================================================================

-- Draws text twice: white on a bright CEF window is unreadable without a shadow.
local function shadowText(text, col)
    local p = imgui.GetCursorPos()
    imgui.SetCursorPos(imgui.ImVec2(p.x + 1, p.y + 1))
    imgui.TextColored(COL_SHADOW, text)
    imgui.SetCursorPos(p)
    imgui.TextColored(col or COL_TEXT, text)
end

local function pushSmall()
    if fontSmall then imgui.PushFont(fontSmall) end
end

local function popSmall()
    if fontSmall then imgui.PopFont() end
end

-- imgui.Text* and SetTooltip are printf-like, so a «%» in the data mangles the output. An item name can contain anything, so escape before showing it.
local function esc(str)
    return (tostring(str):gsub('%%', '%%%%'))
end

-- A checkbox edits its config field and saves it right away.
local function toggle(label, ref, field, hint)
    if imgui.Checkbox(label, ref) then
        config.settings[field] = ref[0] and 1 or 0
        saveConfig()
    end
    if hint and imgui.IsItemHovered() then imgui.SetTooltip(hint) end
end

-- =========================================================================
-- Overlay
-- =========================================================================

local function renderOverlay()
    local id = caseInfo.id
    local collapsed = config.settings.ovl_collapsed == 1

    shadowText(esc(caseName(id)), COL_TEXT)

    -- Glyphs rather than words: a cross reads clearer than any caption and asks for no room.
    local mark = collapsed and ' + ' or ' - '
    local right = imgui.GetWindowContentRegionMax().x
    local closeW = imgui.CalcTextSize(' x ').x + 14

    imgui.SameLine(right - closeW * 2 - 6)
    if imgui.SmallButton(mark .. '##ovl_collapse') then
        config.settings.ovl_collapsed = collapsed and 0 or 1
        saveConfig()
    end

    imgui.SameLine(right - closeW)
    if imgui.SmallButton(' x ##ovl_close') then
        -- For this visit only: the panel comes back with the next case.
        winOn[0] = false
    end

    if collapsed then return end

    local counts = overlayCounts(id)

    pushSmall()
    shadowText('Открыто сегодня: ' .. formatNum(counts.today), COL_DIM)
    shadowText('Открыто всего: ' .. formatNum(counts.all), COL_DIM)
    popSmall()

    imgui.Separator()

    toggle('Пропускать анимацию открытия', cfgSkip, 'auto_skip')
    toggle('Показывать содержимое кейса', cfgOpenAll, 'auto_open_all')
    toggle('Автооткрытие следующего кейса', cfgAutoOpen, 'auto_open',
        'Скрипт сам жмёт «ОТКРЫТЬ», пока кейсы не кончатся.\n'
        .. 'Если предпочитаете контролировать процесс, выключите\n'
        .. 'и нажимайте Пробел.\n'
        .. 'Но что делать с наградами, вы в любом случае\n'
        .. 'решаете вручную.')

    -- Key hints live inside the case window itself, next to what they press.
    imgui.Separator()
    imgui.Spacing()
    if imgui.Button('Что выпадало', imgui.ImVec2(-1, 0)) then
        windowMode[0] = true
        geomDirty = true
        viewRev = -1
    end

end

-- =========================================================================
-- Window
-- =========================================================================

local function renderSummary(stats)
    imgui.BeginChild('##summary', imgui.ImVec2(-1, 34), true)

    imgui.Text('Открыто: ')
    imgui.SameLine(0, 0)
    imgui.TextColored(RARITY_COL.gold, formatNum(stats.totalOpens))
    imgui.SameLine()
    imgui.TextDisabled('|')
    imgui.SameLine()
    imgui.Text('Наломано осколков: ')
    imgui.SameLine(0, 0)
    imgui.TextColored(COL_SHARD, formatNum(stats.shards))

    if stats.caseCount > 1 then
        imgui.SameLine()
        imgui.TextDisabled('|')
        imgui.SameLine()
        imgui.TextDisabled('шанс считается по одному кейсу, выберите его слева')
    end

    imgui.EndChild()
end

-- Rows are rebuilt only when the aggregate, the search or the dictionary changes, not on every frame.
local rowsCache = { stats = nil, search = nil, itemsRev = -1, rows = nil }

local function prizeRows(stats, rawSearch)
    local c = rowsCache
    if c.rows and c.stats == stats and c.search == rawSearch and c.itemsRev == itemsRev then
        return c.rows
    end

    local search = lowerUtf8(rawSearch)
    local rows = {}
    for _, acc in pairs(stats.prizes) do
        local name = itemName(acc.item, acc.count)
        if search == '' or lowerUtf8(name):find(search, 1, true) then
            rows[#rows + 1] = { acc = acc, name = name,
                perDrop = acc.events > 0 and (stats.totalOpens / acc.events) or 0 }
        end
    end
    -- Rarest on top: that is what the table is looked at for.
    table.sort(rows, function(a, b) return a.perDrop > b.perDrop end)

    rowsCache = { stats = stats, search = rawSearch, itemsRev = itemsRev, rows = rows }
    return rows
end

local function renderPrizeTable(stats)
    local rows = prizeRows(stats, ffi.string(searchBuf))

    local widths = { 70, 85, 100 }
    local used = 0
    for _, w in ipairs(widths) do used = used + w end
    local nameWidth = imgui.GetContentRegionAvail().x - used

    local function columns()
        imgui.Columns(4, '##prizes', false)
        imgui.SetColumnWidth(0, nameWidth)
        for i, w in ipairs(widths) do imgui.SetColumnWidth(i, w) end
    end

    columns()
    imgui.TextColored(COL_MUTED, 'Предмет')
    for _, title in ipairs({ 'Забрал', 'Расколол', 'Шанс' }) do
        imgui.NextColumn()
        imgui.TextColored(COL_MUTED, title)
    end
    imgui.Columns(1)
    imgui.Separator()

    for _, row in ipairs(rows) do
        columns()

        -- The count is already inside the label: a row is one prize variant.
        imgui.TextColored(itemColor(row.acc.item, row.acc.count), esc(row.name))
        imgui.NextColumn()

        if row.acc.taken > 0 then
            imgui.TextColored(COL_TEXT, tostring(row.acc.taken))
        else
            imgui.TextDisabled('0')
        end
        imgui.NextColumn()

        if row.acc.sharded > 0 then
            imgui.TextColored(COL_SHARD, tostring(row.acc.sharded))
        else
            imgui.TextDisabled('0')
        end
        imgui.NextColumn()

        -- With several case types mixed the denominator is foreign: events of one case would be divided by openings of all. Showing nothing is more honest.
        if stats.caseCount > 1 then
            imgui.TextDisabled('-')
        else
            -- esc is mandatory: «3.4%» would arrive as «3.4», imgui.Text is printf.
            imgui.TextColored(COL_DIM, esc(formatChance(row.acc.events, stats.totalOpens)))
        end

        imgui.Columns(1)
    end

    if #rows == 0 then
        imgui.TextDisabled('Пусто')
    end
end

local function renderWindow()
    local stats = view()

    imgui.PushItemWidth(160)
    imgui.InputTextWithHint('##search', 'Поиск по предмету...', searchBuf, ffi.sizeof(searchBuf))
    imgui.PopItemWidth()


    imgui.Spacing()
    renderSummary(stats)

    imgui.BeginChild('##filters', imgui.ImVec2(150, -1), true)

    local function pick(label, id, active)
        if active then
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.3, 0.5, 0.3, 1.0))
        end
        local hit = imgui.Button(esc(label) .. '##' .. id, imgui.ImVec2(-1, 0))
        if active then imgui.PopStyleColor() end
        return hit
    end

    -- Cases are few and the list is stable while dates pile up without limit, so cases go on top and dates are what scrolls away.
    if pick('Все кейсы', 'allcases', selectedCase == '') then
        selectedCase = ''
        viewRev = -1
    end
    for _, key in ipairs(openedCases()) do
        if pick(caseName(tonumber(key)), 'case' .. key, selectedCase == key) then
            selectedCase = key
            viewRev = -1
        end
    end

    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()

    if pick('Всё время', 'alltime', selectedDate == '') then
        selectedDate = ''
        viewRev = -1
    end
    for _, date in ipairs(sortedDates()) do
        if pick(formatDate(date), date, selectedDate == date) then
            selectedDate = date
            viewRev = -1
        end
    end

    imgui.EndChild()

    imgui.SameLine()

    imgui.BeginChild('##prizes_panel', imgui.ImVec2(-1, -1), true)
    renderPrizeTable(stats)
    imgui.EndChild()
end

-- =========================================================================
-- Frames
-- =========================================================================

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil
    io.Fonts:Clear()

    local ranges = io.Fonts:GetGlyphRangesCyrillic()
    io.Fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\trebucbd.ttf', 15.0, nil, ranges)

    pcall(function()
        local path = getFolderPath(0x14) .. '\\arial.ttf'
        if doesFileExist(path) then
            fontSmall = io.Fonts:AddFontFromFileTTF(path, 12, nil, ranges)
        end
    end)

    imgui.InvalidateFontsTexture()

    local style = imgui.GetStyle()
    style.WindowRounding = 8.0
    style.ChildRounding = 6.0
    style.FrameRounding = 5.0
    style.ScrollbarSize = 10.0
    style.ItemSpacing = imgui.ImVec2(8, 4)
    style.WindowPadding = imgui.ImVec2(10, 8)
end)

imgui.OnFrame(function() return winOn[0] end, function(player)
    local overlay = not windowMode[0]
    player.HideCursor = overlay
    player.LockPlayer = not overlay

    local flags = imgui.WindowFlags.NoCollapse
    if overlay then
        -- The overlay does take the mouse: inside the case window there is nothing else to click but «ОТКРЫТЬ» in the centre, and the panel sits on the left without covering it.
        flags = flags
            + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize
            + imgui.WindowFlags.NoNav
            + imgui.WindowFlags.NoFocusOnAppearing + imgui.WindowFlags.NoScrollbar
    end

    local sw, sh = getScreenResolution()
    local s = config.settings
    local x, y, w, h

    if overlay then
        w, h = s.ovl_w, 0
        -- By default it lands on the «Похожие кейсы» list: with a backdrop that reads as a panel of its own and covers the least useful thing on screen. Fractions rather than pixels, because the launcher UI scales with the resolution.
        x = (s.ovl_x >= 0) and s.ovl_x or math.floor(sw * 0.035)
        y = (s.ovl_y >= 0) and s.ovl_y or math.floor(sh * 0.19)
    else
        w, h = s.win_w, s.win_h
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
    if overlay then
        -- Fixed width, zero height means fit to content: with a backdrop the spare room would turn into a visible empty rectangle.
        imgui.SetNextWindowSize(imgui.ImVec2(w, 0), imgui.Cond.Always)
        imgui.PushStyleColor(imgui.Col.WindowBg, COL_OVL_BG)
    else
        imgui.SetNextWindowSize(imgui.ImVec2(w, h), cond)
    end

    if imgui.Begin('Case Opener v' .. thisScript().version .. '##main', winOn, flags) then
        if overlay then
            -- The panel is dragged by mouse; the position is written with a delay, otherwise every frame of a drag would hit the disk.
            local pos = imgui.GetWindowPos()
            if math.abs(pos.x - s.ovl_x) > 1 or math.abs(pos.y - s.ovl_y) > 1 then
                s.ovl_x, s.ovl_y = math.floor(pos.x), math.floor(pos.y)
                cfgSaveAt = os.clock() + 1.0
            end
            renderOverlay()
        else
            -- Only this mode can be moved and resized, so only it is saved.
            local pos, size = imgui.GetWindowPos(), imgui.GetWindowSize()
            s.win_x, s.win_y = pos.x, pos.y
            s.win_w, s.win_h = size.x, size.y
            renderWindow()
        end
    end
    imgui.End()
    if overlay then imgui.PopStyleColor() end

    -- The log was closed while the case window is still open: go back to the overlay rather than to nothing. The window cross, Esc and the button behave alike.
    if not overlay and not winOn[0] and inCase then
        winOn[0] = true
        windowMode[0] = false
        geomDirty = true
    end
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

-- The case window opened or closed.
local function setActiveView(name)
    local nowInCase = name == 'OpenCase'
    if nowInCase == inCase then return end
    inCase = nowInCase

    if inCase then
        decorate()
        if not winOn[0] then
            winOn[0] = true
            windowMode[0] = false
            geomDirty = true
        end
    else
        autoOpenAt = nil
        -- Closing the window makes the server take everything the player left undecided.
        autoTakeRemaining()
        if winOn[0] and not windowMode[0] then
            winOn[0] = false
        end
    end
end

local function handleEvent(event, payload)
    if event == 'event.setActiveView' then
        local ok, args = pcall(decodeJson, payload)
        setActiveView(ok and type(args) == 'table' and args[1] or nil)
        return
    end

    if event == 'openCase.initializeMainInfo' then
        local ok, args = pcall(decodeJson, payload)
        local data = ok and type(args) == 'table' and args[1]
        if type(data) ~= 'table' then return end
        -- A partial payload (current only) must not wipe the rest.
        if data.caseId then caseInfo.id = tonumber(data.caseId) or caseInfo.id end
        if data.count then caseInfo.count = tonumber(data.count) or caseInfo.count end
        if data.current then caseInfo.current = tonumber(data.current) or caseInfo.current end
        if data.total then caseInfo.total = tonumber(data.total) or caseInfo.total end
        return
    end

    if event == 'openCase.initializeRewards' then
        local ok, args = pcall(decodeJson, payload)
        local list = ok and type(args) == 'table' and args[1]
        if type(list) == 'table' and #list > 0 then
            onRewards(list, caseInfo.id)
        end
        return
    end

    if event == 'openCase.selectVideo' then
        if config.settings.auto_skip == 1 then skipVideo() end
        -- It waits for its own moment: the cards screen shows up after the video.
        if config.settings.auto_open_all == 1 then openAllCards() end
        return
    end

    if event == 'openCase.selectScreen' then
        -- Arrives once the prizes are dealt with: every informer is already behind us.
        if pending and pending.readyAt then flushPending() end
        -- The same signal means we are on the main screen, where the pool lives.
        local ok, args = pcall(decodeJson, payload)
        if ok and type(args) == 'table' and args[1] == 'main' and inCase then
            autoScan(caseInfo.id)
            -- The screen returns to main only once the prizes are dealt with, so the loop paces itself: open, decide, open.
            if config.settings.auto_open == 1 and not pending and caseInfo.count > 0 then
                autoOpenAt = os.clock() + AUTO_OPEN_DELAY
            end
        end
        return
    end

    if event == 'event.damageInformer.initializeDamageInfo' then
        local ok, args = pcall(decodeJson, payload)
        local data = ok and type(args) == 'table' and args[1]
        if type(data) ~= 'table' then return end

        local itemId = tonumber(data.imageId)
        local name = data.name and cyr:decode(data.name) or nil
        local amount = tonumber(tostring(data.tag or ''):match('^%+(%d+)$'))

        if itemId and itemId == ITEM_SHARDS and amount then
            takeShardAmount(amount)
            learnItem(itemId, name)
        elseif itemId and name then
            -- A taken item is the only source of its own name.
            learnItem(itemId, name)
        end
        return
    end
end

local function readIncoming(bs)
    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) ~= 17 then return end
    raknetBitStreamIgnoreBits(bs, 32)
    local length = raknetBitStreamReadInt16(bs)
    local encoded = raknetBitStreamReadInt8(bs)
    local str = (encoded ~= 0)
        and raknetBitStreamDecodeString(bs, length + encoded)
        or raknetBitStreamReadString(bs, length)
    if not str or not str:find('window.executeEvent', 1, true) then return end

    -- Case events carry no event. prefix, so filtering by it would lose them.
    local event = str:match("window%.executeEvent%('([^']+)'")
    if not event then return end

    local payload = str:match("',%s*`(.-)`%s*%)")
        or str:match("',%s*'(.-)'%s*%)")
    if not payload then return end

    handleEvent(event, payload)
end

-- Returns false for our own scan answer: it must not reach the server.
local function readOutgoing(bs)
    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) ~= 18 then return end
    local length = raknetBitStreamReadInt16(bs)
    local str = raknetBitStreamReadString(bs, length)
    if not str or #str < 3 then return end

    if str:find(SCAN_MSG, 1, true) == 1 then
        onScanAnswer(str:sub(#SCAN_MSG + 1))
        return false
    end

    local sell = str:match('^openCase%.sell|(.+)$')
    if sell then
        setFate(parseIndices(sell), 'shard')
        return
    end

    local save = str:match('^openCase%.save|(.+)$')
    if save then
        setFate(parseIndices(save), 'take')
        return
    end
end

-- Other scripts read packet 220 too: rewind before and after parsing, and keep a parse error from killing the script.
function onReceivePacket(id, bs)
    if id ~= 220 or not bs then return end
    raknetBitStreamResetReadPointer(bs)
    local ok, err = pcall(readIncoming, bs)
    raknetBitStreamResetReadPointer(bs)
    if not ok then logDebug('onReceivePacket: ' .. tostring(err)) end
end

-- The pcall only carries the verdict out: a return false from inside it would never reach the game.
function onSendPacket(id, bs)
    if id ~= 220 or not bs then return end
    raknetBitStreamResetReadPointer(bs)
    local ok, result = pcall(readOutgoing, bs)
    raknetBitStreamResetReadPointer(bs)
    if not ok then
        logDebug('onSendPacket: ' .. tostring(result))
        return
    end
    if result == false then return false end
end

function sampev.onServerMessage(color, rawText)
    local text = cyr:decode(rawText)
    if not text:find('раскололи предмет', 1, true) then return end

    local name = text:match('раскололи предмет "(.-)"')
    if name then takeShardName(name) end
end

-- Skin bonus: the dialog arrives between openCase.open and initializeRewards, so the case is already known while the prizes are not drawn yet.
function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if not inCase then return end

    local body = cyr:decode(tostring(text or ''))
    local head = cyr:decode(tostring(title or ''))
    if not (body:find(BONUS_MARK, 1, true) or head:find(BONUS_TITLE, 1, true)) then
        return
    end

    for _, bonus in ipairs(DIALOG_BONUSES) do
        if body:find(bonus.find, 1, true) then
            learnItem(bonus.item, bonus.name, bonus.rarity)

            local bucket = ensureCase(today(), caseInfo.id)
            local key = prizeKey(bonus.item, bonus.count)
            local rec = bucket.prizes[key]
                or { item = bonus.item, count = bonus.count,
                     events = 0, taken = 0, sharded = 0 }
            rec.events = rec.events + 1
            -- There is no choice to make: the item is already credited.
            rec.taken = rec.taken + 1
            bucket.prizes[key] = rec
            saveHistory()
            return
        end
    end

    -- An unknown bonus has no id to record, so it goes to the console until the item behind it is identified.
    logRaw('незнакомый бонус, dialog id=' .. dialogId)
    logRaw(tostring(text))
end

-- =========================================================================
-- SELF-UPDATE (/caseupdate)
-- =========================================================================

local UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/manifest.json'
local UPDATE_BASE_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/'
local UPDATE_SCRIPT_ID = 'case-opener'
local UPDATE_MANIFEST_TIMEOUT = 10 -- seconds.
local UPDATE_FILE_TIMEOUT = 30 -- seconds, file is bigger than the manifest.
-- No forum topic yet: the manual fallback is the releases page.
local UPDATE_RELEASES_URL = 'https://github.com/TheMY3/arzhub-scripts/releases'

-- "2.10.0" -> 2010000, so versions compare numerically.
local function versionNum(v)
    local a, b, c = tostring(v or ''):match('^(%d+)%.(%d+)%.(%d+)$')
    if not a then return nil end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
end

-- Unguarded on purpose: removing a missing file is a harmless no-op.
local function removeIfExists(path)
    return os.remove(path)
end

-- Whichever of {callback, timeout} fires first wins, the other one is a no-op.
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

-- current -> current.old, tmp -> current, rolled back on failure.
local function atomicReplace(targetPath, tempPath)
    local oldPath = targetPath .. '.old'
    removeIfExists(oldPath)
    if not os.rename(targetPath, oldPath) then
        return false, 'не смог отложить текущий файл в сторону'
    end
    if not os.rename(tempPath, targetPath) then
        os.rename(oldPath, targetPath)
        return false, 'не смог поставить новый файл на место, откатил обратно'
    end
    return true
end

local function manualUrl(entry)
    return (entry and entry.topic and entry.topic ~= '') and entry.topic or UPDATE_RELEASES_URL
end

local function finishUpdate(entry, tempPath)
    local content = readFile(tempPath)
    local gotVersion = content and content:match("script_version%(['\"]([%d%.]+)['\"]%)")

    if not gotVersion then
        removeIfExists(tempPath)
        chat('Обновление не удалось: скачанный файл не похож на скрипт. Скачайте вручную: {5CC9FF}' .. manualUrl(entry))
        return
    end
    if gotVersion == thisScript().version then
        -- The CDN still serves the previous file right after a release.
        removeIfExists(tempPath)
        chat('CDN ещё отдаёт старую версию, попробуйте через пару минут: {5CC9FF}/caseupdate')
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
        chat('Обновление не удалось: ' .. err .. '. Скачайте вручную: {5CC9FF}' .. manualUrl(entry))
        return
    end

    chat('Обновлено до {5CC9FF}v' .. entry.version .. '{FFFFFF}, перезагружаю скрипт...')
    lua_thread.create(function()
        wait(300)
        thisScript():reload()
    end)
end

local function downloadUpdate(entry)
    -- A second download from inside the first one's callback fails as busy, so wait a tick.
    lua_thread.create(function()
        wait(250)
        local tempPath = thisScript().path .. '.tmp'
        removeIfExists(tempPath)
        local dl_status = moonloader.download_status
        local claim = withTimeout(UPDATE_FILE_TIMEOUT, function()
            removeIfExists(tempPath)
            chat('Обновление не удалось: таймаут скачивания. Скачайте вручную: {5CC9FF}' .. manualUrl(entry))
        end)
        downloadUrlToFile(UPDATE_BASE_URL .. entry.path, tempPath, function(_, status)
            if status == dl_status.STATUS_ENDDOWNLOADDATA then
                if claim() then finishUpdate(entry, tempPath) end
            elseif status == dl_status.STATUSEX_ENDDOWNLOAD then
                if claim() then
                    removeIfExists(tempPath)
                    chat('Не удалось скачать обновление. Скачайте вручную: {5CC9FF}' .. manualUrl(entry))
                end
            end
        end)
    end)
end

-- Exactly one of onEntry(entry) / onError(why) fires.
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
            if not ok or type(data) ~= 'table' or not data.scripts then
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

-- Strictly "remote > local": a newer local build is never rolled back.
local function isNewer(entry)
    local remote, current = versionNum(entry.version), versionNum(thisScript().version)
    return remote and current and remote > current
end

local function checkForUpdate()
    chat('Проверяю обновления...')
    fetchManifestEntry(
        function(entry)
            if not isNewer(entry) then
                chat('У вас последняя версия (v' .. thisScript().version .. ').')
                return
            end
            chat('Найдено обновление: v' .. entry.version .. '. Скачиваю...')
            downloadUpdate(entry)
        end,
        function(reason)
            chat('Не удалось проверить обновления (' .. reason .. '). Скачать вручную: {5CC9FF}' .. manualUrl())
        end
    )
end

-- Once at load: silent unless an update exists, never downloads by itself.
local function checkForUpdateSilently()
    fetchManifestEntry(
        function(entry)
            if isNewer(entry) then
                chat('Доступна новая версия {5CC9FF}v' .. entry.version .. '{FFFFFF}! Обновить: {5CC9FF}/caseupdate')
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
    -- Leftovers of an interrupted update; .old stays as the way back.
    removeIfExists(thisScript().path .. '.tmp')
    removeIfExists(thisScript().path .. '.manifest.tmp')

    loadAll()

    -- Printed on every login, so it stays short and says the one thing nobody guesses: the script shows nothing until a case is opened.
    chat('Загружен {5CC9FF}v' .. thisScript().version .. '{FFFFFF}. Откройте кейс, панель появится сама. Что выпадало: {5CC9FF}/caselogs')

    -- /caselogs always means «show me the window»: it opens from nothing, switches the overlay into the window, and only closes when already there.
    local function cmdLog()
        if winOn[0] and windowMode[0] then
            winOn[0] = false
            saveConfig()
            return
        end
        winOn[0] = true
        windowMode[0] = true
        geomDirty = true
        viewRev = -1
    end

    sampRegisterChatCommand('caselogs', cmdLog)
    sampRegisterChatCommand('caseupdate', checkForUpdate)
    checkForUpdateSilently()

    while true do
        wait(0)

        -- The only place an inject leaves from: emulating an incoming packet inside a packet hook or a coroutine kills the script.
        while #injectQueue > 0 do
            evalcef(table.remove(injectQueue, 1))
        end

        pumpScan()

        -- Shard informers arrive after the outgoing packet, hence the deferred write.
        if pending and pending.readyAt and os.clock() >= pending.readyAt then
            flushPending()
        end

        local keysLive = not sampIsChatInputActive()
            and not sampIsDialogActive() and not isPauseMenuActive()

        -- A fullscreen CEF window takes over control: the character ignores keys, so there is nothing to take away from the game. Disabled while the log window is up, where fields accept input.
        if keysLive and inCase and not windowMode[0] then
            if isKeyJustPressed(config.settings.action_key) then
                pressActionButton()
            end
            -- Both the top row and the numpad.
            for i = 1, 9 do
                if isKeyJustPressed(0x30 + i) or isKeyJustPressed(0x60 + i) then
                    pressPrizeKey('card', i)
                end
            end
            if config.settings.take_key > 0 and isKeyJustPressed(config.settings.take_key) then
                pressPrizeKey('take')
            end
            if config.settings.shard_key > 0 and isKeyJustPressed(config.settings.shard_key) then
                pressPrizeKey('shard')
            end
        end

        -- Auto-opening spends cases, so the conditions are checked once more: during the pause the player could have left or switched it off.
        if autoOpenAt and os.clock() >= autoOpenAt then
            autoOpenAt = nil
            if inCase and config.settings.auto_open == 1 and not pending
                    and caseInfo.count > 0 then
                pressActionButton()
            end
        end

        if cfgSaveAt and os.clock() >= cfgSaveAt then
            cfgSaveAt = nil
            saveConfig()
        end
    end
end
