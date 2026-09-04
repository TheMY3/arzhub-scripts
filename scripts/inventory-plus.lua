script_name('[TM] Inventory Plus')
script_author('TheMY3')
script_version('2.4.0')

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
    //region CONFIG & TEARDOWN — selectors, prior/legacy instance cleanup, shared state
    // Same .inventory-grid component everywhere; only the wrapper differs:
    // lavka is .shop__grid-wrapper, wardrobe/warehouse/trunk share one .warehouse__grid (DOM dumps confirm).
    const GRID_SEL = '.shop__grid-wrapper > .inventory-grid, .warehouse__grid > .inventory-grid';
    const INPUT_ID = 'tm-invplus-search';
    // Substituted from the Lua-side DICT_MODE ('all' | 'market').
    // CACHE_KEY follows the mode so a hand-edit can't serve the old slice from cache (stale ETag would 304 forever).
    const DICT_MODE = '__DICT_MODE__';
    const ITEMS_URL = 'https://arzhub.top/api/public/marketplace/items/' + DICT_MODE;
    const CACHE_KEY = 'tm-invplus-names-' + DICT_MODE;
    const SORT_KEY = 'tm-invplus-sort-v1';

    // One-time teardown of the pre-rename (Lavka Enhancer) instance: the CEF page outlives Lua script reloads,
    // so its interval/observer/input and localStorage keys may still be alive under the old names.
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

    const state = { q: '', locked: false, sorted: false };
    try { state.sorted = localStorage.getItem(SORT_KEY) === '1'; } catch (e) {} // the sort toggle persists across sessions
    let lastGrid = null;
    //endregion

    //region CONST & UTILS — selectors, UI strings, sizing helpers
    const getGrid = () => document.querySelector(GRID_SEL);

    const itemId = (img) => {
        if (!img) return null;
        const a = (img.getAttribute('alt') || '').match(/(\d+)/);
        if (a) return a[1];
        // src fallback: lavka serves donate/<id>.webp, warehouse windows serve items.zip/<id>.webp.
        const s = (img.getAttribute('src') || '').match(/(?:donate\/(?:\d+\/)?|items\.zip\/)(\d+)\.webp/);
        return s ? s[1] : null;
    };

    // Native empty slot (from a DOM dump): .inventory-item with a radial --bg and only .inventory-item__hover-overlay inside. Cloned for pad cells.
    const EMPTY_BG = 'radial-gradient(circle, rgba(255, 255, 255, 0.1) 2%, #131516 66%)';
    const PAD_CLASS = 'tm-pad-cell';
    const PLATE_ID = 'tm-empty-msg';
    const NOT_FOUND_TEXT = '\u041D\u0438\u0447\u0435\u0433\u043E \u043D\u0435 \u043D\u0430\u0439\u0434\u0435\u043D\u043E'; // Ничего не найдено
    const RESET_TEXT = '\u0421\u0431\u0440\u043E\u0441\u0438\u0442\u044C \u043F\u043E\u0438\u0441\u043A'; // Сбросить поиск
    const PH_SEARCH = '\u041F\u041E\u0418\u0421\u041A'; // ПОИСК
    const PH_LOADING = '\u0417\u0410\u0413\u0420\u0423\u0417\u041A\u0410...'; // ЗАГРУЗКА...
    const PH_FAILED = '\u0421\u041F\u0418\u0421\u041E\u041A \u041D\u0415 \u0417\u0410\u0413\u0420\u0423\u0416\u0415\u041D'; // СПИСОК НЕ ЗАГРУЖЕН
    const LOCK_HINT = '\u0417\u0430\u043F\u043E\u043C\u043D\u0438\u0442\u044C \u043F\u043E\u0438\u0441\u043A'; // Запомнить поиск
    const LOCK_HINT_ON = '\u0417\u0430\u0431\u044B\u0442\u044C \u043F\u043E\u0438\u0441\u043A'; // Забыть поиск
    const SORT_HINT = '\u0421\u043E\u0440\u0442\u0438\u0440\u043E\u0432\u0430\u0442\u044C \u043F\u043E \u043D\u0430\u0437\u0432\u0430\u043D\u0438\u044E'; // Сортировать по названию
    const SORT_HINT_ON = '\u041E\u0442\u043A\u043B\u044E\u0447\u0438\u0442\u044C \u0441\u043E\u0440\u0442\u0438\u0440\u043E\u0432\u043A\u0443'; // Отключить сортировку

    // Buy/sell dialog string constants (logic lives in the BUY/SELL DIALOG region below)
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
    // Native icon classes (from DOM dumps): magnifier when idle, close cross while typing — same swap the stock inventory search does.
    const ICON_SEARCH = 'inventory-search__search-icon ui-azpotify-magnifier ';
    const ICON_CLEAR = 'inventory-search__search-close ui-close';

    // The game's fluid size formula (copied verbatim from their CSS): n design px at 1920w shrinking to 0.44*n at 800w, scaled by --global-scale.
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

    //endregion

    //region GRID UI — pad cells, reset plate, name banners, sort, filter, search input
    // Synthetic empty cell that looks like a native empty slot.
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

    const clearSynthetic = (gridGrid) => {
        gridGrid.querySelectorAll('.' + PAD_CLASS).forEach((el) => el.remove());
        const msg = document.getElementById(PLATE_ID); // the plate lives outside the grid
        if (msg) msg.remove();
    };

    // Full-width button plate below the grid (width:100% container outside the grid + a native .inventory-button inside). Click resets the search.
    const addPlate = (grid, label) => {
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

        btn.addEventListener('click', () => resetSearch());

        btn.appendChild(text);
        shopBtn.appendChild(btn);
        msg.appendChild(shopBtn);
        // Right after the grid wrapper, not at the host's end: .warehouse keeps its money block (Пополнить/Снять) below the grid.
        host.insertBefore(msg, wrapper ? wrapper.nextSibling : null);
    };

    // Name banner on top of a cell (single line, ellipsis).
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
            // The banner is positioned off the cell — needs a relative context. Cheap inline-style check: getComputedStyle here caused a freeze.
            if (!item.style.position) item.style.position = 'relative';
            el = document.createElement('div');
            el.className = NAME_CLASS;
            const s = el.style;
            s.position = 'absolute';
            // -1 overlaps the cell's 1px border (absolute offsets start inside it, leaving a bright hairline otherwise).
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

    // Sorting helpers: cells are ordered by dictionary name; unnamed items and empty slots go last.
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
        // Move nodes only when the order actually differs — pointless appendChild churn would retrigger the observer every kick.
        for (let i = 0; i < target.length; i++) {
            if (target[i] !== cells[i]) { target.forEach((c) => gridGrid.appendChild(c)); return; }
        }
    };

    // Show only the matches (they collect at the top, always visible) and pad the last row with synthetic empty cells.
    // A reset plate goes below: "Сбросить поиск" with results, "Ничего не найдено" without (the latter also keeps the window from collapsing).
    const applyFilter = () => {
        const grid = getGrid();
        if (!grid) return;
        const gridGrid = grid.querySelector('.inventory-grid__grid');
        if (!gridGrid) return;
        const q = state.q.trim();

        clearSynthetic(gridGrid);
        const names = window.__invPlusNames;   // may not be loaded yet
        applySort(gridGrid, names);
        const realCells = gridGrid.querySelectorAll('.inventory-item-hoc:not(.' + PAD_CLASS + ')');

        realCells.forEach((hoc) => labelItem(hoc, names));   // name banners — always

        if (!q) {
            realCells.forEach((hoc) => { hoc.style.display = ''; });
            return;
        }

        // '%' separates several searches at once (OR): each part is trimmed, empty parts dropped.
        const parts = q.toLowerCase().split('%').map((p) => p.trim()).filter(Boolean);
        if (!parts.length) {
            realCells.forEach((hoc) => { hoc.style.display = ''; });
            return;
        }

        let matches = 0;
        realCells.forEach((hoc) => {
            const img = hoc.querySelector('img.inventory-item__image');
            if (!img) { hoc.style.display = 'none'; return; }   // empty slot — hide while searching
            const id = itemId(img);
            const nm = (id && names) ? names[id] : null;
            const nml = nm && nm.toLowerCase();
            const ok = nml && parts.some((p) => nml.includes(p));
            hoc.style.display = ok ? '' : 'none';
            if (ok) matches++;
        });

        const cols = getCols(grid);
        if (matches === 0) {
            // One row of empty cells so the grid keeps its normal width.
            for (let i = 0; i < cols; i++) gridGrid.appendChild(makePadCell());
            addPlate(grid, NOT_FOUND_TEXT);
        } else {
            const pad = (cols - (matches % cols)) % cols;
            for (let i = 0; i < pad; i++) gridGrid.appendChild(makePadCell());
            addPlate(grid, RESET_TEXT);
        }
    };

    // Reset the query and the visible input; used by the cross icon and the plate button.
    const resetSearch = () => {
        state.q = '';
        const inp = document.getElementById(INPUT_ID);
        if (inp) inp.value = '';
        syncIcon();
        syncLock();
        applyFilter();
    };

    // Native item-style tooltip (global classes: dark plate + name; the stock arrow is too bulky at this size), to mount under a positioned icon.
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

    // Magnifier while idle, clickable cross while a query is set — same swap the stock inventory search does.
    const syncIcon = () => {
        const ico = document.getElementById(ICON_ID);
        if (!ico) return;
        const want = state.q ? ICON_CLEAR : ICON_SEARCH;
        if (ico.className !== want) ico.className = want;
        ico.style.cursor = state.q ? 'pointer' : '';
    };

    // The lock only makes sense together with a query: hidden (and force-unlocked) while the input is empty.
    // Checks :hover itself — the periodic kick() also lands here and must not strip the hover highlight.
    const syncLock = () => {
        const lk = document.getElementById(LOCK_ID);
        if (!lk) return;
        if (!state.q && state.locked) state.locked = false;
        lk.style.display = state.q ? '' : 'none';
        let hovered = false;
        try { hovered = lk.matches(':hover'); } catch (e) {}
        lk.style.opacity = (state.locked || hovered) ? '1' : '0.35';
        // The hint describes the click action, so it flips with the state.
        const nm = lk.querySelector('.inventory-item__tooltip-name');
        const hint = state.locked ? LOCK_HINT_ON : LOCK_HINT;
        if (nm && nm.textContent !== hint) nm.textContent = hint;
    };

    // Sort toggle: dim when off, bright when on or hovered; the hint flips with the state.
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

    // The input is always mounted with the grid window; the dictionary state drives it: enabled ("ПОИСК") / disabled while loading / disabled with a "СПИСОК НЕ ЗАГРУЖЕН" hint on fetch failure.
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

            // Session-only "remember the query" toggle; icon-lock glyph comes from the game's icon font.
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

            // Hover highlight like the stock cross icon + the tooltip.
            lock.addEventListener('mouseenter', () => {
                lock.style.opacity = '1';
                tip.style.display = '';
            });
            lock.addEventListener('mouseleave', () => {
                tip.style.display = 'none';
                syncLock(); // restore the opacity that matches the locked state
            });

            // Sort-by-name toggle at the left edge of the search row.
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
        // While the dictionary is missing the search cannot work; drop leftover text unless the lock preserves it.
        if (!names && input.value && !state.locked) { input.value = ''; state.q = ''; }

        syncIcon();
        syncLock();
        syncSort();
    };

    //endregion

    //region BUY/SELL DIALOG — MAX button + live total
    // Parse an integer that follows a label; the server prints thousands with dots (e.g. "36.000").
    const numAfter = (text, label) => {
        const i = text.indexOf(label);
        if (i === -1) return null;
        const m = text.slice(i + label.length).match(/(\d[\d.\s ]*)/);
        if (!m) return null;
        const n = parseInt(m[1].replace(/[^\d]/g, ''), 10);
        return isFinite(n) ? n : null;
    };
    const fmtNum = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, '.'); // dot thousands, matching the game's format
    // Set textContent only when it actually changes, so our own writes never trip the MutationObserver into a loop.
    const setText = (el, v) => { if (el.textContent !== v) el.textContent = v; };
    // Native value setter + input/change events, so Svelte's bound state updates (a plain input.value = x is ignored by the framework).
    const setFieldValue = (input, val) => {
        try {
            const d = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
            (d && d.set ? d.set : function (v) { this.value = v; }).call(input, val);
        } catch (e) { input.value = val; }
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
        input.focus();
    };

    // Buy/sell quantity dialog: repurpose the layout indicator (idle while typing digits) as a MAX button, and show a live total under the field.
    const enhanceDialog = () => {
        const dlg = document.querySelector('.dialog');
        if (!dlg) return;
        const desc = dlg.querySelector('.dialog-text__description');
        const input = dlg.querySelector('.dialog-input__field');
        if (!desc || !input) return;
        const text = desc.textContent || '';
        if (text.indexOf(T_TRIGGER) === -1) return;

        // Sell is capped by both the buyer's demand and your stock; buy is capped by the shop's stock.
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

        // Currency icon is a glyph from the game's "client-icons" font, already present in the "Стоимость" line (cash/vcash differ per dialog) — reuse it verbatim so the total matches.
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

    //region ENGINE — observer/kick loop, dictionary loader, boot
    // Disconnect the observer during our own mutations (input/cells/plate), otherwise they would loop the MutationObserver.
    let obs = null;
    const OBS_OPTS = { childList: true, subtree: true };
    const kick = () => {
        // A stale closure (in-flight fetch finishing after a version-change teardown) must not revive the old observer.
        const cur = window.__tmInvPlus;
        if (!cur || cur.version !== VERSION) return;
        if (obs) obs.disconnect();
        try { ensureInput(); applyFilter(); try { enhanceDialog(); } catch (e) {} }
        finally { if (obs) obs.observe(document.body, OBS_OPTS); }
    };

    // Dictionary with a localStorage cache and ETag auto-update.
    // Start instantly from cache, then revalidate with a conditional GET: 304 -> current (headers-only on the wire); 200 -> the list actually changed (~once in months) -> parse, apply, re-cache.
    // Check and update are the same request, so there is nothing to notify the user about.
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

    // Debounce: mounting a grid window floods DOM mutations — collapse them into a single kick (50ms feels instant, without dozens of redundant passes).
    let kickPending = false;
    const scheduleKick = () => {
        if (kickPending) return;
        kickPending = true;
        setTimeout(() => { kickPending = false; kick(); }, 50);
    };

    obs = new MutationObserver(scheduleKick);
    const iv = setInterval(kick, 1500);

    window.__tmInvPlus = { version: VERSION, kick, obs, iv, state, reloadNames };
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

        let max = 0; // remember the server order so unpinning restores it
        cells.forEach((c) => { const v = parseInt(c.dataset.tmPinIdx || '', 10) || 0; if (v > max) max = v; });
        cells.forEach((c) => { if (!c.dataset.tmPinIdx) c.dataset.tmPinIdx = String(++max); });
        const orig = (c) => parseInt(c.dataset.tmPinIdx, 10) || 0;
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

        // Locked (unpurchased) expansion slots are .inventory-grid__item-bg, not .inventory-item-hoc, and they
        // live at the end of the grid. Re-appending items would leave those placeholders sitting in front, so
        // items go before the first non-item child instead (insertBefore(null) == appendChild when there is none).
        const anchor = Array.from(gridGrid.children).find((el) => !el.classList.contains('inventory-item-hoc')) || null;

        const target = cells.slice().sort((a, b) => {
            const pa = isPinned(a) ? 1 : 0, pb = isPinned(b) ? 1 : 0;
            return pa !== pb ? pb - pa : orig(a) - orig(b);
        });
        for (let i = 0; i < target.length; i++) {
            if (target[i] !== cells[i]) { target.forEach((c) => gridGrid.insertBefore(c, anchor)); return; }
        }
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
        try { try { applyPinSort(); } catch (e) {} try { enhanceContextMenu(); } catch (e) {} }
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

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

local function removeIfExists(path)
    if doesFileExist(path) then os.remove(path) end
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
    removeIfExists(thisScript().path .. '.tmp')
    removeIfExists(thisScript().path .. '.old')
    removeIfExists(thisScript().path .. '.manifest.tmp')

    sampRegisterChatCommand('ipreload', function()
        reloadNames()
        sampAddChatMessage(tag .. cp('Запущено обновление списка предметов... Результат можно узнать, открыв любое окно с предметами.'), -1)
    end)

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
