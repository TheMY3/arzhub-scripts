script_name('Craft Counter')
script_author('TheMY3')
script_version('1.3.2')

-- Forum topic (current version, discussion): https://www.blast.hk/threads/246012/

local moonloader = require('moonloader')  -- download_status for self-update.
local imgui = require('mimgui')
local ffi = require('ffi')
local encoding = require('encoding')
local hook = require('lib.samp.events')
encoding.default = 'UTF-8'
local cyr = encoding.CP1251
local u8 = encoding.UTF8

local colors = {
	value = '{5CC9FF}',    -- Values and commands in chat, as in the other [TM] scripts.
	overlay = '{FF710A}',  -- Values in the on-screen craft overlay.
	white = '{FFFFFF}'
}

local tag = '{FFA500}[TM] Craft Counter' .. colors.white .. ': '
local FORUM_URL = 'https://www.blast.hk/threads/246012/'
local renderFont = renderCreateFont('Arial', 16, 13)

local HISTORY_MAX_RECORDS = 1000
local CARD_HEIGHT = 76
local CLEAR_CONFIRM_SECONDS = 3

-- ============================================================================
-- HELPERS
-- ============================================================================

-- string.lower leaves CP1251 Cyrillic alone, so А-Я and Ё are mapped to their lowercase bytes.
local LOWER_CP1251 = {['\168'] = '\184'}
for b = 192, 223 do LOWER_CP1251[string.char(b)] = string.char(b + 32) end

local function lowerCp1251(s)
	return (s:lower():gsub('[\168\192-\223]', LOWER_CP1251))
end

-- imgui.Text* is printf-style, so a % in an item name would be read as a format specifier.
local function esc(str)
	return (tostring(str):gsub('%%', '%%%%'))
end

-- "12.5%" for imgui.Text*: the doubled sign survives the printf pass as one.
local function percentUI(value)
	return string.format('%.1f%%%%', value)
end

local function notify(text)
	sampAddChatMessage(tag .. cyr(text), -1)
end

local function colored(value)
	return colors.value .. tostring(value) .. colors.white
end

local function overlayValue(value)
	return colors.overlay .. tostring(value) .. colors.white
end

-- "1 234 567$".
local function formatMoneyFull(amount)
	local str = tostring(amount)
	local result = str:reverse():gsub('(%d%d%d)', '%1 '):reverse():gsub('^ ', '')
	return result .. '$'
end

-- "500$" / "1.5k$" / "2.3kk$".
local function formatMoney(amount)
	if amount >= 1000000 then
		return string.format('%.1fkk$', amount / 1000000)
	elseif amount >= 1000 then
		return string.format('%.1fk$', amount / 1000)
	else
		return string.format('%d$', amount)
	end
end

-- "45 сек." / "2 мин." / "1 мин. 30 сек." for chat and the overlay.
local function formatTime(seconds)
	seconds = math.floor(seconds)
	if seconds < 60 then
		return string.format(cyr('%d сек.'), seconds)
	else
		local minutes = math.floor(seconds / 60)
		seconds = seconds % 60
		if seconds == 0 then
			return string.format(cyr('%d мин.'), minutes)
		else
			return string.format(cyr('%d мин. %d сек.'), minutes, seconds)
		end
	end
end

-- "45 сек." / "~1 мин." / "~1.5 мин.".
local function formatTimeShort(seconds)
	seconds = math.floor(seconds)
	if seconds < 60 then
		return string.format(cyr('%d сек.'), seconds)
	else
		local minutes = math.floor(seconds / 30) * 0.5
		if minutes % 1 == 0 then
			return string.format(cyr('~%d мин.'), minutes)
		else
			return string.format(cyr('~%.1f мин.'), minutes)
		end
	end
end

-- Same as formatTime, but UTF-8 and shorter for the history window.
local function formatTimeUI(seconds)
	seconds = math.floor(seconds)
	if seconds < 60 then
		return string.format('%d сек.', seconds)
	else
		local minutes = math.floor(seconds / 60)
		seconds = seconds % 60
		if seconds == 0 then
			return string.format('%d мин.', minutes)
		else
			return string.format('%d м. %d с.', minutes, seconds)
		end
	end
end

-- "Сегодня 14:05" / "Вчера 14:05" / "3 мар 14:05" / "3 мар 2025 14:05".
local function formatDateRelative(dateStr)
	if not dateStr then return '-' end
	local today = os.date('%Y-%m-%d')
	local yesterday = os.date('%Y-%m-%d', os.time() - 86400)
	local recordDate = dateStr:sub(1, 10)
	local recordTime = dateStr:sub(12, 16)

	if recordDate == today then
		return 'Сегодня ' .. recordTime
	elseif recordDate == yesterday then
		return 'Вчера ' .. recordTime
	else
		local day = tonumber(dateStr:sub(9, 10))
		local month = tonumber(dateStr:sub(6, 7))
		local year = dateStr:sub(1, 4)
		local months = {'янв', 'фев', 'мар', 'апр', 'май', 'июн', 'июл', 'авг', 'сен', 'окт', 'ноя', 'дек'}

		if year == os.date('%Y') then
			return day .. ' ' .. months[month] .. ' ' .. recordTime
		else
			return day .. ' ' .. months[month] .. ' ' .. year .. ' ' .. recordTime
		end
	end
end

-- ============================================================================
-- CRAFT HISTORY (JSON)
-- ============================================================================

local historyDir = getWorkingDirectory() .. '\\config\\TheMY3'
local historyPath = historyDir .. '\\craft_history.json'
local historyTmpPath = historyPath .. '.tmp'
local historyBadPath = historyPath .. '.bad'

local function readFile(path)
	local f = io.open(path, 'rb')
	if not f then return nil end
	local content = f:read('*a')
	f:close()
	return content
end

-- A crash between remove and rename in saveHistory leaves only the temp file, so it is the fallback.
local function loadHistory()
	local path = historyPath
	local content = readFile(path)
	if not content then
		path = historyTmpPath
		content = readFile(path)
	end
	if not content or content == '' then return {} end

	local ok, decoded = pcall(decodeJson, content)
	if ok and type(decoded) == 'table' then return decoded end

	-- Move the unreadable file aside so the next save does not overwrite what is left of it.
	os.remove(historyBadPath)
	os.rename(path, historyBadPath)
	sampAddChatMessage(tag .. cyr('Файл истории повреждён и сохранён как craft_history.json.bad, история начата заново.'), -1)
	return {}
end

-- Write to a temp file first so a crash mid-write cannot leave a torn history behind.
local function saveHistory(history)
	if not doesDirectoryExist(historyDir) then
		createDirectory(historyDir)
	end
	local f = io.open(historyTmpPath, 'w')
	if not f then return false end
	f:write(encodeJson(history))
	f:close()
	os.remove(historyPath)
	return os.rename(historyTmpPath, historyPath) and true or false
end

local function addToHistory(s)
	local history = loadHistory()
	table.insert(history, {
		date = os.date('%Y-%m-%d %H:%M'),
		item = s.itemName and cyr:decode(s.itemName) or nil,
		success = s.success,
		fail = s.fail,
		spent = s.totalSpent,
		time = math.floor(s.totalTime),
		chance = s.chance
	})
	while #history > HISTORY_MAX_RECORDS do
		table.remove(history, 1)
	end
	saveHistory(history)
end

-- ============================================================================
-- HISTORY WINDOW
-- ============================================================================

local renderWindow = imgui.new.bool(false)
local searchBuffer = imgui.new.char[256]('')

local historyCache = {}    -- Records as stored, oldest first.
local historyKeys = {}     -- Lowercase CP1251 item name per record, built once for the search.
local historyTotals = {success = 0, fail = 0, spent = 0}
local visibleRecords = {}  -- Indexes into historyCache matching the search, newest first.
local lastSearch = nil
local clearArmedUntil = 0

local function refreshHistory()
	historyCache = loadHistory()
	historyKeys = {}
	historyTotals = {success = 0, fail = 0, spent = 0}
	for i, record in ipairs(historyCache) do
		historyKeys[i] = lowerCp1251(cyr(record.item or 'Неизвестно'))
		historyTotals.success = historyTotals.success + (record.success or 0)
		historyTotals.fail = historyTotals.fail + (record.fail or 0)
		historyTotals.spent = historyTotals.spent + (record.spent or 0)
	end
	lastSearch = nil
end

local function filterHistory(searchText)
	visibleRecords = {}
	local needle = lowerCp1251(cyr(searchText))
	for i = #historyCache, 1, -1 do
		if needle == '' or historyKeys[i]:find(needle, 1, true) then
			visibleRecords[#visibleRecords + 1] = i
		end
	end
	lastSearch = searchText
end

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
	local glyph_ranges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
	imgui.GetIO().Fonts:AddFontFromFileTTF(getFolderPath(0x14) .. '\\trebucbd.ttf', 16.0, nil, glyph_ranges)
	imgui.InvalidateFontsTexture()
	applyTheme()
end)

local function drawRecord(index)
	local record = historyCache[index]
	local itemName = record.item or 'Неизвестно'

	imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.15, 0.15, 0.15, 0.8))
	imgui.BeginChild('##record' .. index, imgui.ImVec2(-1, CARD_HEIGHT), true, imgui.WindowFlags.NoScrollbar)

	-- Item name and success chance, date on the right.
	local dateFormatted = formatDateRelative(record.date)
	imgui.TextColored(imgui.ImVec4(1.0, 0.7, 0.2, 1.0), u8(esc(itemName)))
	imgui.SameLine(0, 0)
	imgui.Text(u8(' (шанс успеха: ' .. esc(record.chance or 0) .. '%%)'))
	imgui.SameLine(imgui.GetWindowWidth() - imgui.CalcTextSize(dateFormatted).x - 10)
	imgui.TextDisabled(dateFormatted)

	-- Attempts: total, success, fail and the actual rate.
	local total = (record.success or 0) + (record.fail or 0)
	local factPct = total > 0 and ((record.success or 0) / total * 100) or 0
	imgui.Text(u8('Попыток: ' .. total .. ' - '))
	imgui.SameLine(0, 0)
	imgui.TextColored(imgui.ImVec4(0.0, 0.8, 0.0, 1.0), u8('Удачно: ' .. tostring(record.success or 0)))
	imgui.SameLine(0, 0)
	imgui.Text(u8(' - '))
	imgui.SameLine(0, 0)
	imgui.TextColored(imgui.ImVec4(0.8, 0.0, 0.0, 1.0), u8('Неудачно: ' .. tostring(record.fail or 0)))
	imgui.SameLine(0, 0)
	imgui.Text(u8(' (' .. percentUI(factPct) .. ')'))

	imgui.Text(u8('Потрачено: ' .. formatMoneyFull(record.spent or 0) .. ' - Время: ' .. formatTimeUI(record.time or 0)))

	imgui.EndChild()
	imgui.PopStyleColor()
end

imgui.OnFrame(
	function() return renderWindow[0] end,
	function()
		local resX, resY = getScreenResolution()
		imgui.SetNextWindowPos(imgui.ImVec2(resX / 2, resY / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
		imgui.SetNextWindowSize(imgui.ImVec2(760, 600), imgui.Cond.FirstUseEver)

		if imgui.Begin(u8('Craft Counter v' .. thisScript().version .. ' - История крафтов##history'), renderWindow, imgui.WindowFlags.NoCollapse) then
			imgui.PushItemWidth(180)
			imgui.InputTextWithHint('##search', u8'Поиск по предмету...', searchBuffer, ffi.sizeof(searchBuffer))
			imgui.PopItemWidth()

			imgui.SameLine()
			if imgui.Button(u8'Обновить') then
				refreshHistory()
			end

			-- The first click only arms the button, the second one within a few seconds clears.
			imgui.SameLine()
			local armed = os.clock() < clearArmedUntil
			if imgui.Button(armed and u8'Точно очистить?##clear' or u8'Очистить##clear') then
				if armed then
					saveHistory({})
					refreshHistory()
					clearArmedUntil = 0
				else
					clearArmedUntil = os.clock() + CLEAR_CONFIRM_SECONDS
				end
			end

			local searchText = ffi.string(searchBuffer)
			if searchText ~= lastSearch then
				filterHistory(searchText)
			end

			imgui.Separator()

			local totalAttempts = historyTotals.success + historyTotals.fail
			local totalPct = totalAttempts > 0 and (historyTotals.success / totalAttempts * 100) or 0

			imgui.Text(u8('Сессий: ' .. #historyCache .. ' - Попыток: ' .. totalAttempts .. ' - '))
			imgui.SameLine(0, 0)
			imgui.TextColored(imgui.ImVec4(0.0, 0.8, 0.0, 1.0), u8('Удачно: ' .. historyTotals.success))
			imgui.SameLine(0, 0)
			imgui.Text(u8(' - '))
			imgui.SameLine(0, 0)
			imgui.TextColored(imgui.ImVec4(0.8, 0.0, 0.0, 1.0), u8('Неудачно: ' .. historyTotals.fail))
			imgui.SameLine(0, 0)
			imgui.Text(u8(' (' .. percentUI(totalPct) .. ') - Потрачено: ' .. formatMoneyFull(historyTotals.spent)))

			imgui.TextDisabled(u8('Лимит: ' .. HISTORY_MAX_RECORDS .. ' сессий. Старые записи заменяются новыми.'))

			imgui.Separator()

			imgui.BeginChild('##historyList', imgui.ImVec2(-1, -1), false)

			-- Cards share one height, so only the ones in view are drawn and the rest is left as blank space.
			local step = CARD_HEIGHT + imgui.GetStyle().ItemSpacing.y
			local scrollY = imgui.GetScrollY()
			local first = math.max(1, math.floor(scrollY / step))
			local last = math.min(#visibleRecords, math.ceil((scrollY + imgui.GetWindowHeight()) / step) + 1)
			local startY = imgui.GetCursorPosY()
			for n = first, last do
				imgui.SetCursorPosY(startY + (n - 1) * step)
				drawRecord(visibleRecords[n])
			end
			imgui.SetCursorPosY(startY + #visibleRecords * step)
			imgui.Dummy(imgui.ImVec2(0, 0))

			imgui.EndChild()

			imgui.End()
		end
	end
)

local function cmdCraftHistory()
	if not renderWindow[0] then
		refreshHistory()
	end
	renderWindow[0] = not renderWindow[0]
end

-- ============================================================================
-- CRAFT TRACKING
-- ============================================================================

local stats = {
	active = false,
	maxCraft = 0,
	currentCraft = 0,
	timeStart = 0,
	totalTime = 0,
	speedPerItem = 0,
	timeLeft = 0,
	success = 0,
	fail = 0,
	cost = 0,
	totalSpent = 0,
	itemName = nil,
	chance = 0
}

-- Chat prefixes the item name follows (CP1251).
local PATTERN_CRAFT_SUCCESS = cyr("Вы успешно создали предмет '")
local PATTERN_CRAFT_FAIL = cyr("Создание предмета '")

local _, screenH = getScreenResolution()

-- Item name between the prefix and the closing quote of a craft chat message.
local function parseItemName(text)
	local startPos = text:find(PATTERN_CRAFT_SUCCESS, 1, true)
	if not startPos then
		startPos = text:find(PATTERN_CRAFT_FAIL, 1, true)
		if startPos then
			startPos = startPos + #PATTERN_CRAFT_FAIL
		end
	else
		startPos = startPos + #PATTERN_CRAFT_SUCCESS
	end

	if not startPos then return nil end

	local endPos = text:find("'", startPos, true)
	if not endPos then return nil end

	return text:sub(startPos, endPos - 1)
end

local function formatItemName(itemName)
	if itemName then
		return cyr(' «') .. colored(itemName) .. cyr('»')
	end
	return ''
end

local function showFinalStats(action)
	if stats.currentCraft > 0 then
		local successPct = stats.success / stats.currentCraft * 100

		sampAddChatMessage(tag .. cyr('Крафт предмета') .. formatItemName(stats.itemName) .. ' ' .. action .. '!', -1)
		sampAddChatMessage(tag .. cyr('Попыток: ') .. colored(stats.currentCraft) .. cyr(' • Удачно: ') .. colored(stats.success)
			.. cyr(' • Неудачно: ') .. colored(stats.fail) .. string.format(' (%.1f%%)', successPct), -1)
		sampAddChatMessage(tag .. cyr('Потрачено: ') .. colored(formatMoneyFull(stats.totalSpent))
			.. cyr(' • Время: ') .. colored(formatTime(stats.totalTime)), -1)
		sampAddChatMessage(tag .. cyr('История крафтов: ') .. colored('/cchistory'), -1)
	end
end

local function resetStats()
	if stats.currentCraft > 0 then
		addToHistory(stats)
	end

	stats.active = false
	stats.timeStart = os.clock()
	stats.currentCraft = 0
	stats.totalTime = 0
	stats.speedPerItem = 0
	stats.timeLeft = 0
	stats.success = 0
	stats.fail = 0
	stats.cost = 0
	stats.totalSpent = 0
	stats.chance = 0
	stats.itemName = nil
end

local function parseCraftData(str)
	local action = str:match('"action":(%d+)')
	if not action then return nil end
	action = tonumber(action)

	if action == 1 then
		local count = str:match('"count":(%d+)')
		local cost = str:match('"cost":(%d+)')
		local chance = str:match('"chance":(%d+)')
		return {
			action = 1,
			count = tonumber(count) or 0,
			cost = tonumber(cost) or 0,
			chance = tonumber(chance) or 0
		}
	elseif action == 3 then
		return { action = 3 }
	elseif action == 4 then
		local success = str:match('"success":(%d+)')
		return {
			action = 4,
			success = tonumber(success) == 1
		}
	end

	return nil
end

-- action 1: craft window opened (count, cost, chance).
-- action 3: craft stopped (window closed or the stop button).
-- action 4: one attempt finished (success: 0/1).
local function handleCraftEvent(data)
	if data.action == 1 then
		if stats.active then
			stats.maxCraft = data.count + stats.currentCraft
		else
			stats.maxCraft = data.count
		end
		stats.cost = data.cost
		stats.chance = data.chance
	elseif data.action == 3 then
		if stats.active then
			if stats.currentCraft >= stats.maxCraft then
				showFinalStats(cyr('завершен'))
			else
				showFinalStats(cyr('прерван'))
			end
			resetStats()
		end
	elseif data.action == 4 then
		if stats.active then
			stats.currentCraft = stats.currentCraft + 1
			stats.totalTime = os.clock() - stats.timeStart
			stats.speedPerItem = stats.totalTime / stats.currentCraft
			stats.timeLeft = stats.speedPerItem * (stats.maxCraft - stats.currentCraft)

			if data.success then
				stats.success = stats.success + 1
			else
				stats.fail = stats.fail + 1
			end

			stats.totalSpent = stats.totalSpent + stats.cost
		end
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
	if not str or not str:find('event.inventory.craft', 1, true) then return end

	local data = parseCraftData(str)
	if data then
		handleCraftEvent(data)
	end
end

local function readOutgoing(bs)
	raknetBitStreamIgnoreBits(bs, 8)
	if raknetBitStreamReadInt8(bs) ~= 18 then return end
	local length = raknetBitStreamReadInt16(bs)
	local str = raknetBitStreamReadString(bs, length)
	if not str then return end

	if str:find('^startCraft|') then
		local amount = str:match('"amount":%s*(%d+)')
		stats.maxCraft = tonumber(amount) or 0
		stats.timeStart = os.clock()
		stats.active = true
		sampAddChatMessage(tag .. cyr('Вы начали крафт! Число крафтов: ') .. colored(stats.maxCraft) .. '.', -1)
	elseif str:find('^stopCraft') then
		if stats.active then
			showFinalStats(cyr('остановлен'))
			resetStats()
		end
	end
end

-- Other scripts read packet 220 too: rewind before and after parsing, and keep a parse error from killing the script.
function onReceivePacket(id, bs)
	if id ~= 220 or not bs then return end
	raknetBitStreamResetReadPointer(bs)
	local ok, err = pcall(readIncoming, bs)
	raknetBitStreamResetReadPointer(bs)
	if not ok then print('onReceivePacket: ' .. tostring(err)) end
end

function onSendPacket(id, bs)
	if id ~= 220 or not bs then return end
	raknetBitStreamResetReadPointer(bs)
	local ok, err = pcall(readOutgoing, bs)
	raknetBitStreamResetReadPointer(bs)
	if not ok then print('onSendPacket: ' .. tostring(err)) end
end

function hook.onServerMessage(color, text)
	if stats.active and not stats.itemName then
		local itemName = parseItemName(text)
		if itemName then
			stats.itemName = itemName
		end
	end
end

-- ============================================================================
-- SELF-UPDATE (/ccupdate)
-- ============================================================================

local UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/manifest.json'
local UPDATE_BASE_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/'
local UPDATE_SCRIPT_ID = 'craft-counter'
local UPDATE_MANIFEST_TIMEOUT = 10 -- seconds.
local UPDATE_FILE_TIMEOUT = 30 -- seconds, file is bigger than the manifest.

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
	return (entry and entry.topic and entry.topic ~= '') and entry.topic or FORUM_URL
end

-- Most failures pass on their own: GitHub caches files for about 5 minutes.
local UPDATE_RETRY = ', повторите через пару минут или скачайте вручную: {5CC9FF}'
local UPDATE_FAIL_TEXT = {
	timeout = 'Сервер не ответил' .. UPDATE_RETRY,
	empty = 'Файл не скачался' .. UPDATE_RETRY,
	broken = 'Пришёл битый файл' .. UPDATE_RETRY,
	missing = 'Скрипта нет в списке версий, скачайте вручную: {5CC9FF}',
	replace = 'Файл не заменился, старая версия на месте. Скачайте вручную: {5CC9FF}',
}

local function updateFailed(kind, entry)
	notify(UPDATE_FAIL_TEXT[kind] .. manualUrl(entry))
end

-- Set when the new file is in place; main() reloads on its next tick, so no thread of ours is left mid-call.
local reloadPending = false

local function finishUpdate(entry, tempPath)
	local content = readFile(tempPath)
	local gotVersion = content and content:match("script_version%(['\"]([%d%.]+)['\"]%)")

	if not gotVersion then
		removeIfExists(tempPath)
		updateFailed('broken', entry)
		return
	end
	if gotVersion == thisScript().version then
		-- The CDN still serves the previous file right after a release.
		removeIfExists(tempPath)
		notify('Сервер ещё отдаёт старую версию, повторите через пару минут.')
		return
	end
	if gotVersion ~= entry.version then
		removeIfExists(tempPath)
		-- The file and the manifest are cached separately, so this is the CDN too.
		notify('Сервер отдал v' .. gotVersion .. ' вместо v' .. entry.version .. ', повторите через пару минут.')
		return
	end

	local ok, err = atomicReplace(thisScript().path, tempPath)
	if not ok then
		removeIfExists(tempPath)
		updateFailed('replace', entry)
		return
	end

	-- ML-AutoReboot reloads a changed file by itself; a reload of ours on top kills the fresh copy mid-start.
	if script.find('ML-AutoReboot') then
		notify('Обновлено до {5CC9FF}v' .. entry.version .. '{FFFFFF}, скрипт перезагрузится сам.')
		return
	end
	notify('Обновлено до {5CC9FF}v' .. entry.version .. '{FFFFFF}, перезагружаю скрипт...')
	reloadPending = true
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
			updateFailed('timeout', entry)
		end)
		-- Only the final status: at STATUS_ENDDOWNLOADDATA the file may not be in place yet.
		downloadUrlToFile(UPDATE_BASE_URL .. entry.path, tempPath, function(_, status)
			if status ~= dl_status.STATUSEX_ENDDOWNLOAD or not claim() then return end
			local content = readFile(tempPath)
			if not content or content == '' then
				removeIfExists(tempPath)
				updateFailed('empty', entry)
				return
			end
			finishUpdate(entry, tempPath)
		end)
	end)
end

-- Exactly one of onEntry(entry) / onError(kind) fires, kind being a key of UPDATE_FAIL_TEXT.
local function fetchManifestEntry(onEntry, onError)
	local manifestPath = thisScript().path .. '.manifest.tmp'
	removeIfExists(manifestPath)
	local dl_status = moonloader.download_status
	local claim = withTimeout(UPDATE_MANIFEST_TIMEOUT, function()
		removeIfExists(manifestPath)
		onError('timeout')
	end)

	-- Only the final status: at STATUS_ENDDOWNLOADDATA the file may not be in place yet, and decodeJson('') is logged as an exception even under pcall.
	downloadUrlToFile(UPDATE_MANIFEST_URL, manifestPath, function(_, status)
		if status ~= dl_status.STATUSEX_ENDDOWNLOAD or not claim() then return end
		local content = readFile(manifestPath)
		removeIfExists(manifestPath)
		if not content or content == '' then
			onError('empty')
			return
		end
		local ok, data = pcall(decodeJson, content)
		if not ok or type(data) ~= 'table' or not data.scripts then
			onError('broken')
			return
		end

		local entry
		for _, item in ipairs(data.scripts) do
			if item.id == UPDATE_SCRIPT_ID then entry = item break end
		end
		if not entry then
			onError('missing')
			return
		end
		onEntry(entry)
	end)
end

-- Strictly "remote > local": a newer local build is never rolled back.
local function isNewer(entry)
	local remote, current = versionNum(entry.version), versionNum(thisScript().version)
	return remote and current and remote > current
end

local function checkForUpdate()
	notify('Проверяю обновления...')
	fetchManifestEntry(
		function(entry)
			if not isNewer(entry) then
				notify('У вас последняя версия (v' .. thisScript().version .. ').')
				return
			end
			notify('Найдено обновление: v' .. entry.version .. '. Скачиваю...')
			downloadUpdate(entry)
		end,
		function(kind)
			updateFailed(kind)
		end
	)
end

-- Once at load: silent unless an update exists, never downloads by itself.
local function checkForUpdateSilently()
	fetchManifestEntry(
		function(entry)
			if isNewer(entry) then
				notify('Доступна новая версия {5CC9FF}v' .. entry.version .. '{FFFFFF}! Обновить: {5CC9FF}/ccupdate')
			end
		end,
		function() end
	)
end

function main()
	repeat wait(0) until isSampAvailable()
	-- Leftovers of an interrupted update; .old stays as the way back.
	removeIfExists(thisScript().path .. '.tmp')
	removeIfExists(thisScript().path .. '.manifest.tmp')
	wait(1500)

	sampAddChatMessage(tag .. cyr('Загружен {5CC9FF}v' .. thisScript().version .. '{FFFFFF}. История крафтов: {5CC9FF}/cchistory'), -1)
	sampRegisterChatCommand('cchistory', cmdCraftHistory)
	sampRegisterChatCommand('ccupdate', checkForUpdate)
	checkForUpdateSilently()

	while true do wait(0)
		if reloadPending then
			reloadPending = false
			thisScript():reload()
			return
		end
		if stats.active then
			stats.totalTime = os.clock() - stats.timeStart
			if stats.currentCraft > 0 then
				local timeSinceLastCraft = stats.totalTime - (stats.speedPerItem * stats.currentCraft)
				local remainingCrafts = stats.maxCraft - stats.currentCraft
				stats.timeLeft = math.max(0, (remainingCrafts * stats.speedPerItem) - timeSinceLastCraft)
			end

			local progress
			if stats.currentCraft > 0 then
				progress = cyr('Прогресс: ') .. overlayValue(stats.currentCraft) .. ' / ' .. overlayValue(stats.maxCraft)
					.. ' (' .. formatTimeShort(stats.timeLeft) .. ')'
			else
				progress = cyr('Прогресс: ') .. overlayValue(stats.currentCraft) .. ' / ' .. overlayValue(stats.maxCraft)
			end

			local successPct = stats.currentCraft > 0 and (stats.success / stats.currentCraft * 100) or 0
			local results = cyr('Результат: ') .. overlayValue(stats.success) .. ' / ' .. overlayValue(stats.fail) .. string.format(' (%.1f%%)', successPct)

			local spent = cyr('Потрачено: ') .. overlayValue(formatMoney(stats.totalSpent))

			local speed
			if stats.currentCraft > 0 then
				speed = cyr('Скорость: ') .. overlayValue(formatTime(stats.speedPerItem)) .. cyr(' / шт.')
			else
				speed = cyr('Скорость: ') .. overlayValue('...')
			end

			local text = table.concat({progress, results, spent, speed}, '\n')

			renderFontDrawText(renderFont, text, 50, screenH * 0.45, 0xFFFFFFFF)
		end
	end
end
