-- Static TV: playback from GitHub Releases CDN, no PC/ngrok needed.
-- usage:
--   svideo setup <token>   - save read-only token once (settings)
--   svideo <job_id> [fps] [from_sec]
-- example: svideo 46294e34f1d32d049252 20
-- pause: tap monitor / space
--
-- v8 "анти-пленка": сервер MC шлет снимок монитора клиентам РАЗ В ТИК.
-- Раньше кадр рисовался 40-70 блитами с Lua-работой между ними, и снимок
-- регулярно падал посреди отрисовки: верх - новый кадр, низ - старый,
-- шов гуляет = "пленка". Плюс DFPWM-декод (65К сэмплов) и разбор пачек
-- держали комп 50-500мс, видеотаймер ждал, потом кадры летели пачкой.
-- Теперь: вся Lua-работа (RLE, патч дельт) - ДО сна; после пробуждения
-- таймера (начало тика) - только ПЛОТНАЯ серия блитов изменившихся строк
-- (~1-2мс) + палитра. Не больше одного кадра на тик. При отставании дельты
-- ПРИМЕНЯЮТСЯ к базе без показа (а не выбрасываются) - база цельная,
-- шлейфа нет. Звук декодируется кусками по 512 байт с yield между.
-- svideo_dbg.lua = ЭТОТ ЖЕ файл (копия): телеметрия в углу включается
-- по имени программы (*dbg*), отдельную версию не поддерживаем.
local OWNER = "sl574"
local REPO = "cc-cinema"
local AFISHA_URL = "https://raw.githubusercontent.com/" .. OWNER .. "/" .. REPO .. "/main/afisha.json"

local args = { ... }
if args[1] == "setup" and args[2] then
    settings.set("svideo.token", args[2])
    -- БЕЗ save() токен жил только до reboot (вот почему его "не помнило")!
    settings.save()
    print("token saved (" .. #args[2] .. " chars, survives reboot).")
    print("delete this message history!")
    return
end
local jobid = args[1]
local fpsArg = tonumber(args[2])
local fromSec = tonumber(args[3]) or 0
if fromSec < 0 then fromSec = 0 end
-- 4-й аргумент: лимит колонок (диагностика топологии/перфа:
-- дальняя/подвисшая колонка тормозит всех через общий wait).
-- Например: svideo <job> 20 0 1 (только первая колонка).
local maxSpk = tonumber(args[4])
-- fps для расчета окна: файлы уже сняты на своей частоте, meta позже уточнит
local fps = 20
if fpsArg then fps = math.max(1, math.min(30, fpsArg)) end

local token = settings.get("svideo.token")
if not jobid then
    print("usage: svideo setup <token> | svideo <job_id> [fps] [from_sec] [maxspk]")
    return
end
if not token then
    print("no token: run svideo setup <token> first")
    return
end

local DEBUG = (shell and shell.getRunningProgram() or ""):lower():find("dbg") ~= nil

local monitor = peripheral.find("monitor")
if not monitor then print("no monitor"); return end
monitor.setTextScale(0.5)
local mw, mh = monitor.getSize()
print("RTV v8 monitor: " .. mw .. "x" .. mh .. " fps: " .. fps .. (DEBUG and " [dbg]" or ""))

-- стандартные 16 цветов CC: сбрасываем палитру при старте,
-- иначе оборванный прошлый показ оставляет "невидимые чернила"
local DEFAULT_PAL = {
    {240,240,240},{242,178,51},{229,127,216},{153,178,242},
    {222,222,108},{127,204,25},{242,178,204},{76,76,76},
    {153,153,153},{76,153,178},{178,102,229},{51,102,204},
    {127,102,76},{87,166,78},{204,76,76},{17,17,17},
}
for i = 0, 15 do
    local c = DEFAULT_PAL[i + 1]
    monitor.setPaletteColour(2 ^ i, c[1] / 255, c[2] / 255, c[3] / 255)
end

local vw, vh = mw, mh
local ox, oy = 1, 1

local savedPal = {}
for i = 0, 15 do savedPal[i] = { monitor.getPaletteColour(2 ^ i) } end
local function restorePalette()
    for i = 0, 15 do monitor.setPaletteColour(2 ^ i, table.unpack(savedPal[i])) end
end

-- ВСЕ динамики: вплотную + по проводной сети (wired modem + кабель).
-- Дальним колонкам нужен проводной модем у компа и у колонки.
local speakers = { peripheral.find("speaker") }
if maxSpk and maxSpk >= 1 and #speakers > maxSpk then
    print("speakers: " .. #speakers .. " -> using first " .. maxSpk)
    local cut = {}
    for i = 1, maxSpk do cut[i] = speakers[i] end
    speakers = cut
end
if #speakers == 0 then print("no speaker - only video")
else print("speakers: " .. #speakers) end

local dfpwm = nil
if #speakers > 0 then
    local ok, lib = pcall(require, "cc.audio.dfpwm")
    if ok then dfpwm = lib
    else print("no dfpwm lib - sound off") speakers = {} end
end

local headers = {
    ["Authorization"] = "Bearer " .. token,
    ["Accept"] = "application/octet-stream",
}

local function assetUrl(e)
    -- files[] в афише бывает трех форматов: plain asset-id (rebuild_afisha),
    -- {id=...,size=...} (upload.py) и прямая URL-строка (legacy). Едим все.
    local id = e
    if type(e) == "table" then id = e.id end
    if type(id) == "string" and id:sub(1, 4) == "http" then return id end
    return "https://api.github.com/repos/" .. OWNER .. "/" .. REPO ..
           "/releases/assets/" .. tostring(id)
end

local function drawProgress(title, percent, sub)
    percent = percent or 0
    monitor.clear()
    monitor.setCursorPos(1, 1)
    monitor.write(title:sub(1, mw))
    local barw = mw - 2
    if barw < 10 then barw = 10 end
    local filled = math.floor(barw * percent / 100)
    monitor.setCursorPos(1, 3)
    monitor.write("[" .. string.rep("#", filled) .. string.rep("-", barw - filled) .. "]")
    monitor.setCursorPos(1, 5)
    monitor.write(tostring(percent) .. "%")
    if sub then
        monitor.setCursorPos(1, 7)
        monitor.write(sub:sub(1, mw))
    end
end

local function httpGetRetry(u, tries)
    tries = tries or 3
    for i = 1, tries do
        local ok, r = pcall(http.get, u, headers)
        if ok and r then return r end
        sleep(0.3)
    end
    return nil
end

-- Range fetch: returns body string or nil. Warns if server ignored Range.
-- Prints last error on total failure (else silent deaths).
local function httpRangeRetry(u, first, last, tries)
    tries = tries or 3
    local h = {
        ["Authorization"] = "Bearer " .. token,
        ["Accept"] = "application/octet-stream",
        ["Range"] = "bytes=" .. first .. "-" .. last,
    }
    local lastErr = ""
    for i = 1, tries do
        local ok, r, e2 = pcall(http.get, u, h)
        if ok and r then
            local data = r.readAll()
            r.close()
            local want = last - first + 1
            if #data ~= want then
                print("range warn: want " .. want .. " got " .. #data)
            end
            return data
        else
            lastErr = tostring(e2 or r or "request failed")
        end
        sleep(0.3)
    end
    print("range fail [" .. first .. "-" .. last .. "]: " .. lastErr)
    return nil
end

drawProgress("CDN...", 0)

-- 1. afisha -> files{}
local afResp = httpGetRetry(AFISHA_URL, 3)
if not afResp then print("cdn offline"); drawProgress("CDN offline", 0) restorePalette() return end
local afData = textutils.unserializeJSON(afResp.readAll())
afResp.close()
if not afData or not afData.items then print("bad afisha") restorePalette() return end
local files = nil
local foundTitle = nil
for _, it in ipairs(afData.items) do
    if it.job_id == jobid then files, foundTitle = it.files, it.title break end
end
if not files then
    print("job not in afisha:")
    for _, it in ipairs(afData.items) do print(" " .. (it.job_id or "?")) end
    restorePalette()
    return
end
print("CDN: " .. (foundTitle or jobid))

-- 2. meta.json (small, direct, via asset id)
local metaResp = httpGetRetry(assetUrl(files["meta.json"]), 3)
if not metaResp then print("no meta") restorePalette() return end
local meta = textutils.unserializeJSON(metaResp.readAll())
metaResp.close()
if not meta or not meta.total_frames then print("bad meta") restorePalette() return end

if (meta.proto or 0) < 6 then
    print("files too old, re-upload job!")
    drawProgress("Re-upload job!", 0)
    restorePalette()
    return
end
if (meta.proto or 0) < 7 then
    print("note: old encode (proto 6, per-GOP colors) - reconvert for stable colors")
end

-- 3. sixel.idx fully (tiny: 4 bytes x frames)
drawProgress("CDN index...", 0)
local idxData = httpGetRetry(assetUrl(files["sixel.idx"]), 3)
if not idxData then print("no idx") restorePalette() return end
local idxRaw = idxData.readAll()
idxData.close()
local idx0 = {}
for i = 1, math.floor(#idxRaw / 4) do
    -- индекс на сервере little-endian (struct "<I")!
    local o = (i - 1) * 4
    idx0[i] = idxRaw:byte(o + 1) + idxRaw:byte(o + 2) * 256 +
              idxRaw:byte(o + 3) * 65536 + idxRaw:byte(o + 4) * 16777216
end
if #idx0 < 2 then print("bad idx") restorePalette() return end

local job = jobid
print("job: " .. job .. " (static)")

vw, vh = meta.w, meta.h
ox = math.floor((mw - vw) / 2) + 1
oy = math.floor((mh - vh) / 2) + 1
fps = meta.fps
if fpsArg and fpsArg ~= fps then
    print("note: static fps is " .. fps .. ", arg ignored")
end
if vw > mw or vh > mh then
    print("monitor too small for this video!")
    drawProgress("Small monitor", 0)
    restorePalette()
    return
end
local cell = vw * vh
-- кеп очереди в КЛЕТКАХ (~700к): 121x49 -> ~118 кадров, фулскрин 164x67 ->
-- ~63 кадра. Фикс 120 кадров на фулскрине ронял бы комп по памяти.
local maxVQueue = math.max(12, math.floor(700000 / cell))

local total_frames = meta.total_frames
if #idx0 ~= total_frames + 1 then
    print("idx warn: " .. #idx0 .. " vs frames " .. total_frames)
    -- по индексу режем записи: без оффсета кадр не достать
    if #idx0 < total_frames + 1 then total_frames = #idx0 - 1 end
end
local duration = meta.duration or 0
local dchunk = meta.audio_dfpwm_chunk or 8192
local dtotal = meta.audio_dfpwm_total or 0
local total_dchunks = (#speakers > 0 and dfpwm and dtotal > 0) and math.ceil(dtotal / dchunk) or 0

-- старт с секунды: округляем кадр ВНИЗ до кейфрейма, иначе первые дельты не на что класть
local keyint = meta.keyint or 30
local startFrame = math.floor(fromSec * fps)
if startFrame >= total_frames then startFrame = 0 end
startFrame = math.floor(startFrame / keyint) * keyint
local startChunk = 0
if total_dchunks > 0 then
    startChunk = math.floor((startFrame / fps) * 48000 / 65536)
    if startChunk >= total_dchunks then startChunk = 0 end
end
print("ready: GOP frames=" .. total_frames .. " audio=" .. total_dchunks ..
      " " .. vw .. "x" .. vh .. "@" .. fps .. " from=" .. startFrame .. "/" .. startChunk)
print("screen: mon=" .. mw .. "x" .. mh .. " win=" .. vw .. "x" .. vh .. " at=" .. ox .. "," .. oy)
-- заливаем ВЕСЬ монитор черным, чтобы не было мусора по краям окна
monitor.setBackgroundColour(colours.black)
monitor.clear()

local BATCH_V = 60
local BATCH_A = 24

local vQueue = {} -- сырые записи (строки), первый байт = тип K/D/R
local aQueue = {}
local fetch_done = false
local paused = false
local finished = false -- playVideo выставляет в конце, чтобы умер watchPause
-- часы A/V-синка (секунды показанного/сыгранного от старта показа):
-- видео убегает вперед скипами, звук догоняет сбросами (см. playAudio)
local vTime, aTime, droppedA, ceilWaited, audioHold = 0, 0, 0, 0, 0
-- статистика: dropped - кадры, примененные к базе без показа (отставание),
-- late - пробуждений с отставанием >1 кадра, stalls - тиков без данных
-- (сеть/CDN), badRec - битые записи
local dropped, late, stalls, badRec = 0, 0, 0, 0

local sbyte, schar, srep, ssub = string.byte, string.char, string.rep, string.sub
local unpack = table.unpack or unpack
local floor = math.floor
-- table.move есть не во всех версиях Cobalt: ручной фолбэк
local tmove = table.move or function(a, f, e, t, b)
    for i = f, e do b[t + i - f] = a[i] end
    return b
end

-- yield БЕЗ ожидания тика: отдаем очередь событий другим потокам (прежде
-- всего видеотаймеру) посреди тяжелой работы и сразу продолжаем
local function yieldNow()
    os.queueEvent("rtv:y")
    os.pullEvent("rtv:y")
end

-- Пачка с CDN режется на записи ПО ИНДЕКСУ (idx0), а не разбором длин:
-- дешево, и счет кадров всегда совпадает с индексом даже при битой записи
-- (битую отбросит декодер). Обрезанный хвост не съедаем: дозапросится.
local function sliceBatch(data, vn, c, first, out)
    local got = 0
    for i = 0, c - 1 do
        local a = idx0[vn + i + 1] - first + 1
        local b = idx0[vn + i + 2] - first
        if b > #data then break end
        out[#out + 1] = ssub(data, a, b)
        got = got + 1
    end
    return got
end

local function fetcher()
    local vn, an = startFrame, startChunk
    local vFails, aFails = 0, 0
    while vn < total_frames or an < total_dchunks do
        local wantV = (#vQueue < maxVQueue) and (vn < total_frames)
        local wantA = (#aQueue < 24) and (an < total_dchunks)
        if not wantV and not wantA then
            sleep(0.05)
        else
            if wantV then
                -- сколько кадров влезет в ~768КБ по индексу
                -- (CC-лимит 10МБ: чем больше батч, тем меньше запросов
                -- и меньше окон для stall-просадок)
                local c, bytes = 0, 0
                while vn + c < total_frames and c < BATCH_V do
                    local sz = idx0[vn + c + 2] - idx0[vn + c + 1]
                    if bytes + sz > 786432 and c > 0 then break end
                    bytes = bytes + sz
                    c = c + 1
                end
                if c == 0 then c = 1 end
                local first, last = idx0[vn + 1], idx0[vn + c + 1] - 1
                local data = httpRangeRetry(assetUrl(files["sixel.rle"]), first, last, 3)
                if data then
                    local got = sliceBatch(data, vn, c, first, vQueue)
                    if got > 0 then vn = vn + got vFails = 0
                    else vFails = vFails + 1 sleep(0.5) end
                else
                    vFails = vFails + 1 sleep(0.5)
                end
                if vFails > 20 then print("video fetch stuck, abort") break end
            end
            if wantA then
                local c = math.min(BATCH_A, total_dchunks - an)
                -- кламп хвоста к размеру файла, иначе Range упирается в конец
                -- и сыплет "range warn" на последнем куске звука
                local first = an * dchunk
                local last = math.min((an + c) * dchunk - 1, dtotal - 1)
                local data = httpRangeRetry(assetUrl(files["audio.dfpwm"]), first, last, 2)
                if data then
                    if #data > 0 then
                        local p = 1
                        local got = 0
                        while p <= #data do
                            aQueue[#aQueue + 1] = ssub(data, p, p + dchunk - 1)
                            p = p + dchunk
                            got = got + 1
                        end
                        an = an + got
                        aFails = 0
                    else
                        aFails = aFails + 1 sleep(0.5)
                    end
                else
                    aFails = aFails + 1 sleep(0.5)
                end
                if aFails > 20 then print("audio fetch stuck, skip rest") an = total_dchunks end
            end
        end
    end
    fetch_done = true
end

local decoder = dfpwm and dfpwm.make_decoder() or nil
-- DFPWM-декод чанка (8КБ = 65К сэмплов) - чистый Lua, 50-150мс одним куском:
-- пока он шел, таймер видео лежал в очереди и кадр уезжал в следующий тик.
-- Режем на куски по 512 байт (~4К сэмплов, единицы мс) с yield между.
local function decodeChunk(data)
    local out, n = {}, 0
    local step = 512
    for i = 1, #data, step do
        local part = decoder(ssub(data, i, i + step - 1))
        local pn = #part
        tmove(part, 1, pn, n + 1, out)
        n = n + pn
        if i + step <= #data then yieldNow() end
    end
    return out
end
-- отдать кусок PCM (~0.17с) в колонку, дождавшись почти пустого буфера
-- (speaker_audio_empty), а не любого места: иначе буфер стоит полный
-- (2.7с) и слышимый сдвиг гуляет независимо от наших часов.
-- Возвращает true если отдано.
local function feedPiece(sp, piece, tp)
    -- сразу: пустой буфер = есть место, глубина не растет
    if sp.playAudio(piece) then return true end
    -- буфер полон: ждем ИМЕННО опустошения. Чужие события (таймеры видео
    -- каждые 50мс!) игнорируем, иначе накормим по первому чиху и буфер
    -- снова встанет полный на 2.7с. Страховка - свой таймер 0.25с.
    local t = os.startTimer(0.25)
    while true do
        local ev, p1 = os.pullEvent()
        if ev == "speaker_audio_empty" then
            -- может быть чужой empty (6 колонок): не влезло - ждем дальше
            if sp.playAudio(piece) then os.cancelTimer(t) return true end
        elseif ev == "timer" and p1 == t then
            -- empty потерялся: отдать как есть (редкий случай)
            return sp.playAudio(piece)
        elseif tp < vTime - 0.75 or paused then
            os.cancelTimer(t)
            return false
        end
    end
end
local function playAudio()
    if #speakers == 0 then return end
    while true do
        if paused then
            sleep(0.05)
        elseif #aQueue > 0 and not (aTime > vTime + 0.5 and ceilWaited < 10000) then
            local data = aQueue[1]
            local dur = (#data * 8) / 48000 -- чанк звука в секундах
            if aTime < vTime - 0.75 and #aQueue > 1 then
                -- звук отстал от видео (пролаг): роняем старый кусок без
                -- проигрывания. Иначе отстанет навсегда: видео скипает,
                -- а звук скипать не умел.
                table.remove(aQueue, 1)
                aTime = aTime + dur
                droppedA = droppedA + 1
            else
                table.remove(aQueue, 1)
                local pcm = decodeChunk(data)
                -- SUB-PIECE: чанк пилим на куски ~0.17с и отдаем строго по
                -- часам видео. Иначе 2.7с буфер колонки отвязывает слышимое
                -- от выданного (качели быстрее/медленнее при просадках).
                local total, step = #pcm, 8192
                local off = 1
                while off <= total do
                    local e = math.min(off + step - 1, total)
                    local pdur = (e - off + 1) / 48000
                    local more = e < total or #aQueue > 0 or not fetch_done
                    if aTime < vTime - 0.75 and more then
                        aTime = aTime + pdur
                        droppedA = droppedA + 1
                    else
                        while aTime > vTime + 0.5 and ceilWaited < 10000
                                and not paused and not finished do
                            sleep(0.1)
                            ceilWaited = ceilWaited + 100
                            audioHold = audioHold + 1
                        end
                        if paused then
                            -- пауза посреди чанка: динамики и так стопнуты,
                            -- остаток пропускаем (дыра <=1.37с, неслышно)
                            aTime = aTime + (total - off + 1) / 48000
                            break
                        end
                        local tp = aTime
                        local piece = {}
                        for k = off, e do piece[#piece + 1] = pcm[k] end
                        local fns = {}
                        for i, sp in ipairs(speakers) do
                            fns[i] = function() feedPiece(sp, piece, tp) end
                        end
                        parallel.waitForAll(table.unpack(fns))
                        aTime = aTime + pdur
                        ceilWaited = 0
                    end
                    off = e + 1
                end
            end
        elseif #aQueue > 0 then
            -- потолок: звук убежал вперед видео (видос встал/скипнулся) -
            -- стоим, колонки доигрывают буфер и молчат. Без потолка звук
            -- уходит вперед навсегда. Кеп 10с против вечной тишины.
            sleep(0.1)
            ceilWaited = ceilWaited + 100
            audioHold = audioHold + 1
        elseif fetch_done then
            break
        else
            sleep(0.05)
        end
    end
end

-- База (текущий кадр) ПОСТРОЧНО: bt/bf/bg[r] = строки длиной vw, r=0..vh-1.
-- st/sf/sg = что реально стоит на мониторе (nil = неизвестно -> перерисовать).
-- Инвариант: монитор == st/sf/sg всегда, кроме окна между применением кадра
-- к базе и серией блитов на следующем тике.
local bt, bf, bg = {}, {}, {}
local st, sf, sg = {}, {}, {}
local haveBase = false
local pendingPal = nil -- палитра последнего K/R, ставится в серии блитов
local BLANK_T, BLANK_F, BLANK_G = srep(" ", vw), srep("0", vw), srep("f", vw)

local function rleDecode(s, i, j)
    local parts, n = {}, 0
    -- висячий нечетный хвост игнорируем, а не падаем (иначе смерть видеопотока)
    while i + 1 <= j do
        local v, c = sbyte(s, i, i + 1)
        n = n + 1
        parts[n] = (c == 1) and schar(v) or srep(schar(v), c)
        i = i + 2
    end
    return table.concat(parts)
end

-- запись: 'K' [u16][t][u16][f][u16][g][48pal]
--         'D' [u16 n]([u16 idx][ch][fg][bg])*
--         'R' [u16 nrect]([u8 x,y,w,h][ch][fg][bg])* + [48pal]
-- Все u16 big-endian (struct ">H" на сервере).
local function applyK(raw)
    local q, planes = 2, {}
    for k = 1, 3 do
        if #raw < q + 1 then return false end
        local ln = sbyte(raw, q) * 256 + sbyte(raw, q + 1)
        q = q + 2
        if #raw < q + ln - 1 then return false end
        local s = rleDecode(raw, q, q + ln - 1)
        if #s ~= cell then return false end
        planes[k] = s
        q = q + ln
    end
    if #raw < q + 47 then return false end
    local t, f, g = planes[1], planes[2], planes[3]
    for r = 0, vh - 1 do
        local a = r * vw
        bt[r] = ssub(t, a + 1, a + vw)
        bf[r] = ssub(f, a + 1, a + vw)
        bg[r] = ssub(g, a + 1, a + vw)
    end
    pendingPal = ssub(raw, q, q + 47)
    haveBase = true
    return true
end

-- точечные правки строк через байтовые таблицы, потом обратно в строки
local function rowTables(r, T, F, G)
    local t = T[r]
    if not t then
        t = { sbyte(bt[r], 1, -1) }
        T[r] = t
        F[r] = { sbyte(bf[r], 1, -1) }
        G[r] = { sbyte(bg[r], 1, -1) }
    end
    return t, F[r], G[r]
end
local function commitRows(T, F, G)
    for r, t in pairs(T) do
        bt[r] = schar(unpack(t))
        bf[r] = schar(unpack(F[r]))
        bg[r] = schar(unpack(G[r]))
    end
end

local function applyD(raw)
    if not haveBase then return true end -- дельта без базы: молча ждем K
    if #raw < 3 then return false end
    local n = sbyte(raw, 2) * 256 + sbyte(raw, 3)
    if #raw < 3 + n * 5 then return false end
    local T, F, G = {}, {}, {}
    local q = 4
    for _ = 1, n do
        local idx = sbyte(raw, q) * 256 + sbyte(raw, q + 1)
        if idx < cell then
            local r = floor(idx / vw)
            local c = idx - r * vw + 1
            local t, f, g = rowTables(r, T, F, G)
            t[c], f[c], g[c] = sbyte(raw, q + 2, q + 4)
        end
        q = q + 5
    end
    commitRows(T, F, G)
    return true
end

local function applyR(raw)
    if #raw < 3 then return false end
    local n = sbyte(raw, 2) * 256 + sbyte(raw, 3)
    if #raw < 3 + n * 7 + 48 then return false end
    -- R = полный кадр: база с чистого ЧЕРНОГО (как monitor.clear) + прямоугольники
    for r = 0, vh - 1 do bt[r], bf[r], bg[r] = BLANK_T, BLANK_F, BLANK_G end
    local T, F, G = {}, {}, {}
    local q = 4
    for _ = 1, n do
        local x, y, w, h, ch, fc, gc = sbyte(raw, q, q + 6)
        q = q + 7
        if w >= 1 and h >= 1 and x + w <= vw and y + h <= vh then
            for r = y, y + h - 1 do
                local t, f, g = rowTables(r, T, F, G)
                for c = x + 1, x + w do t[c], f[c], g[c] = ch, fc, gc end
            end
        end
    end
    commitRows(T, F, G)
    pendingPal = ssub(raw, q, q + 47)
    haveBase = true
    return true
end

local lastKind = "?"
local function applyRecord(raw)
    local typ = sbyte(raw, 1)
    local ok
    if typ == 75 then ok = applyK(raw) lastKind = "K"
    elseif typ == 68 then ok = applyD(raw) lastKind = "D"
    elseif typ == 82 then ok = applyR(raw) lastKind = "R"
    else ok = false lastKind = "?" end
    if not ok then badRec = badRec + 1 end
    return ok
end

local curPal = nil
local darkIdx = 15
local function paintMargins()
    -- поля вокруг окна красим самым темным слотом текущей палитры
    local dig = string.format("%x", darkIdx)
    local function bar(x, y, w)
        if w <= 0 then return end
        monitor.setCursorPos(x, y)
        monitor.blit(srep(" ", w), srep("0", w), srep(dig, w))
    end
    for y = 1, oy - 1 do bar(1, y, mw) end
    for y = oy + vh, mh do bar(1, y, mw) end
    for y = oy, oy + vh - 1 do
        bar(1, y, ox - 1)
        bar(ox + vw, y, mw - ox - vw + 1)
    end
end
local function applyPalette(pal)
    -- ставим только изменившиеся слоты: меньше всполохов и быстрее
    for i = 0, 15 do
        if not curPal or ssub(pal, i * 3 + 1, i * 3 + 3) ~= ssub(curPal, i * 3 + 1, i * 3 + 3) then
            local r, g, b = sbyte(pal, i * 3 + 1, i * 3 + 3)
            monitor.setPaletteColour(2 ^ i, r / 255, g / 255, b / 255)
        end
    end
    local best, bestV = 15, 10 ^ 9
    for i = 0, 15 do
        local r, g, b = sbyte(pal, i * 3 + 1, i * 3 + 3)
        local v = r + g + b
        if v < bestV then best, bestV = i, v end
    end
    if curPal == nil or best ~= darkIdx then
        darkIdx = best
        paintMargins()
    end
    curPal = pal
end

-- строки, отличающиеся от монитора (считаем ДО сна, не в серии блитов)
local function diffRows()
    local list, n = {}, 0
    for r = 0, vh - 1 do
        if bt[r] ~= st[r] or bf[r] ~= sf[r] or bg[r] ~= sg[r] then
            n = n + 1
            list[n] = r
        end
    end
    return list
end

-- ПЛОТНАЯ серия блитов: между вызовами никакой Lua-работы, чтобы уложиться
-- до снимка монитора в этом же тике. Палитра ПОСЛЕ строк (как YouCube):
-- в одном тике это атомарно, вспышки нет.
local mSetCursor, mBlit = monitor.setCursorPos, monitor.blit
local function blitRows(list)
    for i = 1, #list do
        local r = list[i]
        mSetCursor(ox, oy + r)
        mBlit(bt[r], bf[r], bg[r])
    end
    for i = 1, #list do
        local r = list[i]
        st[r], sf[r], sg[r] = bt[r], bf[r], bg[r]
    end
    if pendingPal then
        applyPalette(pendingPal)
        pendingPal = nil
    end
end

local function drawPauseOverlay()
    local msg = "|| PAUZA - tap/space ||"
    local x = math.max(1, math.floor((mw - #msg) / 2) + 1)
    local y = math.max(1, math.floor(mh / 2))
    monitor.setCursorPos(x, y)
    monitor.setTextColour(colours.yellow)
    monitor.setBackgroundColour(colours.black)
    monitor.write(msg)
end

-- после resume стираем плашку полным репейнтом базы (сброс st/sf/sg),
-- иначе текст "PAUZA" остается висеть до следующего полного кадра
local needRedraw = false
-- дебаунс тоггла паузы (мс): давит дребезг тапов мультиблочного монитора,
-- даблтапы по лагу и автоповторы зажатой клавиши
local lastToggle = 0

local function watchPause()
    while not finished do
        local ev, p1, p3 = os.pullEvent()
        -- p3 для key = is_held (автоповтор зажатого пробела - не клик)
        local tap = ev == "monitor_touch"
        local key = ev == "key" and p1 == keys.space and not p3
        if tap or key then
            local now = os.epoch("utc")
            if now - lastToggle >= 800 then
                lastToggle = now
            else
                tap, key = false, false -- дребезг, игнорим
            end
        end
        if tap or key then
            paused = not paused
            if paused then
                for _, sp in ipairs(speakers) do sp.stop() end
                drawPauseOverlay()
                print("paused")
            else
                os.queueEvent("rtv:resume") -- будим playAudio, если он спит в ожидании
                needRedraw = true -- стереть плашку паузы репейнтом базы
                print("resumed")
            end
        end
    end
end

-- телеметрия ВНЕ видеоокна (строки 1-2 монитора; на фулскрине - поверх
-- видео, эти строки потом перерисуются): F<кадр> <K/R/D> d<dropped>
-- l<late> s<stalls> q<очередь> + геометрия
local function dbgTag(n)
    monitor.setCursorPos(1, 1)
    monitor.setTextColour(colours.lime)
    monitor.setBackgroundColour(colours.black)
    monitor.write(string.format("F%d %s d%d l%d s%d q%d",
        n, lastKind, dropped, late, stalls, #vQueue))
    monitor.setCursorPos(1, 2)
    monitor.write(string.format("mon%dx%d win%dx%d@%d,%d",
        mw, mh, vw, vh, ox, oy))
    -- строки под тегом больше не равны базе: перерисовать в следующей серии
    for y = 1, 2 do
        local r = y - oy
        if r >= 0 and r < vh then st[r] = nil end
    end
end

-- Кадр в тик. Цикл: [пробуждение таймера = начало тика] -> серия блитов
-- подготовленного кадра -> применить к базе СЛЕДУЮЩИЙ кадр ->
-- посчитать изменившиеся строки -> спать до момента показа.
-- СТРОГО ОДИН кадр за тик, всегда по порядку, БЕЗ скипов/догонов/фризов:
-- отставание от стены НЕ гасится прыжками - фильм просто идет медленнее
-- стены, зато картинка и звук всегда вместе (vinyl slowdown, не judder).
-- Звук привязан потолком/сбросами к показанным кадрам, глубины рассинхрона
-- взяться неоткуда: нечего догонять - нечего рвать.
local function playVideo()
    local interval = 1000 / fps
    local n = startFrame   -- следующий кадр из очереди (номер в фильме)
    local m = 0            -- кадров пройдено от старта (показано + dropped)
    -- t0 = момент показа кадра 0 = следующий тик
    local t0 = os.epoch("utc") + 50
    local pendingRows = nil
    while true do
        if paused then
            local pt = os.epoch("utc")
            sleep(0.1)
            t0 = t0 + (os.epoch("utc") - pt) -- часы стоят вместе с картинкой
        else
            -- 1) сразу после пробуждения: серия блитов, ничего лишнего
            if needRedraw then
                needRedraw = false
                st, sf, sg = {}, {}, {}
                pendingRows = nil
            end
            local list = pendingRows or diffRows()
            pendingRows = nil
            if #list > 0 or pendingPal then blitRows(list) end
            if DEBUG and m > 0 then
                dbgTag(startFrame + m - 1)
                if m % 100 == 0 then
                    print("f" .. (startFrame + m - 1) .. " " .. lastKind .. " vq" .. #vQueue ..
                          " aq" .. #aQueue .. " drop" .. dropped .. " late" .. late ..
                          " stall" .. stalls .. " bad" .. badRec .. " ad" .. droppedA .. " ah" .. audioHold .. " done" .. tostring(fetch_done))
                end
            end
            -- 2) конец фильма / фетчер сдался
            if n >= total_frames or (#vQueue == 0 and fetch_done) then break end
            local now = os.epoch("utc")
            if #vQueue == 0 then
                -- 3a) нет данных (сеть): стоим. Часы стоят только если звука
                -- нет (нечего догонять - покажем все кадры); со звуком часы
                -- идут, но догонять НЕ будем - продолжим по порядку, фильм
                -- просто закончится позже стены.
                stalls = stalls + 1
                sleep(0.05)
                local dt = os.epoch("utc") - now
                if total_dchunks == 0 then
                    t0 = t0 + dt
                end
            else
                -- 3b) строго ОДИН следующий кадр за тик: применить к базе,
                -- посчитать строки, показать следующим тиком. Никаких скипов,
                -- догонов и фризов: отставание от стены не гасится прыжками,
                -- фильм идет медленнее стены, зато картинка и звук вместе.
                applyRecord(table.remove(vQueue, 1))
                n, m = n + 1, m + 1
                vTime = m / fps
                pendingRows = diffRows()
                -- 4) спим до момента показа кадра (m-1), минимум до след. тика
                local target = t0 + (m - 1) * interval
                local wait = target - os.epoch("utc")
                if wait < 25 then
                    wait = 25
                    late = late + 1 -- дедлайн сорван: тик опоздал (нагрузка)
                end
                sleep(wait / 1000)
            end
        end
    end
    finished = true
    os.queueEvent("rtv:done") -- будим watchPause: иначе done никогда не печатается
end

monitor.clear()

local function playVideoBuffered()
    while #vQueue < math.min(total_frames - startFrame, math.floor(fps * 1.5), math.floor(maxVQueue / 2)) and not fetch_done do sleep(0.05) end
    playVideo()
end
local function playAudioBuffered()
    if #speakers == 0 then return end
    while #aQueue < math.min(math.max(total_dchunks - startChunk, 0), 8) and not fetch_done do sleep(0.05) end
    playAudio()
end

if duration > 0 then
    print(string.format("length: %d:%02d", math.floor(duration / 60), math.floor(duration % 60)))
end
print("pause: tap monitor / space")
-- GC в инкрементальном режиме: короткие частые шаги вместо редких
-- стоп-пауз на много-МБ куче (очередь + таблицы дельт). Иначе GC-стоп
-- выглядит как late-tick + просадка accepts. pcall: мало ли.
pcall(collectgarbage, "setpause", 110)

if #speakers > 0 then
    parallel.waitForAll(fetcher, playVideoBuffered, playAudioBuffered, watchPause)
else
    parallel.waitForAll(fetcher, playVideoBuffered, watchPause)
end

restorePalette()
monitor.setCursorPos(1, mh)
print("done. dropped(applied unseen): " .. dropped .. " late: " .. late .. " stalls: " .. stalls ..
      " badRec: " .. badRec .. " audioDrop: " .. droppedA .. " audioHold: " .. audioHold .. " - Ctrl+T for new link")
-- цепочка частей (полный метр в нескольких релизах): афиша говорит next -
-- сами подхватываем следующую часть как "одно видео" (пауза на докачку).
if meta.next and meta.next ~= job then
    print("next part: " .. meta.next .. " - loading...")
    sleep(2)
    shell.run(shell.getRunningProgram(), meta.next)
end
