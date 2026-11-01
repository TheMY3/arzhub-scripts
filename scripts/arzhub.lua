script_name('ArzHub')
script_author('TheMY3')
script_version('0.1.11')

-- In-game manager for the ArzHub scripts: what is installed, what is out, install, update and remove in one click.
-- Everything asynchronous is a step of main(): no lua_thread anywhere, hooks and download callbacks only queue or flag.

local moonloader = require('moonloader')
local encoding = require('encoding')
encoding.default = 'UTF-8'
local cyr = encoding.CP1251
local bit = require('bit')
local ffi = require('ffi')
pcall(ffi.cdef, [[
    void* GetActiveWindow(void);
    int IsIconic(void* hWnd);
]])

-- The site's orange: the tag in its light end, highlights (versions, commands) in the peach of the window's command chips.
local TAG = '{FFA31A}[ArzHub]{FFFFFF}: '
local UPDATE_SCRIPT_ID = 'arzhub'
local BASE_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/'
local MANIFEST_URL = BASE_URL .. 'manifest.json'
local RELEASES_URL = 'https://github.com/TheMY3/arzhub-scripts/releases'

local SOCKET_LIB_URL = 'https://github.com/TheMY3/arzhub-scripts/raw/main/lib/luasocket.zip'
local PORT_FIRST, PORT_LAST = 38260, 38270 -- Local HTTP channel from the page, first free port wins.
local CLIENT_TIMEOUT = 2 -- Seconds a page connection may take to send its request line.

local DL_TIMEOUT = 15 -- Seconds per download.
local DL_GAP = 0.25   -- Seconds between downloads: a second downloadUrlToFile right after another fails with "device or resource busy".
local LOG_LIMIT = 512 * 1024

local ML_DIR = getWorkingDirectory()
local DATA_DIR = ML_DIR .. '\\config\\ArzHub'
local DL_DIR = DATA_DIR .. '\\dl'
local CACHE_PATH = DATA_DIR .. '\\cache.json'
local LOG_PATH = DATA_DIR .. '\\arzhub.log'
local SELF_UPDATED_PATH = DATA_DIR .. '\\updated.txt'  -- Version the manager just updated itself to.

local LOAD_FIRST = 'Загружен {FFB48A}v%s{FFFFFF}'
local LOAD_UPDATED = 'Обновлён до {FFB48A}v%s{FFFFFF}'
local LOAD_SCRIPTS = '. %s: {FFB48A}/hub'
local LOAD_MANAGER = ', вышла {FFB48A}v%s{FFFFFF}. Обновить: {FFB48A}/hub'
local LOAD_OPEN = '. Открыть: {FFB48A}/hub'
local SELF_UPDATED_TEXT = 'Менеджер обновлён до %s.'
local SOCKET_FAIL_TEXT = 'Не удалось скачать библиотеку LuaSocket для окна. Скачайте архив и распакуйте его в папку moonloader: {FFB48A}' .. SOCKET_LIB_URL
-- Support hears about a breakage; /hub update then delivers the fix to a player whose window cannot open.
local BOOT_FAIL_TEXT = 'Окно не открылось. Попробуйте ещё раз или обновите менеджер: {FFB48A}/hub update{FFFFFF}. Не помогает - напишите: {FFB48A}https://arzhub.top/support'
local UPDATE_START_TEXT = 'Скачиваю {FFB48A}v%s{FFFFFF}...'
local UPDATE_NONE_TEXT = 'У менеджера последняя версия {FFB48A}v%s{FFFFFF}.'
local UPDATE_OFFLINE_TEXT = 'Не удалось проверить обновления, повторите через пару минут.'
local UPDATE_BUSY_TEXT = 'Менеджер уже обновляется.'
local HELP_TEXT = 'Команды: {FFB48A}/hub{FFFFFF} - окно, {FFB48A}/hub update{FFFFFF} - обновить менеджер.'
local PORTS_BUSY_TEXT = 'Окну нужен свободный порт ' .. PORT_FIRST .. '-' .. PORT_LAST .. ', а все заняты другими программами.'

-- ============================================================================
-- HELPERS
-- ============================================================================

local function logLine(s)
    local f = io.open(LOG_PATH, 'a')
    if not f then return end
    f:write(os.date('%Y-%m-%d %H:%M:%S '), (s:gsub('{%x%x%x%x%x%x}', '')), '\n')
    f:close()
end

-- Manifest text can carry characters CP1251 does not have.
local function toChat(s)
    local ok, out = pcall(cyr, s)
    if ok and type(out) == 'string' then return out end
    return (s:gsub('[\128-\255]+', '?'))
end

local function chat(msg)
    sampAddChatMessage(TAG .. toChat(msg), -1)
    logLine(msg)
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

local function writeFile(path, s)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

-- No doesFileExist guard: removing a missing file is harmless, and the guard let leftovers survive on the live client.
local function removeIfExists(path)
    os.remove(path)
end

local function fileSize(path)
    local f = io.open(path, 'rb')
    if not f then return 0 end
    local size = f:seek('end') or 0
    f:close()
    return size
end

local function readVersion(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local head = f:read(4096) or ''
    f:close()
    return head:match("script_version%(['\"]([%d%.]+)['\"]%)")
end

local function versionNum(v)
    local a, b, c = tostring(v or ''):match('^(%d+)%.(%d+)%.(%d+)$')
    if not a then return nil end
    return tonumber(a) * 1000000 + tonumber(b) * 1000 + tonumber(c)
end

local function urlDecode(s)
    return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
end

local SHA_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- Hex SHA-256 of a byte string, for the LuaSocket files fetched from the manifest.
local function sha256(msg)
    local band, bxor, bnot, rshift, ror, tobit = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.ror, bit.tobit
    local len = #msg
    local bits = len * 8
    local tail = { '\128', string.rep('\0', (55 - len) % 64) }
    local hi, lo = math.floor(bits / 4294967296), bits % 4294967296
    for _, v in ipairs({ hi, lo }) do
        tail[#tail + 1] = string.char(math.floor(v / 16777216) % 256, math.floor(v / 65536) % 256, math.floor(v / 256) % 256, v % 256)
    end
    msg = msg .. table.concat(tail)
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for i = 1, #H do H[i] = tobit(H[i]) end
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
            w[i] = tobit(a * 16777216 + b * 65536 + c * 256 + d)
        end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = bxor(ror(x, 7), ror(x, 18), rshift(x, 3))
            local s1 = bxor(ror(y, 17), ror(y, 19), rshift(y, 10))
            w[i] = tobit(w[i - 16] + s0 + w[i - 7] + s1)
        end
        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
        for i = 0, 63 do
            local t1 = tobit(h + bxor(ror(e, 6), ror(e, 11), ror(e, 25)) + bxor(band(e, f), band(bnot(e), g)) + SHA_K[i + 1] + w[i])
            local t2 = tobit(bxor(ror(a, 2), ror(a, 13), ror(a, 22)) + bxor(band(a, b), band(a, c), band(b, c)))
            h, g, f, e, d, c, b, a = g, f, e, tobit(d + t1), c, b, a, tobit(t1 + t2)
        end
        H[1], H[2], H[3], H[4] = tobit(H[1] + a), tobit(H[2] + b), tobit(H[3] + c), tobit(H[4] + d)
        H[5], H[6], H[7], H[8] = tobit(H[5] + e), tobit(H[6] + f), tobit(H[7] + g), tobit(H[8] + h)
    end
    local out = {}
    for i = 1, 8 do out[i] = bit.tohex(H[i], 8) end
    return table.concat(out)
end

-- ============================================================================
-- DOWNLOADS (one at a time, finished by main())
-- ============================================================================

local dlQueue = {}
local dlActive = nil
local dlFreeAt = 0
local dlFrozen = false     -- Own file replaced: a reload is coming, a download started now would call back into an unloaded script.

-- onDone(err) runs from main(): err is nil, 'timeout' or 'empty'; on success the file stays at dest.
local function queueDownload(url, dest, onDone)
    dlQueue[#dlQueue + 1] = { url = url, dest = dest, onDone = onDone }
end

local function stepDownloads()
    local j = dlActive
    if j then
        if not j.done and os.clock() - j.t0 < DL_TIMEOUT then return end
        dlActive = nil
        dlFreeAt = os.clock() + DL_GAP
        if not j.done then
            removeIfExists(j.dest)
            j.onDone('timeout')
        elseif fileSize(j.dest) == 0 then
            removeIfExists(j.dest)
            j.onDone('empty')
        else
            j.onDone(nil)
        end
        return
    end
    if dlFrozen or #dlQueue == 0 or os.clock() < dlFreeAt then return end
    j = table.remove(dlQueue, 1)
    removeIfExists(j.dest)
    j.t0 = os.clock()
    dlActive = j
    local sep = j.url:find('?', 1, true) and '&' or '?'
    -- The file lands at dest only by STATUSEX_ENDDOWNLOAD; the callback just records what happened.
    downloadUrlToFile(j.url .. sep .. 't=' .. os.time(), j.dest, function(_, status)
        if status == moonloader.download_status.STATUSEX_ENDDOWNLOAD then j.done = true end
    end)
end

-- ============================================================================
-- CATALOG
-- ============================================================================

local catalog = nil

local function strings(t)
    local out = {}
    if type(t) ~= 'table' then return out end
    for _, v in ipairs(t) do
        if type(v) == 'string' then out[#out + 1] = v end
    end
    return out
end

-- Other names the same script may lie under: alt_filenames from the manifest (old names, other spellings)
-- and the name a GitHub release gives it, taken from path.
local function altNames(entry)
    local out = strings(entry.alt_filenames)
    local release = type(entry.path) == 'string' and entry.path:match('([^/]+)$')
    if release then out[#out + 1] = release end
    return out
end

-- path: the installed file (by filename, else the first alternative name found); alt: a second copy lying next to it.
local function scanEntry(entry)
    local res = {}
    local main = type(entry.filename) == 'string' and (ML_DIR .. '\\' .. entry.filename) or nil
    if main and doesFileExist(main) then res.path = main end
    for _, name in ipairs(altNames(entry)) do
        local p = ML_DIR .. '\\' .. name
        -- Windows names ignore case: arzhub.lua from a release is ArzHub.lua itself.
        if doesFileExist(p) and not (main and p:lower() == main:lower()) then
            if not res.path then
                res.path = p
            elseif res.path == main and not res.alt then
                res.alt = p
            end
        end
    end
    if res.path then res.localVersion = readVersion(res.path) end
    return res
end

-- An unreadable local version counts as outdated: the file is ours by name, only the manifest version is known.
local function hasUpdate(entry, scan)
    local remote = versionNum(entry.version)
    if not scan.path or not remote then return false end
    local current = versionNum(scan.localVersion)
    return not current or remote > current
end

local function setCatalog(manifest, fetchedAt, offline)
    local c = { list = {}, ui = manifest.ui, deps = manifest.deps, fetchedAt = fetchedAt, offline = offline }
    for _, e in ipairs(manifest.scripts) do
        if type(e) == 'table' and type(e.id) == 'string' then
            if e.id == UPDATE_SCRIPT_ID then c.manager = e else c.list[#c.list + 1] = e end
        end
    end
    catalog = c
end

local function loadCache()
    local body = readFile(CACHE_PATH)
    if not body then return false end
    local ok, data = pcall(decodeJson, body)
    if not ok or type(data) ~= 'table' or type(data.manifest) ~= 'table' or type(data.manifest.scripts) ~= 'table' then return false end
    setCatalog(data.manifest, tonumber(data.fetchedAt) or 0, true)
    return true
end

-- onDone(err): nil on success, else the download error or 'broken'. A broken answer leaves the cache alone.
local function fetchManifest(onDone)
    local tmp = DL_DIR .. '\\manifest.json.tmp'
    queueDownload(MANIFEST_URL, tmp, function(err)
        if err then onDone(err) return end
        local body = readFile(tmp)
        removeIfExists(tmp)
        local ok, data = pcall(decodeJson, body or '')
        if not ok or type(data) ~= 'table' or type(data.scripts) ~= 'table' then onDone('broken') return end
        local now = os.time()
        writeFile(CACHE_PATH, encodeJson({ fetchedAt = now, manifest = data }))
        setCatalog(data, now, false)
        onDone(nil)
    end)
end

-- Leftovers of an install cut short by a game exit; .old copies stay, they are the manual rollback.
local function cleanupTmp()
    local entries = { catalog.manager }
    for _, e in ipairs(catalog.list) do entries[#entries + 1] = e end
    for _, e in ipairs(entries) do
        if type(e.filename) == 'string' then removeIfExists(ML_DIR .. '\\' .. e.filename .. '.tmp') end
    end
end

-- «Доступно обновление для 1 скрипта», «Доступны обновления для 3 скриптов», «… для 21 скрипта».
local function updatesFor(n)
    local count = '{FFB48A}' .. n .. '{FFFFFF}'
    if n == 1 then return 'Доступно обновление для ' .. count .. ' скрипта' end
    local one = n % 10 == 1 and n % 100 ~= 11
    return 'Доступны обновления для ' .. count .. (one and ' скрипта' or ' скриптов')
end

local justUpdated = false   -- This copy was just put in place by a self-update.

-- One line per load, like the other scripts' «Загружен vX». A count, not names: the window has the list.
-- Updatable scripts win over a new manager: the window shows its banner anyway.
local function loginLine()
    local own = thisScript().version
    local line = (justUpdated and LOAD_UPDATED or LOAD_FIRST):format(own)
    local n = 0
    if catalog then
        for _, e in ipairs(catalog.list) do
            if hasUpdate(e, scanEntry(e)) then n = n + 1 end
        end
    end
    local m = catalog and catalog.manager
    local remote = m and versionNum(m.version)
    if n > 0 then
        line = line .. LOAD_SCRIPTS:format(updatesFor(n))
    elseif remote and remote > (versionNum(own) or 0) then
        line = line .. LOAD_MANAGER:format(m.version)
    else
        line = line .. LOAD_OPEN
    end
    chat(line)
end

-- ============================================================================
-- LUASOCKET AND THE HTTP CHANNEL (polled from main)
-- ============================================================================

local queue = {}          -- Chat commands and page messages, drained by main(): never act from a hook.
local socket = nil
-- nil until checked, then 'ready', 'fetching', 'busy' (no free port), 'missing' (no list or a download failed: tried again)
-- or 'failed' (a hash did not match or the files do not load: final).
local socketState = nil
local server, serverPort = nil, nil
local clients = {}
local token = nil         -- Page requests must carry it: any web page can reach 127.0.0.1 with a no-cors fetch.

local function tryRequire()
    local ok, mod = pcall(require, 'socket')
    if ok and type(mod) == 'table' then
        socket = mod
        return true
    end
    -- A loader that was found but failed leaves a sentinel; without clearing it the next require fails on it.
    package.loaded.socket, package.loaded['socket.core'] = nil, nil
    return false
end

local function startServer()
    for port = PORT_FIRST, PORT_LAST do
        -- Not socket.bind: it sets SO_REUSEADDR, and on Windows that lets a second listener share a taken port.
        local s = socket.tcp()
        if s and s:bind('127.0.0.1', port) and s:listen(8) then
            s:settimeout(0)
            server, serverPort = s, port
            return true
        end
        if s then s:close() end
    end
    return false
end

local function socketReady()
    if not tryRequire() then return 'failed' end
    return startServer() and 'ready' or 'busy'
end

-- A missing LuaSocket is fetched from deps.socket, every file checked by SHA-256 before anything lands in moonloader\lib.
-- A file already at its target is never replaced: it belongs to whatever installed it.
local function ensureSocket()
    if socketState and socketState ~= 'missing' then return end
    if tryRequire() then socketState = socketReady() return end
    if not catalog then socketState = 'missing' return end
    local files = type(catalog.deps) == 'table' and catalog.deps.socket
    if type(files) ~= 'table' or #files == 0 then socketState = 'failed' return end
    socketState = 'fetching'
    local staged = {}
    local function fail(why, final)
        for _, f in ipairs(staged) do removeIfExists(f.tmp) end
        socketState = final and 'failed' or 'missing'
        logLine('LuaSocket не поставлен: ' .. why)
    end
    local i = 0
    local function nextFile()
        i = i + 1
        local d = files[i]
        if not d then
            for _, f in ipairs(staged) do
                if doesFileExist(f.target) then
                    removeIfExists(f.tmp)
                else
                    createDirectory(f.target:match('^(.*)\\[^\\]*$'))
                    os.rename(f.tmp, f.target)
                end
            end
            socketState = socketReady()
            if socketState ~= 'ready' then logLine('LuaSocket разложен, но не загрузился') end
            return
        end
        local target = type(d.target) == 'string' and d.target or ''
        if type(d.path) ~= 'string' or type(d.sha256) ~= 'string' or not target:match('^[%w_%-][%w_%-%./]*$') or target:find('..', 1, true) then
            fail('битая запись deps.socket', true)
            return
        end
        local tmp = DL_DIR .. '\\socket-' .. i .. '.tmp'
        queueDownload(BASE_URL .. d.path, tmp, function(err)
            if err then fail(d.path .. ': ' .. err) return end
            local body = readFile(tmp)
            if not body or sha256(body) ~= d.sha256:lower() then
                removeIfExists(tmp)
                fail(d.path .. ': хеш не совпал', true)
                return
            end
            staged[#staged + 1] = { tmp = tmp, target = ML_DIR .. '\\lib\\' .. target:gsub('/', '\\') }
            nextFile()
        end)
    end
    nextFile()
end

-- Non-blocking: a request may arrive in pieces, so clients wait in a list until the request line is complete.
local function pollServer()
    if not server then return end
    for _ = 1, 8 do
        local c = server:accept()
        if not c then break end
        c:settimeout(0)
        clients[#clients + 1] = { c = c, buf = '', deadline = os.clock() + CLIENT_TIMEOUT }
    end
    for i = #clients, 1, -1 do
        local p = clients[i]
        local data, err, partial = p.c:receive(4096)
        local chunk = data or partial
        if chunk and chunk ~= '' then p.buf = p.buf .. chunk end
        local line = p.buf:match('^([^\r\n]*)\r?\n')
        if line or err == 'closed' or os.clock() > p.deadline then
            local k, d, t = (line or ''):match('^GET /m%?k=(%a+)&d=([^&%s]*)&t=(%x+) HTTP')
            local status = '403 Forbidden'
            if k and t == token then
                status = '204 No Content'
                queue[#queue + 1] = { kind = k, data = urlDecode(d) }
            end
            pcall(p.c.send, p.c, 'HTTP/1.1 ' .. status .. '\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n')
            pcall(p.c.close, p.c)
            table.remove(clients, i)
        end
    end
end

local function newToken()
    math.randomseed(os.time() + math.floor(os.clock() * 1000000) + (tonumber(tostring({}):match('0x(%x+)') or '0', 16) or 0))
    local out = {}
    for i = 1, 16 do out[i] = ('%x'):format(math.random(0, 15)) end
    return table.concat(out)
end

-- ============================================================================
-- CEF TRANSPORT (evalcef only from main())
-- ============================================================================

local CHUNK = 30000 -- Base64 chars per evalcef, one call is capped at 32767 bytes.
local OUTBOX_PER_TICK = 2

local inEval = false      -- Our own emulated packets pass onReceivePacket too; they never carry setActiveView.

local function evalcef(code)
    if #code > 32767 then
        logLine('evalcef ' .. #code .. ' байт больше лимита 32767, не отправлен')
        return false
    end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)        -- Sub-type 17 = eval JS.
    raknetBitStreamWriteInt32(bs, 0)        -- Browser id, 0 = main.
    raknetBitStreamWriteInt16(bs, #code)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteString(bs, code)
    inEval = true
    raknetEmulPacketReceiveBitStream(220, bs)
    inEval = false
    raknetDeleteBitStream(bs)
    return true
end

local outbox = {}
local outboxQueued, outboxSent = 0, 0

-- Returns a ticket: the item has gone out once outboxSent reaches it.
local function enqueue(code)
    outboxQueued = outboxQueued + 1
    outbox[#outbox + 1] = code
    return outboxQueued
end

local function flushOutbox()
    for _ = 1, OUTBOX_PER_TICK do
        local code = table.remove(outbox, 1)
        if not code then return end
        outboxSent = outboxSent + 1
        evalcef(code)
    end
end

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- Payloads cross into CEF as base64: literal non-ASCII in an injected string arrives garbled.
local function b64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = s:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1 = math.floor(n / 262144) % 64
        local c2 = math.floor(n / 4096) % 64
        local c3 = math.floor(n / 64) % 64
        local c4 = n % 64
        out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
            .. (b and B64:sub(c3 + 1, c3 + 1) or '=') .. (c and B64:sub(c4 + 1, c4 + 1) or '=')
    end
    return table.concat(out)
end

local function call(js)
    return enqueue('window.__arzHub&&window.__arzHub.' .. js)
end

local function queuePayload(ch, str)
    local enc = b64(str)
    call(("reset('%s')"):format(ch))
    for i = 1, #enc, CHUNK do call(("push('%s','%s')"):format(ch, enc:sub(i, i + CHUNK - 1))) end
end

-- Lives in the Arizona main document: owns the iframe, keeps the assembled page, relays page messages to the local server.
local BOOT_JS = [==[
(() => {
  const VERSION = '__VERSION__';
  const TOKEN = '__TOKEN__';
  const PORT = __PORT__;
  const send = (kind, data) => {
    fetch('http://127.0.0.1:' + PORT + '/m?k=' + kind + '&d=' + encodeURIComponent(data == null ? '' : String(data)) + '&t=' + TOKEN,
      { mode: 'no-cors', cache: 'no-store' }).catch(() => {});
  };
  const prev = window.__arzHub;
  if (prev && prev.version === VERSION) { send('boot', 'again'); return; }
  if (prev && prev.destroy) { try { prev.destroy(); } catch (e) {} }
  const bufs = {};
  let page = '';
  let frame = null;
  const decode = (s) => new TextDecoder('utf-8').decode(Uint8Array.from(atob(s), (c) => c.charCodeAt(0)));
  const take = (ch) => { const s = bufs[ch] || ''; delete bufs[ch]; return decode(s); };
  const onMessage = (e) => {
    if (!frame || e.source !== frame.contentWindow) return;
    const d = e.data;
    if (!d || d.arzhub !== true) return;
    send(String(d.kind), d.data);
  };
  window.addEventListener('message', onMessage);
  // Arizona's own cursor: the mouse goes to CEF, the keys stay with the game.
  let wantCursor = false;
  const setCursor = (on) => {
    try { window.cef.ToggleCursor(0, on, true); } catch (e) { send('error', 'cursor: ' + e); }
  };
  // Arizona recomputes its cursor on every dialog, menu or window change and knows nothing of ours.
  const watchCursor = () => {
    if (!wantCursor || !frame) return;
    let state;
    try { state = window.cef.GetCursor(); } catch (e) { return; }
    Promise.resolve(state).then((on) => {
      if (on === false && wantCursor) { setCursor(true); send('cursor', 'restored'); }
    }).catch(() => {});
  };
  const watch = setInterval(watchCursor, 500);
  const api = {
    version: VERSION,
    reset: (ch) => { bufs[ch] = ''; },
    push: (ch, part) => { bufs[ch] = (bufs[ch] || '') + part; },
    store: (ch) => { try { page = take(ch); } catch (e) { send('error', 'store: ' + e); } },
    open: () => {
      try {
        if (frame) frame.remove();
        frame = document.createElement('iframe');
        frame.id = 'arzhub-frame';
        frame.setAttribute('allowtransparency', 'true');
        // Exactly the window's size, like an ImGui window: a click beside it reaches the game or Arizona.
        const s = frame.style;
        s.position = 'fixed'; s.left = '50%'; s.top = '50%'; s.transform = 'translate(-50%, -50%)';
        s.width = 'min(860px, 92vw)'; s.height = 'min(520px, 86vh)';
        s.border = '0'; s.zIndex = '2147483646'; s.background = 'transparent';
        frame.onload = () => {
          send('loaded', '');
          try { frame.contentWindow.focus(); } catch (e) {}
        };
        frame.srcdoc = page;
        (document.body || document.documentElement).appendChild(frame);
      } catch (e) { send('error', 'open: ' + e); }
    },
    post: (ch, kind) => {
      try {
        const data = take(ch);
        if (frame && frame.contentWindow) frame.contentWindow.postMessage({ arzhubIn: true, kind: kind, data: data }, '*');
      } catch (e) { send('error', 'post: ' + e); }
    },
    // On always goes off -> on: the client gives the keys back to the game only on that switch, and an
    // Arizona window may have switched the cursor on over ours. `leave` drops ours without switching it off.
    cursor: (on, leave) => {
      wantCursor = !!on;
      if (on) { setCursor(false); setCursor(true); } else if (!leave) setCursor(false);
    },
    close: () => { if (frame) { frame.remove(); frame = null; } },
    destroy: (leave) => {
      if (wantCursor) api.cursor(false, leave);
      clearInterval(watch);
      api.close();
      window.removeEventListener('message', onMessage);
    }
  };
  window.__arzHub = api;
  send('boot', 'new');
})();
]==]

-- Shown when neither the network nor the cache has the real page.
local FALLBACK_HTML = [==[
<!doctype html><html><head><meta charset="utf-8"><style>
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:transparent;font:14px/1.45 "Segoe UI",Arial,sans-serif;color:#f2f2f2}
.win{height:100%;background:#1e1f22;border:1px solid rgba(255,255,255,.12);border-radius:8px;overflow:hidden}
.head{height:42px;display:flex;align-items:center;gap:12px;padding:0 14px;background:#111213;border-bottom:1px solid rgba(255,255,255,.12)}
.logo{font-weight:800;font-size:20px}.logo b{background:#ff6a1a;color:#111213;padding:0 5px;border-radius:4px}
.x{margin-left:auto;cursor:pointer;color:#9a9a9a;font-size:20px}
.bar{padding:12px 14px;background:rgba(217,180,92,.10);color:#d9b45c}
.body{padding:16px 14px}
button{height:34px;padding:0 14px;border-radius:6px;border:0;font-weight:600;color:#111213;background:linear-gradient(180deg,#ffa31a,#ff6a1a);cursor:pointer}
</style></head><body><div class="win">
<div class="head"><div class="logo">ARZ<b>HUB</b></div><span class="x" data-act="close">&times;</span></div>
<div class="bar">Нет связи со списком скриптов</div>
<div class="body"><button data-act="retry">Повторить</button></div>
</div><script>
const toLua = (kind, data) => parent.postMessage({ arzhub: true, kind: kind, data: data == null ? '' : String(data) }, '*');
document.addEventListener('click', (e) => {
  const a = e.target.closest('[data-act]');
  if (!a) return;
  if (a.dataset.act === 'close') toLua('close', 'button'); else toLua('retry', '');
});
toLua('stat', '');
setInterval(() => toLua('stat', ''), 1000);
</script></body></html>
]==]

-- ============================================================================
-- CURSOR AND INPUT
-- ============================================================================

local cursorOn = false    -- Our window holds Arizona's cursor.
local activeView = nil     -- Arizona window open right now, from incoming event.setActiveView.

-- Mouse to CEF without taking the keys: the bootstrap calls window.cef.ToggleCursor and holds it against Arizona.
-- Switching off under an open Arizona window leaves the cursor to that window.
local function cefCursor(on, why)
    cursorOn = on
    if not on and activeView then
        logLine('курсор оставлен окну Arizona ' .. activeView .. ': ' .. why)
        call('cursor(false,true)')
        return
    end
    logLine(('курсор %s: %s'):format(on and 'вкл' or 'выкл', why))
    call(('cursor(%s)'):format(tostring(on)))
end

-- Reload and unload cannot wait for the outbox; destroy() gives the cursor back itself if it holds it.
local function destroyNow(why)
    if cursorOn then logLine('курсор выкл: ' .. why) end
    cursorOn = false
    evalcef(('window.__arzHub&&window.__arzHub.destroy(%s)'):format(tostring(activeView ~= nil)))
end

-- The cursor is never touched while the game is minimized or out of focus.
local function gameFocused()
    local ok, res = pcall(function()
        local h = ffi.C.GetActiveWindow()
        return h ~= nil and ffi.C.IsIconic(h) == 0
    end)
    return not ok or res == true
end

-- ============================================================================
-- WINDOW
-- ============================================================================

local BOOT_WAIT = 2        -- Seconds for the bootstrap to answer.
local LOAD_WAIT = 5        -- Seconds for the iframe to load once open() went out.
local LOST_AFTER = 5       -- Seconds without a heartbeat before the page counts as gone.
local REFETCH_AFTER = 60   -- Seconds: an older list is fetched again when the window opens.
local FOCUS_GRACE = 2      -- Seconds after the game window gets focus back before the cursor is touched again.
local VK_ESCAPE = 0x1B
local WM_KEYDOWN, WM_KEYUP = 0x100, 0x101
local RESTORE_LOG_EVERY = 10  -- Seconds between two log lines about the cursor taken back from Arizona.

local PAGE_DIR = DATA_DIR .. '\\hub'
local PAGE_PATH = PAGE_DIR .. '\\hub.html'
local PAGE_VERSION_PATH = PAGE_DIR .. '\\version.txt'

local isOpen = false
local opening = nil        -- Open in progress: { stage = 'boot' | 'load', html, key, ticket, deadline }.
local wantOpen = false     -- /hub came before LuaSocket was ready.
local bootVersion = ''
local bootAck = nil        -- 'new' or 'again' once the bootstrap answered.
local sentPageKey = nil    -- Page the bootstrap holds in this CEF context.
local openPageKey = nil
local pageLoaded = false
local lastStat = 0
local payloadSeq = 0
local manifestFetching = false
local pageFetching = false
local pageWaiters = {}
local pageFailed = nil     -- ui.version whose download failed this session: opening does not wait for it again.
local busy, results = {}, {}
local bulk = nil           -- Update-all in progress: { i, n }.

local escHidden = false    -- Our Esc press is being hidden from the game; its release closes the window.
local focused = true
local focusBackAt = -math.huge
local reapplyPending = false
local restores, restoreLoggedAt = 0, -math.huge

local function post(kind, str)
    payloadSeq = payloadSeq + 1
    local ch = 'p' .. payloadSeq
    queuePayload(ch, str)
    call(("post('%s','%s')"):format(ch, kind))
end

local function bootCode()
    return (BOOT_JS:gsub('__VERSION__', function() return bootVersion end)
        :gsub('__TOKEN__', function() return token end)
        :gsub('__PORT__', function() return tostring(serverPort) end))
end

local function basename(path)
    return (path:match('([^\\]+)$'))
end

local function cleanCommands(list)
    local out = {}
    if type(list) ~= 'table' then return nil end
    for _, c in ipairs(list) do
        if type(c) == 'table' and type(c.cmd) == 'string' and c.cmd:sub(1, 1) == '/' then
            out[#out + 1] = { cmd = c.cmd, desc = type(c.desc) == 'string' and c.desc or '' }
        end
    end
    return #out > 0 and out or nil
end

local function cleanChangelog(list)
    local out = {}
    if type(list) ~= 'table' then return nil end
    for _, v in ipairs(list) do
        if type(v) == 'table' and type(v.version) == 'string' then out[#out + 1] = { version = v.version, notes = strings(v.notes) } end
    end
    return #out > 0 and out or nil
end

local function entryState(e)
    local scan = scanEntry(e)
    local dead = e.actual == false
    if dead and not scan.path then return nil end
    local status = 'ok'
    if dead then
        status = 'dead'
    elseif not scan.path then
        status = 'missing'
    elseif hasUpdate(e, scan) then
        status = 'update'
    end
    return {
        id = e.id, name = tostring(e.name or e.id), version = tostring(e.version or ''),
        description = type(e.description) == 'string' and e.description or nil,
        usage = type(e.usage) == 'string' and e.usage or nil,
        page = type(e.page) == 'string' and e.page or nil,
        commands = cleanCommands(e.commands), changelog = cleanChangelog(e.changelog),
        status = status, localVersion = scan.localVersion,
        twoCopies = scan.alt and { old = basename(scan.alt), new = basename(scan.path) } or nil,
        busy = busy[e.id], result = results[e.id],
    }
end

local function buildState()
    local st = { scripts = {}, releases = RELEASES_URL }
    local own = thisScript().version
    st.manager = { version = own, busy = busy[UPDATE_SCRIPT_ID], result = results[UPDATE_SCRIPT_ID] }
    if not catalog then
        st.noList = true
        return st
    end
    for _, e in ipairs(catalog.list) do st.scripts[#st.scripts + 1] = entryState(e) end
    local m = catalog.manager
    if m and versionNum(m.version) and versionNum(m.version) > (versionNum(own) or 0) then st.manager.update = m.version end
    if catalog.offline then st.offline = { since = os.date('%H:%M', catalog.fetchedAt) } end
    st.bulk = bulk
    return st
end

local function pushState()
    if isOpen then post('state', encodeJson(buildState())) end
end

-- cb(html, key) runs from main(); key tells whether the bootstrap already holds this page.
local function withPage(cb)
    local ui = catalog and type(catalog.ui) == 'table' and catalog.ui or nil
    local want = ui and type(ui.version) == 'string' and type(ui.path) == 'string' and ui.version or nil
    local html, ver = readFile(PAGE_PATH), readFile(PAGE_VERSION_PATH)
    if html and (not want or ver == want) then cb(html, 'ui:' .. tostring(ver)) return end
    if not want or pageFailed == want then
        if html then cb(html, 'ui:' .. tostring(ver)) else cb(FALLBACK_HTML, 'fallback') end
        return
    end
    pageWaiters[#pageWaiters + 1] = cb
    if pageFetching then return end
    pageFetching = true
    local tmp = PAGE_DIR .. '\\hub.html.tmp'
    queueDownload(BASE_URL .. ui.path, tmp, function(err)
        pageFetching = false
        local body = not err and readFile(tmp) or nil
        removeIfExists(tmp)
        local outHtml, key = FALLBACK_HTML, 'fallback'
        -- The CDN serves an old file for minutes after a push: only a page carrying the announced version is cached.
        local version = body and body:match('<meta name="arzhub%-ui" content="([^"]+)"')
        if version == want and body:find('</html>', 1, true) then
            writeFile(PAGE_PATH, body)
            writeFile(PAGE_VERSION_PATH, want)
            outHtml, key = body, 'ui:' .. want
        else
            pageFailed = want
            logLine('страница окна не скачалась: ' .. tostring(err or 'не та страница'))
            if html then outHtml, key = html, 'ui:' .. tostring(ver) end
        end
        local waiters = pageWaiters
        pageWaiters = {}
        for _, w in ipairs(waiters) do w(outHtml, key) end
    end)
end

local onCatalog

-- A retry while a fetch is running is not dropped: it runs right after, against the network as it is now.
local refetchPending = false

local function refreshCatalog(login)
    if manifestFetching then
        refetchPending = true
        return
    end
    manifestFetching = true
    fetchManifest(function(err)
        manifestFetching = false
        onCatalog(err, login)
        if refetchPending then
            refetchPending = false
            refreshCatalog(false)
        end
    end)
end

local function closeWindow(reason)
    if not isOpen then return end
    isOpen = false
    call('close()')
    -- Under an Arizona window the cursor is that window's.
    if cursorOn then cefCursor(false, 'закрытие окна') end
    reapplyPending = false
    logLine('окно закрыто: ' .. reason)
end

local function cancelOpening()
    opening = nil
    call('close()')
end

local function openWindow()
    local o = { stage = 'boot', deadline = os.clock() + BOOT_WAIT }
    opening = o
    bootAck = nil
    enqueue(bootCode())
    withPage(function(html, key)
        if opening == o then o.html, o.key = html, key end
    end)
end

local function stepOpen()
    local o = opening
    if not o then return end
    if o.stage == 'boot' then
        if not bootAck then
            if os.clock() > o.deadline then
                opening = nil
                chat(BOOT_FAIL_TEXT)
            end
            return
        end
        if not o.html then return end
        if bootAck == 'new' then sentPageKey = nil end
        if sentPageKey ~= o.key then
            queuePayload('page', o.html)
            call("store('page')")
            sentPageKey = o.key
        end
        pageLoaded = false
        o.ticket = call('open()')
        openPageKey = o.key
        o.stage, o.deadline = 'load', nil
    elseif o.stage == 'load' then
        if not o.deadline then
            if outboxSent >= o.ticket then o.deadline = os.clock() + LOAD_WAIT end
            return
        end
        if pageLoaded then
            opening = nil
            isOpen = true
            lastStat = os.clock()
            logLine('окно открыто')
            if focused then
                cefCursor(true, 'окно открылось')
            else
                logLine('игра без фокуса: курсор возьмём после возврата фокуса')
                reapplyPending = true
            end
            pushState()
            if not catalog or catalog.offline or os.time() - catalog.fetchedAt > REFETCH_AFTER then refreshCatalog(false) end
        elseif os.clock() > o.deadline then
            cancelOpening()
            chat(BOOT_FAIL_TEXT)
        end
    end
end

-- ============================================================================
-- INSTALLER
-- ============================================================================

local OK_INSTALL = 'Установлено, скрипт запущен.'
local OK_UPDATE = 'Обновлено до %s, скрипт перезапущен.'
local OK_KEEPNEW = 'Старая копия удалена.'
local FAIL_TEXT = {
    timeout = 'Сервер не ответил, повторите через пару минут.',
    empty = 'Файл не скачался, повторите через пару минут.',
    broken = 'Файл скачался с ошибкой, повторите через пару минут.',
    stale = 'Новая версия ещё не успела разойтись, повторите через пару минут.',
    replace = 'Не удалось записать файл: он занят другой программой или нет прав.',
}
local FAIL_KEEP = ' Старая версия на месте.'
local SITE_PATTERN = '^https://arzhub%.top/[%w%-%._~/]*$'

local reloadPending = false
local selfReplaced = false  -- Own file replaced: only closing and the manual download still work.
local runPending = nil     -- Command to run on the next tick, after the window closed.

local function findLoaded(path)
    local want = path:lower()
    for _, s in ipairs(script.list()) do
        if type(s.path) == 'string' and s.path:lower() == want then return s end
    end
end

local function autoReboot()
    return script.find('ML-AutoReboot') ~= nil
end

-- ML-AutoReboot watches only the scripts that were loaded when it started; the ones loaded from here it never sees.
local loadedHere = {}

local function loadScript(path)
    loadedHere[path:lower()] = true
    return script.load(path)
end

-- current -> current.old, tmp -> current; a failed second step puts current back. The .old copy is the manual rollback.
local function atomicReplace(tmp, target)
    local old = target .. '.old'
    removeIfExists(old)
    if not os.rename(target, old) then return false end
    if not os.rename(tmp, target) then
        os.rename(old, target)
        return false
    end
    return true
end

-- Checks a downloaded build: nil when it is the announced version, else 'stale' (CDN still serves the installed one) or 'broken'.
local function checkBuild(tmp, want, installedVersion)
    local got = readVersion(tmp)
    if got == want then return nil end
    if got and installedVersion and got == installedVersion then return 'stale' end
    return 'broken'
end

local function entryById(id)
    if not catalog then return nil end
    for _, e in ipairs(catalog.list) do
        if e.id == id then return e end
    end
end

local function validEntry(e)
    return type(e.filename) == 'string' and type(e.path) == 'string' and versionNum(e.version) ~= nil
        and not e.filename:find('[\\/]') and not e.path:find('..', 1, true)
end

-- done(ok) runs once the entry is installed or has failed; results land in the state either way.
local function installEntry(e, done)
    local id = e.id
    local scan = scanEntry(e)
    local target = ML_DIR .. '\\' .. e.filename
    local keep = scan.path and FAIL_KEEP or ''
    local function finish(ok, text)
        busy[id] = nil
        results[id] = { ok = ok, text = text }
        pushState()
        if done then done(ok) end
    end
    busy[id], results[id] = true, nil
    pushState()
    local tmp = target .. '.tmp'
    queueDownload(BASE_URL .. e.path, tmp, function(err)
        if err then
            removeIfExists(tmp)
            finish(false, FAIL_TEXT[err] .. keep)
            return
        end
        local bad = checkBuild(tmp, e.version, scan.localVersion)
        if bad then
            removeIfExists(tmp)
            finish(false, FAIL_TEXT[bad] .. keep)
            return
        end
        if scan.path == target then
            if not atomicReplace(tmp, target) then
                removeIfExists(tmp)
                finish(false, FAIL_TEXT.replace .. keep)
                return
            end
            -- ML-AutoReboot restarts a replaced file it watches; a second load of our own would race it.
            if autoReboot() and not loadedHere[target:lower()] then
                finish(true, OK_UPDATE:format(e.version))
                return
            end
            local running = findLoaded(target)
            if running then running:unload() end
            loadScript(target)
            finish(true, OK_UPDATE:format(e.version))
            return
        end
        if not os.rename(tmp, target) then
            removeIfExists(tmp)
            finish(false, FAIL_TEXT.replace .. keep)
            return
        end
        -- Found under another name: that copy stops and is put aside, the main name always loads.
        if scan.path then
            local running = findLoaded(scan.path)
            if running then running:unload() end
            removeIfExists(scan.path .. '.old')
            os.rename(scan.path, scan.path .. '.old')
        end
        loadScript(target)
        finish(true, scan.path and OK_UPDATE:format(e.version) or OK_INSTALL)
    end)
end

local function deleteEntry(e)
    local scan = scanEntry(e)
    for _, p in ipairs({ scan.path, scan.alt }) do
        local running = findLoaded(p)
        if running then running:unload() end
        os.remove(p)
    end
    results[e.id] = nil
    pushState()
end

local function keepNew(e)
    local scan = scanEntry(e)
    if not scan.alt then return end
    local running = findLoaded(scan.alt)
    if running then running:unload() end
    os.remove(scan.alt)
    results[e.id] = { ok = true, text = OK_KEEPNEW }
    pushState()
end

local function updateAll()
    local list = {}
    for _, e in ipairs(catalog.list) do
        if e.actual ~= false and validEntry(e) and hasUpdate(e, scanEntry(e)) then list[#list + 1] = e end
    end
    if #list == 0 then return end
    bulk = { i = 0, n = #list }
    local function nextOne()
        bulk.i = bulk.i + 1
        local e = list[bulk.i]
        if not e then
            bulk = nil
            pushState()
            return
        end
        installEntry(e, nextOne)
    end
    nextOne()
end

-- announce: started by /hub update, so a failure goes to the chat too: the window may not be there at all.
local function selfUpdate(announce)
    local m = catalog.manager
    local own = thisScript().version
    if not m or not versionNum(m.version) or versionNum(m.version) <= (versionNum(own) or 0) or type(m.path) ~= 'string' then return end
    local target = thisScript().path
    local tmp = target .. '.tmp'
    local function finish(ok, text)
        busy[UPDATE_SCRIPT_ID] = nil
        results[UPDATE_SCRIPT_ID] = { ok = ok, text = text }
        pushState()
        if announce and not ok then chat(text) end
    end
    busy[UPDATE_SCRIPT_ID], results[UPDATE_SCRIPT_ID] = true, nil
    pushState()
    queueDownload(BASE_URL .. m.path, tmp, function(err)
        if err then
            removeIfExists(tmp)
            finish(false, FAIL_TEXT[err] .. FAIL_KEEP)
            return
        end
        local bad = checkBuild(tmp, m.version, own)
        if bad or not atomicReplace(tmp, target) then
            removeIfExists(tmp)
            finish(false, FAIL_TEXT[bad or 'replace'] .. FAIL_KEEP)
            return
        end
        selfReplaced, dlFrozen = true, true
        -- The new copy says so in the chat once it runs: the window goes away with the old one.
        writeFile(SELF_UPDATED_PATH, m.version)
        if autoReboot() then
            -- ML-AutoReboot may reload us before the outbox drains: a queued close would leave the window behind.
            finish(true, SELF_UPDATED_TEXT:format(m.version))
            if isOpen then destroyNow('обновление менеджера') end
            closeWindow('обновление менеджера, перезапустит ML-AutoReboot')
            return
        end
        reloadPending = true
    end)
end

local function runCommand(e, cmd)
    for _, c in ipairs(cleanCommands(e.commands) or {}) do
        if c.cmd == cmd then
            closeWindow('команда ' .. cmd)
            runPending = cmd
            return
        end
    end
end

-- The address goes through cmd.exe: only plain arzhub.top paths, a '&' would start a second command.
local function openSite(e)
    local url = e.page
    if type(url) == 'string' and url:match(SITE_PATTERN) then os.execute('start ' .. url) end
end

local ACTIONS = {
    install = true, update = true, delete = true, keepNew = true, open = true, run = true,
    updateAll = true, selfUpdate = true, releases = true,
}

-- Page actions need a fresh list and never overlap: a busy entry or a running update-all ignores them.
local function onAction(kind, data)
    -- The manual download is for exactly the cases where the rest fails, so it needs no list.
    if kind == 'releases' then
        os.execute('start ' .. RELEASES_URL)
        return
    end
    if not catalog or catalog.offline or bulk or selfReplaced or busy[UPDATE_SCRIPT_ID] then return end
    if kind == 'updateAll' then updateAll() return end
    if kind == 'selfUpdate' then
        if not busy[UPDATE_SCRIPT_ID] then selfUpdate() end
        return
    end
    local id, arg = data:match('^([^|]*)|(.*)$')
    local e = entryById(id or data)
    if not e or busy[e.id] then return end
    if kind == 'open' then
        openSite(e)
    elseif kind == 'run' then
        runCommand(e, arg or '')
    elseif kind == 'delete' then
        deleteEntry(e)
    elseif kind == 'keepNew' then
        keepNew(e)
    elseif validEntry(e) and (e.actual ~= false or kind ~= 'install') then
        installEntry(e)
    end
end

-- ============================================================================
-- MAIN
-- ============================================================================

local updateAsked = false   -- /hub update waits for a fresh list.

onCatalog = function(err, login)
    if err then
        logLine('манифест не скачался: ' .. err)
        if not catalog then loadCache() end
    end
    if catalog then
        cleanupTmp()
        withPage(function() end)
    end
    if login then loginLine() end
    ensureSocket()
    if updateAsked then
        updateAsked = false
        local m = catalog and catalog.manager
        local remote = m and versionNum(m.version)
        if err or not m then
            chat(UPDATE_OFFLINE_TEXT)
        elseif remote and remote > (versionNum(thisScript().version) or 0) then
            chat(UPDATE_START_TEXT:format(m.version))
            selfUpdate(true)
        else
            chat(UPDATE_NONE_TEXT:format(thisScript().version))
        end
    end
    -- The fallback page has nothing to show once the list is back: the real one replaces it.
    if not err and isOpen and openPageKey == 'fallback' and catalog.ui then
        closeWindow('пришёл список, открываю настоящую страницу')
        wantOpen = true
        return
    end
    pushState()
end

local function onPageMessage(kind, data)
    if kind == 'boot' then
        bootAck = data == 'again' and 'again' or 'new'
    elseif kind == 'loaded' then
        pageLoaded = true
    elseif kind == 'stat' then
        lastStat = os.clock()
    elseif kind == 'close' then
        closeWindow(data)
    elseif kind == 'view' then
        logLine('окно Arizona: ' .. (data ~= '' and data or 'закрыто'))
        -- Arizona switched the cursor on over ours: only a fresh off -> on gives the keys back to the game.
        -- When its window closes Arizona switches the cursor off, and the bootstrap's watchdog takes it back.
        if data ~= '' and isOpen and cursorOn then cefCursor(true, 'открылось окно Arizona ' .. data) end
    elseif kind == 'retry' then
        pageFailed = nil
        refreshCatalog(false)
    elseif kind == 'cursor' then
        restores = restores + 1
        if os.clock() - restoreLoggedAt >= RESTORE_LOG_EVERY then
            logLine(('курсор вернули (%d раз): Arizona выключила его, пересчитывая свои окна'):format(restores))
            restores, restoreLoggedAt = 0, os.clock()
        end
    elseif kind == 'error' then
        logLine('ошибка в CEF: ' .. data)
    elseif ACTIONS[kind] then
        onAction(kind, data)
    else
        logLine('страница: ' .. kind .. ' ' .. data)
    end
end

-- The manager's own update without the window: the way out when Arizona breaks CEF.
local function onUpdateCommand()
    if updateAsked or busy[UPDATE_SCRIPT_ID] or selfReplaced then
        chat(UPDATE_BUSY_TEXT)
        return
    end
    updateAsked = true
    refreshCatalog(false)
end

local function onCommand(arg)
    arg = tostring(arg or ''):match('^%s*(.-)%s*$'):lower()
    if arg == 'update' then onUpdateCommand() return end
    if arg ~= '' then chat(HELP_TEXT) return end
    if opening then cancelOpening() return end
    if isOpen then closeWindow('команда /hub') return end
    wantOpen = not wantOpen
end

local function onQueueItem(item)
    if item.cmd then
        onCommand(item.arg)
    else
        onPageMessage(item.kind, item.data)
    end
end

local socketRetried = false

local function stepWindow()
    if wantOpen and not opening and not isOpen then
        if socketState == 'ready' then
            wantOpen, socketRetried = false, false
            openWindow()
        elseif socketState == 'missing' and not socketRetried then
            -- One more try per /hub: the list or GitHub may be back by now.
            socketRetried = true
            socketState = nil
            refreshCatalog(false)
        elseif socketState == 'failed' or socketState == 'missing' then
            wantOpen, socketRetried = false, false
            chat(SOCKET_FAIL_TEXT)
        elseif socketState == 'busy' then
            wantOpen = false
            chat(PORTS_BUSY_TEXT)
        end
    end
    stepOpen()
    local now = os.clock()
    local nowFocused = gameFocused()
    if nowFocused ~= focused then
        focused = nowFocused
        logLine(focused and 'фокус игры вернулся' or 'игра потеряла фокус')
        if focused then
            focusBackAt = now
            reapplyPending = true
        end
    end
    if not isOpen then return end
    -- No heartbeat is expected from a page while the game is minimized.
    if not focused then lastStat = now end
    if now - lastStat > LOST_AFTER then
        closeWindow('страница не отвечает ' .. LOST_AFTER .. ' с')
        return
    end
    if not focused or now - focusBackAt <= FOCUS_GRACE then return end
    if reapplyPending then
        -- After a restore the cursor may be claimed on while it is not drawn: one forced re-apply.
        reapplyPending = false
        cefCursor(true, 'после возврата фокуса')
    end
end

-- ============================================================================
-- HOOKS (queue only)
-- ============================================================================

-- Esc toggles Arizona's own main menu even over our window, so while ours is open the key never reaches the game.
-- Ours closes first even over an Arizona window: it sits on top, the next Esc is that window's.
-- Both messages are hidden and the window closes on release, or the game is left thinking Esc is held.
function onWindowMessage(msg, wparam)
    if wparam ~= VK_ESCAPE or (msg ~= WM_KEYDOWN and msg ~= WM_KEYUP) then return end
    if msg == WM_KEYUP then
        if not escHidden then return end
        escHidden = false
        consumeWindowMessage(true, false)
        queue[#queue + 1] = { kind = 'close', data = 'esc' }
        return
    end
    if not isOpen then
        -- A release lost to Alt+Tab must not keep the next Esc from the game.
        escHidden = false
        return
    end
    if not escHidden then
        if sampIsChatInputActive() or sampIsDialogActive() or isPauseMenuActive() then return end
        escHidden = true
    end
    consumeWindowMessage(true, false)
end

-- Tracks which Arizona window is open: our cursor is switched again over it and left to it when ours closes.
local function readIncoming(bs)
    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) ~= 17 then return end
    raknetBitStreamIgnoreBits(bs, 32)
    local length = raknetBitStreamReadInt16(bs)
    local encoded = raknetBitStreamReadInt8(bs)
    local str = (encoded ~= 0) and raknetBitStreamDecodeString(bs, length + encoded) or raknetBitStreamReadString(bs, length)
    if not str or not str:find('event.setActiveView', 1, true) then return end
    local arg = str:match([=[setActiveView['"]%s*,%s*[`'"](%b[])]=])
    if not arg then return end
    local view = arg:match('"([^"]*)"')
    if view == '' then view = nil end
    if view ~= activeView then
        activeView = view
        queue[#queue + 1] = { kind = 'view', data = view or '' }
    end
end

function onReceivePacket(id, bs)
    if id ~= 220 or inEval then return end
    raknetBitStreamResetReadPointer(bs)
    pcall(readIncoming, bs)
    raknetBitStreamResetReadPointer(bs)
end

function onScriptTerminate(s)
    if s ~= thisScript() then return end
    for _, p in ipairs(clients) do pcall(p.c.close, p.c) end
    if server then pcall(server.close, server) end
    -- Always: a close still waiting in the outbox dies with the script and would leave the window behind.
    pcall(destroyNow, 'выгрузка скрипта')
end

function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end

    createDirectory(DATA_DIR)
    createDirectory(DL_DIR)
    createDirectory(PAGE_DIR)
    if fileSize(LOG_PATH) > LOG_LIMIT then removeIfExists(LOG_PATH) end
    logLine('--- ArzHub v' .. thisScript().version)

    sampRegisterChatCommand('hub', function(arg) queue[#queue + 1] = { cmd = 'hub', arg = arg } end)
    sampRegisterChatCommand('arzhub', function(arg) queue[#queue + 1] = { cmd = 'arzhub', arg = arg } end)

    -- A fresh bootstrap per script load, so an updated script never meets its old JS in the page.
    bootVersion = thisScript().version .. '-' .. os.time()
    token = newToken()
    -- An installed LuaSocket needs no list: /hub must not wait for GitHub.
    if tryRequire() then socketState = socketReady() end
    -- Right after a self-update the load line says «Обновлён до» instead of «Загружен».
    local updatedTo = readFile(SELF_UPDATED_PATH)
    removeIfExists(SELF_UPDATED_PATH)
    justUpdated = updatedTo == thisScript().version
    refreshCatalog(true)

    while true do
        wait(0)
        if reloadPending then
            -- reload() drops whatever the outbox still holds, so the bootstrap is torn down right here.
            if isOpen then destroyNow('обновление менеджера') end
            closeWindow('обновление менеджера')
            thisScript():reload()
            return
        end
        if runPending then
            local cmd = runPending
            runPending = nil
            sampProcessChatInput(cmd)
        end
        pollServer()
        local q = queue
        queue = {}
        for _, item in ipairs(q) do onQueueItem(item) end
        stepWindow()
        stepDownloads()
        flushOutbox()
    end
end
