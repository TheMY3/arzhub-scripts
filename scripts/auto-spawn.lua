script_name('Auto Spawn')
script_author('ArzHub')
script_version('1.1.0')
script_url('https://arzhub.top/hub/auto-spawn')

-- Forum topic (current version, discussion): https://www.blast.hk/threads/258154/

local moonloader = require('moonloader')  -- download_status for the update check.
local encoding = require('encoding')
local inicfg = require('inicfg')
encoding.default = 'UTF-8'
local cyr = encoding.CP1251

local tag = '{FFA31A}[ArzHub] Auto Spawn{FFFFFF}: '

-- ============================================================================
-- CONFIG
-- ============================================================================

local configPath = 'ArzHub/auto-spawn/config.ini'

-- One-time move from the old place, before the first read; a failed move keeps the old file and is retried next load.
do
    local base = getWorkingDirectory() .. '\\config\\'
    local old, new = base .. 'TheMY3\\auto_spawn.ini', base .. 'ArzHub\\auto-spawn\\config.ini'
    if not doesFileExist(new) and doesFileExist(old) then
        createDirectory(base .. 'ArzHub')
        createDirectory(base .. 'ArzHub\\auto-spawn')
        if not os.rename(old, new) then
            print('config move failed, still using ' .. old)
            configPath = 'TheMY3/auto_spawn.ini'
        end
    end
end

local config = inicfg.load({
    settings = {
        target = '',  -- Starred point title (UTF-8), '' = off.
        delay = 5     -- Countdown in seconds, 0 = at once.
    }
}, configPath)

local function saveConfig()
    -- One level at a time: config\ArzHub may not exist yet either.
    local dir = getWorkingDirectory() .. '\\config'
    for part in configPath:match('(.+)/'):gmatch('[^/]+') do
        dir = dir .. '\\' .. part
        if not doesDirectoryExist(dir) then createDirectory(dir) end
    end
    inicfg.save(config, configPath)
end

local INJECT_DELAY = 200   -- ms, lets the page render the list first.
local MSG_PREFIX = 'tmAutoSpawn|'

-- ============================================================================
-- STATE
-- ============================================================================

local points = {}         -- {id, name} in list order, names in CP1251.
local targetIndex = nil   -- Target position in points.
local countdown = nil     -- Running countdown token.
local deadline = 0        -- os.clock() of the countdown end.
local ownSend = false

local function notify(text)
    sampAddChatMessage(tag .. cyr(text), -1)
end

local function evalcef(code)
    if #code > 32767 then return false end  -- Length is an Int16.
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)        -- sub-type 17 = eval JS
    raknetBitStreamWriteInt32(bs, 0)        -- browser id (0 = main)
    raknetBitStreamWriteInt16(bs, #code)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteString(bs, code)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
    return true
end

local function sendCef(str)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #str)
    raknetBitStreamWriteString(bs, str)
    raknetBitStreamWriteInt32(bs, 0)
    ownSend = true
    raknetSendBitStream(bs)
    ownSend = false
    raknetDeleteBitStream(bs)
end

-- ============================================================================
-- PAGE INJECT
-- ============================================================================

-- Star markup is the vehicle menu favorite, its CSS is global. The page only draws the countdown.
local SPAWN_JS = ([[
(() => {
    const VERSION = '__VERSION__';
    const STAR_CLASS = 'tm-as-star';
    const ACTIVE_CLASS = 'vehicle-menu-vehicle-item__favorite--active';
    const COUNT_TEXT = '\u0421\u043f\u0430\u0432\u043d \u0447\u0435\u0440\u0435\u0437 '; // Спавн через
    const SEC_TEXT = ' \u0441\u0435\u043a..'; // сек..

    const prev = window.__tmAutoSpawn;
    if (prev) {
        if (prev.version === VERSION) return;
        try { prev.teardown(); } catch (e) {}
        window.__tmAutoSpawn = null;
    }

    let star = -1;          // Starred point index, -1 = none.
    let deadline = 0;       // Date.now() of the spawn, 0 = no countdown.
    let nativeText = null;  // Button caption to restore.
    let fullDelay = 0;      // Countdown for a freshly set star, ms.
    let activeAtStart = -1; // Highlighted point at the countdown start.

    const send = (msg) => {
        try { window.cef.SendMessage('__PREFIX__' + msg, 0); } catch (e) {}
    };
    const items = () => Array.from(document.querySelectorAll('.spawn-list__item'));
    const buttonText = () => document.querySelector('.spawn-list__spawn-button .auth-red-button__text');

    const paintStars = () => {
        if (!document.querySelector('.spawn-list')) return;
        items().forEach((item, i) => {
            const point = item.querySelector('.spawn-point');
            if (!point) return;
            let box = point.querySelector('.' + STAR_CLASS);
            if (!box) {
                const pin = point.querySelector('.spawn-point__item-geo-icon');
                if (pin) pin.style.display = 'none';
                box = document.createElement('div');
                box.className = 'vehicle-menu-vehicle-item__favorite ' + STAR_CLASS;
                box.innerHTML = '<i class="vehicle-menu-vehicle-item__favorite-icon icon-favorite-star"></i>';
                point.insertBefore(box, point.firstChild);
            }
            if (box.dataset.index !== String(i)) box.dataset.index = String(i);
            box.classList.toggle(ACTIVE_CLASS, i === star);
        });
    };

    const paintButton = () => {
        const t = buttonText();
        if (!t) return;
        if (deadline) {
            if (nativeText === null) nativeText = t.textContent;
            const left = Math.max(0, Math.ceil((deadline - Date.now()) / 1000));
            const label = COUNT_TEXT + left + SEC_TEXT;
            if (t.textContent !== label) t.textContent = label;
        } else if (nativeText !== null) {
            t.textContent = nativeText;
            nativeText = null;
        }
    };

    const activeIndex = () => items().findIndex((item) => item.querySelector('.spawn-point--active'));

    let iv = null;
    const stopCountdown = () => {
        deadline = 0;
        clearInterval(iv);
        iv = null;
        paintButton();
    };

    // Arrow keys move the highlight without a click, so that counts as a manual pick too.
    const tick = () => {
        if (Date.now() - deadline > 3000) { stopCountdown(); return; }
        if (activeIndex() !== activeAtStart) { stopCountdown(); send('cancel'); return; }
        paintButton();
    };

    const startCountdown = (ms) => {
        deadline = Date.now() + ms;
        activeAtStart = activeIndex();
        if (!iv) iv = setInterval(tick, 250);
        paintButton();
    };

    // A star click must not select the point under it.
    const starOf = (e) => e.target.closest && e.target.closest('.' + STAR_CLASS);
    const kill = (e) => { e.preventDefault(); e.stopImmediatePropagation(); };
    const swallow = (e) => { if (starOf(e)) kill(e); };

    const onClick = (e) => {
        const box = starOf(e);
        if (box) {
            kill(e);
            const i = Number(box.dataset.index);
            star = (star === i) ? -1 : i;
            if (star === -1) stopCountdown();
            else if (!deadline && fullDelay > 0) startCountdown(fullDelay);
            paintStars();
            send('star|' + star);
            return;
        }
        // A manual pick stops the countdown, the star stays.
        if (deadline && e.target.closest && e.target.closest('.spawn-list__item')) {
            stopCountdown();
            send('cancel');
        }
    };

    const DOWN_EVENTS = ['pointerdown', 'pointerup', 'mousedown', 'mouseup'];
    document.addEventListener('click', onClick, true);
    DOWN_EVENTS.forEach((type) => document.addEventListener(type, swallow, true));

    let paintPending = false;
    const schedulePaint = () => {
        if (paintPending) return;
        paintPending = true;
        setTimeout(() => { paintPending = false; paintStars(); paintButton(); }, 50);
    };
    const obs = new MutationObserver(schedulePaint);
    obs.observe(document.body, { childList: true, subtree: true });

    const teardown = () => {
        obs.disconnect();
        document.removeEventListener('click', onClick, true);
        DOWN_EVENTS.forEach((type) => document.removeEventListener(type, swallow, true));
        stopCountdown();
        document.querySelectorAll('.' + STAR_CLASS).forEach((box) => {
            const pin = box.parentNode && box.parentNode.querySelector('.spawn-point__item-geo-icon');
            if (pin) pin.style.display = '';
            box.remove();
        });
    };

    const show = (starIndex, delayMs, fullMs) => {
        star = starIndex;
        fullDelay = fullMs;
        if (starIndex >= 0 && delayMs > 0) startCountdown(delayMs); else stopCountdown();
        paintStars();
    };

    window.__tmAutoSpawn = { version: VERSION, show, teardown };
})();
]]):gsub('__VERSION__', thisScript().version):gsub('__PREFIX__', MSG_PREFIX)

local function delaySeconds()
    return math.max(0, tonumber(config.settings.delay) or 0)
end

-- The bootstrap returns early when this version is already on the page.
local function showOnPage(index, delayMs)
    return evalcef(SPAWN_JS .. ('window.__tmAutoSpawn.show(%d, %d, %d);')
        :format(index, delayMs, math.floor(delaySeconds() * 1000)))
end

-- ============================================================================
-- SPAWN
-- ============================================================================

local function cancelCountdown()
    countdown = nil
end

local function spawnTarget()
    local point = targetIndex and points[targetIndex]
    if not point then return end
    sendCef('authSpawn|' .. point.id)
    sampAddChatMessage(tag .. cyr('Спавн: ') .. point.name, -1)
end

local function startCountdown(delay)
    local token = {}
    countdown = token
    deadline = os.clock() + delay
    lua_thread.create(function()
        wait(math.floor(delay * 1000))
        if countdown ~= token then return end
        countdown = nil
        spawnTarget()
    end)
end

local function onSpawnPoints(str)
    points = {}
    for id, name in str:gmatch('"id"%s*:%s*(%d+)%s*,%s*"spawn"%s*:%s*"([^"]*)"') do
        points[#points + 1] = {id = id, name = name}
    end
    if #points == 0 then return end

    -- A repeated list during a countdown only redraws the page.
    if not countdown then
        targetIndex = nil
        local target = config.settings.target
        if target ~= '' then
            local want = cyr(target)
            for i, point in ipairs(points) do
                if point.name == want then targetIndex = i break end
            end
            if not targetIndex then
                notify('Места "' .. target .. '" нет в списке, выберите вручную')
            end
        end
        if targetIndex then startCountdown(delaySeconds()) end
    end

    local index = targetIndex and (targetIndex - 1) or -1
    local leftMs = countdown and math.floor((deadline - os.clock()) * 1000) - INJECT_DELAY or 0
    lua_thread.create(function()
        wait(INJECT_DELAY)
        showOnPage(index, math.max(0, leftMs))
    end)
end

-- The index is the point position in the list.
local function onStar(index)
    if index < 0 then
        config.settings.target = ''
        targetIndex = nil
        cancelCountdown()
        saveConfig()
        notify('Автоспавн выключен')
        return
    end
    local point = points[index + 1]
    if not point then return end
    config.settings.target = cyr:decode(point.name)
    saveConfig()
    -- With delay 0 a star click never spawns at once.
    local delay = delaySeconds()
    if countdown or delay > 0 then targetIndex = index + 1 end
    if not countdown and delay > 0 then startCountdown(delay) end
    sampAddChatMessage(tag .. cyr('Автоспавн: ') .. point.name, -1)
end

-- Returns false to keep page messages off the server.
local function handleOutgoing(str)
    if str:sub(1, #MSG_PREFIX) == MSG_PREFIX then
        local body = str:sub(#MSG_PREFIX + 1)
        local star = body:match('^star|(%-?%d+)$')
        if star then
            onStar(tonumber(star))
        elseif body == 'cancel' then
            cancelCountdown()
        end
        return false
    end
    if str:sub(1, 10) == 'authSpawn|' then cancelCountdown() end
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
    if str and str:find("'event.auth.initializeSpawnPoints'", 1, true) then onSpawnPoints(str) end
end

local function readOutgoing(bs)
    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) ~= 18 then return end
    local length = raknetBitStreamReadInt16(bs)
    return handleOutgoing(raknetBitStreamReadString(bs, length))
end

function onReceivePacket(id, bs)
    if id ~= 220 then return end
    raknetBitStreamResetReadPointer(bs)
    local ok, err = pcall(readIncoming, bs)
    raknetBitStreamResetReadPointer(bs)
    if not ok then print('onReceivePacket: ' .. tostring(err)) end
end

function onSendPacket(id, bs)
    if id ~= 220 or ownSend then return end
    raknetBitStreamResetReadPointer(bs)
    local ok, result = pcall(readOutgoing, bs)
    raknetBitStreamResetReadPointer(bs)
    if not ok then print('onSendPacket: ' .. tostring(result)) return end
    if result == false then return false end
end

-- ============================================================================
-- UPDATES (/asupdate): only through the ArzHub manager, the script just says where to get them
-- ============================================================================

local UPDATE_MANIFEST_URL = 'https://arzhub.top/hub/manifest.json'
local UPDATE_SCRIPT_ID = 'auto-spawn'
local UPDATE_MANIFEST_TIMEOUT = 10 -- seconds.
local MANAGER_URL = 'https://arzhub.top/hub'
local VIA_MANAGER = 'Обновления - через менеджер ArzHub: {FFB48A}' .. MANAGER_URL

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

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

-- Asked right before a line goes out, not at load: by then every script is loaded.
local function managerRunning()
    return script.find('ArzHub') ~= nil
end

-- Exactly one of onEntry(entry) / onError() fires.
local function fetchManifestEntry(onEntry, onError)
    local manifestPath = thisScript().path .. '.manifest.tmp'
    removeIfExists(manifestPath)
    local dl_status = moonloader.download_status
    local claim = withTimeout(UPDATE_MANIFEST_TIMEOUT, function()
        removeIfExists(manifestPath)
        onError()
    end)

    -- Only the final status: at STATUS_ENDDOWNLOADDATA the file may not be in place yet, and decodeJson('') is logged as an exception even under pcall.
    downloadUrlToFile(UPDATE_MANIFEST_URL, manifestPath, function(_, status)
        if status ~= dl_status.STATUSEX_ENDDOWNLOAD or not claim() then return end
        local content = readFile(manifestPath)
        removeIfExists(manifestPath)
        if not content or content == '' then
            onError()
            return
        end
        local ok, data = pcall(decodeJson, content)
        if not ok or type(data) ~= 'table' or not data.scripts then
            onError()
            return
        end
        for _, item in ipairs(data.scripts) do
            if item.id == UPDATE_SCRIPT_ID then
                onEntry(item)
                return
            end
        end
        onError()
    end)
end

-- Strictly "remote > local": a newer local build is never offered an older one.
local function isNewer(entry)
    local remote, current = versionNum(entry.version), versionNum(thisScript().version)
    return remote and current and remote > current
end

local function newVersionText(entry)
    return 'Вышла {FFB48A}v' .. entry.version .. '{FFFFFF}. Обновить можно через менеджер ArzHub: {FFB48A}' .. MANAGER_URL
end

local function checkForUpdate()
    if managerRunning() then
        notify('Обновления - через менеджер: {FFB48A}/hub')
        return
    end
    fetchManifestEntry(
        function(entry)
            if isNewer(entry) then
                notify(newVersionText(entry))
            else
                notify('У вас последняя версия {FFB48A}v' .. thisScript().version .. '{FFFFFF}. ' .. VIA_MANAGER)
            end
        end,
        function()
            notify('Не удалось проверить обновления. ' .. VIA_MANAGER)
        end
    )
end

-- Once at load, and only without the manager: silent unless a new version is out.
local function checkForUpdateSilently()
    if managerRunning() then return end
    fetchManifestEntry(
        function(entry)
            if isNewer(entry) and not managerRunning() then notify(newVersionText(entry)) end
        end,
        function() end
    )
end

-- ============================================================================
-- MAIN
-- ============================================================================

function main()
    while not isSampAvailable() do wait(0) end
    -- Leftovers of an interrupted update; .old stays as the way back.
    removeIfExists(thisScript().path .. '.tmp')
    removeIfExists(thisScript().path .. '.manifest.tmp')
    saveConfig()
    local target = config.settings.target
    notify('Загружен {FFB48A}v' .. thisScript().version .. '{FFFFFF}. '
        .. (target ~= '' and 'Выбранное место спавна: ' .. target or 'Место спавна не выбрано'))
    sampRegisterChatCommand('asupdate', checkForUpdate)
    checkForUpdateSilently()
    -- Hooks do the rest; main() only has to stay alive.
    wait(-1)
end
