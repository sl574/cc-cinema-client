-- Static TV DEBUG: то же что svideo + телеметрия в углу монитора.
-- usage: svideo_dbg <job_id> [fps] [from_sec]
-- В углу (поля, вне видео): F<кадр> <K/R/D> d<dropped> r<resyncs> q<очередь>.
-- Каждые 100 кадров - подробный print в терминал компа.
-- По тегу видно: полоса совпадает с K (шов перерисовки) или с d-ростом (скипы).
-- usage:
--   svideo setup <token>   - save read-only token once (settings)
--   svideo <job_id> [fps] [from_sec]
-- example: svideo 46294e34f1d32d049252 20
-- pause: tap monitor / space
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
-- fps для расчета окна: файлы уже сняты на своей частоте, meta позже уточнит
local fps = 20
if fpsArg then fps = math.max(1, math.min(20, fpsArg)) end

local token = settings.get("svideo.token")
if not jobid then
    print("usage: svideo setup <token> | svideo <job_id> [fps] [from_sec]")
    return
end
if not token then
    print("no token: run svideo setup <token> first")
    return
end

local monitor = peripheral.find("monitor")
if not monitor then print("no monitor"); return end
monitor.setTextScale(0.5)
local mw, mh = monitor.getSize()
print("RTV v6 monitor: " .. mw .. "x" .. mh .. " fps: " .. fps)

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
local limit = 14000
if fps >= 16 then limit = 12000
elseif fps >= 11 then limit = 12000 end
if vw * vh > limit then
    local k = math.sqrt(limit / (vw * vh))
    vw = math.max(20, math.floor(vw * k))
    vh = math.max(20, math.floor(vh * k))
    print("video window: " .. vw .. "x" .. vh .. " (center, shrunk for fps)")
else
    print("video window: " .. vw .. "x" .. vh)
end
local ox = math.floor((mw - vw) / 2) + 1
local oy = math.floor((mh - vh) / 2) + 1

local savedPal = {}
for i = 0, 15 do savedPal[i] = { monitor.getPaletteColour(2 ^ i) } end
local function restorePalette()
    for i = 0, 15 do monitor.setPaletteColour(2 ^ i, table.unpack(savedPal[i])) end
end

-- ВСЕ динамики: вплотную + по проводной сети (wired modem + кабель).
-- Дальним колонкам нужен проводной модем у компа и у колонки.
local speakers = { peripheral.find("speaker") }
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

local vQueue = {}
local aQueue = {}
local fetch_done = false
local paused = false
local finished = false -- playVideo выставляет в конце, чтобы умер watchPause
-- часы A/V-синка (секунды показанного/сыгранного от старта показа):
-- видео убегает вперед скипами, звук догоняет сбросами (см. playAudio)
local vTime, avWaited, aTime, droppedA = 0, 0, 0, 0
local lastFrame = nil
-- статистика потока: K/R/D принято, drop битых, trunc обрезанных батчей,
-- gap разрывов непрерывности, dup дублей
local cntBlitErr = 0

local function rleDecode(rle)
    local parts = {}
    local p = 1
    -- висячий нечетный хвост игнорируем, а не падаем (иначе смерть видеопотока)
    while p + 1 <= #rle do
        local v = rle:byte(p)
        local c = rle:byte(p + 1)
        p = p + 2
        parts[#parts + 1] = string.rep(string.char(v), c)
    end
    return table.concat(parts)
end

-- запись: 'K' [u16][t][u16][f][u16][g][48pal]
--         'D' [u16 n]([u16 idx][ch][fg][bg])*
--         'R' [u16 nrect]([u8 x,y,w,h][ch][fg][bg])* + [48pal]
-- Обрезанный хвост не съедаем: фетчер дозапросит остаток.
-- Возвращает got (принято записей).
local function parseSBatch(data, out)
    local p, got = 1, 0
    while p <= #data do
        local rs = p -- начало записи (точка отката при обрезе)
        local typ = data:sub(p, p)
        p = p + 1
        if typ == "K" then
            local lens, ok = {}, true
            for k = 1, 3 do
                if p + 1 > #data then ok = false break end
                local ln = data:byte(p) * 256 + data:byte(p + 1)
                if ln > cell * 2 + 64 then ok = false break end -- мусор, не запись
                if p + 2 + ln - 1 > #data then ok = false break end
                lens[k] = ln
                p = p + 2 + ln
            end
            if ok then
                if p + 47 > #data then ok = false else p = p + 48 end
            end
            if not ok then p = rs break end
            local q, vals = rs + 1, {}
            for k = 1, 3 do
                local ln = data:byte(q) * 256 + data:byte(q + 1) q = q + 2
                vals[k] = rleDecode(data:sub(q, q + ln - 1)) q = q + ln
            end
            local pal = data:sub(q, q + 47)
            if #vals[1] == cell and #vals[2] == cell and #vals[3] == cell then
                out[#out + 1] = { full = true, t = vals[1], f = vals[2], g = vals[3], pal = pal }
                got = got + 1
            end
        elseif typ == "D" then
            if p + 1 > #data then p = rs break end
            local n = data:byte(p) * 256 + data:byte(p + 1)
            if n > cell then p = rs break end -- мусор, не запись
            if p + 2 + n * 5 - 1 > #data then p = rs break end
            -- группируем по строкам: одна склейка на строку вместо одной на клетку
            local byrow, q, ok = {}, p + 2, true
            for _ = 1, n do
                local idx = data:byte(q) * 256 + data:byte(q + 1)
                if idx >= cell then ok = false break end
                local ch, f, g = data:byte(q + 2), data:byte(q + 3), data:byte(q + 4)
                local row = math.floor(idx / vw)
                local r = byrow[row]
                if not r then r = {} byrow[row] = r end
                r[#r + 1] = { col = idx % vw, n = 1, ch = ch, f = f, g = g }
                q = q + 5
            end
            p = p + 2 + n * 5
            if ok then
                out[#out + 1] = { full = false, byrow = byrow }
                got = got + 1
            end
        elseif typ == "R" then
            if p + 1 > #data then p = rs break end
            local nrect = data:byte(p) * 256 + data:byte(p + 1)
            if nrect > cell then p = rs break end -- мусор, не запись
            if p + 2 + nrect * 7 + 48 - 1 > #data then p = rs break end
            local byrow, q, ok = {}, p + 2, true
            for _ = 1, nrect do
                local x, y, w, h = data:byte(q, q + 3)
                if x + w > vw or y + h > vh or w < 1 or h < 1 then ok = false break end
                local ch, f, g = data:byte(q + 4), data:byte(q + 5), data:byte(q + 6)
                q = q + 7
                -- n растягиваем сразу в спан: одна склейка на строку
                for yy = y, y + h - 1 do
                    local r = byrow[yy]
                    if not r then r = {} byrow[yy] = r end
                    r[#r + 1] = { col = x, n = w, ch = ch, f = f, g = g }
                end
            end
            local pal = data:sub(q, q + 47)
            if ok and #pal == 48 then
                p = q + 48
                out[#out + 1] = { full = "rect", pal = pal, byrow = byrow }
                got = got + 1
            else
                -- битый R целиком пропускаем по вычисленной границе (не рвем поток)
                p = rs + 1 + 2 + nrect * 7 + 48
            end
        else
            break -- неизвестный тип: байт не едим, остаток дозапросится
        end
    end
    return got
end

-- плашка "нет сети" поверх застывшего кадра + полная перерисовка базы при оживлении
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
                    local got = parseSBatch(data, vQueue)
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
                            aQueue[#aQueue + 1] = data:sub(p, p + dchunk - 1)
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
local function playOn(sp, pcm)
    -- ждем ЛЮБОЕ событие (не только speaker_audio_empty):
    -- иначе пауза внутри ожидания = вечный сон и немой звук.
    -- rtv:resume от watchPause гарантированно будит даже в тишине.
    while not sp.playAudio(pcm) do
        os.pullEvent()
    end
end
local function playAudio()
    if #speakers == 0 then return end
    while true do
        if paused then
            sleep(0.05)
        elseif #aQueue > 0 then
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
                local pcm = decoder(data)
            -- один чанк сразу во все колонки, параллельно (как у YouCube)
            local fns = {}
            for i, sp in ipairs(speakers) do
                fns[i] = function() playOn(sp, pcm) end
            end
            parallel.waitForAll(table.unpack(fns))
                aTime = aTime + dur
            end
        elseif fetch_done then
            break
        else
            sleep(0.05)
        end
    end
end

-- базовый кадр для дельт
local base = nil
local curPal = nil
local darkIdx = 15
local function paintMargins()
    -- поля вокруг окна красим самым темным слотом текущей палитры
    local dig = string.format("%x", darkIdx)
    local function bar(x, y, w)
        if w <= 0 then return end
        monitor.setCursorPos(x, y)
        monitor.blit(string.rep(" ", w), string.rep("0", w), string.rep(dig, w))
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
        if not curPal or pal:sub(i * 3 + 1, i * 3 + 3) ~= curPal:sub(i * 3 + 1, i * 3 + 3) then
            local r, g, b = pal:byte(i * 3 + 1, i * 3 + 3)
            monitor.setPaletteColour(2 ^ i, r / 255, g / 255, b / 255)
        end
    end
    local best, bestV = 15, 10 ^ 9
    for i = 0, 15 do
        local r, g, b = pal:byte(i * 3 + 1, i * 3 + 3)
        local v = r + g + b
        if v < bestV then best, bestV = i, v end
    end
    if curPal == nil or best ~= darkIdx then
        darkIdx = best
        paintMargins()
    end
    curPal = pal
end

-- безопасный блит: кривые длины пропускаем со счетчиком, а не роняем видеопоток
local function safeBlit(x, y, ts, fs, gs)
    if #ts == vw and #fs == vw and #gs == vw then
        monitor.setCursorPos(x, y)
        monitor.blit(ts, fs, gs)
    else
        cntBlitErr = cntBlitErr + 1
    end
end

local function blitRow(y, t, f, g)
    safeBlit(ox, oy + y,
             t:sub(y * vw + 1, (y + 1) * vw),
             f:sub(y * vw + 1, (y + 1) * vw),
             g:sub(y * vw + 1, (y + 1) * vw))
end

-- вшивание спанов byrow[row] = {{col, n, ch, f, g}} в строки bs (без отрисовки).
-- Возвращает список {row, t, f, g} затронутых строк.
local function patchRows(bs, byrow)
    local dirty = {}
    for row, list in pairs(byrow) do
        if row >= 0 and row < vh then
            local a, b = row * vw + 1, (row + 1) * vw
            local t = { bs.t:sub(a, b):byte(1, -1) }
            local f = { bs.f:sub(a, b):byte(1, -1) }
            local g = { bs.g:sub(a, b):byte(1, -1) }
            for _, c in ipairs(list) do
                local n = c.n or 1
                for k = 0, n - 1 do
                    local kk = c.col + 1 + k
                    if kk <= vw then t[kk], f[kk], g[kk] = c.ch, c.f, c.g end
                end
            end
            local ts, fs, gs = string.char(table.unpack(t)),
                               string.char(table.unpack(f)),
                               string.char(table.unpack(g))
            bs.t = bs.t:sub(1, a - 1) .. ts .. bs.t:sub(b + 1)
            bs.f = bs.f:sub(1, a - 1) .. fs .. bs.f:sub(b + 1)
            bs.g = bs.g:sub(1, a - 1) .. gs .. bs.g:sub(b + 1)
            dirty[#dirty + 1] = { row = row, t = ts, f = fs, g = gs }
        end
    end
    return dirty
end


local function drawFrame(fr)
    if fr.full == true then
        local old = base
        base = { t = fr.t, f = fr.f, g = fr.g }
        if not old then
            for y = 0, vh - 1 do blitRow(y, fr.t, fr.f, fr.g) end
        else
            -- v7.1: полный кадр рисуем только изменившимися строками.
            -- Было 49 блитов вслепую: на стене 8x5 sweep было видно как
            -- "плывущую пленку". Семантика та же (база+палитра обновлены).
            for y = 0, vh - 1 do
                local a, b = y * vw + 1, (y + 1) * vw
                if fr.t:sub(a, b) ~= old.t:sub(a, b)
                or fr.f:sub(a, b) ~= old.f:sub(a, b)
                or fr.g:sub(a, b) ~= old.g:sub(a, b) then
                    blitRow(y, fr.t, fr.f, fr.g)
                end
            end
        end
        -- палитру ставим ПОСЛЕ строк (как YouCube): перекрас всего экрана
        -- атомарный, без цветовой вспышки перед sweep перерисовки
        applyPalette(fr.pal)
    elseif fr.full == "rect" then
        -- R is a full frame: reset base to BLACK and fill rectangles
        -- (фон "f"=black как monitor.clear; было "0"=white и ореолы на-unsync)
        local old = base
        base = { t = string.rep(" ", cell), f = string.rep("0", cell), g = string.rep("f", cell) }
        patchRows(base, fr.byrow)
        if not old then
            for y = 0, vh - 1 do blitRow(y, base.t, base.f, base.g) end
        else
            for y = 0, vh - 1 do
                local a, b = y * vw + 1, (y + 1) * vw
                local t, f, g = base.t:sub(a, b), base.f:sub(a, b), base.g:sub(a, b)
                if t ~= old.t:sub(a, b) or f ~= old.f:sub(a, b) or g ~= old.g:sub(a, b) then
                    safeBlit(ox, oy + y, t, f, g)
                end
            end
        end
        applyPalette(fr.pal)
    else
        if not base then return end -- delta without base, wait for keyframe
        local dirty = patchRows(base, fr.byrow)
        for _, d in ipairs(dirty) do
            monitor.setCursorPos(ox, oy + d.row)
            monitor.blit(d.t, d.f, d.g)
        end
    end
    lastFrame = fr
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

-- после resume стираем плашку полным репейнтом базы, иначе текст
-- "PAUZA" остается висеть до следующего полного кадра
local dropped = 0
local resyncs = 0 -- сколько раз скип уперся в полный кадр (ресинк цепочки D)
local needRedraw = false
-- дебаунс тоггла паузы (мс): давит дребезг тапов мультиблочного монитора,
-- даблтапы по лагу и автоповторы зажатой клавиши
local lastToggle = 0
local dbgN, dbgKind = 0, "?"
local function repaintBase()
    if not base then return end
    for y = 0, vh - 1 do blitRow(y, base.t, base.f, base.g) end
end

-- телеметрия ВНЕ видеоокна (строки 1-2 монитора, поверх полей)
local function dbgTag()
    monitor.setCursorPos(1, 1)
    monitor.setTextColour(colours.lime)
    monitor.setBackgroundColour(colours.black)
    monitor.write(string.format("F%d %s d%d r%d q%d",
        dbgN, dbgKind, dropped, resyncs, #vQueue))
    -- геометрия для фулскрина: один скриншот = все цифры
    monitor.setCursorPos(1, 2)
    monitor.write(string.format("mon%dx%d win%dx%d@%d,%d",
        mw, mh, vw, vh, ox, oy))
end

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
local function playVideo()
    local interval = 1 / fps
    local t0 = os.epoch("utc")
    local n = startFrame
    local m = 0
    while true do
        if needRedraw and base and not paused then
            needRedraw = false
            repaintBase()
        end
        if paused then
            sleep(0.05)
            t0 = t0 + 50
        elseif #vQueue > 0 and not (#speakers > 0 and aTime < vTime - 1.0 and avWaited < 3000) then
            local now = os.epoch("utc")
            local expected = (now - t0) / 1000 * fps
            if expected - m > fps * 0.75 and #vQueue > 2 then
                -- v7.1 цепные дельты: скипаем все D до ближайшего полного кадра,
                -- полный всегда рисуем (там же ресинк базы). Пропуск D без
                -- ресинка давал бы шлейф до конца GOP.
                local skip = math.min(#vQueue - 1, math.floor(expected - m) - 1)
                while skip > 0 and #vQueue > 1 do
                    if vQueue[1].full then resyncs = resyncs + 1 break end
                    table.remove(vQueue, 1) n = n + 1 m = m + 1 dropped = dropped + 1
                    skip = skip - 1
                end
            end
            local fr = table.remove(vQueue, 1)
            drawFrame(fr)
            dbgN = n + 1
            dbgKind = fr.full == true and "K" or (fr.full == "rect" and "R" or "D")
            dbgTag()
            if dbgN % 100 == 0 then
                print("f" .. dbgN .. " " .. dbgKind .. " vq" .. #vQueue ..
                      " aq" .. #aQueue .. " drop" .. dropped ..
                      " rs" .. resyncs .. " be" .. cntBlitErr ..
                      " done" .. tostring(fetch_done))
            end
            -- скип мог выкинуть кейфрейм: если дельта пришла без базы, ждем следующий K
            n = n + 1
            m = m + 1
            vTime = m / fps
            if aTime >= vTime - 0.5 then avWaited = 0 end
            if n >= total_frames and fetch_done then break end
            local target = t0 + m * interval * 1000
            local now2 = os.epoch("utc")
            if target > now2 then sleep((target - now2) / 1000) end
        elseif #vQueue > 0 then
            -- av-wait: звук отстал больше секунды (пролаг) - стоим на месте,
            -- двигаем часы как на паузе. Иначе скип убежит вперед, а звук
            -- догонять не умеет и отстанет навсегда.
            sleep(0.1)
            t0 = t0 + 100
            avWaited = avWaited + 100
        elseif fetch_done then
            break
        else
            sleep(0.02)
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

-- враппер потоков: любая ошибка печатается СРАЗУ с именем потока
-- (раньше тихая смерть видеопотока выглядела как "стоп-кадр + звук идет"),
-- Terminated (Ctrl+T) пробрасываем дальше чтобы не стать неубиваемым
if #speakers > 0 then
    parallel.waitForAll(fetcher, playVideoBuffered, playAudioBuffered, watchPause)
else
    parallel.waitForAll(fetcher, playVideoBuffered, watchPause)
end

restorePalette()
monitor.setCursorPos(1, mh)
print("done. dropped(skipped late): " .. dropped .. " resyncs: " .. resyncs .. " blitErr: " .. cntBlitErr .. " audioDrop: " .. droppedA .. " - Ctrl+T for new link")
-- цепочка частей (полный метр в нескольких релизах): афиша говорит next -
-- сами подхватываем следующую часть как "одно видео" (пауза на докачку).
if meta.next and meta.next ~= job then
    print("next part: " .. meta.next .. " - loading...")
    sleep(2)
    shell.run(shell.getRunningProgram(), meta.next)
end
