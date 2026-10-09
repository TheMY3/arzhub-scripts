script_name('Auto Spawn')
script_author('TheMY3')
script_version('1.0.2')

local moonloader = require('moonloader')  -- download_status for self-update.
local encoding = require('encoding')
local inicfg = require('inicfg')
encoding.default = 'UTF-8'
local cyr = encoding.CP1251

local tag = '{FFA500}[TM] Auto Spawn{FFFFFF}: '

-- ============================================================================
-- CONFIG
-- ============================================================================

local configPath = 'TheMY3/auto_spawn.ini'
local config = inicfg.load({
    settings = {
        target = '',  -- Starred point title (UTF-8), '' = off.
        delay = 5     -- Countdown in seconds, 0 = at once.
    }
}, configPath)

local function saveConfig()
    local dir = getWorkingDirectory() .. '\\config\\' .. configPath:match('(.+)/')
    if not doesDirectoryExist(dir) then
        createDirectory(dir)
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
-- SELF-UPDATE
-- ============================================================================

local UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/manifest.json'
local UPDATE_BASE_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/'
local UPDATE_SCRIPT_ID = 'auto-spawn'
local UPDATE_MANIFEST_TIMEOUT = 10 -- seconds.
local UPDATE_FILE_TIMEOUT = 30 -- seconds, file is bigger than the manifest.
local FALLBACK_URL = 'https://github.com/TheMY3/arzhub-scripts/releases'  -- Used when the manifest has no topic.

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
    return (entry and entry.topic and entry.topic ~= '') and entry.topic or FALLBACK_URL
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
        if not ok or not data or not data.scripts then
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
                notify('Доступна новая версия {5CC9FF}v' .. entry.version .. '{FFFFFF}! Обновить: {5CC9FF}/asupdate')
            end
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
    notify('Загружен {5CC9FF}v' .. thisScript().version .. '{FFFFFF}. '
        .. (target ~= '' and 'Выбранное место спавна: ' .. target or 'Место спавна не выбрано'))
    sampRegisterChatCommand('asupdate', checkForUpdate)
    checkForUpdateSilently()
    -- Only a pending reload needs servicing after start-up.
    while true do
        wait(100)
        if reloadPending then
            reloadPending = false
            thisScript():reload()
            return
        end
    end
end
