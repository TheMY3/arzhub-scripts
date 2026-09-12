script_name('[TM] Inventory Plus')
script_author('TheMY3')
script_version('2.5.0')

-- Тема на форуме (актуальная версия, обсуждение): https://www.blast.hk/threads/255785/

local moonloader = require('moonloader')
local encoding = require('encoding')
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local function cp(s) return u8:decode(s) end

local tag = '{FFA500}[TM] Inventory Plus{FFFFFF}: '

-- Срез словаря имён: 'all' = все предметы, 'market' = только торгуемые на маркете.
-- Если с 'all' словарь грузится слишком долго или не грузится вовсе (в поиске висит «ЗАГРУЗКА...» или «СПИСОК НЕ ЗАГРУЖЕН») — поменяйте на 'market' (менять только слово в кавычках) и перезапустите игру.
local DICT_MODE = 'all'

-- Lavka + wardrobe/warehouse/trunk: search, sort, name dictionary, MAX button in buy/sell dialogs.
local WAREHOUSE_JS = ([[
(() => {
    const VERSION = '__VERSION__';
    //region CONFIG & TEARDOWN - selectors, prior/legacy instance cleanup, shared state
    const GRID_SEL = '.shop__grid-wrapper > .inventory-grid, .warehouse__grid > .inventory-grid';
    const INPUT_ID = 'tm-invplus-search';
    const DICT_MODE = '__DICT_MODE__';
    const ITEMS_URL = 'https://arzhub.top/api/public/marketplace/items/' + DICT_MODE;
    const CACHE_KEY = 'tm-invplus-names-' + DICT_MODE;
    const SORT_KEY = 'tm-invplus-sort-v1';

    const legacy = window.__tmLavkaSearch;
    if (legacy) {
        try { clearInterval(legacy.iv); } catch (e) {}
        try { if (legacy.obs) legacy.obs.disconnect(); } catch (e) {}
        try {
            document.querySelectorAll('#tm-lavka-search').forEach((el) => {
                const w = el.closest('.inventory-search__shop');
                (w || el).remove();
            });
        } catch (e) {}
        try {
            localStorage.removeItem('tm-lavka-names-v1');
            localStorage.removeItem('tm-lavka-sort-v1');
        } catch (e) {}
        window.__tmLavkaSearch = null;
    }

    const prev = window.__tmInvPlus;
    if (prev) {
        if (prev.version === VERSION) { prev.kick(); return; }
        try { clearInterval(prev.iv); } catch (e) {}
        try { if (prev.obs) prev.obs.disconnect(); } catch (e) {}
        try {
            document.querySelectorAll('#' + INPUT_ID).forEach((el) => {
                const w = el.closest('.inventory-search__shop');
                (w || el).remove();
            });
        } catch (e) {}
        window.__tmInvPlus = null;
    }

    const state = { q: '', locked: false, sorted: false, takeAllRunning: false };
    try { state.sorted = localStorage.getItem(SORT_KEY) === '1'; } catch (e) {} // the sort toggle persists across sessions
    let lastGrid = null;

    //endregion

    //region CONST & UTILS - selectors, UI strings, sizing helpers
    const getGrid = () => document.querySelector(GRID_SEL);

    const itemId = (img) => {
        if (!img) return null;
        const a = (img.getAttribute('alt') || '').match(/(\d+)/);
        if (a) return a[1];
        const s = (img.getAttribute('src') || '').match(/(?:donate\/(?:\d+\/)?|items\.zip\/)(\d+)\.webp/);
        return s ? s[1] : null;
    };

    const EMPTY_BG = 'radial-gradient(circle, rgba(255, 255, 255, 0.1) 2%, #131516 66%)';
    const PAD_CLASS = 'tm-pad-cell';
    const PLATE_ID = 'tm-empty-msg';
    const NOT_FOUND_TEXT = '\u041D\u0438\u0447\u0435\u0433\u043E \u043D\u0435 \u043D\u0430\u0439\u0434\u0435\u043D\u043E'; // Ничего не найдено
    const TAKE_ALL_TEXT = '\u0417\u0430\u0431\u0440\u0430\u0442\u044C \u0432\u0441\u0451'; // Забрать всё
    const TAKE_TEXT = '\u0417\u0430\u0431\u0440\u0430\u0442\u044C'; // Забрать
    const STOP_TEXT = '\u041E\u0441\u0442\u0430\u043D\u043E\u0432\u0438\u0442\u044C'; // Остановить
    const PH_SEARCH = '\u041F\u041E\u0418\u0421\u041A'; // ПОИСК
    const PH_LOADING = '\u0417\u0410\u0413\u0420\u0423\u0417\u041A\u0410...'; // ЗАГРУЗКА...
    const PH_FAILED = '\u0421\u041F\u0418\u0421\u041E\u041A \u041D\u0415 \u0417\u0410\u0413\u0420\u0423\u0416\u0415\u041D'; // СПИСОК НЕ ЗАГРУЖЕН
    const LOCK_HINT = '\u0417\u0430\u043F\u043E\u043C\u043D\u0438\u0442\u044C \u043F\u043E\u0438\u0441\u043A'; // Запомнить поиск
    const LOCK_HINT_ON = '\u0417\u0430\u0431\u044B\u0442\u044C \u043F\u043E\u0438\u0441\u043A'; // Забыть поиск
    const SORT_HINT = '\u0421\u043E\u0440\u0442\u0438\u0440\u043E\u0432\u0430\u0442\u044C \u043F\u043E \u043D\u0430\u0437\u0432\u0430\u043D\u0438\u044E'; // Сортировать по названию
    const SORT_HINT_ON = '\u041E\u0442\u043A\u043B\u044E\u0447\u0438\u0442\u044C \u0441\u043E\u0440\u0442\u0438\u0440\u043E\u0432\u043A\u0443'; // Отключить сортировку

    const DLG_COST_ID = 'tm-dlg-cost';
    const T_TRIGGER = '\u043a\u0430\u043a\u043e\u0435 \u043a\u043e\u043b\u0438\u0447\u0435\u0441\u0442\u0432\u043e'; // какое количество
    const T_PLAYER_BUYS = '\u0418\u0433\u0440\u043e\u043a \u043f\u043e\u043a\u0443\u043f\u0430\u0435\u0442'; // Игрок покупает
    const T_YOU_HAVE = '\u0423 \u0432\u0430\u0441 \u0432 \u043d\u0430\u043b\u0438\u0447\u0438\u0438'; // У вас в наличии
    const T_IN_STOCK = '\u0412 \u043d\u0430\u043b\u0438\u0447\u0438\u0438'; // В наличии
    const T_PRICE = '\u0421\u0442\u043e\u0438\u043c\u043e\u0441\u0442\u044c'; // Стоимость
    const T_TOTAL = '\u0418\u0442\u043e\u0433\u043e'; // Итого
    const T_NO_FEE = '(\u0431\u0435\u0437 \u0443\u0447\u0451\u0442\u0430 \u043a\u043e\u043c\u0438\u0441\u0441\u0438\u0438)'; // (без учёта комиссии)

    const ICON_ID = 'tm-invplus-search-ico';
    const LOCK_ID = 'tm-invplus-search-lock';
    const SORT_ID = 'tm-invplus-search-sort';
    const ICON_SEARCH = 'inventory-search__search-icon ui-azpotify-magnifier ';
    const ICON_CLEAR = 'inventory-search__search-close ui-close';

    const gs = (n) => {
        const t = 'var(--global-scale)*' + n + '*var(--global-scale)';
        const d = '(var(--global-scale)*1920 - var(--global-scale)*800)';
        const e = 'calc((' + t + ' - ' + t + '*0.44)/' + d + ')*100vw + calc((' + t + '*0.44 - (' + t + ' - ' + t + '*0.44)/' + d + '*800*var(--global-scale))*1px)';
        return n < 0 ? 'min(' + e + ',-1px)' : 'max(' + e + ',1px)';
    };

    const getCols = (grid) => {
        const raw = (grid.style.getPropertyValue('--columns-count') || '').trim();
        return parseInt(raw, 10) || 5;
    };


    const makePadCell = () => {
        const hoc = document.createElement('div');
        hoc.className = 'inventory-item-hoc ' + PAD_CLASS;
        const item = document.createElement('div');
        item.className = 'inventory-item';
        item.style.setProperty('--bg', EMPTY_BG);
        const overlay = document.createElement('div');
        overlay.className = 'inventory-item__hover-overlay';
        item.appendChild(overlay);
        hoc.appendChild(item);
        return hoc;
    };

    const clearSynthetic = (gridGrid, keepPlate) => {
        gridGrid.querySelectorAll('.' + PAD_CLASS).forEach((el) => el.remove());
        if (keepPlate) return;
        const msg = document.getElementById(PLATE_ID); // the plate lives outside the grid
        if (msg) msg.remove();
    };

    const isWarehouse = (grid) => {
        const w = grid.parentElement;
        return !!(w && w.classList.contains('warehouse__grid'));
    };

    const addPlate = (grid, label, onClick) => {
        const wrapper = grid.parentElement;                       // .shop__grid-wrapper | .warehouse__grid
        const host = (wrapper && wrapper.parentElement) || grid;  // .shop__grid | .warehouse

        const msg = document.createElement('div');
        msg.id = PLATE_ID;
        msg.style.width = '100%';
        msg.style.boxSizing = 'border-box';
        msg.style.padding = gs(8) + ' ' + gs(14) + ' ' + gs(12);

        const shopBtn = document.createElement('div');
        shopBtn.className = 'shop__button';

        const btn = document.createElement('div');
        btn.className = 'inventory-button inventory-button--default';
        btn.style.cursor = 'pointer';

        const text = document.createElement('div');
        text.className = 'inventory-button__text';
        text.textContent = label;

        btn.addEventListener('click', onClick);

        btn.appendChild(text);
        shopBtn.appendChild(btn);
        msg.appendChild(shopBtn);
        host.insertBefore(msg, wrapper ? wrapper.nextSibling : null);
    };

    const NAME_CLASS = 'tm-item-name';
    const labelItem = (hoc, names) => {
        const item = hoc.querySelector('.inventory-item');
        if (!item) return;
        const img = hoc.querySelector('img.inventory-item__image');
        const id = img ? itemId(img) : null;
        const nm = (names && id) ? names[id] : null;
        let el = item.querySelector('.' + NAME_CLASS);
        if (!nm) { if (el) el.remove(); return; }   // no name/dictionary — no banner
        if (!el) {
            if (!item.style.position) item.style.position = 'relative';
            el = document.createElement('div');
            el.className = NAME_CLASS;
            const s = el.style;
            s.position = 'absolute';
            s.top = gs(-1); s.left = gs(-1); s.right = gs(-1);
            s.padding = gs(1) + ' ' + gs(4);
            s.fontSize = gs(10);
            s.lineHeight = '1.25';
            s.background = 'rgba(0, 0, 0, 0.7)';
            s.color = '#fff';
            s.whiteSpace = 'nowrap';
            s.overflow = 'hidden';
            s.textOverflow = 'ellipsis';
            s.borderRadius = gs(10) + ' ' + gs(10) + ' 0 0'; // match the cell's own corner radius
            s.pointerEvents = 'none';
            s.zIndex = '50';
            item.appendChild(el);
        }
        if (el.textContent !== nm) el.textContent = nm;
    };

    const cellName = (hoc, names) => {
        if (!names) return null;
        const img = hoc.querySelector('img.inventory-item__image');
        const id = img ? itemId(img) : null;
        return id ? (names[id] || null) : null;
    };

    const applySort = (gridGrid, names) => {
        const cells = Array.from(gridGrid.querySelectorAll('.inventory-item-hoc:not(.' + PAD_CLASS + ')'));
        if (!cells.length) return;
        let max = 0; // remember the server order once per cell so turning the toggle off can restore it
        cells.forEach((c) => { const v = parseInt(c.dataset.tmIdx || '', 10) || 0; if (v > max) max = v; });
        cells.forEach((c) => { if (!c.dataset.tmIdx) c.dataset.tmIdx = String(++max); });
        const orig = (c) => parseInt(c.dataset.tmIdx, 10) || 0;
        const target = cells.slice().sort((a, b) => {
            if (state.sorted) {
                const na = cellName(a, names), nb = cellName(b, names);
                if (na && nb) return na.localeCompare(nb, 'ru') || (orig(a) - orig(b));
                if (na) return -1;
                if (nb) return 1;
            }
            return orig(a) - orig(b);
        });
        for (let i = 0; i < target.length; i++) {
            if (target[i] !== cells[i]) { target.forEach((c) => gridGrid.appendChild(c)); return; }
        }
    };

    const applyFilter = () => {
        const grid = getGrid();
        if (!grid) return;
        const gridGrid = grid.querySelector('.inventory-grid__grid');
        if (!gridGrid) return;
        const q = state.q.trim();
        const warehouse = isWarehouse(grid);

        // Skip tearing down/rebuilding an already-running take-all plate on every grid mutation - each
        // successful take mutates the grid and would otherwise replace the button out from under a click.
        // Checked by label, not just presence, so the initial switch to STOP_TEXT still happens.
        const existingPlate = document.getElementById(PLATE_ID);
        const existingPlateText = existingPlate && existingPlate.querySelector('.inventory-button__text');
        const plateAlreadyRunning = state.takeAllRunning && !!existingPlateText && existingPlateText.textContent === STOP_TEXT;
        clearSynthetic(gridGrid, plateAlreadyRunning);
        const names = window.__invPlusNames;   // may not be loaded yet
        applySort(gridGrid, names);
        const realCells = gridGrid.querySelectorAll('.inventory-item-hoc:not(.' + PAD_CLASS + ')');

        realCells.forEach((hoc) => labelItem(hoc, names));   // name banners — always

        // Item ids of the given cells - sent straight to Lua instead of query text, so it never has to redo the
        // matching itself (Lua's string.lower() is ASCII-only, doesn't fold Cyrillic case the way JS's does).
        const idsOf = (cells) => {
            const ids = [];
            cells.forEach((hoc) => {
                const img = hoc.querySelector('img.inventory-item__image');
                const id = img && itemId(img);
                if (id) ids.push(id);
            });
            return ids;
        };

        if (!q) {
            realCells.forEach((hoc) => { hoc.style.display = ''; });
            if (warehouse && !plateAlreadyRunning) addPlate(grid, state.takeAllRunning ? STOP_TEXT : TAKE_ALL_TEXT, () => onTakeAllClick(idsOf(realCells)));
            return;
        }

        const parts = q.toLowerCase().split('%').map((p) => p.trim()).filter(Boolean);
        if (!parts.length) {
            realCells.forEach((hoc) => { hoc.style.display = ''; });
            if (warehouse && !plateAlreadyRunning) addPlate(grid, state.takeAllRunning ? STOP_TEXT : TAKE_ALL_TEXT, () => onTakeAllClick(idsOf(realCells)));
            return;
        }

        let matches = 0;
        const matchedCells = [];
        realCells.forEach((hoc) => {
            const img = hoc.querySelector('img.inventory-item__image');
            if (!img) { hoc.style.display = 'none'; return; }   // empty slot — hide while searching
            const id = itemId(img);
            const nm = (id && names) ? names[id] : null;
            const nml = nm && nm.toLowerCase();
            const ok = nml && parts.some((p) => nml.includes(p));
            hoc.style.display = ok ? '' : 'none';
            if (ok) { matches++; matchedCells.push(hoc); }
        });

        const cols = getCols(grid);
        if (matches === 0) {
            for (let i = 0; i < cols; i++) gridGrid.appendChild(makePadCell());
            // Zero matches mid-run just means we cleared the filtered list, not that nothing exists - keep
            // showing the stop plate instead of "not found" (and don't touch it if already showing it).
            if (state.takeAllRunning) {
                if (warehouse && !plateAlreadyRunning) addPlate(grid, STOP_TEXT, () => onTakeAllClick([]));
            } else {
                addPlate(grid, NOT_FOUND_TEXT, () => resetSearch());
            }
        } else {
            const pad = (cols - (matches % cols)) % cols;
            for (let i = 0; i < pad; i++) gridGrid.appendChild(makePadCell());
            if (warehouse && !plateAlreadyRunning) addPlate(grid, state.takeAllRunning ? STOP_TEXT : TAKE_TEXT, () => onTakeAllClick(idsOf(matchedCells)));
        }
    };

    const resetSearch = () => {
        state.q = '';
        const inp = document.getElementById(INPUT_ID);
        if (inp) inp.value = '';
        syncIcon();
        syncLock();
        applyFilter();
    };

    const onTakeAllClick = (ids) => {
        if (state.takeAllRunning) {
            window.cef.SendMessage('tmInvPlusTakeAllStop', 0);
        } else {
            window.cef.SendMessage('tmInvPlusTakeAll|' + ids.join(','), 0);
        }
    };

    const makeTip = (label) => {
        const tip = document.createElement('div');
        tip.className = 'inventory-item__tooltip';
        tip.style.display = 'none';
        tip.style.top = '100%';                    // right below the icon (the stock cell variant overlaps its parent)
        tip.style.transform = 'translateX(-50%)';
        tip.style.marginTop = gs(6);
        const bg = document.createElement('div');
        bg.className = 'inventory-item__tooltip-background';
        const nm = document.createElement('div');
        nm.className = 'inventory-item__tooltip-name';
        nm.textContent = label;
        tip.appendChild(bg);
        tip.appendChild(nm);
        return tip;
    };

    const syncIcon = () => {
        const ico = document.getElementById(ICON_ID);
        if (!ico) return;
        const want = state.q ? ICON_CLEAR : ICON_SEARCH;
        if (ico.className !== want) ico.className = want;
        ico.style.cursor = state.q ? 'pointer' : '';
    };

    const syncLock = () => {
        const lk = document.getElementById(LOCK_ID);
        if (!lk) return;
        if (!state.q && state.locked) state.locked = false;
        lk.style.display = state.q ? '' : 'none';
        let hovered = false;
        try { hovered = lk.matches(':hover'); } catch (e) {}
        lk.style.opacity = (state.locked || hovered) ? '1' : '0.35';
        const nm = lk.querySelector('.inventory-item__tooltip-name');
        const hint = state.locked ? LOCK_HINT_ON : LOCK_HINT;
        if (nm && nm.textContent !== hint) nm.textContent = hint;
    };

    const syncSort = () => {
        const el = document.getElementById(SORT_ID);
        if (!el) return;
        let hovered = false;
        try { hovered = el.matches(':hover'); } catch (e) {}
        el.style.opacity = (state.sorted || hovered) ? '1' : '0.35';
        const nm = el.querySelector('.inventory-item__tooltip-name');
        const hint = state.sorted ? SORT_HINT_ON : SORT_HINT;
        if (nm && nm.textContent !== hint) nm.textContent = hint;
    };

    const ensureInput = () => {
        const grid = getGrid();
        if (!grid) return;
        if (grid !== lastGrid) { // window reopened / tab switched (new grid node) — reset the filter unless the lock keeps it
            lastGrid = grid;
            if (!state.locked) state.q = '';
        }

        let input = grid.querySelector('#' + INPUT_ID);
        if (!input) {
            input = document.createElement('input');
            input.id = INPUT_ID;
            input.type = 'text';
            input.className = 'inventory-search__search-field';
            input.spellcheck = false;
            input.value = state.q;
            input.style.paddingLeft = gs(34); // room for the sort icon
            input.addEventListener('input', (e) => { state.q = e.target.value; syncIcon(); syncLock(); applyFilter(); });

            const icon = document.createElement('i');
            icon.id = ICON_ID;
            icon.className = ICON_SEARCH;
            icon.addEventListener('click', () => { if (state.q) resetSearch(); });

            const lock = document.createElement('i');
            lock.id = LOCK_ID;
            lock.className = 'icon-lock';
            const ls = lock.style;
            ls.position = 'absolute';
            ls.right = gs(48);
            ls.top = '50%';
            ls.transform = 'translateY(-50%)';
            ls.fontSize = gs(18); // visually matches the stock magnifier glyph
            ls.color = '#fff';
            ls.cursor = 'pointer';
            ls.zIndex = '5';
            lock.addEventListener('click', () => { state.locked = !state.locked; syncLock(); });

            const tip = makeTip(LOCK_HINT);
            lock.appendChild(tip);

            lock.addEventListener('mouseenter', () => {
                lock.style.opacity = '1';
                tip.style.display = '';
            });
            lock.addEventListener('mouseleave', () => {
                tip.style.display = 'none';
                syncLock(); // restore the opacity that matches the locked state
            });

            const sort = document.createElement('i');
            sort.id = SORT_ID;
            sort.className = 'icon-refresh-arrows';
            const ss = sort.style;
            ss.position = 'absolute';
            ss.left = gs(14);
            ss.top = '50%';
            ss.transform = 'translateY(-50%)';
            ss.fontSize = gs(18);
            ss.color = '#fff';
            ss.cursor = 'pointer';
            ss.zIndex = '5';
            sort.addEventListener('click', () => {
                state.sorted = !state.sorted;
                try { localStorage.setItem(SORT_KEY, state.sorted ? '1' : '0'); } catch (e) {}
                syncSort();
                applyFilter();
            });
            const sortTip = makeTip(SORT_HINT);
            sortTip.style.left = '0';        // left-align so the plate stays off the window's left edge
            sortTip.style.transform = 'none';
            sort.appendChild(sortTip);
            sort.addEventListener('mouseenter', () => { sortTip.style.display = ''; syncSort(); });
            sort.addEventListener('mouseleave', () => { sortTip.style.display = 'none'; syncSort(); });

            const search = document.createElement('div');
            search.className = 'inventory-search__search';
            search.style.position = 'relative'; // anchor for the absolute lock and sort icons
            search.appendChild(input);
            search.appendChild(icon);
            search.appendChild(lock);
            search.appendChild(sort);

            const wrap = document.createElement('div');
            wrap.className = 'inventory-search inventory-search__shop';
            wrap.style.marginTop = gs(10);
            wrap.style.marginBottom = gs(10);
            wrap.appendChild(search);

            grid.insertBefore(wrap, grid.firstChild);
        }

        const names = window.__invPlusNames;
        const ph = names ? PH_SEARCH
            : (window.__invPlusNamesFailed ? PH_FAILED : PH_LOADING);
        if (input.placeholder !== ph) input.placeholder = ph;
        if (input.disabled === !!names) input.disabled = !names;
        if (!names && input.value && !state.locked) { input.value = ''; state.q = ''; }

        syncIcon();
        syncLock();
        syncSort();
    };

    //endregion

    //region BUY/SELL DIALOG - MAX button + live total
    const numAfter = (text, label) => {
        const i = text.indexOf(label);
        if (i === -1) return null;
        const m = text.slice(i + label.length).match(/(\d[\d.\s ]*)/);
        if (!m) return null;
        const n = parseInt(m[1].replace(/[^\d]/g, ''), 10);
        return isFinite(n) ? n : null;
    };
    const fmtNum = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, '.'); // dot thousands, matching the game's format
    const setText = (el, v) => { if (el.textContent !== v) el.textContent = v; };
    const setFieldValue = (input, val) => {
        try {
            const d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            (d && d.set ? d.set : function (v) { this.value = v; }).call(input, val);
        } catch (e) { input.value = val; }
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        input.focus();
    };

    const enhanceDialog = () => {
        const dlg = document.querySelector('.dialog');
        if (!dlg) return;
        const desc = dlg.querySelector('.dialog-text__description');
        const input = dlg.querySelector('.dialog-input__field');
        if (!desc || !input) return;
        const text = desc.textContent || '';
        if (text.indexOf(T_TRIGGER) === -1) return;

        let max = null;
        if (text.indexOf(T_PLAYER_BUYS) !== -1) {
            const cands = [numAfter(text, T_PLAYER_BUYS), numAfter(text, T_YOU_HAVE)].filter((v) => v != null);
            if (cands.length) max = Math.min.apply(null, cands);
        } else {
            max = numAfter(text, T_IN_STOCK);
        }
        const unit = numAfter(text, T_PRICE);

        const lang = dlg.querySelector('.dialog-input__keyboard-language');
        if (lang && max != null) {
            if (!lang.classList.contains('tm-max-btn')) {
                lang.classList.add('tm-max-btn');
                lang.style.cursor = 'pointer';
                lang.style.padding = '0 8px'; // native width fits "En"; give "MAX" breathing room
            }
            setText(lang, 'MAX');
            lang.onclick = () => setFieldValue(input, String(max)); // property assignment is idempotent across re-runs
        }

        let glyph = '', glyphFont = '';
        const gEl = desc.querySelector('span[style*="client-icons"]');
        if (gEl) {
            glyph = gEl.textContent || '';
            glyphFont = 'client-icons, sans-serif';
        } else {
            const pi = text.indexOf(T_PRICE); // fallback: a plain symbol printed before the price digits
            if (pi !== -1) {
                const mm = text.slice(pi + T_PRICE.length).match(/[:\s]*([^\d\s]+)\s*\d/);
                if (mm) glyph = mm[1];
            }
        }

        if (unit == null) return; // not a priced buy/sell dialog — don't inject an empty total
        const host = dlg.querySelector('.dialog-text__input') || input.parentElement;
        let cost = document.getElementById(DLG_COST_ID);
        if (!cost || !host.contains(cost)) {
            cost = document.createElement('div');
            cost.id = DLG_COST_ID;
            cost.style.cssText = 'margin-top:6px;font-size:0.9em;font-weight:500;color:#67BE55;';
            const lbl = document.createElement('span'); lbl.textContent = T_TOTAL + ': ';
            const cur = document.createElement('span'); cur.className = 'tm-cost-cur'; cur.style.fontFamily = glyphFont; cur.textContent = glyph;
            const val = document.createElement('span'); val.className = 'tm-cost-val';
            const note = document.createElement('span'); note.textContent = ' ' + T_NO_FEE; note.style.cssText = 'opacity:0.55;font-weight:400;';
            cost.appendChild(lbl); cost.appendChild(cur); cost.appendChild(document.createTextNode(' ')); cost.appendChild(val); cost.appendChild(note);
            host.appendChild(cost);
        }
        const curEl = cost.querySelector('.tm-cost-cur');
        const valEl = cost.querySelector('.tm-cost-val');
        setText(curEl, glyph);
        const update = () => {
            const qty = parseInt((input.value || '').replace(/[^\d]/g, ''), 10) || 0;
            const hidden = (!unit || qty <= 0);
            if (cost._tmHidden !== hidden) { cost._tmHidden = hidden; cost.style.display = hidden ? 'none' : ''; }
            if (hidden) { setText(valEl, ''); return; }
            const over = (max != null && qty > max);
            setText(valEl, fmtNum(qty * unit) + (over ? '  (>' + fmtNum(max) + ')' : ''));
            if (cost._tmOver !== over) { cost._tmOver = over; cost.style.color = over ? '#ff6b6b' : '#67BE55'; }
        };
        input.oninput = update;
        update();
    };

    //endregion

    //region ENGINE - observer/kick loop, dictionary loader, boot
    let obs = null;
    const OBS_OPTS = { childList: true, subtree: true };
    const kick = () => {
        const cur = window.__tmInvPlus;
        if (!cur || cur.version !== VERSION) return;
        if (obs) obs.disconnect();
        try { ensureInput(); applyFilter(); try { enhanceDialog(); } catch (e) {} }
        finally { if (obs) obs.observe(document.body, OBS_OPTS); }
    };

    const loadCache = () => {
        try {
            const c = JSON.parse(localStorage.getItem(CACHE_KEY) || 'null');
            return (c && c.items) ? c : null;
        } catch (e) { return null; }
    };
    const saveCache = (etag, items) => {
        try { localStorage.setItem(CACHE_KEY, JSON.stringify({ etag: etag || '', items: items })); } catch (e) {}
    };

    const loadNames = (force) => {
        if (window.__invPlusNamesLoading) return;
        window.__invPlusNamesLoading = true;
        window.__invPlusNamesFailed = false;
        const cached = loadCache();
        if (cached && !window.__invPlusNames) {
            window.__invPlusNames = cached.items;
            kick();
        }
        const opts = { cache: 'no-store', headers: {} };
        let url = ITEMS_URL;
        if (force) {
            url += '?r=' + Date.now();
        } else if (cached && cached.etag) {
            opts.headers['If-None-Match'] = cached.etag;
        }
        fetch(url, opts)
            .then((r) => {
                if (r.status === 304) return null;
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.text().then((t) => {
                    const resp = JSON.parse(t);
                    const items = resp.items;
                    window.__invPlusNames = items;
                    saveCache(r.headers.get('ETag'), items);
                });
            })
            .then(() => { window.__invPlusNamesLoading = false; kick(); })
            .catch((e) => {
                window.__invPlusNamesLoading = false;
                window.__invPlusNamesFailed = !window.__invPlusNames;
                console.log('InvPlus names fetch failed: ' + e);
                kick();
            });
    };
    const reloadNames = () => loadNames(true);

    let kickPending = false;
    const scheduleKick = () => {
        if (kickPending) return;
        kickPending = true;
        setTimeout(() => { kickPending = false; kick(); }, 50);
    };

    obs = new MutationObserver(scheduleKick);
    const iv = setInterval(kick, 1500);

    const setTakeAllRunning = (running) => {
        state.takeAllRunning = !!running;
        applyFilter();
    };

    window.__tmInvPlus = { version: VERSION, kick, obs, iv, state, reloadNames, setTakeAllRunning };
    kick();
    loadNames();
    //endregion
})();
]]):gsub('__VERSION__', thisScript().version):gsub('__DICT_MODE__', DICT_MODE)

-- The player's own "Инвентарь" window: separate script, separate evalcef() call (own 32767-byte budget) —
-- own class names (.inventory-main__grid, not .warehouse__grid), no ПКМ menu in lavka/wardrobe/warehouse at
-- all, so pin only makes sense here.
local INVENTORY_JS = ([[
(() => {
    const VERSION = '__VERSION__';
    const GRID_SEL = '.inventory-main__grid > .inventory-grid';
    const PIN_KEY = 'tm-invplus-pin-v1';
    const PIN_BTN_CLASS = 'tm-pin-btn';
    const PIN_TEXT = '\u0417\u0430\u043a\u0440\u0435\u043f\u0438\u0442\u044c'; // Закрепить
    const UNPIN_TEXT = '\u041e\u0442\u043a\u0440\u0435\u043f\u0438\u0442\u044c'; // Открепить

    const prev = window.__tmInvPin;
    if (prev) {
        if (prev.version === VERSION) { prev.kick(); return; }
        try { clearInterval(prev.iv); } catch (e) {}
        try { if (prev.obs) prev.obs.disconnect(); } catch (e) {}
        window.__tmInvPin = null;
    }

    // Pin is by item TYPE id, not per-stack instance - the server never exposes an instance id for ordinary
    // items (docs/inventory.md's unic_id note), so pinning one stack pins every stack of that type.
    let pinned = new Set();
    try { pinned = new Set(JSON.parse(localStorage.getItem(PIN_KEY) || '[]')); } catch (e) {}
    const savePinned = () => { try { localStorage.setItem(PIN_KEY, JSON.stringify(Array.from(pinned))); } catch (e) {} };

    const getGrid = () => document.querySelector(GRID_SEL);
    const cellId = (hoc) => {
        const img = hoc.querySelector('img.inventory-item__image');
        const a = img && (img.getAttribute('alt') || '').match(/(\d+)/);
        return a ? a[1] : null;
    };

    const applyPinSort = () => {
        const grid = getGrid();
        const gridGrid = grid && grid.querySelector('.inventory-grid__grid');
        if (!gridGrid) return;
        const cells = Array.from(gridGrid.querySelectorAll('.inventory-item-hoc'));
        if (!cells.length) return;

        if (pinned.size) {
            // Garbage-collect ids for items no longer anywhere in this grid (consumed/traded away).
            const present = new Set();
            cells.forEach((c) => { const id = cellId(c); if (id) present.add(id); });
            let changed = false;
            pinned.forEach((id) => { if (!present.has(id)) { pinned.delete(id); changed = true; } });
            if (changed) savePinned();
        }

        const isPinned = (c) => { const id = cellId(c); return !!(id && pinned.has(id)); };

        // Badge position is mirrored off the native top-right .inventory-item__activity-icon (its computed
        // right becomes our left), so it lines up at any resolution - the game sizes everything with a fluid
        // vw formula, fixed px would drift. One probe per pass: getComputedStyle per cell froze the UI before.
        let probe = null;
        const badgeStyle = (item) => {
            if (probe !== null) return probe;
            probe = false;
            const native = item.querySelector('.inventory-item__activity-icon');
            if (!native) return probe;
            try {
                const cs = getComputedStyle(native);
                if (cs.right && cs.right !== 'auto' && cs.top && cs.top !== 'auto') {
                    probe = { top: cs.top, left: cs.right, fontSize: cs.fontSize };
                }
            } catch (e) {}
            return probe;
        };

        // pointer-events:none like the warehouse name banner, so it never intercepts a native click.
        cells.forEach((c) => {
            const item = c.querySelector('.inventory-item');
            let ic = c.querySelector('.tm-pin-icon');
            if (!item) return;
            if (isPinned(c)) {
                if (!ic) {
                    if (!item.style.position) item.style.position = 'relative';
                    ic = document.createElement('i');
                    ic.className = 'tm-pin-icon icon-pin';
                    const s = ic.style;
                    const p = badgeStyle(item);
                    s.position = 'absolute';
                    s.top = p ? p.top : '6%';
                    s.left = p ? p.left : '6%';
                    if (p) s.fontSize = p.fontSize;
                    s.color = '#fff';
                    s.textShadow = '0 0 2px rgba(0,0,0,0.8)';
                    s.pointerEvents = 'none';
                    s.zIndex = '5';
                    item.appendChild(ic);
                }
            } else if (ic) {
                ic.remove();
            }
        });

        // Order only, never move nodes: the grid is a display:grid, and reordering its children behind svelte's
        // back is what broke 2.4.0 - see "Не переставлять узлы игрового DOM" in docs/cef.md.
        cells.forEach((c) => {
            if (isPinned(c)) c.style.order = '-1';
            else if (c.style.order) c.style.removeProperty('order');
        });
    };

    // One-shot cleanup after 2.4.0: a page it already permuted stays that way until the game restarts, and
    // nothing above touches the order any more. Fires only when the grid really is inverted.
    let orderRepaired = false;
    const repairLegacyOrder = () => {
        if (orderRepaired) return;
        const grid = getGrid();
        const gridGrid = grid && grid.querySelector('.inventory-grid__grid');
        if (!gridGrid) return;
        const kids = Array.from(gridGrid.children);
        const isLock = (el) => el.classList.contains('inventory-grid__item-bg');
        const isItem = (el) => el.classList.contains('inventory-item-hoc');
        const firstLock = kids.findIndex(isLock);
        let lastItem = -1;
        kids.forEach((el, i) => { if (isItem(el)) lastItem = i; });
        if (firstLock === -1 || lastItem === -1) return;   // nothing to compare yet
        orderRepaired = true;
        if (firstLock > lastItem) return;                  // already the way the game wants it
        kids.forEach((el) => { if (isLock(el)) gridGrid.appendChild(el); });
        gridGrid.querySelectorAll('[data-tm-pin-idx]').forEach((el) => { delete el.dataset.tmPinIdx; });
    };

    // The menu wrapper (.inventory-item-context-menu-wrapper) lands as a sibling of the right-clicked cell
    // inside the same .inventory-grid__grid, and that cell gets .inventory-item--active - found via a live
    // /debug_dom with the menu open (2026-08-31).
    const enhanceContextMenu = () => {
        const grid = getGrid();
        const gridGrid = grid && grid.querySelector('.inventory-grid__grid');
        const buttons = gridGrid && gridGrid.querySelector('.inventory-info__buttons');
        if (!buttons) return;

        // Don't duplicate a future official pin entry, if Arizona ever ships one.
        const already = Array.from(buttons.children).some((el) => {
            if (el.classList.contains(PIN_BTN_CLASS)) return false;
            const t = (el.textContent || '').trim();
            return t === PIN_TEXT || t === UNPIN_TEXT;
        });
        if (already) return;

        const active = gridGrid.querySelector('.inventory-item--active');
        const hoc = active && active.closest('.inventory-item-hoc');
        const id = hoc && cellId(hoc);
        if (!id) return; // can't resolve the target item - don't inject a button that would do nothing

        let btn = buttons.querySelector('.' + PIN_BTN_CLASS);
        if (!btn) {
            btn = document.createElement('div');
            btn.className = 'inventory-info__button ' + PIN_BTN_CLASS;
            const inner = document.createElement('div');
            inner.className = 'inventory-button inventory-button--default inventory-button--context';
            const icon = document.createElement('i');
            icon.className = 'inventory-button__icon icon-pin inventory-button__icon--small';
            const text = document.createElement('div');
            text.className = 'inventory-button__text inventory-button__text--absolute tm-pin-text';
            inner.appendChild(icon);
            inner.appendChild(text);
            btn.appendChild(inner);
            btn.addEventListener('click', () => {
                const curId = btn.dataset.tmItemId;
                if (!curId) return;
                if (pinned.has(curId)) pinned.delete(curId); else pinned.add(curId);
                savePinned();
                applyPinSort();
                // Native buttons close the menu themselves; ours doesn't hook into that, so trigger the
                // native "Закрыть" button (still the last child - we insert before it) instead of reimplementing it.
                const closeBtn = buttons.lastElementChild;
                const closeInner = closeBtn && closeBtn.querySelector('.inventory-button');
                (closeInner || closeBtn).click();
            });
            buttons.insertBefore(btn, buttons.lastElementChild); // keep the native "Закрыть" last
        }
        btn.dataset.tmItemId = id;
        const textEl = btn.querySelector('.tm-pin-text');
        const label = pinned.has(id) ? UNPIN_TEXT : PIN_TEXT;
        if (textEl.textContent !== label) textEl.textContent = label;
    };

    let obs = null;
    const kick = () => {
        const cur = window.__tmInvPin;
        if (!cur || cur.version !== VERSION) return;
        if (obs) obs.disconnect();
        try { try { repairLegacyOrder(); } catch (e) {} try { applyPinSort(); } catch (e) {} try { enhanceContextMenu(); } catch (e) {} }
        finally { if (obs) obs.observe(document.body, { childList: true, subtree: true }); }
    };

    let kickPending = false;
    const scheduleKick = () => {
        if (kickPending) return;
        kickPending = true;
        setTimeout(() => { kickPending = false; kick(); }, 50);
    };

    obs = new MutationObserver(scheduleKick);
    const iv = setInterval(kick, 1500);
    window.__tmInvPin = { version: VERSION, kick, obs, iv };
    kick();
})();
]]):gsub('__VERSION__', thisScript().version)

local function evalcef(code, encoded)
    -- Code length is written as Int16 -> hard cap of 32767 bytes.
    if type(code) ~= 'string' or code == '' or #code > 32767 then return false end
    encoded = encoded or 0
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)        -- sub-type 17 = eval JS
    raknetBitStreamWriteInt32(bs, 0)        -- browser id (0 = main)
    raknetBitStreamWriteInt16(bs, #code)    -- code length
    raknetBitStreamWriteInt8(bs, encoded)   -- encoded flag
    raknetBitStreamWriteString(bs, code)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
    return true
end

local function inject()
    evalcef(WAREHOUSE_JS)
    evalcef(INVENTORY_JS)
end

-- The dictionary lives in JS; this forces a re-fetch past every cache.
local function reloadNames()
    evalcef("(()=>{if(window.__tmInvPlus&&window.__tmInvPlus.reloadNames)window.__tmInvPlus.reloadNames();})()")
end

-- Real outgoing CEF action (sub-command 18, actually sent to the server) - distinct from evalcef's sub-command 17,
-- which only emulates a local receive and never leaves the client.
local function sendCefAction(str)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #str)
    raknetBitStreamWriteString(bs, str)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

-- Arizona's own toast (event.notify.initialize), triggered locally without server involvement.
-- Used here instead of chat: the warehouse window covers the chat anyway. title/text go through
-- cp(), same as every sampAddChatMessage call in this file.
local function notifyToast(kind, title, text, ms)
    local function esc(s) return (s:gsub('\\', '\\\\'):gsub('"', '\\"')) end
    evalcef(('window.executeEvent("event.notify.initialize", "[\\"%s\\", \\"%s\\", \\"%s\\", \\"%s\\"]");')
        :format(esc(kind), esc(cp(title)), esc(cp(text)), esc(tostring(ms))))
end

-- Shared by both regions below (dict cache reading and update-manifest reading).
local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

--region PACKET CAPTURE - hidden /ipexport: buffer container snapshots straight off the wire (220/17).
-- Human labels for the type ids confirmed so far; not an allowlist, an unlisted type still exports as "type_N".
local CONTAINER_LABELS = {
    [1] = 'Инвентарь',
    [5] = 'Шкаф дома',
    [7] = 'Мусорка',
    [8] = 'Багажник',
    [13] = 'Лавка',
    [49] = 'Склад уличный',
}

-- ASCII-only, filenames stay Latin (Windows + non-UTF8 io.open path is unverified with Cyrillic). Only for types with a confirmed label above - unconfirmed ones keep the type_N filename.
local CONTAINER_SLUGS = {
    [1] = 'inventory',
    [5] = 'shkaf_doma',
    [7] = 'musorka',
    [8] = 'bagazhnik',
    [13] = 'lavka',
    [49] = 'sklad_ulichny',
}

-- Every inventory-style grid renders 5 columns.
local GRID_COLUMNS = 5

local invBuf = {}        -- invBuf[type][slot] = {item = id, amount = n}, accumulate, never wipe wholesale.
local lastOpenType = nil -- type of the container whose action:0 (full snapshot) arrived most recently, i.e. what's open right now.

local function mergeItems(itemType, items)
    local slots = invBuf[itemType]
    if not slots then
        slots = {}
        invBuf[itemType] = slots
    end
    for _, it in ipairs(items) do
        if it.item then
            slots[it.slot] = { item = it.item, amount = it.amount }
        else
            slots[it.slot] = nil -- absent "item" field is the server's own clear-this-slot signal
        end
    end
end

-- Packet 220, sub-command 17 in. evalcef()'s own emulated packets lack the leading ignored byte real server packets carry, so they safely misalign and bail at the subtype check below.
function onReceivePacket(id, bs)
    if id ~= 220 or not bs then return end
    if raknetBitStreamGetNumberOfBytesUsed(bs) < 3 then return end
    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) ~= 17 then return end
    raknetBitStreamIgnoreBits(bs, 32)
    local length = raknetBitStreamReadInt16(bs)
    local encoded = raknetBitStreamReadInt8(bs)
    local str = (encoded ~= 0)
        and raknetBitStreamDecodeString(bs, length + encoded)
        or raknetBitStreamReadString(bs, length)
    if not str or not str:find('event.inventory.playerInventory', 1, true) then return end

    local payload = str:match('`(.+)`')
    if not payload then return end
    local ok, msgs = pcall(decodeJson, payload)
    if not ok or not msgs then return end

    for _, msg in ipairs(msgs) do
        local data = msg.data
        if data and data.items then
            mergeItems(data.type, data.items)
            if msg.action == 0 then lastOpenType = data.type end
        end
    end
end

-- Separate from the JS-side dictionary (used for the search UI) - fetched once via plain Lua HTTP, cached to disk.
local DICT_CACHE_DIR = getWorkingDirectory() .. '\\config\\TheMY3\\inventory-plus'
local DICT_CACHE_PATH = DICT_CACHE_DIR .. '\\items-' .. DICT_MODE .. '.json'
local DICT_URL = 'https://arzhub.top/api/public/marketplace/items/' .. DICT_MODE

-- The .txt output is for the human to open, not for the script itself - kept out of config (settings/cache) in its own top-level folder, same spirit as Debug.lua's config\cef_dumps.
local EXPORT_DIR = getWorkingDirectory() .. '\\dumps\\inventory-plus'

local namesCache = nil -- nil until resolved once; then kept for the rest of the session
local namesFetching = false

local function loadNamesFromDisk()
    local content = readFile(DICT_CACHE_PATH)
    if not content then return nil end
    local ok, data = pcall(decodeJson, content)
    if ok and data and data.items then return data.items end
    return nil
end

local DICT_FETCH_TIMEOUT = 10 -- seconds
local pendingNameCallbacks = {}

local function resolvePendingNames(names)
    local cbs = pendingNameCallbacks
    pendingNameCallbacks = {}
    for _, cb in ipairs(cbs) do cb(names) end
end

-- Lazy on purpose - only /ipexport ever calls this, so a user who never runs the command never triggers a fetch.
-- onDone(names) fires once resolved: synchronously for a warm cache, or after the download/timeout race for a cold one - the caller never needs to retry by hand.
local function fetchNamesDict(onDone)
    if namesCache then onDone(namesCache) return end
    local cached = loadNamesFromDisk()
    if cached then namesCache = cached onDone(namesCache) return end

    pendingNameCallbacks[#pendingNameCallbacks + 1] = onDone
    if namesFetching then return end -- already in flight, just queued behind it

    namesFetching = true
    sampAddChatMessage(tag .. cp('Качаю словарь имён (разово за сессию)...'), -1)
    if not doesDirectoryExist(DICT_CACHE_DIR) then createDirectory(DICT_CACHE_DIR) end

    local claimed = false
    lua_thread.create(function()
        wait(DICT_FETCH_TIMEOUT * 1000)
        if claimed then return end
        claimed = true
        namesFetching = false
        resolvePendingNames(nil)
    end)

    local dl_status = moonloader.download_status
    downloadUrlToFile(DICT_URL, DICT_CACHE_PATH, function(_, status)
        if claimed then return end -- timeout already fired first
        claimed = true
        namesFetching = false
        if status == dl_status.STATUS_ENDDOWNLOADDATA then namesCache = loadNamesFromDisk() end
        resolvePendingNames(namesCache)
    end)
end

local function containerLabel(t)
    return CONTAINER_LABELS[t] or ('type_' .. tostring(t))
end

local function exportFilename(t)
    local slug = CONTAINER_SLUGS[t] or ('type_' .. tostring(t))
    return EXPORT_DIR .. '\\' .. os.date('%Y%m%d_%H%M%S') .. '_' .. slug .. '.txt'
end

-- Chat display only - the real path handed to io.open stays the full one from exportFilename().
local function shortPath(p)
    local wd = getWorkingDirectory()
    if p:sub(1, #wd) == wd then return 'moonloader' .. p:sub(#wd + 1) end
    return p
end

local UTF8_BOM = '\239\187\191'

local function doExport()
    if not lastOpenType or not invBuf[lastOpenType] then
        sampAddChatMessage(tag .. cp('Сначала открой шкаф/склад/багажник (или любое другое окно с предметами) и повтори {5CC9FF}/ipexport'), -1)
        return
    end

    fetchNamesDict(function(names)
        if not names then
            sampAddChatMessage(tag .. cp('Не удалось скачать словарь имён (нет сети или таймаут). Повтори {5CC9FF}/ipexport{FFFFFF}.'), -1)
            return
        end

        -- One line per occupied slot, never merged by item id - the point is "what's in which cell", not a total count.
        local slots = {}
        for slot in pairs(invBuf[lastOpenType]) do slots[#slots + 1] = slot end
        table.sort(slots)

        if #slots == 0 then
            sampAddChatMessage(tag .. cp('Контейнер пуст, экспортировать нечего.'), -1)
            return
        end

        if not doesDirectoryExist(EXPORT_DIR) then createDirectory(EXPORT_DIR) end

        -- Both the header and item names below are already UTF-8 on disk, no cp() - that decodes CP1251, which is what SAMP chat wants but corrupts a plain UTF-8 text file.
        local lines = {
            containerLabel(lastOpenType) .. ' - ' .. os.date('%Y-%m-%d %H:%M') .. ', слотов занято: ' .. #slots,
            '',
        }
        -- Blank line at every row boundary, mirroring the grid's own 5-column layout (GRID_COLUMNS) - lets a line's position on screen be read straight off the file.
        local lastRow = nil
        for _, slot in ipairs(slots) do
            local row = math.floor(slot / GRID_COLUMNS)
            if lastRow and row ~= lastRow then lines[#lines + 1] = '' end
            lastRow = row
            local entry = invBuf[lastOpenType][slot]
            local nm = names[tostring(entry.item)] or ('ID:' .. entry.item)
            -- 1-based slot number as the line label - not a running count, so gaps (empty slots) stay visible instead of hiding which cells are empty.
            lines[#lines + 1] = (slot + 1) .. '. ' .. nm .. ' x' .. (entry.amount or 0)
        end

        local fname = exportFilename(lastOpenType)
        local f = io.open(fname, 'wb')
        if not f then
            sampAddChatMessage(tag .. cp('Не удалось создать файл экспорта.'), -1)
            return
        end
        f:write(UTF8_BOM .. table.concat(lines, '\r\n'))
        f:close()

        sampAddChatMessage(tag .. cp('Экспортировано слотов: ') .. #slots .. cp(' -> {5CC9FF}') .. shortPath(fname), -1)
    end)
end

-- Hidden "Забрать всё"/"Забрать" plate: same invBuf/amount data as /ipexport, but instead of writing a file it
-- moves every matching slot into the player's own inventory, one moveItemForce per slot.
local TAKEALL_SLOT_TIMEOUT = 2 -- seconds to wait for a slot to clear before giving up on the whole run
local takeAllRunning = false
local takeAllStopRequested = false

local function setTakeAllRunningJS(running)
    evalcef('(()=>{if(window.__tmInvPlus&&window.__tmInvPlus.setTakeAllRunning)window.__tmInvPlus.setTakeAllRunning('
        .. (running and 'true' or 'false') .. ');})()')
end

-- ids is the set of item ids JS already decided to show (as strings) - matching happens once, in JS, not
-- duplicated here. An empty table means nothing to take.
local function startTakeAll(ids)
    if takeAllRunning then return end
    local containerType = lastOpenType
    if not containerType or not invBuf[containerType] then
        notifyToast('info', 'Inventory Plus', 'Нечего забирать', 2500)
        return
    end

    local wanted = {}
    for _, id in ipairs(ids) do wanted[id] = true end

    local slots = {}
    for slot, entry in pairs(invBuf[containerType]) do
        if wanted[tostring(entry.item)] then slots[#slots + 1] = slot end
    end
    if #slots == 0 then
        -- invBuf can have moved on since the click (item taken/moved elsewhere in the meantime).
        notifyToast('info', 'Inventory Plus', 'Нечего забирать', 2500)
        return
    end
    table.sort(slots)

    takeAllRunning = true
    takeAllStopRequested = false
    setTakeAllRunningJS(true)

    lua_thread.create(function()
        local stuck = false
        for _, slot in ipairs(slots) do
            if takeAllStopRequested then break end
            local entry = invBuf[containerType][slot]
            if entry then
                sendCefAction(('inventory.moveItemForce|{"slot": %d, "type": %d, "amount": %d}')
                    :format(slot, containerType, entry.amount or 1))

                local waited = 0
                while invBuf[containerType][slot] and not takeAllStopRequested
                    and waited < TAKEALL_SLOT_TIMEOUT * 1000 do
                    wait(50)
                    waited = waited + 50
                end

                if invBuf[containerType][slot] and not takeAllStopRequested then
                    stuck = true -- no confirmation at all - likely own inventory full, further slots would fail the same way
                    break
                end
            end
        end

        takeAllRunning = false
        setTakeAllRunningJS(false)
        if stuck then
            notifyToast('error', 'Inventory Plus', 'Остановлено — похоже, инвентарь переполнен', 4000)
        elseif not takeAllStopRequested then
            notifyToast('success', 'Inventory Plus', 'Забрано предметов: ' .. #slots, 3000)
        end
    end)
end

local TAKEALL_TRIGGER = 'tmInvPlusTakeAll|'
local TAKEALL_STOP_TRIGGER = 'tmInvPlusTakeAllStop'

-- Packet 220, sub-command 18 out - a real outgoing action, unlike onReceivePacket above (17 in). window.cef.SendMessage
-- routes through here; we suppress our own made-up action names (return false) so the server never sees them.
function onSendPacket(id, bs)
    if id ~= 220 then return end
    raknetBitStreamIgnoreBits(bs, 8)
    if raknetBitStreamReadInt8(bs) ~= 18 then
        raknetBitStreamSetReadOffset(bs, 0)
        return
    end
    local len = raknetBitStreamReadInt16(bs)
    local ok, str = pcall(raknetBitStreamReadString, bs, len)
    raknetBitStreamSetReadOffset(bs, 0)
    if not ok or not str then return end

    if str:find(TAKEALL_TRIGGER, 1, true) == 1 then
        local ids = {}
        for id in str:sub(#TAKEALL_TRIGGER + 1):gmatch('[^,]+') do ids[#ids + 1] = id end
        startTakeAll(ids)
        return false
    end
    if str:find(TAKEALL_STOP_TRIGGER, 1, true) == 1 then
        takeAllStopRequested = true
        return false
    end
end
--endregion

--region SELF-UPDATE

-- One silent, non-blocking check on load (never downloads, just a heads-up + the command to run); the actual download/install only ever happens via command.
-- Manifest + raw files served from github for now, but later want to try change it to myself.
local UPDATE_MANIFEST_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/manifest.json'
local UPDATE_BASE_URL = 'https://raw.githubusercontent.com/TheMY3/arzhub-scripts/main/'
local UPDATE_SCRIPT_ID = 'inventory-plus'
local UPDATE_MANIFEST_TIMEOUT = 10 -- seconds
local UPDATE_FILE_TIMEOUT = 30 -- seconds, file is bigger than the manifest

local function updateStatus(msg)
    sampAddChatMessage(tag .. cp(msg), -1)
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
-- downloadUrlToFile has no cancel API, so a late callback after a timeout isn't stopped — it just finds the claim already taken and does nothing.
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

-- current -> current.old, tmp -> current; rolls back on failure so a broken rename never leaves neither file in place. current.old is left behind on success as a manual-recovery
-- copy.
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
        updateStatus('Обновление не удалось: скачанный файл не похож на скрипт. Скачайте вручную: {5CC9FF}' .. (entry.topic or ''))
        return
    end
    if gotVersion == thisScript().version then
        -- Manifest already points at the new version but the raw.githubusercontent.com CDN
        -- edge is still serving the previous file — a stale-cache race, not a real failure.
        removeIfExists(tempPath)
        updateStatus('CDN ещё отдаёт старую версию, попробуйте через пару минут: {5CC9FF}/ipupdate')
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
        updateStatus('Обновление не удалось: ' .. err .. '. Скачайте вручную: {5CC9FF}' .. (entry.topic or ''))
        return
    end

    updateStatus('Обновлено до {5CC9FF}v' .. entry.version .. '{FFFFFF}, перезагружаю скрипт...')
    lua_thread.create(function()
        wait(300)
        thisScript():reload()
    end)
end

local function downloadUpdate(entry)
    -- Called from inside the manifest downloadUrlToFile's own callback - calling downloadUrlToFile again immediately (same tick) throws "device or resource busy",
    -- the native downloader hasn't released its handle yet. A tick of delay in its own thread fixes it - the same workaround Fire Helper uses before its own download call.
    lua_thread.create(function()
        wait(250)
        local tempPath = thisScript().path .. '.tmp'
        removeIfExists(tempPath)
        local dl_status = moonloader.download_status
        local claim = withTimeout(UPDATE_FILE_TIMEOUT, function()
            removeIfExists(tempPath)
            updateStatus('Обновление не удалось: таймаут скачивания. Скачайте вручную: {5CC9FF}' .. (entry.topic or ''))
        end)
        downloadUrlToFile(UPDATE_BASE_URL .. entry.path, tempPath, function(_, status)
            if status == dl_status.STATUS_ENDDOWNLOADDATA then
                if claim() then finishUpdate(entry, tempPath) end
            elseif status == dl_status.STATUSEX_ENDDOWNLOAD then
                if claim() then
                    removeIfExists(tempPath)
                    updateStatus('Не удалось скачать обновление. Скачайте вручную: {5CC9FF}' .. (entry.topic or ''))
                end
            end
        end)
    end)
end

-- Fetches manifest.json and hands the entry for UPDATE_SCRIPT_ID to onEntry(entry).
-- onError(why) covers everything else (fetch failure, timeout, bad JSON, missing entry) - exactly one fires.
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
            -- Strictly "remote > local", not "remote ~= local" - downgrade is intentionally unsupported here (a manifest rollback would otherwise fight a newer local dev
            -- build). Picking an older release on purpose is a separate, not-yet-built path: explicit version argument, fetched from that version's GitHub Release asset
            -- (github.com/TheMY3/arzhub-scripts/releases/download/inventory-plus-vX.Y.Z/...), not from entry.path (which always serves the latest).
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
                updateStatus('Доступна новая версия {5CC9FF}v' .. entry.version .. '{FFFFFF}! Обновить: {5CC9FF}/ipupdate')
            end
        end,
        function() end
    )
end
--endregion

function main()
    while not isSampAvailable() do wait(0) end

    -- Remnants of an interrupted update (game closed mid-download etc.) — clean before anything else.
    -- .old is deliberately not touched: it is the previous build, the only way back from an update that turned out broken. One generation at most - atomicReplace overwrites it every time. MoonLoader will not pick it up, the extension is not .lua.
    removeIfExists(thisScript().path .. '.tmp')
    removeIfExists(thisScript().path .. '.manifest.tmp')

    sampRegisterChatCommand('ipreload', function()
        reloadNames()
        sampAddChatMessage(tag .. cp('Запущено обновление списка предметов... Результат можно узнать, открыв любое окно с предметами.'), -1)
    end)

    -- Intentionally not advertised in the boot message below - hidden command.
    sampRegisterChatCommand('ipexport', doExport)
    sampRegisterChatCommand('ipupdate', function()
        checkForUpdate()
    end)

    sampAddChatMessage(tag .. cp('Загружен {5CC9FF}v' .. thisScript().version .. '{FFFFFF}. Принудительно обновить список предметов: {5CC9FF}/ipreload'), -1)
    checkForUpdateSilently()

    -- Delay the first inject: CEF starts asynchronously.
    -- Then re-inject forever: it is the only way to catch a recreated CEF context (reconnect etc.), and within a live context the bootstrap's version guard makes it a cheap no-op.
    -- Local packet emulation — no network traffic.
    wait(2000)
    while true do
        inject()
        wait(5000)
    end
end
