script_name('Dialog Plus')
script_author('TheMY3')
script_version('1.2.0')

-- Forum topic (current version, discussion): https://www.blast.hk/threads/256216/

local moonloader = require('moonloader') -- download_status for self-update.
local sampev = require('samp.events')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local function cp(s) return u8:decode(s) end

local tag = '{FFA500}[TM] Dialog Plus{FFFFFF}: '
local FORUM_URL = 'https://www.blast.hk/threads/256216/'

local function notify(text)
    sampAddChatMessage(tag .. cp(text), -1)
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

local GRACE = 0.25 -- seconds after a dialog opens when digits are ignored: the key that opened it may still be held.

-- Swallow digits for the game while a list dialog is open.
local BLOCK_DIGITS = true
-- Digits the game binds to its own menus; an empty table means every digit.
local BLOCK_ONLY = { [2] = true, [3] = true }
local DEBUG = false -- log dialogs and keys to moonloader.log.

local function dbg(fmt, ...)
    if DEBUG then print(('[%7.2f] ' .. fmt):format(os.clock(), ...)) end
end

local LIST_STYLES = { [2] = true, [4] = true, [5] = true }  -- LIST / TABLIST / TABLIST_HEADERS
local INPUT_STYLES = { [1] = true, [3] = true }             -- INPUT / PASSWORD (have a text field)
local curStyle = nil
local shownAt = 0
local needBoot = false -- set by onShowDialog, the bootstrap is sent from the main loop.

local function isListDialog()
    return sampIsDialogActive() and LIST_STYLES[curStyle] == true
end

local function isInputDialog()
    return sampIsDialogActive() and INPUT_STYLES[curStyle] == true
end

local NUMKEYS = {} -- vkey -> digit (top row and numpad).
for i = 1, 9 do NUMKEYS[0x30 + i] = i; NUMKEYS[0x60 + i] = i end
NUMKEYS[0x30] = 10; NUMKEYS[0x60] = 10 -- 0 selects item 10.

-- Whether the game must not see this digit.
local function blocked(d)
    return d ~= nil and (next(BLOCK_ONLY) == nil or BLOCK_ONLY[d] == true)
end

-- A CEF dialog does not block game input, so a digit would also fire the game's bind; swallow it for the game only.
local WM_KEYDOWN, WM_KEYUP, WM_CHAR = 0x100, 0x101, 0x102

-- A keyup is swallowed only when its keydown was, otherwise the game sees the key as held forever.
local consumedDown = {} -- vkey -> true while a swallowed press is still held.

if BLOCK_DIGITS then
    -- List dialogs only, and not while chat or console input is open.
    addEventHandler('onWindowMessage', function(msg, wparam, lparam)
        if msg == WM_KEYUP then
            if consumedDown[wparam] then
                consumedDown[wparam] = nil
                consumeWindowMessage(true, false)
                dbg('hook: keyup vk=%02X swallowed', wparam)
            end
            return
        end
        -- Called for every window message, so filter by type first.
        if msg ~= WM_KEYDOWN and msg ~= WM_CHAR then return end
        if not isListDialog() or sampIsChatInputActive() or isSampfuncsConsoleActive() then return end
        if msg == WM_KEYDOWN and blocked(NUMKEYS[wparam]) then
            consumedDown[wparam] = true
            consumeWindowMessage(true, false)
            dbg('hook: keydown vk=%02X swallowed', wparam)
        elseif msg == WM_CHAR and wparam >= 0x30 and wparam <= 0x39 then
            -- WM_CHAR carries the character, not the vkey: '0' means digit 10, like NUMKEYS.
            if blocked(wparam == 0x30 and 10 or wparam - 0x30) then consumeWindowMessage(true, false) end
        end
    end)
end

-- Inject JS into the main CEF page (packet 220, sub-type 17).
local function evalcef(code)
    if type(code) ~= 'string' or code == '' or #code > 32767 then return false end
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)
    raknetBitStreamWriteInt32(bs, 0)
    raknetBitStreamWriteInt16(bs, #code)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteString(bs, code)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
    return true
end

-- Page-side singleton: setMode keeps the dialog tweak applied via MutationObserver, press(N) picks item N.
-- Versioned: a live CEF context keeps the old code until script_version changes.
local BOOT_JS = ([==[
(function(){
    var VERSION='__VERSION__';
    var prev=window.__tmDialogPlus;
    if(prev){
        if(prev.version===VERSION)return;
        try{clearInterval(prev.iv);}catch(e){}
        try{if(prev.obs)prev.obs.disconnect();}catch(e){}
        window.__tmDialogPlus=null;
    }
    var ROW='.dialog-list-loop__list-item';
    var NUM_RE=/^\s*\[?(\d+)[\].]/;
    var STRIP_RE=/^\s*(?:\[[^\]]*\]|\d+[.)])\s*/;
    // Grey [N] prefix and data-tmnum on every selectable row: server numbers are kept, unnumbered lists are numbered by position.
    function numberRows(){
        var rows=document.querySelectorAll(ROW);
        if(!rows.length)return;
        var hasNums=false, parsed=[];
        for(var i=0;i<rows.length;i++){
            // Rows numbered by us do not count as server-numbered.
            var m=rows[i].getAttribute('data-tmauto')?null:(rows[i].textContent||'').match(NUM_RE);
            parsed[i]=m?parseInt(m[1],10):null;
            if(m)hasNums=true;
        }
        var auto=0;
        for(var i=0;i<rows.length;i++){
            var row=rows[i], num;
            if(parsed[i]!=null){ num=parsed[i]; }
            else if(!hasNums && (row.textContent||'').trim()!==''){ num=(++auto); row.setAttribute('data-tmauto','1'); }
            else { continue; }
            if(row.getAttribute('data-tmnum')===String(num) && row.querySelector('.tm-num')) continue;
            row.setAttribute('data-tmnum', num);
            var ns=document.createElement('span'); ns.className='tm-num'; ns.style.color='#C0C0C0'; ns.textContent='['+num+'] ';
            // Replace the leading marker in the first non-empty text node with our [N], so a server number is not doubled.
            var w=document.createTreeWalker(row, NodeFilter.SHOW_TEXT, null), tn=null, n;
            while(n=w.nextNode()){ if((n.nodeValue||'').trim()!==''){ tn=n; break; } }
            if(tn){
                var stripped=tn.nodeValue.replace(STRIP_RE,'');
                if(stripped!==tn.nodeValue) tn.nodeValue=stripped;
                tn.parentNode.insertBefore(ns, tn);
            }else{
                var host=row.querySelector('[data-column="1"]')||row;
                host.insertBefore(ns, host.firstChild);
            }
        }
    }
    // MAX on the layout indicator fills in the amount from the "Количество: N ед." line.
    function addMax(){
        var f=document.querySelector('.dialog-input__field');
        var desc=document.querySelector('.dialog-text__description');
        if(!f||!desc)return;
        var m=(desc.textContent||'').match(/\u041a\u043e\u043b\u0438\u0447\u0435\u0441\u0442\u0432\u043e:\s*([\d.\s]+)\u0435\u0434/);
        if(!m)return;
        var max=parseInt(m[1].replace(/[^\d]/g,''),10);
        if(!isFinite(max)||max<=0)return;
        var lang=document.querySelector('.dialog-input__keyboard-language');
        if(!lang)return;
        if(lang.textContent!=='MAX'){ lang.textContent='MAX'; lang.style.cursor='pointer'; lang.style.padding='0 8px'; }
        lang.onclick=function(){
            try{ var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value'); (d&&d.set?d.set:function(v){this.value=v;}).call(f,String(max)); }catch(e){ f.value=String(max); }
            f.dispatchEvent(new Event('input',{bubbles:true}));
            f.dispatchEvent(new Event('change',{bubbles:true}));
            f.focus();
        };
    }
    var mode=null, obs=null, pending=false;
    var OBS_OPTS={childList:true, subtree:true, characterData:true};
    // The observer is off while the tweak runs, or our own edits would re-trigger it.
    function kick(){
        var cur=window.__tmDialogPlus;
        if(!cur||cur.version!==VERSION||!mode)return;
        if(obs)obs.disconnect();
        try{ if(mode==='list')numberRows(); else if(mode==='input')addMax(); }
        catch(e){}
        finally{ if(obs&&mode)obs.observe(document.body, OBS_OPTS); }
    }
    function schedule(){
        if(pending)return;
        pending=true;
        setTimeout(function(){ pending=false; kick(); }, 30);
    }
    // 'list' | 'input' | null as seen by Lua; null stops the observer.
    function setMode(m){
        mode=m||null;
        if(!mode){ if(obs)obs.disconnect(); return; }
        kick();
    }
    // Select row D, or confirm it if it is already active.
    function press(D){
        if(mode==='list')numberRows();
        var rows=document.querySelectorAll(ROW);
        if(!rows.length)return;
        var el=null;
        for(var i=0;i<rows.length;i++){ if(rows[i].getAttribute('data-tmnum')==D){el=rows[i];break;} }
        if(!el){
            var numbered=false;
            for(var i=0;i<rows.length;i++){
                var m=(rows[i].textContent||'').match(NUM_RE);
                if(m){numbered=true; if(parseInt(m[1],10)===D){el=rows[i];break;}}
            }
            if(!el && !numbered && D-1<rows.length) el=rows[D-1];
        }
        if(!el)return;
        if(el.className.indexOf('dialog-list-loop__list-item--active')!==-1){
            var b=document.querySelector('.dialog__button--primary'); if(b)b.click();
        }else{
            el.click();
        }
    }
    obs=new MutationObserver(schedule);
    var iv=setInterval(kick, 1000);
    window.__tmDialogPlus={version:VERSION, obs:obs, iv:iv, kick:kick, setMode:setMode, press:press};
})();
]==]):gsub('__VERSION__', thisScript().version)

-- Bootstrap and mode in one call, so a recreated CEF context gets the singleton back on the next dialog.
local function sendMode(mode)
    evalcef(BOOT_JS .. ('window.__tmDialogPlus&&window.__tmDialogPlus.setMode(%s);'):format(
        mode and ("'" .. mode .. "'") or 'null'))
end

local function pressDigit(d)
    evalcef(('window.__tmDialogPlus&&window.__tmDialogPlus.press(%d);'):format(d))
end

-- ============================================================================
-- SELF-UPDATE (/dpupdate)
-- ============================================================================

local UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/manifest.json'
local UPDATE_BASE_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/'
local UPDATE_SCRIPT_ID = 'dialog-plus'
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

    local ok = atomicReplace(thisScript().path, tempPath)
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
                notify('Доступна новая версия {5CC9FF}v' .. entry.version .. '{FFFFFF}! Обновить: {5CC9FF}/dpupdate')
            end
        end,
        function() end
    )
end

function sampev.onShowDialog(id, style, title, button1, button2, text)
    curStyle = style
    needBoot = true -- no evalcef from inside the packet hook, the main loop sends it.
    shownAt = os.clock()
    dbg('dialog shown: id=%s style=%s title=%s', tostring(id), tostring(style), tostring(title))
end

function main()
    while not isSampAvailable() do wait(0) end
    -- Leftovers of an interrupted update; .old stays as the way back.
    removeIfExists(thisScript().path .. '.tmp')
    removeIfExists(thisScript().path .. '.manifest.tmp')
    wait(1500)

    notify('Загружен {5CC9FF}v' .. thisScript().version .. '{FFFFFF}. В списках пункт выбирается цифрой, повторное нажатие подтверждает. В «Забрать» есть кнопка MAX.')
    sampRegisterChatCommand('dpupdate', checkForUpdate)
    checkForUpdateSilently()

    local sentMode = false -- false = nothing sent yet, nil = no dialog.
    while true do
        wait(0)
        if reloadPending then
            reloadPending = false
            thisScript():reload()
            return
        end
        local mode = (isListDialog() and 'list') or (isInputDialog() and 'input') or nil
        if needBoot or mode ~= sentMode then
            needBoot = false
            sentMode = mode
            sendMode(mode)
            dbg('mode -> %s', tostring(mode))
        end
        -- Digits belong to the chat or console while their input is open.
        if mode == 'list' and not sampIsChatInputActive() and not isSampfuncsConsoleActive() then
            for vk, d in pairs(NUMKEYS) do
                if isKeyJustPressed(vk) then
                    -- The digit that opened the dialog may still be held; counting it would confirm the remembered row.
                    if os.clock() - shownAt < GRACE then
                        dbg('digit %d ignored, dialog just opened', d)
                    else
                        dbg('digit %d pressed (vk=%02X)', d, vk)
                        pressDigit(d)
                    end
                end
            end
        end
    end
end
