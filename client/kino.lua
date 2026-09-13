-- Кинотеатр v7: афиша. Выбор из уже загруженного прямо в игре.
-- usage: kino [server]
-- сервер запоминается: kino https://xxx.ngrok-free.dev (один раз)
-- управление: стрелки + enter, цифры 1-9, ТАП по строке, q - выход
local targs = { ... }
local server = targs[1] or settings.get("rtv.server")
if server then
    if server:sub(-1) == "/" then server = server:sub(1, -2) end
    settings.set("rtv.server", server)
    settings.save()
end
if not server then
    print("usage: kino <server>")
    print("example: kino https://xxx.ngrok-free.dev")
    return
end

local monitor = peripheral.find("monitor")
if not monitor then print("no monitor"); return end
monitor.setTextScale(0.5)
local mw, mh = monitor.getSize()
print("RTV kino v7 @ " .. server)

local headers = { ["ngrok-skip-browser-warning"] = "true" }

local function fmtDur(sec)
    sec = math.floor(sec or 0)
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
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
    -- побайтово собираем UTF-8 символы (кириллица = 2 байта D0/D1 xx)
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

local function fetchLib()
    local ok, r = pcall(http.get, server .. "/library", headers)
    if not ok or not r then return nil end
    local data = r.readAll()
    r.close()
    local j = textutils.unserializeJSON(data)
    if not j or not j.items then return nil end
    return j.items
end

local function shortTitle(it)
    local t = translit(it.title or it.url or it.job_id or "?")
    if #t > mw - 12 then t = t:sub(1, mw - 15) .. "..." end
    return t
end

local function drawMenu(items, sel, scroll)
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.white)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextColour(colours.yellow)
    monitor.write(("=== AFISHA ==="):sub(1, mw))
    monitor.setTextColour(colours.lightGrey)
    monitor.setCursorPos(mw - 7, 1)
    monitor.write(#items .. " kino")
    local firstRow = 3
    local perPage = mh - firstRow
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
        else
            monitor.setBackgroundColour(colours.black)
            monitor.setTextColour(colours.white)
        end
        local num = idx < 10 and (idx .. ". ") or ""
        local line = num .. shortTitle(it) .. " " .. fmtDur(it.duration)
        line = line:sub(1, mw)
        monitor.write(line .. string.rep(" ", mw - #line))
    end
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.grey)
    monitor.setCursorPos(1, mh)
    monitor.write(("up/dn+enter digits tap q-exit"):sub(1, mw))
end

local function playItem(it)
    if not it.url then print("no url"); sleep(1) return end
    -- тот же fps/w/h что в кэше -> мгновенный кэш-хит, без переконвертации
    shell.run("video", it.url, server, tostring(it.fps or 15))
end

while true do
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.white)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write("Loading afisha...")
    local items = fetchLib()
    if not items then
        monitor.setCursorPos(1, 3)
        monitor.write("Server offline")
        print("server offline, retry in 3s (Ctrl+T to exit)")
        sleep(3)
    elseif #items == 0 then
        monitor.setCursorPos(1, 3)
        monitor.write("Pusto. Zakini ssylku:")
        monitor.setCursorPos(1, 4)
        monitor.write("video <rutube> + enter")
        print("empty library")
        sleep(3)
    else
        local sel, scroll = 1, 0
        local perPage = math.max(mh - 3, 1)
        local done = false
        while not done do
            if sel < scroll + 1 then scroll = sel - 1 end
            if sel > scroll + perPage then scroll = sel - perPage end
            drawMenu(items, sel, scroll)
            local ev, p1, p2, p3 = os.pullEvent()
            if ev == "key" then
                if p1 == keys.up then sel = sel - 1 if sel < 1 then sel = #items end
                elseif p1 == keys.down then sel = sel + 1 if sel > #items then sel = 1 end
                elseif p1 == keys.enter then playItem(items[sel])
                elseif p1 == keys.q then return
                elseif p1 >= keys.one and p1 <= keys.nine then
                    local n = p1 - keys.one + 1
                    if items[n] then playItem(items[n]) end
                end
            elseif ev == "monitor_touch" then
                -- p2,p3 = x,y тапа
                local row = p3 - 3 + 1 + scroll
                if row >= 1 and row <= #items then playItem(items[row]) end
            end
        end
    end
end
