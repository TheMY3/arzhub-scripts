script_author('TheMY3')
script_name('[TM] Crypto Collector')
script_version('2.5.0')

-- Тема на форуме (актуальная версия, обсуждение): https://www.blast.hk/threads/243868/

local sampev = require("samp.events")
local inicfg = require('inicfg')
local moonloader = require('moonloader')  -- Needed for moonloader.download_status (SELF-UPDATE region).
-- The window is built on mimgui, and not everyone has it. Hence the pcall: with no library the script still works like 2.3.0 - collection, history, settings from the ini, output to the chat.
local hasWindow, imgui = pcall(require, 'mimgui')
if not hasWindow then imgui = nil end
local encoding = require('encoding')
encoding.default = 'UTF-8'
local cyr = encoding.CP1251
local u8 = encoding.UTF8  -- imgui wants UTF-8, while the chat and the clipboard want CP1251.

-- CONSTANTS
-- Dialogs are recognized by title, not by id. A server update shifted the ids and collection stalled on the foreign-dialog guard. MiningToolFixed does the same.
local DIALOG_HOUSE_LIST = 'houses'
local DIALOG_CARDS_LIST = 'cards'
local DIALOG_CARD_ACTION = 'action'
local DIALOG_WITHDRAW = 'withdraw'

--- Dialog kind by title, or nil for a foreign dialog. Color tags and hyphens are stripped: the server inserts them unpredictably.
local function dialogKind(title)
	local clean = tostring(title):gsub('{%x%x%x%x%x%x}', ''):gsub('%-', '')
	if clean:find('Выбор дома', 1, true) then return DIALOG_HOUSE_LIST end
	if clean:find('Выберите видеокарту', 1, true) then return DIALOG_CARDS_LIST end
	if clean:find('Вывод прибыли', 1, true) then return DIALOG_WITHDRAW end
	if clean:find('Стойка №%d+ | Полка №%d+') then return DIALOG_CARD_ACTION end
	return nil
end

local CONFIG_FILE = 'TheMY3\\crypto\\config.ini'
local DEBUG_TARGETS = {chat = true, log = true, both = true}
local config = {
	settings = {
		-- No CEF packets at all: no progress ticker, no popup notifications. Results still go to the chat, so a remote/headless client loses nothing it could have seen.
		silent = false,
		-- 0 off, 1 key stages, 2 stages plus raw CEF strings (noisy - one ticker row per second).
		debug_level = 0,
		-- 'chat' | 'log' | 'both'. 'log' means the moonloader console plus our own file.
		debug_target = 'log',
		-- Cooling thresholds in percent: below urgent = red, below soon = orange.
		cooling_urgent = 20,
		cooling_soon = 50,
		-- Electricity account thresholds in MILLIONS (the account tops out at 60).
		balance_urgent = 12,
		balance_soon = 30,
		-- House numbers to skip during collection, comma-separated (e.g. "821,456").
		ignored_houses = '',
	}
}
-- Mirrors of config.settings, kept as plain locals because debugLog reads them on every line.
local DEBUG_LEVEL = config.settings.debug_level
local DEBUG_TARGET = config.settings.debug_target

-- Maintenance and balance thresholds. The values come from the config (loadConfig), these are only the initial ones - they double as the defaults when the file is missing.
local COOLING_URGENT = 20        -- Needs servicing urgently, %.
local COOLING_SOON = 50          -- Needs servicing soon, %.
local BALANCE_URGENT = 12000000  -- Top up the account urgently.
local BALANCE_SOON   = 30000000  -- Top up the account soon.
local BALANCE_MAX_MLN = 60       -- Electricity account ceiling, millions (the stepper scale).

-- Live progress ticker (CEF damageInformer): resending with the same id updates the row in place, and it fades out showTime ms after the last update.
-- Single row: name = house counter, badge = cards state.
local TICKER_ID = 690100  -- The server countdown timer occupies 690000.
local TICKER_SHOW_TIME = 7000
local TICKER_BADGE_COLOR = '#32CD32'  -- The badge shows the collected total.

local tag = '{FFA500}[TM] Crypto Collector{FFFFFF}: '
local FORUM_URL = 'https://www.blast.hk/threads/243868/'  -- Manual fallback when self-update fails, and the link in the help tab.

local function configDir()
	local parent = getWorkingDirectory() .. '\\config\\TheMY3'
	if not doesDirectoryExist(parent) then
		createDirectory(parent)
	end
	local dir = parent .. '\\crypto'
	if not doesDirectoryExist(dir) then
		createDirectory(dir)
	end
	return dir
end

--- Path of the standalone debug log (see debugLog for why it lives next to moonloader.log).
local function debugFilePath()
	return configDir() .. '\\debug.log'
end

--- Whole file as a string, or nil when it is not there. Shared by the history/config readers and by the SELF-UPDATE region.
local function readFile(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local content = f:read('*a')
	f:close()
	return content
end

--- Clamp a hand-edited ini number into range, falling back when it is not a number at all.
local function asNumber(value, fallback, min, max)
	local n = tonumber(value)
	if not n then return fallback end
	return math.max(min, math.min(max, math.floor(n)))
end

--- Coerce an ini value to a boolean: for a hand-edited file inicfg may hand back a string.
local function asBool(value, fallback)
	if type(value) == 'boolean' then return value end
	if value == 'true' or value == '1' or value == 1 then return true end
	if value == 'false' or value == '0' or value == 0 then return false end
	return fallback
end

--- Load settings from the ini, falling back to the defaults above for anything missing or out of range. Hand-edited files are expected, so every value is validated.
local function loadConfig()
	local loaded = inicfg.load(config, CONFIG_FILE)
	if type(loaded) == 'table' and type(loaded.settings) == 'table' then
		config = loaded
	end
	local s = config.settings
	s.silent = asBool(s.silent, false)
	s.debug_level = asNumber(s.debug_level, 0, 0, 2)
	s.debug_target = DEBUG_TARGETS[tostring(s.debug_target)] and s.debug_target or 'log'
	s.cooling_urgent = asNumber(s.cooling_urgent, 20, 0, 100)
	s.cooling_soon = asNumber(s.cooling_soon, 50, 0, 100)
	s.balance_urgent = asNumber(s.balance_urgent, 12, 0, BALANCE_MAX_MLN)
	s.balance_soon = asNumber(s.balance_soon, 30, 0, BALANCE_MAX_MLN)
	-- "Urgent" cannot be milder than "soon" - otherwise the orange band disappears.
	s.cooling_urgent = math.min(s.cooling_urgent, s.cooling_soon)
	s.balance_urgent = math.min(s.balance_urgent, s.balance_soon)
	s.ignored_houses = tostring(s.ignored_houses or '')

	DEBUG_LEVEL, DEBUG_TARGET = s.debug_level, s.debug_target
	COOLING_URGENT, COOLING_SOON = s.cooling_urgent, s.cooling_soon
	BALANCE_URGENT = s.balance_urgent * 1000000
	BALANCE_SOON = s.balance_soon * 1000000
end

--- Persist settings. configDir() is called first because inicfg will not create the subfolder.
local function saveConfig()
	configDir()
	return inicfg.save(config, CONFIG_FILE)
end

--- Ignored house numbers as a set, keyed by the number as a string.
local function parseIgnoredHouses()
	local ignored = {}
	for numStr in config.settings.ignored_houses:gmatch('[^,]+') do
		local trimmed = numStr:match('^%s*(%d+)%s*$')
		if trimmed then ignored[trimmed] = true end
	end
	return ignored
end

--- Persist an ignored-house set back into the comma-separated string, sorted for a stable ini diff.
local function saveIgnoredHouses(ignored)
	local list = {}
	for numStr in pairs(ignored) do table.insert(list, numStr) end
	table.sort(list, function(a, b) return tonumber(a) < tonumber(b) end)
	config.settings.ignored_houses = table.concat(list, ',')
	saveConfig()
end

local function addIgnoredHouse(numStr)
	local ignored = parseIgnoredHouses()
	if not ignored[numStr] then
		ignored[numStr] = true
		saveIgnoredHouses(ignored)
	end
end

local function removeIgnoredHouse(numStr)
	local ignored = parseIgnoredHouses()
	if ignored[numStr] then
		ignored[numStr] = nil
		saveIgnoredHouses(ignored)
	end
end

loadConfig()

-- Where the current debug line comes from: set by the event handlers and by the main loop. Shows whether a CEF send happened inside a RakNet callback or on the main tick.
local debugCtx = 'main'
local cefSeq = 0  -- Running number of visualCEF calls, to pair the CEF> and CEF< markers.
local visualCEF   -- Defined below, but the ticker declared above already needs it.

-- Debug output.
---@param message string raw UTF-8 text, may carry {RRGGBB} tags for the chat output.
---@param level number|nil minimal DEBUG_LEVEL required to print (default 1).
---@param encoded boolean|nil true if message is already CP1251 (skip the conversion).
local function debugLog(message, level, encoded)
	if DEBUG_LEVEL < (level or 1) then
		return
	end
	local cp = encoded and message or cyr(message)
	if DEBUG_TARGET ~= 'log' then
		sampAddChatMessage(tag .. '{808080}[DEBUG] ' .. cp, -1)
	end
	if DEBUG_TARGET ~= 'chat' then
		-- Console and file get no color tags, but they do get a timestamp and the calling context.
		local plain = string.format('%s[%s] %s', os.date('[%H:%M:%S] '), debugCtx, (cp:gsub('{%x%x%x%x%x%x}', '')))
		print(plain)
		-- Reopened and closed on every line on purpose: a hard crash must not eat the tail, and nobody promises moonloader.log is flushed per line.
		local f = io.open(debugFilePath(), 'a')
		if f then
			f:write(plain .. '\n')
			f:close()
		end
	end
end

-- Auto-collection state.
local isEnabled = false  -- Profit auto-collection mode.
local collectingHouses = {}  -- Houses to walk through.
local currentHouseIndex = 0  -- Current house index.
local currentHouseCollected = {btc = 0, asc = 0}  -- Collected from the current house.
local isCollecting = false  -- Card collection mode.
local cryptoAnalysys = {btc = 0, asc = 0}  -- Crypto collected over the run.
local isMiningToolActive = false  -- Whether MiningTool was active at startup.
local expectedDialog = nil  -- Kind of the expected dialog, the guard against a foreign one.
local isEnablingInHouse = false  -- Card-enabling phase in the current house.
local enabledCardsCount = 0  -- Cards enabled during the session.
local houseProfitableCards = 0  -- Cards with profit >= 1 in the current house (ticker total).
local houseCollectedCards = 0  -- Cards withdrawn in the current house (ticker progress).
-- Ticker state: rows are resent every second the way the server does it, while events only change the content.
local ticker = {active = false, cardsText = '...', lastSent = 0}
local runStartedAt = 0  -- os.time() when /crypto started, needed for the duration.

--- Build one damageInformer row object (texts must be CP1251-encoded).
---@param rowId number
---@param name string white label, CEF renders it uppercase.
---@param value string green text rendered to the LEFT of the name ('' = none).
---@param badgeText string
---@param badgeColor string '#RRGGBB', background color of the badge.
---@param showTime number|nil row lifetime in ms (default TICKER_SHOW_TIME).
local function tickerRowJson(rowId, name, value, badgeText, badgeColor, showTime)
	local safeText = badgeText:gsub('\\', '\\\\'):gsub('"', '\\"')
	return string.format(
		'{"type":"incoming","id":%d,"name":"%s","nameColor":"#FFFFFF","value":"%s","valueColor":"#32CD32","imageType":0,"imageId":-1,"showTime":%d,"tag":"%s","tagTextColor":"#000000","tagBackgroundColor":"%s"}',
		rowId, name, value, showTime or TICKER_SHOW_TIME, safeText, badgeColor
	)
end

--- Resend the single ticker row: name = house counter and cards state, badge = collected total, and the badge color encodes the phase. Mirrors the server countdown mechanics: one row, same id, a resend once per second.
---@param showTime number|nil row lifetime in ms for this send (default TICKER_SHOW_TIME).
local function sendTickerRows(showTime)
	-- Silent mode: bail out before building the row, nothing downstream needs it.
	if config.settings.silent then
		return
	end
	local name = #collectingHouses > 0
		and string.format('Дом %d/%d · %s', currentHouseIndex, #collectingHouses, ticker.cardsText)
		or 'Поиск домов...'
	local collectedParts = {}
	if cryptoAnalysys.btc > 0 then
		table.insert(collectedParts, '+' .. cryptoAnalysys.btc .. ' BTC')
	end
	if cryptoAnalysys.asc > 0 then
		table.insert(collectedParts, '+' .. cryptoAnalysys.asc .. ' ASC')
	end
	-- No badge at all until something is collected.
	local badge = #collectedParts > 0 and 'всего ' .. table.concat(collectedParts, ' ') or ''
	if badge ~= '' then
		name = name .. ' ·'
	end
	-- The second executeEvent argument is a template-literal STRING in backticks, not a raw array.
	local str = string.format(
		'window.executeEvent(\'event.damageInformer.initializeDamageInfo\', `[%s]`);',
		tickerRowJson(TICKER_ID, cyr(name), '', cyr(badge), TICKER_BADGE_COLOR, showTime)
	)
	-- Already CP1251: name and badge went through cyr, converting them twice is not allowed.
	debugLog('ticker OUT: ' .. str, 2, true)
	visualCEF(str, true)
	ticker.lastSent = os.clock()
end

--- Stop the ticker: a final resend with a short lifetime so the row fades quickly instead of hanging for the full TICKER_SHOW_TIME.
local function stopTicker()
	ticker.active = false
	sendTickerRows(2500)
end

--- Update the ticker content and push it immediately.
---@param cardsText string raw UTF-8 for the cards slot in the name, encoded on send.
local function updateTicker(cardsText)
	ticker.active = true
	ticker.cardsText = cardsText
	sendTickerRows()
end

-- Local history in two files with different jobs: history.jsonl - one run per line, full per-house detail, ages out and gets trimmed; daily.json - per-day totals, tiny, kept forever. Details are what a player wants for recent runs, while the day totals are what the "all time" period needs, and they cost about 50 bytes a day, so nothing is ever really lost.
local HISTORY_TRIM_BYTES = 1024 * 1024  -- Trim once the detail file passes ~1 MB.
local HISTORY_KEEP = 500                -- How many of the newest records survive a trim.

local function historyPath()
	return configDir() .. '\\history.jsonl'
end

local function dailyPath()
	return configDir() .. '\\daily.json'
end

--- Read the run history, skipping unparsable lines. A hard crash can leave the last line torn, and that must cost one record rather than the whole file. Oldest first.
---@return table[]
local function readHistory()
	local runs = {}
	local f = io.open(historyPath(), 'r')
	if not f then
		return runs
	end
	for line in f:lines() do
		if line ~= '' then
			local ok, record = pcall(decodeJson, line)
			if ok and type(record) == 'table' then
				table.insert(runs, record)
			end
		end
	end
	f:close()
	return runs
end

--- Append one run, then trim if the file outgrew HISTORY_TRIM_BYTES. Appending cannot corrupt what is already written, which matters in a script that sometimes takes the game down mid-run.
local function appendHistory(run)
	-- One run per line is the whole contract, so any newline inside the record breaks it.
	local encoded = encodeJson(run):gsub('[\r\n]', ' ')
	local f = io.open(historyPath(), 'a')
	if not f then
		debugLog('appendHistory: не удалось открыть ' .. historyPath())
		return
	end
	f:write(encoded .. '\n')
	local size = f:seek('end')
	f:close()

	if not size or size <= HISTORY_TRIM_BYTES then
		return
	end

	local runs = readHistory()
	local first = math.max(1, #runs - HISTORY_KEEP + 1)
	local kept = {}
	for i = first, #runs do
		table.insert(kept, (encodeJson(runs[i]):gsub('[\r\n]', ' ')))
	end
	local tmpPath = historyPath() .. '.tmp'
	local out = io.open(tmpPath, 'w')
	if not out then
		debugLog('appendHistory: не удалось открыть ' .. tmpPath .. ' для обрезки')
		return
	end
	out:write(table.concat(kept, '\n') .. '\n')
	out:close()
	os.remove(historyPath())
	os.rename(tmpPath, historyPath())
	debugLog(string.format('appendHistory: история обрезана, осталось %d записей', #kept))
end

--- Add the run to the per-day totals. The day is local time on purpose: the player thinks in their own day, not in UTC.
local function updateDaily(run)
	local daily = {}
	local content = readFile(dailyPath())
	if content then
		local ok, decoded = pcall(decodeJson, content)
		if ok and type(decoded) == 'table' then
			daily = decoded
		end
	end

	local day = os.date('%Y-%m-%d')
	local entry = daily[day]
	if type(entry) ~= 'table' then
		entry = {btc = 0, asc = 0, runs = 0}
		daily[day] = entry
	end
	entry.btc = (tonumber(entry.btc) or 0) + (run.total.btc or 0)
	entry.asc = (tonumber(entry.asc) or 0) + (run.total.asc or 0)
	entry.runs = (tonumber(entry.runs) or 0) + 1

	-- The same temp-then-rename dance as the outbox: a torn totals file loses every day at once.
	local tmpPath = dailyPath() .. '.tmp'
	local out = io.open(tmpPath, 'w')
	if not out then
		debugLog('updateDaily: не удалось открыть ' .. tmpPath)
		return
	end
	out:write(encodeJson(daily))
	out:close()
	os.remove(dailyPath())
	os.rename(tmpPath, dailyPath())
end

--- Save the last run stats to a JSON file so other tools can read them.
---@param status 'success' | 'fail'
local function writeLastRunFile(status)
	local houses = {}
	for _, house in ipairs(collectingHouses) do
		if house.hasCards then
			table.insert(houses, {
				name = house.name,
				collected = {btc = house.collected.btc, asc = house.collected.asc},
				cards = {
					working = house.cards.working,
					paused = house.cards.paused,
					urgent = house.cards.urgent,
					soon = house.cards.soon
				},
				balance = house.balance,
				balanceRaw = house.balanceRaw  -- Display string for /crstats (":CASH:18.138.307").
			})
		end
	end
	local run = {
		ts = os.time(),
		status = status,
		duration = os.time() - runStartedAt,
		total = {btc = cryptoAnalysys.btc, asc = cryptoAnalysys.asc},
		houses = houses
	}

	-- History first: last-run.json is an outbox the Companion consumes and deletes, while these two are the copies that stay on this machine.
	appendHistory(run)
	updateDaily(run)

	local dir = configDir()
	-- Write to a temp file first so readers never see a half-written JSON.
	local path = dir .. '\\last-run.json'
	local tmpPath = path .. '.tmp'
	local f = io.open(tmpPath, 'w')
	if not f then
		-- Still return the run: callers format the summary from it, and nil would break them.
		debugLog('writeLastRunFile: не удалось открыть ' .. tmpPath)
		return run
	end
	f:write(encodeJson(run))
	f:close()
	os.remove(path)
	os.rename(tmpPath, path)
	debugLog('writeLastRunFile: записан прогон status=' .. status)
	return run
end


--- Format seconds as "2 мин 34 сек" or "45 сек" (raw UTF-8, encode on print).
---@param seconds number
local function formatDuration(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	if seconds >= 60 then
		return string.format('%d мин %d сек', math.floor(seconds / 60), seconds % 60)
	end
	return seconds .. ' сек'
end

local window      -- Window state pointer, alive only together with mimgui.
local openWindow  -- Open the window on a given tab.

if hasWindow then
	-- ============================================================================
	-- WINDOW (mimgui): history, settings, help
	-- ============================================================================

	window = imgui.new.bool(false)
	local forcedTab = nil          -- 'history' | 'settings' | 'help', set when the window opens.
	local historyCache = {}        -- Runs from history.jsonl, read when the window opens.
	local dailyCache = {}          -- Per-day totals from daily.json.
	local selectedRun = nil        -- ts of the expanded run: survives a period switch and a resort.
	local periodIndex = 1          -- Selected period on the history tab.
	local confirmClear = false     -- Second stage of the clear button.

	local PERIODS = {
		{key = 'today',     title = 'Сегодня'},
		{key = 'yesterday', title = 'Вчера'},
		{key = 'week',      title = 'Неделя'},
		{key = 'month',     title = 'Месяц'},
		{key = 'all',       title = 'Всё время'},
	}

	local ffi = require('ffi')

	-- Mirrors of the settings for the controls.
	local uiSilent = imgui.new.bool(false)
	local uiIgnoreInput = imgui.new.char[8]('')  -- House number to add to the ignore list.

	-- ImGuiTabBarFlags_NoTooltip = 1 << 5: ImGui tabs have a built-in tooltip that merely repeats the tab name. Turn it off.
	local TAB_BAR_NO_TOOLTIP = 32
	do
		local flags = rawget(imgui, 'TabBarFlags') or rawget(imgui, 'ImGuiTabBarFlags')
		if type(flags) == 'table' and tonumber(flags.NoTooltip) then
			TAB_BAR_NO_TOOLTIP = flags.NoTooltip
		end
	end

	-- ImGuiTabItemFlags_SetSelected = 1 << 1. mimgui spells the enum tables out by hand, and a build may have no TabItemFlags - then the value is taken from imgui itself.
	local TAB_SET_SELECTED = 2
	do
		local flags = rawget(imgui, 'TabItemFlags') or rawget(imgui, 'ImGuiTabItemFlags')
		if type(flags) == 'table' and tonumber(flags.SetSelected) then
			TAB_SET_SELECTED = flags.SetSelected
		end
	end

	local faicons = nil
	do
		local ok, mod = pcall(require, 'fAwesome6')
		if ok and mod then faicons = mod end
	end

	-- The icons we need and the fallback words for them. Names differ between fAwesome6 builds, so every icon has several candidates - the first one the build knows wins.
	local ICON_CANDIDATES = {
		house     = {'HOUSE', 'HOME'},
		coins     = {'COINS', 'COIN', 'SACK_DOLLAR'},
		working   = {'CIRCLE_PLAY', 'PLAY', 'CIRCLE_CHECK'},
		paused    = {'CIRCLE_PAUSE', 'PAUSE'},
		fine      = {'SNOWFLAKE'},
		soon      = {'TRIANGLE_EXCLAMATION', 'EXCLAMATION_TRIANGLE'},
		urgent    = {'CIRCLE_EXCLAMATION', 'EXCLAMATION_CIRCLE', 'FIRE'},
		money     = {'MONEY_BILL', 'MONEY_BILL_1', 'DOLLAR_SIGN'},
		failed    = {'TRIANGLE_EXCLAMATION', 'EXCLAMATION_TRIANGLE'},
		expanded  = {'CHEVRON_DOWN', 'ANGLE_DOWN', 'CARET_DOWN'},
		collapsed = {'CHEVRON_RIGHT', 'ANGLE_RIGHT', 'CARET_RIGHT'},
	}
	local glyphs = {}

	--- The whole set is probed at once rather than icon by icon. Either all of them are there and the compact icon layout is drawn, or none are and the wordy layout is drawn.
	local function probeIcons()
		if not faicons then return false end
		for key, candidates in pairs(ICON_CANDIDATES) do
			local resolved = nil
			for _, name in ipairs(candidates) do
				local ok, glyph = pcall(faicons, name)
				if ok and type(glyph) == 'string' and glyph ~= '' then
					resolved = glyph
					break
				end
			end
			if not resolved then return false end
			glyphs[key] = resolved
		end
		return true
	end

	local iconsReady = probeIcons()

	--- Icon by key, or an empty string - the caller decides what to put in its place.
	local function ic(key)
		return iconsReady and glyphs[key] or ''
	end

	--- Text for imgui. Text, TextColored and SetTooltip are printf-like: the string goes in as a format and a lone %% is eaten together with the next character, so it is doubled before output - otherwise "От 20%% до 50%%" turns into "От 20до 50".
	local function txt(text)
		return u8((tostring(text):gsub('%%', '%%%%')))
	end

	--- Text with an icon in front. With no icons no stray space appears.
	local function withIcon(key, text)
		local glyph = ic(key)
		if glyph == '' then return text end
		return glyph .. ' ' .. text
	end

	local COLOR_GOOD = imgui.ImVec4(0.20, 0.80, 0.20, 1.00)
	local COLOR_WARN = imgui.ImVec4(1.00, 0.65, 0.00, 1.00)
	local COLOR_BAD  = imgui.ImVec4(0.85, 0.25, 0.25, 1.00)
	local COLOR_GOLD = imgui.ImVec4(1.00, 0.70, 0.20, 1.00)
	local COLOR_HOUSE = imgui.ImVec4(0.81, 0.36, 1.00, 1.00)
	local COLOR_TIME = imgui.ImVec4(0.78, 0.80, 0.86, 1.00)  -- Readable both on the dark background and on the blue highlight.
	local COLOR_ACTIVE = imgui.ImVec4(0.18, 0.45, 0.75, 1.00)
	local COLOR_ACTIVE_HOVER = imgui.ImVec4(0.24, 0.55, 0.88, 1.00)

	--- Toggle button: the selected one is highlighted by color instead of changing its text.
	local function drawToggle(text, active, id, size)
		if active then
			imgui.PushStyleColor(imgui.Col.Button, COLOR_ACTIVE)
			imgui.PushStyleColor(imgui.Col.ButtonHovered, COLOR_ACTIVE_HOVER)
			imgui.PushStyleColor(imgui.Col.ButtonActive, COLOR_ACTIVE)
		end
		-- An if on purpose, not "size and A or B": on a false from the first branch and/or would call Button a second time, and two widgets with the same id break click handling.
		local label = txt(text) .. '###' .. id
		local clicked
		if size then
			clicked = imgui.Button(label, size)
		else
			clicked = imgui.Button(label)
		end
		if active then
			-- One at a time rather than PopStyleColor(3): if the build ignores the count, two pushes leak per frame and a hundred frames later imgui dies on a stack mismatch.
			imgui.PopStyleColor(1)
			imgui.PopStyleColor(1)
			imgui.PopStyleColor(1)
		end
		return clicked
	end

	--- A value with two steps in each direction. A build may have no real slider, but buttons are everywhere. The value is clamped right away, going out of range is impossible.
	---@return number the new value, boolean whether it changed.
	local function drawStepper(id, value, min, max, smallStep, bigStep, suffix, color, label)
		local style = imgui.GetStyle()
		local buttonWidth = imgui.CalcTextSize(txt('-10')).x + style.FramePadding.x * 2
		local valueX = (buttonWidth + 4) * 2 + 8
		local valueWidth = imgui.CalcTextSize(txt('100 млн')).x
		local plusX = valueX + valueWidth + 8
		local labelX = plusX + (buttonWidth + 4) * 2 + 12
		local changed = false

		local function step(delta, tag, offset)
			if offset then imgui.SameLine(offset) end
			local caption = (delta > 0 and '+' or '') .. delta
			if imgui.Button(txt(caption) .. '###' .. id .. tag, imgui.ImVec2(buttonWidth, 0)) then
				value = math.max(min, math.min(max, value + delta))
				changed = true
			end
		end

		step(-bigStep, 'bigdn')
		imgui.SameLine(0, 4)
		step(-smallStep, 'smdn')
		-- The value and the plus buttons sit at fixed positions: otherwise "5" against "100" would send the right-hand buttons jumping along the row.
		local valueText = txt(value .. suffix)
		imgui.SameLine(valueX + (valueWidth - imgui.CalcTextSize(valueText).x) / 2)
		imgui.TextColored(color, valueText)
		step(smallStep, 'smup', plusX)
		imgui.SameLine(0, 4)
		step(bigStep, 'bigup')
		imgui.SameLine(labelX)
		imgui.TextDisabled(txt(label))
		return value, changed
	end

	--- 46602199 -> "46.602.199", the way the server shows the account.
	local function formatMoney(value)
		local digits = tostring(math.floor(tonumber(value) or 0))
		local grouped = (digits:reverse():gsub('(%d%d%d)', '%1.'):reverse())
		return (grouped:gsub('^%.', ''))
	end

	--- Russian plural forms: 1 прогон, 2 прогона, 5 прогонов.
	local function plural(n, one, few, many)
		local last, lastTwo = n % 10, n % 100
		if last == 1 and lastTwo ~= 11 then return one end
		if last >= 2 and last <= 4 and (lastTwo < 12 or lastTwo > 14) then return few end
		return many
	end

	--- "Дом №796" -> icon + 796, or "Дом 796". The № sign is deliberately dropped: it is outside the glyph range of the Cyrillic font and renders as a question mark.
	local function houseLabel(house)
		local name = tostring(house.name or '')
		local number = name:match('(%d+)')
		if not number then
			return (name:gsub('№', ''))
		end
		if iconsReady then
			return glyphs.house .. ' ' .. number
		end
		return 'Дом ' .. number
	end

	--- Midnight of the day the timestamp falls into, local time.
	local function dayStart(ts)
		local d = os.date('*t', ts)
		d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
		return os.time(d)
	end

	--- Half-open range [from, to) for a period key, nil means unbounded on that side.
	local function periodRange(key)
		local today = dayStart(os.time())
		if key == 'today' then return today, nil end
		if key == 'yesterday' then return today - 86400, today end
		if key == 'week' then return today - 6 * 86400, nil end
		if key == 'month' then return today - 29 * 86400, nil end
		return nil, nil
	end

	local function inRange(ts, from, to)
		ts = tonumber(ts)
		if not ts then return false end
		if from and ts < from then return false end
		if to and ts >= to then return false end
		return true
	end

	--- Totals for a period. Taken from daily.json on purpose: it is kept forever while history.jsonl is trimmed, so "Всё время" stays correct even after a trim.
	local function periodTotals(key)
		local from, to = periodRange(key)
		local btc, asc, runs = 0, 0, 0
		for date, entry in pairs(dailyCache) do
			local y, m, d = tostring(date):match('^(%d+)-(%d+)-(%d+)$')
			if y and type(entry) == 'table' then
				-- Noon, so comparing against midnight boundaries does not depend on a daylight saving shift.
				local ts = os.time({year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12})
				if inRange(ts, from, to) then
					btc = btc + (tonumber(entry.btc) or 0)
					asc = asc + (tonumber(entry.asc) or 0)
					runs = runs + (tonumber(entry.runs) or 0)
				end
			end
		end
		return btc, asc, runs
	end

	--- Runs of the period, newest first.
	local function periodRuns(key)
		local from, to = periodRange(key)
		local list = {}
		for _, run in ipairs(historyCache) do
			if type(run) == 'table' and inRange(run.ts, from, to) then
				table.insert(list, run)
			end
		end
		-- By time, not by line order in the file: after a trim or a hand edit it can be anything.
		table.sort(list, function(a, b) return (tonumber(a.ts) or 0) > (tonumber(b.ts) or 0) end)
		return list
	end

	local function readDaily()
		local content = readFile(dailyPath())
		if not content then return {} end
		local ok, decoded = pcall(decodeJson, content)
		return (ok and type(decoded) == 'table') and decoded or {}
	end

	--- Reload both files. Called when the window opens, never per frame.
	local function loadWindowData()
		historyCache = readHistory()
		dailyCache = readDaily()
		selectedRun = nil
		confirmClear = false
	end

	local function syncSettingsToUI()
		local s = config.settings
		uiSilent[0] = s.silent
	end

	--- Open the window on a given tab, or close it when it is already open. Which tab is showing is deliberately not taken into account: only the tab bar knows that, and asking it back is not worth the trouble.
	---@param tab 'history' | 'settings' | 'help'
	openWindow = function(tab)
		if window[0] then
			window[0] = false
			return
		end
		loadWindowData()
		syncSettingsToUI()
		forcedTab = tab
		window[0] = true
	end

	--- "5 минут назад", "2 часа назад", "3 дня назад". More compact than a date, and the exact time shows up in the hover tooltip.
	local function formatRelative(ts)
		local delta = os.time() - (tonumber(ts) or 0)
		if delta < 60 then
			return 'только что'
		end
		if delta < 3600 then
			local minutes = math.floor(delta / 60)
			return minutes .. ' ' .. plural(minutes, 'минуту', 'минуты', 'минут') .. ' назад'
		end
		if delta < 86400 then
			local hours = math.floor(delta / 3600)
			return hours .. ' ' .. plural(hours, 'час', 'часа', 'часов') .. ' назад'
		end
		local days = math.floor(delta / 86400)
		if days <= 30 then
			return days .. ' ' .. plural(days, 'день', 'дня', 'дней') .. ' назад'
		end
		return nil  -- Long ago: fall back to a plain date.
	end

	-- Exposed for the test: the time plural forms cannot be checked otherwise, and they are easy to get wrong.
	function relativeForTest(ts) return formatRelative(ts) end

	local function formatDateTime(ts)
		ts = tonumber(ts)
		if not ts then return '?' end
		return os.date('%d.%m.%Y %H:%M', ts)
	end

	-- The theme is shared with CraftCounter and RouletteHelper.
	local function applyTheme()
		imgui.SwitchContext()
		local style = imgui.GetStyle()

		style.WindowPadding = imgui.ImVec2(10, 10)
		style.WindowRounding = 8.0
		style.ChildRounding = 4.0
		style.FramePadding = imgui.ImVec2(6, 4)
		style.FrameRounding = 4.0
		style.ItemSpacing = imgui.ImVec2(6, 4)
		style.ScrollbarSize = 12.0
		style.ScrollbarRounding = 8.0
		style.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)

		style.Colors[imgui.Col.Text]                 = imgui.ImVec4(0.90, 0.90, 0.93, 1.00)
		style.Colors[imgui.Col.TextDisabled]         = imgui.ImVec4(0.40, 0.40, 0.45, 1.00)
		style.Colors[imgui.Col.WindowBg]             = imgui.ImVec4(0.08, 0.08, 0.08, 0.95)
		style.Colors[imgui.Col.ChildBg]              = imgui.ImVec4(0.12, 0.12, 0.12, 0.50)
		style.Colors[imgui.Col.Border]               = imgui.ImVec4(0.30, 0.30, 0.30, 1.00)
		style.Colors[imgui.Col.FrameBg]              = imgui.ImVec4(0.15, 0.15, 0.15, 1.00)
		style.Colors[imgui.Col.FrameBgHovered]       = imgui.ImVec4(0.25, 0.25, 0.25, 1.00)
		style.Colors[imgui.Col.FrameBgActive]        = imgui.ImVec4(0.30, 0.30, 0.30, 1.00)
		style.Colors[imgui.Col.TitleBg]              = imgui.ImVec4(0.10, 0.10, 0.10, 1.00)
		style.Colors[imgui.Col.TitleBgActive]        = imgui.ImVec4(0.15, 0.15, 0.15, 1.00)
		style.Colors[imgui.Col.ScrollbarBg]          = imgui.ImVec4(0.10, 0.10, 0.10, 1.00)
		style.Colors[imgui.Col.ScrollbarGrab]        = imgui.ImVec4(0.30, 0.30, 0.30, 1.00)
		style.Colors[imgui.Col.ScrollbarGrabHovered] = imgui.ImVec4(0.40, 0.40, 0.40, 1.00)
		style.Colors[imgui.Col.ScrollbarGrabActive]  = imgui.ImVec4(0.50, 0.50, 0.50, 1.00)
		style.Colors[imgui.Col.Button]               = imgui.ImVec4(0.20, 0.20, 0.20, 1.00)
		style.Colors[imgui.Col.ButtonHovered]        = imgui.ImVec4(0.40, 0.40, 0.40, 1.00)
		style.Colors[imgui.Col.ButtonActive]         = imgui.ImVec4(0.50, 0.50, 0.50, 1.00)
		style.Colors[imgui.Col.Header]               = imgui.ImVec4(0.20, 0.20, 0.20, 1.00)
		style.Colors[imgui.Col.HeaderHovered]        = imgui.ImVec4(0.25, 0.25, 0.25, 1.00)
		style.Colors[imgui.Col.HeaderActive]         = imgui.ImVec4(0.30, 0.30, 0.30, 1.00)
		style.Colors[imgui.Col.Separator]            = imgui.ImVec4(0.30, 0.30, 0.30, 1.00)
	end

	imgui.OnInitialize(function()
		imgui.GetIO().IniFilename = nil
		imgui.GetIO().Fonts:Clear()
		local glyphRanges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
		imgui.GetIO().Fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\trebucbd.ttf', 16.0, nil, glyphRanges)
		-- Icons are merged in as a second font. If the build cannot do that, the wordy layout stays.
		if faicons then
			local ok = pcall(function()
				local cfg = imgui.ImFontConfig()
				cfg.MergeMode = true
				local iconRanges = imgui.new.ImWchar[3](faicons.min_range, faicons.max_range, 0)
				imgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(
					faicons.get_font_data_base85('solid'), 14, cfg, iconRanges)
			end)
			if not ok then
				faicons = nil
				iconsReady = false
			end
		end
		imgui.InvalidateFontsTexture()
		applyTheme()
	end)

	local function padNumber(value)
		local number = tonumber(value) or 0
		if number < 10 then
			return ' ' .. number
		end
		return tostring(number)
	end

	--- Pairs of "icon + number" separated by a plain gap. One tooltip covers the whole group.
	local function drawSlots(items, tooltip)
		for i, item in ipairs(items) do
			if i > 1 then
				imgui.SameLine(0, 14)
			end
			local text = padNumber(item.value)
			if item.icon ~= '' then
				text = item.icon .. ' ' .. text
			end
			imgui.TextColored(item.color, txt(text))
			if tooltip and imgui.IsItemHovered() then
				imgui.SetTooltip(txt(tooltip))
			end
		end
	end

	local function drawRunCard(run, key, isSelected)
		local total = run.total or {}
		local btc = tonumber(total.btc) or 0
		local asc = tonumber(total.asc) or 0

		local marker
		if iconsReady then
			marker = isSelected and glyphs.expanded or glyphs.collapsed
		else
			marker = isSelected and '-' or '+'
		end
		local dateText = marker .. ' ' .. formatDateTime(run.ts)

		local tail = formatDuration(run.duration)
		if run.status ~= 'success' then
			-- The icon goes before the time, not after: that way it does not drift away from the window edge.
			tail = (iconsReady and glyphs.failed or '!') .. ' ' .. tail
		end

		-- The button label is left-aligned: imgui centers it by default.
		local style = imgui.GetStyle()
		local alignX, alignY = style.ButtonTextAlign.x, style.ButtonTextAlign.y
		style.ButtonTextAlign = imgui.ImVec2(0.0, 0.5)
		local clicked = drawToggle(dateText, isSelected, 'run' .. key, imgui.ImVec2(-1, 0))
		style.ButtonTextAlign = imgui.ImVec2(alignX, alignY)

		imgui.SameLine(style.FramePadding.x + imgui.CalcTextSize(txt(dateText .. '     ')).x)
		imgui.TextColored(COLOR_GOLD, txt(withIcon('coins', btc .. ' BTC')))
		if asc > 0 then
			imgui.SameLine(0, 12)
			imgui.TextColored(COLOR_WARN, txt(withIcon('coins', asc .. ' ASC')))
		end

		-- Not TextDisabled: the gray disappeared on the blue highlight of the selected row.
		imgui.SameLine(imgui.GetWindowWidth() - imgui.CalcTextSize(txt(tail)).x - 18)
		imgui.TextColored(COLOR_TIME, txt(tail))
		return clicked
	end

	--- The house table. With icons every number explains itself and the header labels are not needed. Without icons they come back - otherwise a bare "20 0" and "11 9 0" mean nothing.
	local function drawHouseTable(houses)
		local avail = imgui.GetContentRegionAvail().x
		local pairWidth = imgui.CalcTextSize(txt(ic('urgent') .. ' 00')).x + 12
		local cardsWidth = math.max(2 * pairWidth + 16, avail * 0.14)
		local coolingWidth = math.max(3 * pairWidth + 16, avail * 0.20)
		local restWidth = math.max(160, avail - cardsWidth - coolingWidth)

		imgui.Columns(5, '##houses', false)
		imgui.SetColumnWidth(0, restWidth * 0.24)
		imgui.SetColumnWidth(1, restWidth * 0.42)
		imgui.SetColumnWidth(2, cardsWidth)
		imgui.SetColumnWidth(3, coolingWidth)

		for _, title in ipairs({'Дом', 'Собрано', 'Карты', 'Охлаждение', 'Счёт'}) do
			imgui.Text(txt(title))
			imgui.NextColumn()
		end
		if not iconsReady then
			for _, sub in ipairs({'', '', 'раб / пауза', 'норма / скоро / срочно', ''}) do
				imgui.TextDisabled(txt(sub))
				imgui.NextColumn()
			end
		end

		local totals = {btc = 0, asc = 0, working = 0, paused = 0, fine = 0, soon = 0, urgent = 0, balance = 0}
		for _, house in ipairs(houses) do
			local cards = house.cards or {}
			local working = tonumber(cards.working) or 0
			local paused = tonumber(cards.paused) or 0
			local urgent = tonumber(cards.urgent) or 0
			local soon = tonumber(cards.soon) or 0
			local fine = math.max(0, working + paused - soon - urgent)
			local collected = house.collected or {}
			local btc = tonumber(collected.btc) or 0
			local asc = tonumber(collected.asc) or 0

			totals.btc = totals.btc + btc
			totals.asc = totals.asc + asc
			totals.working = totals.working + working
			totals.paused = totals.paused + paused
			totals.fine = totals.fine + fine
			totals.soon = totals.soon + soon
			totals.urgent = totals.urgent + urgent
			totals.balance = totals.balance + (tonumber(house.balance) or 0)

			imgui.TextColored(COLOR_HOUSE, txt(houseLabel(house)))
			imgui.NextColumn()

			-- BTC and ASC are labeled on every row: a house can have both.
			imgui.TextColored(COLOR_GOLD, txt(withIcon('coins', btc .. ' BTC')))
			if asc > 0 then
				imgui.SameLine(0, 8)
				imgui.TextColored(COLOR_WARN, txt(withIcon('coins', asc .. ' ASC')))
			end
			imgui.NextColumn()

			drawSlots({
				{icon = ic('working'), value = tostring(working), color = COLOR_GOOD},
				{icon = ic('paused'), value = tostring(paused), color = COLOR_BAD},
			}, string.format('Работают: %d\nНа паузе: %d', working, paused))
			imgui.NextColumn()

			drawSlots({
				{icon = ic('fine'), value = tostring(fine), color = COLOR_GOOD},
				{icon = ic('soon'), value = tostring(soon), color = COLOR_WARN},
				{icon = ic('urgent'), value = tostring(urgent), color = COLOR_BAD},
			}, string.format('Охлаждение выше %d%%: %d карт\nОт %d%% до %d%%: %d карт\nНиже %d%%: %d карт',
				COOLING_SOON, fine, COOLING_URGENT, COOLING_SOON, soon, COOLING_URGENT, urgent))
			imgui.NextColumn()

			local balance = tonumber(house.balance) or 0
			local balanceColor = COLOR_GOOD
			if balance < BALANCE_URGENT then
				balanceColor = COLOR_BAD
			elseif balance < BALANCE_SOON then
				balanceColor = COLOR_WARN
			end
			imgui.TextColored(balanceColor, txt(withIcon('money', formatMoney(balance))))
			imgui.NextColumn()
		end

		-- The totals row: otherwise the card and cooling sums have to be added up by eye.
		if #houses > 1 then
			imgui.Separator()
			imgui.Text(txt('Итого'))
			imgui.NextColumn()

			imgui.TextColored(COLOR_GOLD, txt(withIcon('coins', totals.btc .. ' BTC')))
			if totals.asc > 0 then
				imgui.SameLine(0, 8)
				imgui.TextColored(COLOR_WARN, txt(withIcon('coins', totals.asc .. ' ASC')))
			end
			imgui.NextColumn()

			drawSlots({
				{icon = ic('working'), value = totals.working, color = COLOR_GOOD},
				{icon = ic('paused'), value = totals.paused, color = COLOR_BAD},
			})
			imgui.NextColumn()

			drawSlots({
				{icon = ic('fine'), value = totals.fine, color = COLOR_GOOD},
				{icon = ic('soon'), value = totals.soon, color = COLOR_WARN},
				{icon = ic('urgent'), value = totals.urgent, color = COLOR_BAD},
			})
			imgui.NextColumn()

			imgui.Text(txt(withIcon('money', formatMoney(totals.balance))))
			imgui.NextColumn()
		end

		imgui.Columns(1)
	end

	--- House rows of the selected run - the same numbers /crstats used to print into the chat.
	local function drawRunDetail(run)
		local houses = run.houses
		if type(houses) ~= 'table' or #houses == 0 then
			imgui.TextDisabled(txt('В этом прогоне нет домов с картами.'))
			return
		end
		drawHouseTable(houses)
	end

	--- Height of the houses block from the row count. With ImVec2(-1, 0) imgui would stretch it over all the remaining space, leaving half the window empty under eight houses.
	local function detailHeight(run)
		local houses = type(run.houses) == 'table' and #run.houses or 0
		local style = imgui.GetStyle()
		local lineHeight = imgui.CalcTextSize('A').y + style.ItemSpacing.y
		local rows = math.max(1, houses) + (iconsReady and 1 or 2)  -- Header: one row or two.
		if houses > 1 then rows = rows + 1 end  -- The "Итого" row.
		return rows * lineHeight + style.WindowPadding.y * 2
	end

	--- Timestamp of the newest record in the history - regardless of the selected period.
	local function lastRunTs()
		local newest = 0
		for _, run in ipairs(historyCache) do
			local ts = tonumber(run.ts) or 0
			if ts > newest then newest = ts end
		end
		return newest > 0 and newest or nil
	end

	--- Gray text with line wrapping. TextDisabled does not wrap and gets cut at the window edge, while TextWrapped cannot do gray - so the color is swapped by hand.
	local function textNoteWrapped(text)
		imgui.PushStyleColor(imgui.Col.Text, imgui.GetStyle().Colors[imgui.Col.TextDisabled])
		imgui.TextWrapped(txt(text))
		imgui.PopStyleColor(1)
	end

	local function drawHistoryTab()
		-- Period switch: the buttons split the width evenly.
		local avail = imgui.GetContentRegionAvail().x
		local spacing = imgui.GetStyle().ItemSpacing.x
		local buttonWidth = (avail - spacing * (#PERIODS - 1)) / #PERIODS
		for i, period in ipairs(PERIODS) do
			if i > 1 then imgui.SameLine(0, spacing) end
			if drawToggle(period.title, periodIndex == i, 'period' .. i, imgui.ImVec2(buttonWidth, 0)) then
				periodIndex = i
				selectedRun = nil
			end
		end
		imgui.Separator()

		local period = PERIODS[periodIndex]
		local btc, asc, runs = periodTotals(period.key)
		imgui.Text(txt(iconsReady and glyphs.coins or 'Собрано:'))
		imgui.SameLine()
		imgui.TextColored(COLOR_GOLD, txt(string.format('%d BTC', btc)))
		if asc > 0 then
			imgui.SameLine()
			imgui.TextColored(COLOR_WARN, txt(string.format('%d ASC', asc)))
		end
		imgui.SameLine()
		imgui.TextDisabled(txt(string.format('за %d %s', runs, plural(runs, 'прогон', 'прогона', 'прогонов'))))

		-- On the right, the "when it was collected" group and the start button: the date is pinned to the button instead of hanging in the middle of the row.
		local rightEdge = imgui.GetWindowWidth() - 18
		local label = isEnabled and 'Сбор идёт...' or withIcon('working', 'Начать сбор')
		local buttonWidth = imgui.CalcTextSize(txt(label)).x + 24

		local newest = lastRunTs()
		if newest then
			local when = formatRelative(newest) or formatDateTime(newest)
			imgui.SameLine(rightEdge - buttonWidth - 14 - imgui.CalcTextSize(txt(when)).x)
			imgui.TextDisabled(txt(when))
			if imgui.IsItemHovered() then
				imgui.SetTooltip(txt('Последний сбор: ' .. formatDateTime(newest)))
			end
		end

		imgui.SameLine(rightEdge - buttonWidth)
		if isEnabled then
			imgui.TextColored(COLOR_GOOD, txt(label))
		elseif drawToggle(label, false, 'startrun', imgui.ImVec2(buttonWidth, 0)) then
			-- The window is closed: collection takes minutes, and the player should be watching the game, not this.
			window[0] = false
			startCryptoCollection()
		end

		-- The history is not hidden behind a missing optional library: the data is shown as is, and the icons get a single line of explanation.
		if not iconsReady then
			imgui.TextDisabled(txt('Значки не найдены. Положите fAwesome6.lua в moonloader/lib - вид станет компактнее.'))
		end
		imgui.Separator()

		local list = periodRuns(period.key)
		if #list == 0 then
			imgui.TextDisabled(txt('За этот период сборов не было.'))
			if runs > 0 then
				imgui.TextDisabled(txt('Итоги выше учтены, но подробности старых прогонов уже вытеснены.'))
			end
			return
		end

		imgui.BeginChild('##runs', imgui.ImVec2(-1, -1), false)
		for _, run in ipairs(list) do
			local key = tostring(run.ts)
			if drawRunCard(run, key, selectedRun == key) then
				-- An if on purpose: "X and nil or key" always returns key because nil is falsy, and the run could never be collapsed.
				if selectedRun == key then
					selectedRun = nil
				else
					selectedRun = key
				end
			end
			if selectedRun == key then
				imgui.BeginChild('##detail' .. key, imgui.ImVec2(-1, detailHeight(run)), true)
				drawRunDetail(run)
				imgui.EndChild()
			end
		end
		imgui.EndChild()
	end

	local DEBUG_LEVEL_NAMES = {[0] = 'Выключена', [1] = 'Обычная', [2] = 'Подробная'}
	local DEBUG_LEVEL_HINTS = {
		[0] = 'Ничего не пишется.',
		[1] = 'Пишется ход сбора: дома, карты, ответы на диалоги.',
		[2] = 'То же плюс сырые строки, уходящие в интерфейс игры. Файл растёт быстро.',
	}
	local DEBUG_TARGET_NAMES = {
		{'chat', 'в чат'},
		{'log', 'в отдельный файл'},
		{'both', 'везде'},
	}

	local function drawSettingsTab()
		local s = config.settings
		local dirty = false

		imgui.TextColored(COLOR_GOLD, txt('Охлаждение карт'))
		local value, changed = drawStepper('coolurg', s.cooling_urgent, 0, 100, 1, 10, '%', COLOR_BAD, 'срочно обслужить')
		if changed then
			s.cooling_urgent = value
			dirty = true
		end
		value, changed = drawStepper('coolsoon', s.cooling_soon, 0, 100, 1, 10, '%', COLOR_WARN, 'обслужить вскоре')
		if changed then
			s.cooling_soon = value
			dirty = true
		end
		imgui.Separator()

		imgui.TextColored(COLOR_GOLD, txt('Счёт за электроэнергию'))
		value, changed = drawStepper('balurg', s.balance_urgent, 0, BALANCE_MAX_MLN, 1, 5, ' млн', COLOR_BAD, 'срочно пополнить')
		if changed then
			s.balance_urgent = value
			dirty = true
		end
		value, changed = drawStepper('balsoon', s.balance_soon, 0, BALANCE_MAX_MLN, 1, 5, ' млн', COLOR_WARN, 'пополнить вскоре')
		if changed then
			s.balance_soon = value
			dirty = true
		end
		imgui.Separator()

		imgui.TextColored(COLOR_GOLD, txt('Игнорируемые дома'))
		textNoteWrapped('Эти дома скрипт пропускает при обходе, даже если в них есть доступ к картам.')

		local ignoredList = {}
		for numStr in pairs(parseIgnoredHouses()) do
			table.insert(ignoredList, tonumber(numStr))
		end
		table.sort(ignoredList)

		if #ignoredList == 0 then
			imgui.TextDisabled(txt('Список пуст.'))
		else
			for _, num in ipairs(ignoredList) do
				imgui.TextColored(COLOR_HOUSE, txt(withIcon('house', tostring(num))))
				imgui.SameLine()
				if imgui.Button(txt('Убрать') .. '###unignore' .. num) then
					removeIgnoredHouse(tostring(num))
				end
			end
		end

		imgui.PushItemWidth(80)
		imgui.InputTextWithHint('##ignoreinput', txt('номер'), uiIgnoreInput, ffi.sizeof(uiIgnoreInput))
		imgui.PopItemWidth()
		imgui.SameLine()
		if imgui.Button(txt('Добавить в игнор') .. '###ignoreadd') then
			local numStr = ffi.string(uiIgnoreInput):match('%d+')
			if numStr then
				addIgnoredHouse(numStr)
				uiIgnoreInput[0] = 0
			end
		end
		imgui.Separator()

		imgui.TextColored(COLOR_GOLD, txt('Отладка'))
		for level = 0, 2 do
			if level > 0 then imgui.SameLine() end
			if drawToggle(DEBUG_LEVEL_NAMES[level], s.debug_level == level, 'lvl' .. level) then
				s.debug_level = level
				dirty = true
			end
		end
		imgui.TextDisabled(txt(DEBUG_LEVEL_HINTS[s.debug_level] or ''))

		if s.debug_level > 0 then
			imgui.Text(txt('Куда выводить:'))
			for _, target in ipairs(DEBUG_TARGET_NAMES) do
				imgui.SameLine()
				if drawToggle(target[2], s.debug_target == target[1], 'tg' .. target[1]) then
					s.debug_target = target[1]
					dirty = true
				end
			end
			-- The path only makes sense when we write to a file: with chat output there is none.
			if s.debug_target ~= 'chat' then
				imgui.TextDisabled(txt(configDir()))
				if imgui.Button(txt('Открыть папку') .. '###opendir') then
					os.execute('explorer "' .. configDir() .. '"')
				end
			end
		end
		imgui.Separator()

		if imgui.Checkbox(txt('Тихий режим'), uiSilent) then
			s.silent = uiSilent[0]
			if s.silent then ticker.active = false end
			dirty = true
		end
		textNoteWrapped('Только итоги сбора в чат, без показа деталей по домам на экране. Может помочь в том случае, если при сборе вылетает игра.')
		imgui.Separator()

		if dirty then
			-- "Urgent" cannot be milder than "soon": otherwise the orange band disappears. Clamped here rather than in the buttons so the rule holds for any editing order.
			s.cooling_urgent = math.max(0, math.min(100, s.cooling_urgent))
			s.cooling_soon = math.max(0, math.min(100, s.cooling_soon))
			s.balance_urgent = math.max(0, math.min(BALANCE_MAX_MLN, s.balance_urgent))
			s.balance_soon = math.max(0, math.min(BALANCE_MAX_MLN, s.balance_soon))
			s.cooling_urgent = math.min(s.cooling_urgent, s.cooling_soon)
			s.balance_urgent = math.min(s.balance_urgent, s.balance_soon)

			COOLING_URGENT, COOLING_SOON = s.cooling_urgent, s.cooling_soon
			BALANCE_URGENT = s.balance_urgent * 1000000
			BALANCE_SOON = s.balance_soon * 1000000
			DEBUG_LEVEL, DEBUG_TARGET = s.debug_level, s.debug_target
			saveConfig()
		end

		if not confirmClear then
			if imgui.Button(txt('Очистить историю') .. '###clearhistory') then
				confirmClear = true
			end
			textNoteWrapped('Удалит все прогоны и дневные итоги без возможности вернуть. Настройки останутся.')
		else
			imgui.TextColored(COLOR_BAD, txt('Удалить всю историю сборов? Это необратимо.'))
			if imgui.Button(txt('Да, удалить') .. '###clearyes') then
				os.remove(historyPath())
				os.remove(dailyPath())
				loadWindowData()
			end
			imgui.SameLine()
			if imgui.Button(txt('Отмена') .. '###clearno') then
				confirmClear = false
			end
		end
	end

	local function drawHelpTab()
		imgui.TextColored(COLOR_GOLD, txt('Что делает'))
		imgui.TextWrapped(txt('Обходит все ваши дома с майнинг-фермами, забирает накопленную криптовалюту с каждой видеокарты и запускает те карты, что стоят на паузе, если в них осталась охлаждающая жидкость. По окончании пишет итоги в чат и сохраняет прогон в историю.'))
		textNoteWrapped('Нужна «Флешка майнера»: именно через неё скрипт открывает список домов. Без неё сбор не запустится.')
		textNoteWrapped('Не заливает охлаждающую жидкость и не пополняет счёт за электроэнергию - только показывает, где это пора сделать.')
		imgui.Separator()

		imgui.TextColored(COLOR_GOLD, txt('Тема на форуме'))
		imgui.TextWrapped(txt('Там актуальная версия и список изменений. Нашли ошибку, чего-то не хватает или есть идея - напишите в тему, это самый быстрый способ до меня достучаться.'))
		imgui.TextDisabled(txt(FORUM_URL))
		if imgui.Button(txt('Открыть тему') .. '###openforum') then
			os.execute('start ' .. FORUM_URL)
		end
		imgui.SameLine()
		if imgui.Button(txt('Скопировать ссылку') .. '###copyforum') then
			setClipboardText(FORUM_URL)
		end
		imgui.Separator()

		imgui.TextColored(COLOR_GOLD, txt('Команды'))
		imgui.Text(txt('/crypto'))
		imgui.SameLine()
		imgui.TextDisabled(txt('- запустить сбор'))
		imgui.Text(txt('/crstats'))
		imgui.SameLine()
		imgui.TextDisabled(txt('- история и это окно'))
		imgui.Text(txt('/crconfig'))
		imgui.SameLine()
		imgui.TextDisabled(txt('- настройки'))
		imgui.Text(txt('/crupdate'))
		imgui.SameLine()
		imgui.TextDisabled(txt('- проверить и установить обновление'))
		imgui.Text(txt('/crhelp'))
		imgui.SameLine()
		imgui.TextDisabled(txt('- эта справка'))
		textNoteWrapped('Сбор можно запустить и кнопкой на вкладке «История».')
		textNoteWrapped('Старые команды тоже работают: /cstats, /cconfig и /chelp делают то же самое.')
		imgui.Separator()

		imgui.TextColored(COLOR_GOLD, txt('Файлы'))
		imgui.TextDisabled(txt(configDir()))
		if imgui.Button(txt('Открыть папку') .. '###opendirhelp') then
			os.execute('explorer "' .. configDir() .. '"')
		end
		textNoteWrapped('Там лежат настройки, история сборов и файл отладки. Историю можно удалить кнопкой в настройках.')
		if not iconsReady then
			textNoteWrapped('Значки в окне рисует библиотека fAwesome6. Её нет - поэтому вместо значков подписи словами. Положите fAwesome6.lua в moonloader/lib, если хотите компактный вид.')
		end
	end

	imgui.OnFrame(
		function() return window[0] end,
		function()
			local resX, resY = getScreenResolution()
			imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
			imgui.SetNextWindowSize(imgui.ImVec2(720, 560), imgui.Cond.FirstUseEver)

			-- End() is mandatory even when Begin() returned false (the window is collapsed or clipped), otherwise the imgui window stack goes out of sync and the game crashes inside the library itself.
			if imgui.Begin(txt('Crypto Collector v' .. thisScript().version), window, imgui.WindowFlags.NoCollapse) then
				if imgui.BeginTabBar('##tabs', TAB_BAR_NO_TOOLTIP) then
					local function tabFlag(name)
						return forcedTab == name and TAB_SET_SELECTED or 0
					end

					if imgui.BeginTabItem(txt('История'), nil, tabFlag('history')) then
						drawHistoryTab()
						imgui.EndTabItem()
					end
					if imgui.BeginTabItem(txt('Настройки'), nil, tabFlag('settings')) then
						drawSettingsTab()
						imgui.EndTabItem()
					end
					if imgui.BeginTabItem(txt('Справка'), nil, tabFlag('help')) then
						drawHelpTab()
						imgui.EndTabItem()
					end
					forcedTab = nil  -- The forced tab lasts a single frame.
					imgui.EndTabBar()
				end
			end
			imgui.End()
		end
	)
end

local WM_KEYDOWN, WM_KEYUP = 0x100, 0x101
local VK_ESCAPE = 0x1B

--- Esc closes the window. Done through window messages rather than by polling the key, because only here can the message be hidden from the game - otherwise Esc would close the window and open the pause menu at the same time. The message is swallowed only while our window is open, so the pause menu keeps working the rest of the time.
function onWindowMessage(msg, wparam, lparam)
	if not hasWindow or not window[0] then
		return
	end
	if wparam ~= VK_ESCAPE or (msg ~= WM_KEYDOWN and msg ~= WM_KEYUP) then
		return
	end
	-- Esc belongs to the chat and to dialogs first: with either of them open the window stays as it is.
	if isPauseMenuActive() or sampIsChatInputActive() or sampIsDialogActive() then
		return
	end
	-- Both messages are swallowed, but the window closes on the release. If imgui never sees the key go up it keeps believing Esc is held down, and text fields in the next window that opens lose their focus.
	consumeWindowMessage(true, false)
	if msg == WM_KEYUP then
		window[0] = false
	end
end

--- Send a string to CEF to display notifications.
---@param str string
---@param is_encoded boolean
function visualCEF(str, is_encoded)
	-- Single choke point for silent mode: no emulated packet ever leaves the script.
	if config.settings.silent then
		return
	end
	-- CEF> / CEF= / CEF< bracket the emulated packet so a hard crash shows exactly which step died: a log ending on CEF> means the fault is inside the emulated dispatch.
	cefSeq = cefSeq + 1
	local seq = cefSeq
	debugLog(string.format('CEF> #%d len=%d enc=%d', seq, #str, is_encoded and 1 or 0))
	local bs = raknetNewBitStream()
	raknetBitStreamWriteInt8(bs, 17)
	raknetBitStreamWriteInt32(bs, 0)
	raknetBitStreamWriteInt16(bs, #str)
	raknetBitStreamWriteInt8(bs, is_encoded and 1 or 0)
	if is_encoded then
		raknetBitStreamEncodeString(bs, str)
	else
		raknetBitStreamWriteString(bs, str)
	end
	raknetEmulPacketReceiveBitStream(220, bs)
	debugLog(string.format('CEF= #%d emul вернулся', seq))
	raknetDeleteBitStream(bs)
	debugLog(string.format('CEF< #%d готово', seq))
end

--- Show an Arizona notification and run the callback right away. There used to be a queue with its own thread here that spaced the popups out in time, but per-house progress moved to the ticker long ago, and there are only a couple of event notifications per run, seconds apart - there was nothing left to space out.
---@param type 'info' | 'error' | 'success' | 'halloween'
---@param title string
---@param text string
---@param time number display time in ms.
---@param callback function|nil runs right after the popup is shown.
local function notify(type, title, text, time, callback)
	local function escape_js(s)
		return s:gsub("\\", "\\\\"):gsub('"', '\\"')
	end
	local str = ('window.executeEvent("event.notify.initialize", "[\\\"%s\\\", \\\"%s\\\", \\\"%s\\\", \\\"%s\\\"]");')
		:format(escape_js(type), escape_js(title), escape_js(text), escape_js(tostring(time)))
	visualCEF(str, true)
	if callback then
		callback()
	end
end

-- Dialog delay system (from MiningToolFixed).
local jsonTimer = {
	isActive = false,
	lastTime = os.clock(),
	dialogId = 0,
	button = 0,
	listItem = 0,
	text = ''
}

-- Check whether MiningTool is present.
local function checkMiningToolActivity()
	-- The config comes first, an explicit setting wins.
	local configPath = getWorkingDirectory() .. '\\config\\[JF, F] Mining Tools [Fixed]\\config.json'
	local content = readFile(configPath)
	if content then
		local config = decodeJson(content)
		if config then
			return config.on == true
		end
	end

	-- No config - check for the script file instead (enabled by default).
	local scriptPath = getWorkingDirectory() .. '\\MiningToolFixed.lua'
	return doesFileExist(scriptPath)
end

--region SELF-UPDATE
local UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/manifest.json'
local UPDATE_BASE_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/'
local UPDATE_SCRIPT_ID = 'crypto-collector'
local UPDATE_MANIFEST_TIMEOUT = 10 -- seconds
local UPDATE_FILE_TIMEOUT = 30 -- seconds, file is bigger than the manifest

local function updateStatus(msg)
	sampAddChatMessage(tag .. cyr(msg), -1)
end

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
		updateStatus('Обновление не удалось: скачанный файл не похож на скрипт. Скачайте вручную: {5CC9FF}' .. (entry.topic or FORUM_URL))
		return
	end
	if gotVersion == thisScript().version then
		-- Manifest already points at the new version but the raw.githubusercontent.com CDN edge is still serving the previous file - a stale-cache race, not a real failure.
		removeIfExists(tempPath)
		updateStatus('CDN ещё отдаёт старую версию, попробуйте через пару минут: {5CC9FF}/crupdate')
		return
	end
	if gotVersion ~= entry.version then
		removeIfExists(tempPath)
		updateStatus('Обновление не удалось: версия в файле (' .. gotVersion .. ') не совпадает с манифестом (' .. entry.version .. ').')
		return
	end

	local ok, err = atomicReplace(thisScript().path, tempPath)
	if not ok then
		removeIfExists(tempPath)
		updateStatus('Обновление не удалось: ' .. err .. '. Скачайте вручную: {5CC9FF}' .. (entry.topic or FORUM_URL))
		return
	end

	updateStatus('Обновлено до {5CC9FF}v' .. entry.version .. '{FFFFFF}, перезагружаю скрипт...')
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
			updateStatus('Обновление не удалось: таймаут скачивания. Скачайте вручную: {5CC9FF}' .. (entry.topic or FORUM_URL))
		end)
		downloadUrlToFile(UPDATE_BASE_URL .. entry.path, tempPath, function(_, status)
			if status == dl_status.STATUS_ENDDOWNLOADDATA then
				if claim() then finishUpdate(entry, tempPath) end
			elseif status == dl_status.STATUSEX_ENDDOWNLOAD then
				if claim() then
					removeIfExists(tempPath)
					updateStatus('Не удалось скачать обновление. Скачайте вручную: {5CC9FF}' .. (entry.topic or FORUM_URL))
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
			for _, s in ipairs(data.scripts) do
				if s.id == UPDATE_SCRIPT_ID then entry = s break end
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
	updateStatus('Проверяю обновления...')
	fetchManifestEntry(
		function(entry)
			-- Strictly "remote > local", not "remote ~= local" - downgrade is intentionally unsupported (a manifest rollback would otherwise fight a newer local dev build).
			local remote, current = versionNum(entry.version), versionNum(thisScript().version)
			if not remote or not current or remote <= current then
				updateStatus('У вас последняя версия (v' .. thisScript().version .. ').')
				return
			end
			updateStatus('Найдено обновление: v' .. entry.version .. '. Скачиваю...')
			downloadUpdate(entry)
		end,
		function(reason)
			updateStatus('Не удалось проверить обновления (' .. reason .. ').')
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
				updateStatus('Доступна новая версия {5CC9FF}v' .. entry.version .. '{FFFFFF}! Обновить: {5CC9FF}/crupdate')
			end
		end,
		function() end
	)
end
--endregion

function main()
	repeat wait(0) until isSampAvailable()
	wait(1000)

	-- Remnants of an interrupted update (game closed mid-download etc.) - clean before anything else.
	-- .old is deliberately not touched: it is the previous build, the only way back from an update that turned out broken. One generation at most - atomicReplace overwrites it every time. MoonLoader will not pick it up, the extension is not .lua.
	removeIfExists(thisScript().path .. '.tmp')
	removeIfExists(thisScript().path .. '.manifest.tmp')

	if hasWindow then
		sampAddChatMessage(tag .. cyr('Загружен {5CC9FF}v' .. thisScript().version .. '{FFFFFF}. Сбор: {5CC9FF}/crypto{FFFFFF}. История: {5CC9FF}/crstats{FFFFFF}. Настройка: {5CC9FF}/crconfig'), -1)
	else
		sampAddChatMessage(tag .. cyr('Загружен {5CC9FF}v' .. thisScript().version .. '{FFFFFF}. Сбор: {5CC9FF}/crypto{FFFFFF}. Статистика: {5CC9FF}/crstats'), -1)
		sampAddChatMessage(tag .. cyr('{C0C0C0}Библиотеки {FFFFFF}mimgui{C0C0C0} нет, поэтому окна не будет.'), -1)
	end
	sampRegisterChatCommand('crypto', startCryptoCollection)
	sampRegisterChatCommand('crconfig', showConfig)
	sampRegisterChatCommand('crstats', showCollectionStats)
	sampRegisterChatCommand('crupdate', checkForUpdate)
	sampRegisterChatCommand('crhelp', showHelp)
	-- Old names: never advertised anywhere anymore, kept only for people used to them.
	sampRegisterChatCommand('cconfig', showConfig)
	sampRegisterChatCommand('cstats', showCollectionStats)
	sampRegisterChatCommand('chelp', showHelp)
	debugLog(string.format('=== запуск v%s, тихий режим %s, уровень отладки %d, вывод %s ===',
		thisScript().version, config.settings.silent and 'вкл' or 'выкл', DEBUG_LEVEL, DEBUG_TARGET))
	checkForUpdateSilently()
	while true do
		wait(100)
		-- Anything logged from here on runs on the main tick, not inside a RakNet callback.
		debugCtx = 'main'
		-- Handle the dialog delay.
		if jsonTimer.isActive then
			if jsonTimer.lastTime + 0.125 <= os.clock() then
				jsonTimer.lastTime = os.clock()
				jsonTimer.isActive = false
				debugLog(string.format('RESP! отправляю dlg=%s btn=%s item=%s', tostring(jsonTimer.dialogId), tostring(jsonTimer.button), tostring(jsonTimer.listItem)))
				sampSendDialogResponse(jsonTimer.dialogId, jsonTimer.button, jsonTimer.listItem, jsonTimer.text)
				debugLog('RESP. отправлено')
			end
		end
		-- Keep the ticker rows fresh at a one-second cadence like the server: otherwise they age towards showTime and the next sparse update visibly recreates them.
		if isEnabled and ticker.active and os.clock() - ticker.lastSent >= 1.0 then
			sendTickerRows()
		end
	end
end

local function buildSummaryParts()
	local summaryParts = {}
	if cryptoAnalysys.btc > 0 then
		table.insert(summaryParts, string.format(':coin: {FFD700}%d BTC{FFFFFF}', cryptoAnalysys.btc))
	end
	if cryptoAnalysys.asc > 0 then
		table.insert(summaryParts, string.format(':arz: {FFA500}%d ASC{FFFFFF}', cryptoAnalysys.asc))
	end
	return summaryParts
end

-- Build the notification parts (no emoji, no colors).
local function buildNotifyParts()
	local notifyParts = {}
	if cryptoAnalysys.btc > 0 then
		table.insert(notifyParts, cryptoAnalysys.btc .. ' BTC')
	end
	if cryptoAnalysys.asc > 0 then
		table.insert(notifyParts, cryptoAnalysys.asc .. ' ASC')
	end
	return notifyParts
end

local function printHistoryHint()
	sampAddChatMessage(tag .. cyr(':bar_chart: {C0C0C0}История всех сборов: {5CC9FF}/crstats'), -1)
end

local function printHouseStats(run)
	local showBTC = run.total.btc > 0
	local showASC = run.total.asc > 0
	for _, house in ipairs(run.houses) do
		local totalCards = house.cards.working + house.cards.paused

		-- Build the collection line.
		local statusMessage = string.format(':u1f3da: {CE5BFF}%s{FFFFFF}', house.name)

		local collectedParts = {}
		if showBTC then
			table.insert(collectedParts, string.format(':coin: {FFD700}%d BTC{FFFFFF}', house.collected.btc))
		end
		if showASC then
			table.insert(collectedParts, string.format(':arz: {FFA500}%d ASC{FFFFFF}', house.collected.asc))
		end
		if #collectedParts > 0 then
			statusMessage = string.format('%s | %s', statusMessage, table.concat(collectedParts, ' | '))
		end

		-- Add the cards info.
		statusMessage = string.format('%s | {C0C0C0}Карты: {32CD32}:u23fa:%d {FF5555}:u23f8:%d{FFFFFF}',
			statusMessage,
			house.cards.working,
			house.cards.paused
		)

		-- Add the cooling info.
		statusMessage = string.format('%s | {5CC9FF}Охлаждение: :cool: {32CD32}%d :u1f6a8: {FFA500}%d :sos: {FF5555}%d{FFFFFF}',
			statusMessage,
			(totalCards - house.cards.soon - house.cards.urgent),
			house.cards.soon,
			house.cards.urgent
		)

		-- Add the account balance info.
		local balanceColor
		if house.balance < BALANCE_URGENT then
			balanceColor = '{FF5555}'
		elseif house.balance < BALANCE_SOON then
			balanceColor = '{FFA500}'
		else
			balanceColor = '{32CD32}'
		end
		statusMessage = string.format('%s | %s%s', statusMessage, balanceColor, house.balanceRaw or tostring(house.balance))

		sampAddChatMessage(tag .. cyr(statusMessage), -1)
	end
end

--- Last run stats into the chat. Needed when there is no window: without mimgui this is the only way to see them, and it behaves like 2.3.0.
local function printLastRunToChat()
	local runs = readHistory()
	local last = nil
	for _, run in ipairs(runs) do
		if not last or (tonumber(run.ts) or 0) > (tonumber(last.ts) or 0) then
			last = run
		end
	end
	if not last or type(last.total) ~= 'table' then
		sampAddChatMessage(tag .. cyr('{C0C0C0}История пуста. Запустите сбор командой {5CC9FF}/crypto'), -1)
		return
	end

	local parts = {}
	if (tonumber(last.total.btc) or 0) > 0 then
		table.insert(parts, string.format(':coin: {FFD700}%d BTC{FFFFFF}', last.total.btc))
	end
	if (tonumber(last.total.asc) or 0) > 0 then
		table.insert(parts, string.format(':arz: {FFA500}%d ASC{FFFFFF}', last.total.asc))
	end
	local collected = #parts > 0 and table.concat(parts, ' | ') or '{C0C0C0}ничего{FFFFFF}'
	local interrupted = last.status ~= 'success' and ' {FF5555}Сбор был прерван.{FFFFFF}' or ''
	sampAddChatMessage(tag .. cyr(string.format(':bar_chart: {5CC9FF}Последний сбор (%s).{FFFFFF}%s Собрано: %s',
		formatDuration(last.duration), interrupted, collected)), -1)
	printHouseStats(last)
end

--- Help into the chat - the same text as the window tab, only shorter.
local function printHelpToChat()
	sampAddChatMessage(tag .. cyr('{FFD700}Crypto Collector{FFFFFF} собирает криптовалюту со всех домов через Флешку майнера.'), -1)
	sampAddChatMessage(tag .. cyr('{5CC9FF}/crypto{FFFFFF} - запустить сбор, {5CC9FF}/crstats{FFFFFF} - статистика последнего сбора, {5CC9FF}/crupdate{FFFFFF} - проверить обновление.'), -1)
	sampAddChatMessage(tag .. cyr('{C0C0C0}Пороги охлаждения и счёта, тихий режим и отладка настраиваются в файле:'), -1)
	sampAddChatMessage(tag .. cyr('{C0C0C0}' .. configDir() .. '\\config.ini'), -1)
	sampAddChatMessage(tag .. cyr('{C0C0C0}Окно с историей и настройками появится, если положить {FFFFFF}mimgui{C0C0C0} в moonloader/lib.'), -1)
end

-- Entry points. With no mimgui there is no window, so the commands print into the chat the way 2.3.0 did. /cstats, /cconfig and /chelp still work, unadvertised, for those used to the old names.
function showHelp()
	if hasWindow then
		openWindow('help')
	else
		printHelpToChat()
	end
end

function showConfig()
	if not hasWindow then
		sampAddChatMessage(tag .. cyr('{C0C0C0}Окно требует библиотеку {FFFFFF}mimgui{C0C0C0}, её нет. Настройки правятся в файле:'), -1)
		sampAddChatMessage(tag .. cyr('{C0C0C0}' .. configDir() .. '\\config.ini'), -1)
		return
	end
	openWindow('settings')
end

-- Delayed response helper (from MiningToolFixed).
local function sampSendDialogResponsed(dialogId, button, list, text)
	jsonTimer.isActive = true
	jsonTimer.dialogId = dialogId
	jsonTimer.button = button
	jsonTimer.listItem = list
	jsonTimer.text = text or ''
	-- RESP> pairs with RESP! and RESP. in the main loop: a log ending on RESP> means the process died on the way out of the handler while cancelling the dialog RPC, and one ending on RESP! means it died inside sampSendDialogResponse itself.
	debugLog(string.format('RESP> в очередь dlg=%s btn=%s item=%s', tostring(dialogId), tostring(button), tostring(list)))
end

function finishCollection()
    debugLog(string.format('finishCollection: домов %d, собрано %d BTC / %d ASC', #collectingHouses, cryptoAnalysys.btc, cryptoAnalysys.asc))
    isEnabled = false
    expectedDialog = nil
    stopTicker()
    local run = writeLastRunFile('success')
 	-- Build the collection summary.
	local summaryParts = buildSummaryParts()
	local notifyParts = buildNotifyParts()
	local durationText = formatDuration(run.duration)

    -- Notification suffix: the enabled cards.
    local enabledSuffix = ''
    local enabledNotifySuffix = ''
    if enabledCardsCount > 0 then
        enabledSuffix = string.format(' | :u23fa: {FFFFFF}Включено карт: {32CD32}%d{FFFFFF}', enabledCardsCount)
        enabledNotifySuffix = cyr('. Включено карт: ') .. enabledCardsCount
    end

    -- Show the notification with a callback that writes into the chat.
    if #notifyParts > 0 then
        notify('success', 'Crypto Collector', cyr('Автосбор завершён за ' .. durationText .. '! Собрано: ' .. table.concat(notifyParts, ', ')) .. enabledNotifySuffix, 4000, function()
            local summaryMessage = string.format(':tada: {5CC9FF}Автосбор завершён за %s.{FFFFFF} Всего собрано: %s%s. Статистика по домам:', durationText, table.concat(summaryParts, ' | '), enabledSuffix)
            sampAddChatMessage(tag .. cyr(summaryMessage), -1)
            printHouseStats(run)
            printHistoryHint()
        end)
    else
        notify('info', 'Crypto Collector', cyr('Автосбор завершён за ' .. durationText .. '. Ничего не собрано.') .. enabledNotifySuffix, 3000, function()
            sampAddChatMessage(tag .. cyr(':tada: {5CC9FF}Автосбор завершён за ' .. durationText .. '.{FFFFFF} {C0C0C0}Ничего не собрано.{FFFFFF}' .. enabledSuffix .. ' Статистика по домам:'), -1)
            printHouseStats(run)
            printHistoryHint()
        end)
    end

    -- The stats are saved in the file, so the memory can be cleared.
    collectingHouses = {}
    currentHouseIndex = 0
    cryptoAnalysys = {btc = 0, asc = 0}
    currentHouseCollected = {btc = 0, asc = 0}

    -- Turn MiningTool back on if it was active.
    if isMiningToolActive then
        sampProcessChatInput('/jmnt')
    end
end

-- Stop the collection when it is interrupted.
function stopCollection()
	debugLog('stopCollection: дом=' .. currentHouseIndex .. ' isCollecting=' .. tostring(isCollecting) .. ' isEnablingInHouse=' .. tostring(isEnablingInHouse))
	isEnabled = false
	isCollecting = false
	isEnablingInHouse = false
	expectedDialog = nil
	stopTicker()
	writeLastRunFile('fail')
	currentHouseIndex = 0

	-- Build the message about what was collected (before the stats are reset).
	local summaryParts = buildSummaryParts()
	local notifyParts = buildNotifyParts()

	-- Show the notification with a callback that writes into the chat.
	if #notifyParts > 0 then
		notify('error', 'Crypto Collector', cyr('Сбор прерван! Собрано: ' .. table.concat(notifyParts, ', ')), 4000, function()
			local summaryMessage = string.format(':warning: {FF5555}:warning: Сбор прерван.{FFFFFF} Успели собрать: %s', table.concat(summaryParts, ' | '))
			sampAddChatMessage(tag .. cyr(summaryMessage), -1)
		printHistoryHint()
		end)
	else
		notify('error', 'Crypto Collector', cyr('Сбор прерван'), 3000, function()
			sampAddChatMessage(tag .. cyr(':warning: {FF5555}Сбор прерван.'), -1)
		printHistoryHint()
		end)
	end

	-- Reset all the stats.
	currentHouseIndex = 0
	collectingHouses = {}
	cryptoAnalysys = {btc = 0, asc = 0}
	currentHouseCollected = {btc = 0, asc = 0}

	-- Turn MiningTool back on if it was active.
	if isMiningToolActive then
		sampProcessChatInput('/jmnt')
	end
end

-- Move on to the next house.
local function goToNextHouse(extraDelay)
	lua_thread.create(function()
		if extraDelay then
			wait(extraDelay)
		end

		-- Check whether the collection was interrupted.
		if not isEnabled then
			return
		end

		currentHouseIndex = currentHouseIndex + 1
		debugLog('goToNextHouse: переход к дому ' .. currentHouseIndex .. '/' .. #collectingHouses)

		if currentHouseIndex > #collectingHouses then
			finishCollection()
		else
			-- Reset the cards slot so the previous house counter does not linger.
			updateTicker('анализ...')
			wait(1000)
			expectedDialog = DIALOG_HOUSE_LIST
		debugLog('goToNextHouse: отправляем /flashminer, ожидаем список домов')
			sampSendChat('/flashminer')
		end
	end)
end

function showCollectionStats()
	if hasWindow then
		openWindow('history')
	else
		printLastRunToChat()
	end
end

function startCryptoCollection()
	-- Check MiningTool.
	isMiningToolActive = checkMiningToolActivity()
	debugLog('startCryptoCollection: MiningTool активен=' .. tostring(isMiningToolActive))

	-- Start the auto-collection.
	isEnabled = true
	runStartedAt = os.time()
	-- Initialize the variables.
	collectingHouses = {}
	currentHouseIndex = 0
	currentHouseCollected = {btc = 0, asc = 0}
	isCollecting = false
	isEnablingInHouse = false
	enabledCardsCount = 0
	houseProfitableCards = 0
	houseCollectedCards = 0
	cryptoAnalysys = {btc = 0, asc = 0}
	expectedDialog = DIALOG_HOUSE_LIST

	-- Turn MiningTool off if it is active.
	if isMiningToolActive then
		sampProcessChatInput('/jmnt')
	end

	updateTicker('поиск...')
	sampSendChat('/flashminer')
end

function sampev.onServerMessage(color,rawText)
	debugCtx = 'msg'
	if not isEnabled then
		return
	end

    local text = cyr:decode(rawText)

	-- Hide the informational message about choosing a house.
	if text:find('Выберите дом с майнинг фермой') then
		return false
	end

	if text:find('У вас нет флешки майнера.') then
		notify('error', 'Crypto Collector', cyr('Нужна флешка майнера в инвентаре!'), 3000)
		isEnabled = false
		return false
	end

	-- Handle the profit withdrawal (same as MiningToolFixed).
	if text:find("^Вы вывели {ffffff}%d+ [BTCASC]+{ffff00}") then
		if text:find("BTC") then
			local amount = tonumber(text:match("Вы вывели {ffffff}(%d+)"))
			if amount then
				cryptoAnalysys.btc = cryptoAnalysys.btc + amount
				currentHouseCollected.btc = currentHouseCollected.btc + amount
				debugLog(string.format('вывод: +%d BTC (дом %d, всего %d)', amount, currentHouseIndex, cryptoAnalysys.btc))
			end
		elseif text:find("ASC") then
			local amount = tonumber(text:match("Вы вывели {ffffff}(%d+)"))
			if amount then
				cryptoAnalysys.asc = cryptoAnalysys.asc + amount
				currentHouseCollected.asc = currentHouseCollected.asc + amount
				debugLog(string.format('вывод: +%d ASC (дом %d, всего %d)', amount, currentHouseIndex, cryptoAnalysys.asc))
			end
		end

		return false
	end

	if text:find('добавлен предмет') then
		if text:find(':item1811:', 1, true) or text:find(':item5996:', 1, true) then
			return false
		end
	end

	-- If the house has no basement or is rented out, skip it.
	if text:find('В этом доме нет подвала с вентиляцией') or text:find('он еще не достроен') or text:find('Пока дом находится в аренде') then
		debugLog('дом ' .. currentHouseIndex .. ': нет подвала / не достроен / в аренде - пропуск')
		-- The message can arrive before the house list dialog, while the index is still 0.
		local house = collectingHouses[currentHouseIndex]
		if house then
			house.hasCards = false
		end
		updateTicker('пропуск')
		goToNextHouse()
		return false
	end

	-- Failed to start a card (no coolant left).
	if isEnablingInHouse and text:find('%[Ошибка%]') and text:find('Чтобы запустить видеокарту в работу') then
		return false
	end

	-- If the player is a tenant and cannot act, skip this house.
	if text:find('%[Ошибка%]') and text:find('Жильцы дома не могут совершать такие действия') then
		debugLog('дом ' .. currentHouseIndex .. ': нет доступа (жилец) - пропуск')
		local house = collectingHouses[currentHouseIndex]
		if house then
			house.hasCards = false
		end
		isCollecting = false
		isEnablingInHouse = false
		updateTicker('нет доступа')
		goToNextHouse()
		return false
	end
end

function sampev.onShowDialog(id, style, rawTitle, button1, button2, rawText)
	debugCtx = 'dlg:' .. tostring(id)
	if not isEnabled then
		return  -- With auto-collection off, dialogs are none of our business.
	end

	local title = cyr:decode(rawTitle)
	local kind = dialogKind(title)
	debugLog('onShowDialog: id=' .. id .. ' "' .. title .. '" | вид=' .. tostring(kind) .. ' | ожидается=' .. tostring(expectedDialog))

	-- Interruption guard: check that the dialog that opened is the one we expected.
	if expectedDialog and kind ~= expectedDialog then
		debugLog('!!! СТОП: ожидался ' .. expectedDialog .. ', пришёл ' .. tostring(kind) .. ' (id=' .. id .. ') "' .. title .. '"')
		stopCollection()
		return  -- Let the dialog through.
	end

	local text = cyr:decode(rawText)

	-- Helper taken from MiningToolFixed.
	local function findLineAndRespond(pattern, checkFunc, listboxId)
		for line in text:gmatch('[^\r\n]+') do
			if line:find(pattern) and checkFunc(line) then
				sampSendDialogResponsed(id, 1, listboxId)
				return true
			end
			listboxId = listboxId + 1
		end
		return false
	end

	if kind == DIALOG_HOUSE_LIST then
		if #collectingHouses == 0 then
			-- First time round: build the house list.
			local ignoredHouses = parseIgnoredHouses()
			local listboxIndex = 0  -- Item index in the listbox (houses only).
			for n in text:gmatch('[^\r\n]+') do
				-- Look for house rows: [1] Дом №821 San Fierro 0 0 циклов (:CASH:18.138.307 / :CASH:60.000.000).
				local houseNumber = n:match('%[%d+%] (Дом №%d+)')
				if houseNumber then
					-- Ignored houses still occupy a listbox slot - skip adding them, but keep counting so later indices stay aligned.
					if ignoredHouses[houseNumber:match('%d+')] then
						listboxIndex = listboxIndex + 1
					else
						-- Extract the account balance (format :CASH:X.XXX.XXX, or :CASHV: for Vice City).
						local balance = 0
						local balanceRaw = ''
						-- Extract everything between the brackets: (:CASH:18.138.307 / :CASH:60.000.000).
						local fullBalance = n:match('%((.-)%)')
						local balanceStr = nil
						if fullBalance then
							-- Take the part before the slash.
							balanceStr = fullBalance:match('(.-)%s*/')
						end
						if balanceStr then
							-- :CASH:5.000.550 or :CASHV:5.000.550 - the dots are thousand separators.
							balanceRaw = balanceStr:match(':CASHV?:[%d%.]+') or ''
							local cashStr = balanceStr:match(':CASHV?:([%d%.]+)')
							if cashStr then
								balance = tonumber((cashStr:gsub('%.', ''))) or 0
							end
						end

						table.insert(collectingHouses, {
							name = houseNumber,
							index = listboxIndex,
							hasCards = false,
							collected = {btc = 0, asc = 0},
							balance = balance,
							balanceRaw = balanceRaw,
							cards = {
								working = 0,
								paused = 0,
								urgent = 0,
								soon = 0
							}
						})
						listboxIndex = listboxIndex + 1
					end
				end
			end

			if #collectingHouses > 0 then
				debugLog('HOUSE_LIST: найдено домов ' .. #collectingHouses .. ', кликаем на ' .. collectingHouses[1].name)
				-- Notification that the collection has started.
				notify('info', 'Crypto Collector', cyr('Найдено домов: ') .. #collectingHouses .. cyr('. Начинаю собирать криптовалюту...'), 3000)
				currentHouseIndex = 1
				-- Click the first house.
				expectedDialog = DIALOG_CARDS_LIST
				updateTicker('анализ...')
				sampSendDialogResponsed(id, 1, collectingHouses[1].index)
				return false
			else
				-- Error notification.
				notify('error', 'Crypto Collector', cyr('Дома не найдены!'), 3000)
				isEnabled = false
			end
		elseif collectingHouses[currentHouseIndex] then
			-- Back at the house list - click the next house.
			local house = collectingHouses[currentHouseIndex]
			debugLog('HOUSE_LIST: кликаем на дом ' .. currentHouseIndex .. ' (' .. house.name .. ')')
			expectedDialog = DIALOG_CARDS_LIST
			sampSendDialogResponsed(id, 1, house.index)
			return false
		end
	elseif kind == DIALOG_CARDS_LIST then
		local house = collectingHouses[currentHouseIndex]
		if not house then
			-- Index out of sync with the house list: stop instead of erroring inside the handler.
			debugLog('!!! CARDS_LIST: нет дома с индексом ' .. currentHouseIndex .. ', прерываю сбор')
			stopCollection()
			return false
		end
		-- First pass - analyze the cards.
		if not isCollecting and not isEnablingInHouse then
			local totalProfit = {btc = 0, asc = 0}
			local totalCards = 0
			local workingCards = 0
			local pausedCards = 0
			local urgentService = 0
			local soonService = 0
			local pausedWithCoolant = 0
			local profitableCards = 0

			for n in text:gmatch('[^\r\n]+') do
				if n:find("^Полка") then
					totalCards = totalCards + 1

					-- The same criterion the collection loop uses to pick a card.
					local firstInt = tonumber(n:match('(%d+)%.%d+'))
					if firstInt and firstInt >= 1 then
						profitableCards = profitableCards + 1
					end

					-- Count the card statuses.
					if n:find("Работает") then
						workingCards = workingCards + 1
					elseif n:find("На паузе") then
						pausedCards = pausedCards + 1
						-- Check whether there is coolant left to start the card.
						local coolant = tonumber(n:match("(%d+%.%d+)%%?%s*$"))
						if coolant and coolant > 0 then
							pausedWithCoolant = pausedWithCoolant + 1
						end
					end

					-- Count the BTC and ASC profit.
					-- tonumber can still fail on a [%d%.]+ capture like "1.2.3" or "." - guard it.
					local profitBTC = tonumber(n:match('([%d%.]+)%s+BTC') or '')
					if profitBTC then
						totalProfit.btc = totalProfit.btc + math.floor(profitBTC)
					end
					local profitASC = tonumber(n:match('([%d%.]+)%s+ASC') or '')
					if profitASC then
						totalProfit.asc = totalProfit.asc + math.floor(profitASC)
					end

					-- Check the cooling level.
					local coolingLevel = tonumber(n:match('([%d%.]+)%%') or '')
					if coolingLevel then
						if coolingLevel < COOLING_URGENT then
							urgentService = urgentService + 1
						elseif coolingLevel < COOLING_SOON then
							soonService = soonService + 1
						end
					end
				end
			end

			-- Save the per-house stats.
			house.hasCards = totalCards > 0
			house.cards.working = workingCards
			house.cards.paused = pausedCards
			house.cards.urgent = urgentService
			house.cards.soon = soonService
			house.collected = {btc = 0, asc = 0}  -- Nothing collected yet.
			currentHouseCollected = house.collected
			house.needsEnabling = pausedWithCoolant > 0
			debugLog('CARDS_LIST: ' .. house.name .. ' | карт=' .. totalCards .. ' работает=' .. workingCards .. ' пауза=' .. pausedCards .. ' BTC=' .. totalProfit.btc .. ' ASC=' .. totalProfit.asc .. ' needsEnabling=' .. tostring(house.needsEnabling))

			if totalProfit.btc > 0 or totalProfit.asc > 0 then
				-- Switch to collection mode.
				isCollecting = true
				houseProfitableCards = profitableCards
				houseCollectedCards = 0
				updateTicker(string.format('Карты 0/%d', houseProfitableCards))
				-- Keep going in collection mode (do not leave the handler).
			elseif house.needsEnabling then
				-- No profit, but there are cards to start.
				updateTicker('включаю')
				isEnablingInHouse = true
				-- Keep going in enabling mode.
			else
				-- Neither profit nor cards to start.
				updateTicker('пусто')
				goToNextHouse(1000)
				return false
			end
		end

		-- Collection mode - look for a card with profit >= 1 (BTC or ASC).
		if isCollecting then
			-- Look for a card with profit >= 1 (same as MiningToolFixed).
			expectedDialog = DIALOG_CARD_ACTION
			local foundCard = text:find('%d+%.%d+') and findLineAndRespond('%d+%.%d+', function(line)
				return tonumber(line:match('(%d+)%.%d+')) >= 1
			end, -1)
			debugLog('CARDS_LIST: isCollecting, foundCard=' .. tostring(foundCard ~= false))

			if not foundCard then
				-- No cards >= 1 found, or the list is empty.
				isCollecting = false
				-- No need to record what was collected separately: house.collected and currentHouseCollected are the same table.

				-- Move on to starting the cards if needed.
				if house.needsEnabling then
					updateTicker('включаю')
					isEnablingInHouse = true
					-- Carry on within this same call.
				else
					goToNextHouse()
					return false
				end
			end
			if isCollecting then
				return false
			end
		end

		-- Card-enabling phase in the current house.
		if isEnablingInHouse then
			expectedDialog = DIALOG_CARD_ACTION
			local found = findLineAndRespond("На паузе", function(line)
				local coolant = tonumber(line:match("(%d+%.%d+)%%?%s*$"))
				return coolant and coolant > 0
			end, -1)

			if not found then
				isEnablingInHouse = false
				goToNextHouse()
			end
			return false
		end
	elseif kind == DIALOG_CARD_ACTION then
		if isCollecting then
			expectedDialog = DIALOG_WITHDRAW
			-- Look for a row with a number >= 1 (same as MiningToolFixed).
			if not findLineAndRespond('%d+%.%d+', function(line)
				return tonumber(line:match('(%d+)%.%d+')) >= 1
			end, 0) then
				-- Nothing found - close the dialog.
				debugLog('CARD_ACTION: нет действия для вывода, закрываем')
				expectedDialog = DIALOG_CARDS_LIST
				sampSendDialogResponsed(id, 0, 0)
			else
				debugLog('CARD_ACTION: нашли вывод, ждём WITHDRAW')
			end
			return false
		elseif isEnablingInHouse then
			-- Work out which dialog this is: a start prompt or an already running card.
			if text:find("Запустить видеокарту") then
				-- Click "Запустить".
				debugLog('CARD_ACTION: запускаем карту #' .. (enabledCardsCount + 1))
				expectedDialog = DIALOG_CARD_ACTION
				findLineAndRespond("Запустить видеокарту", function() return true end, 0)
				enabledCardsCount = enabledCardsCount + 1
				-- Refresh the ticker so the row stays alive during a long enabling pass.
				updateTicker('включаю')
				-- Update the house stats.
				local house = collectingHouses[currentHouseIndex]
				if house then
					house.cards.paused = house.cards.paused - 1
					house.cards.working = house.cards.working + 1
				end
			elseif text:find("Остановить видеокарту") then
				-- The card is already running and the dialog refreshed: close it and go back to the list.
				debugLog('CARD_ACTION: карта уже запущена, закрываем')
				expectedDialog = DIALOG_CARDS_LIST
				sampSendDialogResponsed(id, 0, 0)
			else
				-- No start buttons, close it.
				debugLog('CARD_ACTION: нет кнопок включения, закрываем')
				expectedDialog = DIALOG_CARDS_LIST
				sampSendDialogResponsed(id, 0, 0)
			end
			return false
		end
	elseif kind == DIALOG_WITHDRAW then
		-- After the withdrawal we go back to the card action dialog.
		debugLog('WITHDRAW: подтверждаем вывод, возвращаемся к CARD_ACTION')
		expectedDialog = DIALOG_CARD_ACTION
		houseCollectedCards = houseCollectedCards + 1
		updateTicker(string.format('Карты %d/%d', houseCollectedCards, houseProfitableCards))
		sampSendDialogResponsed(id, 1, 0)
		return false
	end
end
