-- Static Kino v2: кинотеатр с GitHub CDN. ПК и ngrok НЕ нужны.
-- usage:
--   skino              (токен берется из `svideo setup <token>`)
-- управление: стрелки + enter, ТАП (строка/карточка/кнопки), q - выход,
--   печать - фильтр, backspace - стереть, esc - сброс фильтра.
-- часть 1/2 сама подхватит часть 2 (склейка next в плеере).
-- постеры: poster.rle из релиза, иначе генеративная мозаика по job_id.
local OWNER = "sl574"
local REPO = "cc-cinema"

local token = settings.get("svideo.token")
if not token then
    print("no token: run svideo setup <token> first")
    return
end

local monitor = peripheral.find("monitor")
if not monitor then print("no monitor"); return end
monitor.setTextScale(0.5)
local mw, mh = monitor.getSize()
print("Static Kino v2 @ " .. OWNER .. "/" .. REPO)

local headers = {
    ["Authorization"] = "Bearer " .. token,
    ["Accept"] = "application/vnd.github+json",
    ["X-GitHub-Api-Version"] = "2022-11-28",
}

-- мини-base64 (в CC нет встроенного): контент afisha.json приходит в base64
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64dec(s)
    s = s:gsub("%s+", "")
    local out = {}
    for i = 1, #s, 4 do
        local n, pad = 0, 0
        for k = 0, 3 do
            local c = s:sub(i + k, i + k)
            if c == "=" or c == "" then
                pad = pad + 1
                n = n * 64
            else
                n = n * 64 + (B64:find(c, 1, true) - 1)
            end
        end
        out[#out + 1] = string.char(math.floor(n / 65536) % 256)
        if pad < 2 then out[#out + 1] = string.char(math.floor(n / 256) % 256) end
        if pad < 1 then out[#out + 1] = string.char(n % 256) end
    end
    return table.concat(out)
end

local function fmtDur(sec)
    sec = math.floor(sec or 0)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function fmtRes(it)
    if it.w and it.h and it.w > 0 then
        return it.w .. "x" .. it.h
    end
    return ""
end

-- CC-шрифт без кириллицы: транслит русских названий
local TR = { ["А"]="A",["Б"]="B",["В"]="V",["Г"]="G",["Д"]="D",["Е"]="E",["Ё"]="Yo",
["Ж"]="Zh",["З"]="Z",["И"]="I",["Й"]="Y",["К"]="K",["Л"]="L",["М"]="M",["Н"]="N",
["О"]="O",["П"]="P",["Р"]="R",["С"]="S",["Т"]="T",["У"]="U",["Ф"]="F",["Х"]="Kh",
["Ц"]="Ts",["Ч"]="Ch",["Ш"]="Sh",["Щ"]="Sch",["Ъ"]="'",["Ы"]="Y",["Ь"]="'",
["Э"]="E",["Ю"]="Yu",["Я"]="Ya",
["а"]="a",["б"]="b",["в"]="v",["г"]="g",["д"]="d",["е"]="e",["ё"]="yo",
["ж"]="zh",["з"]="z",["и"]="i",["й"]="y",["к"]="k",["л"]="l",["м"]="m",["н"]="n",
["о"]="o",["п"]="p",["р"]="r",["с"]="s",["т"]="t",["у"]="u",["ф"]="f",["х"]="kh",
["ц"]="ts",["ч"]="ch",["ш"]="sh",["щ"]="sch",["ъ"]="'",["ы"]="y",["ь"]="'",
["э"]="e",["ю"]="yu",["я"]="ya" }
local function translit(s)
    local out, i = {}, 1
    while i <= #s do
        local b = s:byte(i)
        if (b == 208 or b == 209) and i < #s then
            local ch = s:sub(i, i + 1)
            out[#out + 1] = TR[ch] or "?"
            i = i + 2
        else
            out[#out + 1] = s:sub(i, i)
            i = i + 1
        end
    end
    return table.concat(out)
end

-- asset id из трех форматов files[] (plain id / {id,size} / legacy URL);
-- для постера URL не подходит (нужен id) -> nil
local function assetId(e)
    if type(e) == "table" then return e.id end
    if type(e) == "number" then return e end
    return nil
end

local function assetUrl(id)
    return "https://api.github.com/repos/" .. OWNER .. "/" .. REPO ..
           "/releases/assets/" .. tostring(id)
end

local function fetchAfisha()
    local url = "https://api.github.com/repos/" .. OWNER .. "/" .. REPO ..
                "/contents/afisha.json"
    local ok, r = pcall(http.get, url, headers)
    if not ok or not r then return nil end
    local raw = r.readAll()
    r.close()
    local wrap = textutils.unserializeJSON(raw)
    if not wrap or not wrap.content then return nil end
    local af = textutils.unserializeJSON(b64dec(wrap.content))
    if not af or not af.items then return nil end
    return af.items
end

-- RLE пары (значение, длина), как в sixel-потоке
local function rleDecode(rle)
    local parts = {}
    local p = 1
    while p + 1 <= #rle do
        local v = rle:byte(p)
        local c = rle:byte(p + 1)
        p = p + 2
        parts[#parts + 1] = string.rep(string.char(v), c)
    end
    return table.concat(parts)
end

-- poster.rle: "P" [u16 w][u16 h][48pal] ([u16 len][RLE] x3).
-- Возвращает {w,h,t,f,g,pal} или nil (тогда рисуем мозаику).
local function parsePoster(data)
    if not data or #data < 56 then return nil end
    if data:sub(1, 1) ~= "P" then return nil end
    local w = data:byte(2) * 256 + data:byte(3)
    local h = data:byte(4) * 256 + data:byte(5)
    if w < 1 or h < 1 or w > 64 or h > 64 then return nil end
    local pal = data:sub(6, 53)
    local p = 54
    local vals = {}
    for k = 1, 3 do
        if p + 1 > #data then return nil end
        local ln = data:byte(p) * 256 + data:byte(p + 1)
        p = p + 2
        if p + ln - 1 > #data then return nil end
        vals[k] = rleDecode(data:sub(p, p + ln - 1))
        p = p + ln
    end
    if #vals[1] ~= w * h or #vals[2] ~= w * h or #vals[3] ~= w * h then
        return nil
    end
    return { w = w, h = h, t = vals[1], f = vals[2], g = vals[3], pal = pal }
end

local posterCache = {}
local function getPoster(it)
    local jid = it.job_id
    if posterCache[jid] ~= nil then return posterCache[jid] end
    posterCache[jid] = false
    if not it.files then return nil end
    local id = assetId(it.files["poster.rle"])
    if not id then return nil end
    local h = {
        ["Authorization"] = "Bearer " .. token,
        ["Accept"] = "application/octet-stream",
    }
    local ok, r = pcall(http.get, assetUrl(id), h)
    if not ok or not r then return nil end
    local data = r.readAll()
    r.close()
    local pic = parsePoster(data)
    if pic then posterCache[jid] = pic end
    return pic
end

-- генеративная мозаика-заглушка: симметричный узор из хэша job_id.
-- Рисуется тем же слотом что постер (pw x ph), ф return rows {t,f,g}.
local HEXD = "0123456789abcdef"
local function mosaic(jid, pw, ph)
    local h = 0
    local s = tostring(jid or "?")
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 1000003 end
    local x = h + 12345
    local function rnd(n)
        x = (x * 48271) % 2147483647
        return x % n
    end
    local pal = {}
    for i = 0, 15 do pal[i] = rnd(16) end
    local rows = {}
    for y = 1, ph do
        local t, f, g = {}, {}, {}
        for xx = 1, pw do
            -- зеркалим по вертикали: как постер-обложка
            local sx = xx
            if sx > math.floor((pw + 1) / 2) then sx = pw - xx + 1 end
            local v = (rnd(100) < 12) and 1 or 0
            local slot = pal[(sx * 7 + y * 13 + (v * 5)) % 16]
            t[#t + 1] = " "
            f[#f + 1] = "0"
            g[#g + 1] = HEXD:sub(slot + 1, slot + 1)
        end
        rows[y] = { table.concat(t), table.concat(f), table.concat(g) }
    end
    return rows
end

-- палитра постера -> слоты монитора (и запоминаем было для возврата)
local savedPal = nil
local function pushPalette(pal48)
    if not savedPal then
        savedPal = {}
        for i = 0, 15 do savedPal[i] = { monitor.getPaletteColour(2 ^ i) } end
    end
    for i = 0, 15 do
        local r, g, b = pal48:byte(i * 3 + 1, i * 3 + 3)
        monitor.setPaletteColour(2 ^ i, r / 255, g / 255, b / 255)
    end
end
local function popPalette()
    if savedPal then
        for i = 0, 15 do monitor.setPaletteColour(2 ^ i, table.unpack(savedPal[i])) end
        savedPal = nil
    end
end

-- раскладка: wide = две панели (список + карточка), иначе одна колонка
local WIDE = mw >= 100
local PW, PH = 36, 22          -- слот постера/мозаики в карточке
local LW = mw
local PX = 1
if WIDE then
    LW = mw - 46
    if LW < 40 then LW = 40 end
    PX = LW + 3                -- x карточки (рамка+зазор)
end

local function shortTitle(it, maxw)
    local t = translit(it.title or it.job_id or "?")
    local tag = " " .. fmtDur(it.duration) .. " " .. fmtRes(it)
    if #t + #tag > maxw then
        t = t:sub(1, math.max(maxw - #tag - 3, 1)) .. "..."
    end
    return t .. tag
end

-- карточка выбранного (правая панель). Возвращает ничего.
local function drawCard(it)
    if not WIDE then return end
    local x0 = PX
    local function at(dx, y, s, fg, bg)
        if y < 1 or y > mh - 1 then return end -- за низ = скролл всего меню!
        monitor.setBackgroundColour(bg or colours.black)
        monitor.setTextColour(fg or colours.white)
        monitor.setCursorPos(x0 + dx, y)
        monitor.write((s or ""):sub(1, 43))
    end
    local yTop = 3
    -- рамка карточки
    monitor.setBackgroundColour(colours.grey)
    monitor.setCursorPos(x0, yTop - 1)
    monitor.write(string.rep(" ", 44))
    -- постер или мозаика
    local pic = getPoster(it)
    local prow = yTop
    if pic then
        pushPalette(pic.pal)
        local ox = x0 + math.max(math.floor((44 - pic.w) / 2), 0)
        for y = 0, pic.h - 1 do
            if prow + y > mh - 1 then break end
            local a, b = y * pic.w + 1, (y + 1) * pic.w
            monitor.setCursorPos(ox, prow + y)
            monitor.blit(pic.t:sub(a, b), pic.f:sub(a, b), pic.g:sub(a, b))
        end
        popPalette()
        prow = prow + pic.h + 1
    else
        local rows = mosaic(it.job_id, 32, 12)
        local ox = x0 + 6
        for y = 1, #rows do
            if prow + y - 1 > mh - 1 then break end
            monitor.setCursorPos(ox, prow + y - 1)
            monitor.blit(rows[y][1], rows[y][2], rows[y][3])
        end
        prow = prow + #rows + 1
    end
    -- инфо
    local names = translit(it.title or it.job_id or "?")
    at(0, prow, names:sub(1, 43), colours.yellow); prow = prow + 1
    at(0, prow, fmtDur(it.duration) .. "  " .. fmtRes(it) ..
        "  @" .. tostring(it.fps or "?") .. "fps", colours.lightGrey); prow = prow + 1
    local frames = it.frames or it.total_frames
    if frames then at(0, prow, "frames: " .. frames, colours.lightGrey); prow = prow + 1 end
    at(0, prow, "id " .. tostring(it.job_id or "?"):sub(1, 20), colours.grey); prow = prow + 1
    if it.next then
        at(0, prow, "-> sleduyuschaya chast", colours.lime); prow = prow + 1
    end
    if prow < mh - 1 then
        at(0, mh - 1, "[OK] smotret (tap/enter)", colours.lime)
    end
end

local function drawMenu(items, sel, scroll, filter)
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.white)
    monitor.clear()
    -- шапка
    monitor.setBackgroundColour(colours.blue)
    monitor.setTextColour(colours.yellow)
    monitor.setCursorPos(1, 1)
    local head = "=== KINO ==="
    if filter ~= "" then head = head .. " [" .. filter:sub(1, 20) .. "]" end
    monitor.write(head:sub(1, mw))
    monitor.setTextColour(colours.white)
    local cnt = #items .. " kino"
    monitor.setCursorPos(math.max(mw - #cnt + 1, 1), 1)
    monitor.write(cnt)
    monitor.setBackgroundColour(colours.black)
    -- список
    local firstRow = 3
    local perPage = mh - firstRow - 1
    if perPage < 1 then perPage = 1 end
    for i = 1, perPage do
        local idx = scroll + i
        if idx > #items then break end
        local it = items[idx]
        local y = firstRow + i - 1
        monitor.setCursorPos(1, y)
        if idx == sel then
            monitor.setBackgroundColour(colours.blue)
            monitor.setTextColour(colours.white)
        elseif idx % 2 == 0 then
            monitor.setBackgroundColour(colours.black)
            monitor.setTextColour(colours.lightGrey)
        else
            monitor.setBackgroundColour(colours.black)
            monitor.setTextColour(colours.white)
        end
        local line = shortTitle(it, LW - 4)
        line = line:sub(1, LW)
        monitor.write(line .. string.rep(" ", math.max(LW - #line, 0)))
    end
    monitor.setBackgroundColour(colours.black)
    -- карточка
    if WIDE and items[sel] then drawCard(items[sel]) end
    -- подвал с тап-зонами [◀][OK][▶]
    local fmsg = "up/dn+enter tap q-exit type=filter"
    monitor.setTextColour(colours.grey)
    monitor.setCursorPos(1, mh)
    monitor.write(fmsg:sub(1, mw))
    if WIDE then
        monitor.setTextColour(colours.yellow)
        local lz = "[<]"
        monitor.setCursorPos(1, mh)
        monitor.write(lz:sub(1, 9))
        local okm = "[ OK ]"
        monitor.setCursorPos(math.floor((mw - #okm) / 2) + 1, mh)
        monitor.write(okm)
        monitor.setCursorPos(mw - 3, mh)
        monitor.write("[>]")
    end
end

local function matchFilter(it, f)
    if f == "" then return true end
    local s = string.lower(translit(it.title or "") .. " " .. tostring(it.job_id or ""))
    -- фильтр тоже через транслит: кириллица в вводе должна матчиться
    local ff = string.lower(translit(f))
    return s:find(ff, 1, true) ~= nil
end

local function playItem(it)
    if not it or not it.job_id then print("no job"); sleep(1) return end
    shell.run("svideo", it.job_id)
end

-- narrow: одна колонка + 3 строки инфо + подвал
local function drawNarrow(items, sel, scroll, filter)
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.white)
    monitor.clear()
    monitor.setBackgroundColour(colours.blue)
    monitor.setTextColour(colours.yellow)
    monitor.setCursorPos(1, 1)
    monitor.write(("=== KINO === " .. #items):sub(1, mw))
    monitor.setBackgroundColour(colours.black)
    local firstRow = 3
    local perPage = math.max(mh - firstRow - 4, 1)
    for i = 1, perPage do
        local idx = scroll + i
        if idx > #items then break end
        local y = firstRow + i - 1
        monitor.setCursorPos(1, y)
        if idx == sel then
            monitor.setBackgroundColour(colours.blue)
            monitor.setTextColour(colours.white)
        else
            monitor.setBackgroundColour(colours.black)
            monitor.setTextColour(colours.white)
        end
        local line = shortTitle(items[idx], mw - 2)
        line = line:sub(1, mw)
        monitor.write(line .. string.rep(" ", math.max(mw - #line, 0)))
    end
    monitor.setBackgroundColour(colours.black)
    local it = items[sel]
    if it then
        monitor.setTextColour(colours.yellow)
        monitor.setCursorPos(1, mh - 3)
        monitor.write(translit(it.title or "?"):sub(1, mw))
        monitor.setTextColour(colours.lightGrey)
        monitor.setCursorPos(1, mh - 2)
        monitor.write((fmtDur(it.duration) .. " " .. fmtRes(it)):sub(1, mw))
    end
    monitor.setTextColour(colours.grey)
    monitor.setCursorPos(1, mh)
    monitor.write(("up/dn enter tap q" .. (filter ~= "" and " [" .. filter .. "]" or "")):sub(1, mw))
end

local selJob = nil
while true do
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.white)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Loading afisha...")
    local items = fetchAfisha()
    if not items then
        monitor.setCursorPos(1, 3)
        monitor.write("CDN offline (check token)")
        print("cdn offline, retry in 3s (Ctrl+T to exit)")
        sleep(3)
    elseif #items == 0 then
        monitor.setCursorPos(1, 3)
        monitor.write("Pusto. Zalei filmy!")
        print("empty afisha")
        sleep(3)
    else
        local sel, scroll, filter = 1, 0, ""
        if selJob then
            for i, it in ipairs(items) do
                if it.job_id == selJob then sel = i break end
            end
        end
        local perPage = math.max((WIDE and (mh - 4) or (mh - 7)), 1)
        local view = items
        local function applyFilter()
            view = {}
            for _, it in ipairs(items) do
                if matchFilter(it, filter) then view[#view + 1] = it end
            end
            sel, scroll = 1, 0
        end
        local done = false
        while not done do
            if sel < 1 then sel = 1 end
            if sel > #view then sel = math.max(#view, 1) end
            if sel < scroll + 1 then scroll = sel - 1 end
            if sel > scroll + perPage then scroll = sel - perPage end
            if WIDE then drawMenu(view, sel, scroll, filter)
            else drawNarrow(view, sel, scroll, filter) end
            local ev, p1, p2, p3 = os.pullEvent()
            if ev == "key" then
                if p1 == keys.up then
                    sel = sel - 1
                    if sel < 1 then sel = #view end
                elseif p1 == keys.down then
                    sel = sel + 1
                    if sel > #view then sel = 1 end
                elseif p1 == keys.enter then
                    if view[sel] then
                        selJob = view[sel].job_id
                        playItem(view[sel])
                    end
                elseif p1 == keys.q then
                    return
                elseif p1 == keys.backspace then
                    filter = filter:sub(1, -2)
                    applyFilter()
                elseif p1 == keys.esc then
                    if filter ~= "" then filter = "" applyFilter() end
                end
            elseif ev == "char" then
                -- ВЕСЬ ввод текста только отсюда (key event несет скан-коды,
                -- а не буквы!). p1 = напечатанный символ (включая пробел).
                filter = (filter .. string.lower(p1)):sub(1, 24)
                applyFilter()
            elseif ev == "monitor_touch" then
                if p3 == 1 or p3 == 2 then
                    -- тап по шапке = сброс фильтра
                    if filter ~= "" then filter = "" applyFilter() end
                elseif p3 == mh then
                    -- подвал: [<] [OK] [>]
                    if p2 <= math.floor(mw / 3) then
                        scroll = math.max(scroll - perPage, 0)
                        sel = scroll + 1
                    elseif p2 > math.floor(mw * 2 / 3) then
                        scroll = scroll + perPage
                        if scroll > #view - 1 then scroll = math.max(#view - 1, 0) end
                        sel = scroll + 1
                    else
                        if view[sel] then
                            selJob = view[sel].job_id
                            playItem(view[sel])
                        end
                    end
                elseif WIDE and p2 > LW then
                    -- тап по карточке = играть выбранное
                    if view[sel] then
                        selJob = view[sel].job_id
                        playItem(view[sel])
                    end
                else
                    local row = p3 - 3 + 1 + scroll
                    if row >= 1 and row <= #view then
                        selJob = view[row].job_id
                        playItem(view[row])
                    end
                end
            end
        end
    end
end
