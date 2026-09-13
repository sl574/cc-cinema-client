-- Static Kino v1: афиша кинотеатра с GitHub CDN. ПК и ngrok НЕ нужны.
-- usage:
--   skino              (токен берется из `svideo setup <token>`)
-- управление: стрелки + enter, цифры 1-9, ТАП по строке, q - выход
-- часть 1/2 сама подхватит часть 2 (склейка next в плеере).
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
print("Static Kino v1 @ " .. OWNER .. "/" .. REPO)

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

local function shortTitle(it)
    local t = translit(it.title or it.job_id or "?")
    local tag = " " .. fmtDur(it.duration) .. " " .. fmtRes(it)
    local maxw = mw - #tag
    if maxw < 8 then maxw = 8 end
    if #t > maxw then t = t:sub(1, maxw - 3) .. "..." end
    return t .. tag
end

local function drawMenu(items, sel, scroll)
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.white)
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.setTextColour(colours.yellow)
    monitor.write(("=== KINO ==="):sub(1, mw))
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
        local line = num .. shortTitle(it)
        line = line:sub(1, mw)
        monitor.write(line .. string.rep(" ", mw - #line))
    end
    monitor.setBackgroundColour(colours.black)
    monitor.setTextColour(colours.grey)
    monitor.setCursorPos(1, mh)
    monitor.write(("up/dn+enter digits tap q-exit"):sub(1, mw))
end

local function playItem(it)
    if not it.job_id then print("no job"); sleep(1) return end
    shell.run("svideo", it.job_id)
end

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
                local row = p3 - 3 + 1 + scroll
                if row >= 1 and row <= #items then playItem(items[row]) end
            end
        end
    end
end
