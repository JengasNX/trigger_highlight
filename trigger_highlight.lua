--[[
  Trigger Highlight v1.2
  Подсветка слов-триггеров в чате для администрации (GTA:SA / SA-MP, Arizona RP)

  Требования:
    - MoonLoader + SAMP.Lua (папка samp -> moonloader/lib/)
    - mimgui (github.com/THE-FYP/mimgui) — для графического меню.
      Если mimgui не установлен, скрипт автоматически работает в режиме
      команд (см. ниже).

  Файлы:
    - moonloader/trigger_words.txt            — слова-триггеры (UTF-8)
    - moonloader/config/trigger_highlight.ini — настройки (через inicfg)

  Кодировка: скрипт и файл слов — UTF-8; чат SA-MP работает в CP1251,
  поэтому всё автоматически конвертируется на границе (вход и вывод).

  Управление:
    /trig — открыть/закрыть меню (ESC тоже закрывает).

  Все настройки (вкл/выкл, слова, журнал, цвета, память) — ТОЛЬКО в меню.
  Команд настройки больше нет; без mimgui доступны запасные команды:
    /trigadd X, /trigdel X, /triglist, /trigid, /triglog, /trigclear
]]

script_name('Trigger Highlight')
script_description('Подсветка слов-триггеров в чате для администрации')
script_author('JengasZ')
script_version('1.2.0')

local eventsOk, sampev = pcall(require, 'samp.events')
if not eventsOk then sampev = nil end

local hasFfi,   ffi   = pcall(require, 'ffi')
local hasImgui, imgui = pcall(require, 'mimgui')
local hasIni,   inicfg = pcall(require, 'inicfg')
local MENU_OK = hasImgui and hasFfi

-- ======================== НАСТРОЙКИ ========================
local cfg = {
  enabled     = true,           -- подсветка включена при старте
  marker      = '{FF2222}[!] ', -- метка в начале сработавшего сообщения
  markerHex   = 'FF2222',
  bodyColor   = '{FF8888}',     -- цвет подсветки текста сообщения
  bodyHex     = 'FF8888',
  notify      = true,           -- доп. строка-уведомление с деталями
  notifyColor = 0xFFFF2222,     -- цвет уведомления (ARGB), выводится цветом метки
  remember    = 20,             -- сколько срабатываний помнить в журнале
}
-- ===========================================================

local SETTINGS_FILE = 'trigger_highlight.ini'
local WORDS_FILE = (getWorkingDirectory():gsub('\\+$', '')) .. '\\trigger_words.txt'

local function applyColors()
  cfg.marker    = '{' .. cfg.markerHex .. '}[!] '
  cfg.bodyColor = '{' .. cfg.bodyHex .. '}'
  cfg.notifyColor = 0xFF000000 + (tonumber(cfg.markerHex, 16) or 0xFF2222)
end

local function toBool(v)
  return v == true or v == 1 or v == '1' or v == 'true'
end

local function loadSettings()
  local defaults = {
    main = {
      enabled = 1,
      notify = 1,
      remember = cfg.remember,
      marker = cfg.markerHex,
      body = cfg.bodyHex,
    },
  }
  local data = defaults
  if hasIni then
    local ok, res = pcall(inicfg.load, defaults, SETTINGS_FILE)
    if ok and type(res) == 'table' and type(res.main) == 'table' then
      data = res
    end
  end
  local m = data.main
  cfg.enabled = toBool(m.enabled)
  cfg.notify  = toBool(m.notify)
  cfg.remember = math.floor(tonumber(m.remember) or 20)
  if cfg.remember < 5 then cfg.remember = 5 end
  if cfg.remember > 100 then cfg.remember = 100 end
  cfg.markerHex = tostring(m.marker or ''):match('^%x%x%x%x%x%x$') and tostring(m.marker):upper() or cfg.markerHex
  cfg.bodyHex   = tostring(m.body or ''):match('^%x%x%x%x%x%x$') and tostring(m.body):upper() or cfg.bodyHex
  applyColors()
end

local function saveSettings()
  if not hasIni then return false end
  local defaults = {
    main = {
      enabled = cfg.enabled and 1 or 0,
      notify = cfg.notify and 1 or 0,
      remember = cfg.remember,
      marker = cfg.markerHex,
      body = cfg.bodyHex,
    },
  }
  -- читаем текущий файл (чтобы не потерять чужие ключи), затем пишем своё
  local okLoad, res = pcall(inicfg.load, defaults, SETTINGS_FILE)
  local target = (okLoad and type(res) == 'table' and type(res.main) == 'table')
      and res or defaults
  target.main.enabled  = cfg.enabled and 1 or 0
  target.main.notify   = cfg.notify and 1 or 0
  target.main.remember = cfg.remember
  target.main.marker   = cfg.markerHex
  target.main.body     = cfg.bodyHex
  local okSave, result = pcall(inicfg.save, target, SETTINGS_FILE)
  return okSave and result and true or false
end

loadSettings()

local function settingsSnapshot()
  return table.concat({
    tostring(cfg.enabled), tostring(cfg.notify), tostring(cfg.remember),
    cfg.markerHex, cfg.bodyHex,
  }, '|')
end

local savedSnapshot = settingsSnapshot()

local FILE_HEADER = {
  '# Слова-триггеры: по одному на строку.',
  '# Строки, начинающиеся с #, игнорируются.',
  '# Регистр не важен, пробелы/знаки внутри сообщения игнорируются.',
  '# Управление: /trig — меню.',
}

local DEFAULT_WORDS = {
  'реклама',
  'discord.gg',
  'слово-пример',
}

local words     = {}   -- слова-триггеры (UTF-8)
local queue     = {}   -- очередь строк для вывода в чат
local log       = {}   -- журнал срабатываний (новые в начале)
local lastHit   = nil
local totalHits = 0    -- всего срабатываний за сессию

----------------------------------------------------------------
-- Нормализация текста (устойчивость к обходам фильтра)
----------------------------------------------------------------

-- карта заглавных кириллических -> строчные (UTF-8, 2 байта)
local LOWER = {}
for b = 0x90, 0x9F do -- А..П
  LOWER[string.char(0xD0, b)] = string.char(0xD0, b + 0x20)
end
for b = 0xA0, 0xAF do -- Р..Я
  LOWER[string.char(0xD1, b)] = string.char(0xD1, b - 0x20)
end
LOWER[string.char(0xD0, 0x81)] = string.char(0xD1, 0x91) -- Ё -> ё

-- похожая латиница -> кириллица (символ в символ, одинаково для слов и сообщений)
local LOOK = {
  a='а', b='в', c='с', d='д', e='е', f='ф', g='г', h='н',
  i='и', j='й', k='к', l='л', m='м', n='п', o='о', p='р',
  q='з', r='г', s='с', t='т', u='и', v='ж', w='ш', x='х',
  y='у', z='з',
}

local function asciiLower(s)
  -- только ASCII A-Z -> a-z, без string.lower() (в MSVC-сборках Lua
  -- string.lower()/%s/%p портят кириллические байты)
  return (s:gsub('[A-Z]', function(c) return string.char(c:byte() + 32) end))
end

local function lowerRu(s)
  s = asciiLower(s)
  return (s:gsub('[\208\209][\128-\191]', function(c) return LOWER[c] or c end))
end

local function stripColors(s)
  s = s:gsub('{[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]}', '')
  s = s:gsub('~[A-Za-z0-9]~', '')
  return s
end

-- приводит строку к "чистому" виду: нижний регистр, без цветов,
-- без пробелов/знаков/цифр, латиница заменена на кириллицу
local function normalize(s)
  s = lowerRu(stripColors(s))
  s = s:gsub('[a-z]', LOOK)
  s = s:gsub('[0-9]', '')
  s = s:gsub('[^%w\128-\255]', '') -- убрать всё ASCII кроме букв/цифр, высокие байты не трогать
  return s
end

local function utf8Trim(s, n)
  local r = s:sub(1, n)
  while #r > 0 and r:byte(-1) >= 128 do r = r:sub(1, -2) end
  return r
end

local function trimAscii(s)
  return (s:match('^[ \t]*(.-)[ \t]*$'))
end

----------------------------------------------------------------
-- Кодировки: чат SA-MP работает в CP1251, а скрипт и файл слов —
-- в UTF-8. Без конвертации кириллица в чате превращается в мусор,
-- а кириллические слова-триггеры не находят входящие сообщения.
----------------------------------------------------------------

-- байт CP1251 (128..255) -> номер Unicode (сгенерировано из cp1251)
local CP1251 = {
  [128]=0x402, [129]=0x403, [130]=0x201A, [131]=0x453, [132]=0x201E, [133]=0x2026, [134]=0x2020, [135]=0x2021, [136]=0x20AC, [137]=0x2030, [138]=0x409, [139]=0x2039, [140]=0x40A, [141]=0x40C, [142]=0x40B, [143]=0x40F, [144]=0x452, [145]=0x2018, [146]=0x2019, [147]=0x201C, [148]=0x201D, [149]=0x2022, [150]=0x2013, [151]=0x2014, [153]=0x2122, [154]=0x459, [155]=0x203A, [156]=0x45A, [157]=0x45C, [158]=0x45B, [159]=0x45F, [160]=0xA0, [161]=0x40E, [162]=0x45E, [163]=0x408, [164]=0xA4, [165]=0x490, [166]=0xA6, [167]=0xA7, [168]=0x401, [169]=0xA9, [170]=0x404, [171]=0xAB, [172]=0xAC, [173]=0xAD, [174]=0xAE, [175]=0x407, [176]=0xB0, [177]=0xB1, [178]=0x406, [179]=0x456, [180]=0x491, [181]=0xB5, [182]=0xB6, [183]=0xB7, [184]=0x451, [185]=0x2116, [186]=0x454, [187]=0xBB, [188]=0x458, [189]=0x405, [190]=0x455, [191]=0x457, [192]=0x410, [193]=0x411, [194]=0x412, [195]=0x413, [196]=0x414, [197]=0x415, [198]=0x416, [199]=0x417, [200]=0x418, [201]=0x419, [202]=0x41A, [203]=0x41B, [204]=0x41C, [205]=0x41D, [206]=0x41E, [207]=0x41F, [208]=0x420, [209]=0x421, [210]=0x422, [211]=0x423, [212]=0x424, [213]=0x425, [214]=0x426, [215]=0x427, [216]=0x428, [217]=0x429, [218]=0x42A, [219]=0x42B, [220]=0x42C, [221]=0x42D, [222]=0x42E, [223]=0x42F, [224]=0x430, [225]=0x431, [226]=0x432, [227]=0x433, [228]=0x434, [229]=0x435, [230]=0x436, [231]=0x437, [232]=0x438, [233]=0x439, [234]=0x43A, [235]=0x43B, [236]=0x43C, [237]=0x43D, [238]=0x43E, [239]=0x43F, [240]=0x440, [241]=0x441, [242]=0x442, [243]=0x443, [244]=0x444, [245]=0x445, [246]=0x446, [247]=0x447, [248]=0x448, [249]=0x449, [250]=0x44A, [251]=0x44B, [252]=0x44C, [253]=0x44D, [254]=0x44E, [255]=0x44F,
}

-- обратная карта: номер Unicode -> байт CP1251
local CP1251_REV = {}
for b = 128, 255 do
  local u = CP1251[b]
  if u then CP1251_REV[u] = b end
end

-- кодировка чата по входящим данным: nil — ещё не определена
-- (для вывода по умолчанию считаем CP1251, это верно для SA-MP)
local chatEnc = nil

local function hasHighByte(s)
  return s:find('[\128-\255]') ~= nil
end

-- проверка, что строка является корректным UTF-8
local function isUtf8(s)
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      i = i + 1
    elseif b >= 0xC2 and b <= 0xDF and i + 1 <= n
        and s:byte(i + 1) >= 0x80 and s:byte(i + 1) <= 0xBF then
      i = i + 2
    elseif b >= 0xE0 and b <= 0xEF and i + 2 <= n
        and s:byte(i + 1) >= 0x80 and s:byte(i + 1) <= 0xBF
        and s:byte(i + 2) >= 0x80 and s:byte(i + 2) <= 0xBF then
      i = i + 3
    elseif b >= 0xF0 and b <= 0xF4 and i + 3 <= n
        and s:byte(i + 1) >= 0x80 and s:byte(i + 1) <= 0xBF
        and s:byte(i + 2) >= 0x80 and s:byte(i + 2) <= 0xBF
        and s:byte(i + 3) >= 0x80 and s:byte(i + 3) <= 0xBF then
      i = i + 4
    else
      return false
    end
  end
  return true
end

-- номер Unicode -> строка UTF-8
local function utf8Char(u)
  if u < 0x80 then
    return string.char(u)
  elseif u < 0x800 then
    return string.char(0xC0 + math.floor(u / 0x40), 0x80 + u % 0x40)
  elseif u < 0x10000 then
    return string.char(0xE0 + math.floor(u / 0x1000),
                       0x80 + math.floor(u / 0x40) % 0x40,
                       0x80 + u % 0x40)
  end
  return '?'
end

local function cp1251ToUtf8(s)
  local out = {}
  for i = 1, #s do
    local b = s:byte(i)
    if b < 0x80 then
      out[#out + 1] = string.char(b)
    else
      out[#out + 1] = utf8Char(CP1251[b] or 63)
    end
  end
  return table.concat(out)
end

local function utf8ToCp1251(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b < 0x80 then
      out[#out + 1] = string.char(b)
      i = i + 1
    else
      local u, len
      if b >= 0xC2 and b <= 0xDF then
        u, len = b % 0x20, 2
      elseif b >= 0xE0 and b <= 0xEF then
        u, len = b % 0x10, 3
      elseif b >= 0xF0 and b <= 0xF4 then
        u, len = b % 0x08, 4
      else
        out[#out + 1] = '?'
        i = i + 1
      end
      if len then
        local ok = (i + len - 1 <= n)
        if ok then
          for k = 1, len - 1 do
            local cb = s:byte(i + k)
            if cb < 0x80 or cb > 0xBF then
              ok = false
              break
            end
            u = u * 0x40 + (cb - 0x80)
          end
        end
        if ok then
          out[#out + 1] = string.char(CP1251_REV[u] or 63)
          i = i + len
        else
          out[#out + 1] = '?'
          i = i + 1
        end
      end
    end
  end
  return table.concat(out)
end

-- входящая строка из чата/команд -> UTF-8; заодно уточняем кодировку
-- чата: не-UTF-8 вход однозначно означает CP1251 (для вывода)
local function toUtf8(s)
  if not hasHighByte(s) then return s end
  if isUtf8(s) then
    if chatEnc == nil then chatEnc = 'utf8' end
    return s
  end
  chatEnc = 'cp1251'
  return cp1251ToUtf8(s)
end

-- UTF-8 -> кодировка чата (для sampAddChatMessage)
local function fromUtf8(s)
  if not hasHighByte(s) then return s end
  if chatEnc == 'utf8' then return s end
  return utf8ToCp1251(s)
end

----------------------------------------------------------------
-- Файл со словами
----------------------------------------------------------------

local function saveWords()
  local f = io.open(WORDS_FILE, 'w')
  if not f then return false end
  for _, l in ipairs(FILE_HEADER) do f:write(l, '\n') end
  for _, w in ipairs(words) do f:write(w, '\n') end
  f:close()
  return true
end

local function loadWords()
  words = {}
  local f = io.open(WORDS_FILE, 'r')
  if not f then
    for _, w in ipairs(DEFAULT_WORDS) do words[#words + 1] = w end
    saveWords()
    return
  end
  for line in f:lines() do
    local w = trimAscii(line)
    if w ~= '' and w:sub(1, 1) ~= '#' then words[#words + 1] = w end
  end
  f:close()
end

----------------------------------------------------------------
-- Общие операции (меню и запасные команды)
----------------------------------------------------------------

local ui = nil -- состояние меню (заполняется ниже, если mimgui доступен)

-- добавляет слово; возвращает ok, сообщение
local function addWord(raw)
  local word = trimAscii(tostring(raw or ''))
  if word == '' then return false, 'введите слово' end
  local n = lowerRu(word)
  for _, w in ipairs(words) do
    if lowerRu(w) == n then
      return false, 'уже есть в списке: ' .. w
    end
  end
  words[#words + 1] = word
  saveWords()
  return true, 'добавлено: ' .. word
end

-- удаляет слово по индексу (1-based)
local function delWordAt(i)
  if type(i) ~= 'number' or i < 1 or i > #words then return false end
  local removed = table.remove(words, i)
  saveWords()
  if ui and ui.selWord[0] >= #words then
    ui.selWord[0] = #words - 1
  end
  return true, removed
end

local function clearLog()
  log = {}
  lastHit = nil
  if ui then ui.selLog = nil end
end

local function pushMsg(text)
  queue[#queue + 1] = text
end

local function pushLog(entry)
  table.insert(log, 1, entry)
  while #log > cfg.remember do table.remove(log) end
end

-- достаёт ник и ID автора из форматов "Nick[123]:", "Имя Фамилия[123]:", "(123) Имя:"
local function extractPlayer(text)
  local nick, id = text:match('([A-Za-z0-9_]+)[ \t]*%[([0-9]+)%]')
  if nick then return nick, tonumber(id) end

  id = text:match('%[([0-9]+)%]')
  if id then
    nick = trimAscii(text:match('^([^:%{%[]+)') or '')
    if nick == '' then nick = nil end
    return nick or '?', tonumber(id)
  end

  nick, id = text:match('([A-Za-z0-9_]+)[ \t]+%(([0-9]+)%)')
  if nick then return nick, tonumber(id) end

  id = text:match('%(([0-9]+)%)')
  if id then return '?', tonumber(id) end

  return nil, nil
end

local function findTrigger(normalizedMsg)
  for _, w in ipairs(words) do
    local wn = normalize(w)
    if #wn > 0 and normalizedMsg:find(wn, 1, true) then
      return w
    end
  end
  return nil
end

----------------------------------------------------------------
-- Меню (mimgui)
----------------------------------------------------------------

local WIN_W, WIN_H = 660.0, 520.0

local function hexToRgb(hex)
  return (tonumber(hex:sub(1, 2), 16) or 0) / 255,
         (tonumber(hex:sub(3, 4), 16) or 0) / 255,
         (tonumber(hex:sub(5, 6), 16) or 0) / 255
end

local function rgbToHex(r, g, b)
  local function c(v)
    v = math.floor((v or 0) * 255 + 0.5)
    if v < 0 then v = 0 elseif v > 255 then v = 255 end
    return string.format('%02X', v)
  end
  return c(r) .. c(g) .. c(b)
end

local function float3FromHex(hex)
  local r, g, b = hexToRgb(hex)
  return imgui.new.float[3]({ r, g, b })
end

local function setStatus(msg)
  if not ui then return end
  ui.status = tostring(msg or '')
  ui.statusT = os.clock()
end

local function copyLogId()
  local e = ui and ui.selLog
  if not e then setStatus('запись не выбрана'); return end
  if not e.id then setStatus('ID неизвестен для этой записи'); return end
  setClipboardText(tostring(e.id))
  setStatus(('ID %d скопирован'):format(e.id))
end

local function copyLogNick()
  local e = ui and ui.selLog
  if not e then setStatus('запись не выбрана'); return end
  if e.id then
    setClipboardText(('%s[%d]'):format(e.nick, e.id))
  else
    setClipboardText(e.nick)
  end
  setStatus('автор скопирован')
end

local function clearLogUi()
  clearLog()
  setStatus('журнал очищен')
end

local function addWordFromInput()
  local word = trimAscii(ffi.string(ui.word))
  if word == '' then setStatus('введите слово'); return end
  if #word > 64 then setStatus('слишком длинное слово (макс. 64 байта)'); return end
  local ok, msg = addWord(word)
  setStatus(msg)
  if ok then
    imgui.StrCopy(ui.word, '')
    ui.selWord[0] = #words - 1
  end
end

local menuCond = nil
local menuFrame = nil
local drawMenu = nil

if MENU_OK then

  ui = {
    open        = imgui.new.bool(false),
    enabled     = imgui.new.bool(cfg.enabled),
    notify      = imgui.new.bool(cfg.notify),
    remember    = imgui.new.int(cfg.remember),
    markerRGB   = float3FromHex(cfg.markerHex),
    bodyRGB     = float3FromHex(cfg.bodyHex),
    word        = imgui.new.char[128](''),
    selWord     = imgui.new.int(-1),
    selLog      = nil,
    status      = '',
    statusT     = -10,
    focusInput  = false,
    anim        = 0,
  }

  imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
  end)

  drawMenu = function(self)
    self.HideCursor = false
    self.LockPlayer = ui.open[0]

    -- мягкая анимация появления/исчезновения
    local target = ui.open[0] and 1 or 0
    ui.anim = ui.anim + (target - ui.anim) * 0.18
    if target == 0 and ui.anim < 0.006 then ui.anim = 0 end

    local ar, ag, ab = hexToRgb(cfg.markerHex)
    local accent = imgui.ImVec4(ar, ag, ab, 1.0)
    local accentDim = imgui.ImVec4(ar * 0.75, ag * 0.75, ab * 0.75, 1.0)

    local sx, sy = getScreenResolution()
    imgui.SetNextWindowPos(imgui.ImVec2(sx / 2, sy / 2), imgui.Cond.Appearing, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(WIN_W, WIN_H), imgui.Cond.Always)

    local np = 0
    local function pc(col, v)
      imgui.PushStyleColor(col, v)
      np = np + 1
    end

    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, 6.0)
    imgui.PushStyleVarFloat(imgui.StyleVar.ChildRounding, 8.0)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(16.0, 14.0))
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8.0, 7.0))
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, ui.anim)

    pc(imgui.Col.WindowBg,        imgui.ImVec4(0.055, 0.062, 0.085, 0.97))
    pc(imgui.Col.ChildBg,         imgui.ImVec4(0.035, 0.040, 0.055, 0.90))
    pc(imgui.Col.Border,          imgui.ImVec4(ar * 0.45, ag * 0.45, ab * 0.45, 0.85))
    pc(imgui.Col.Text,            imgui.ImVec4(0.90, 0.91, 0.94, 1.0))
    pc(imgui.Col.TextDisabled,    imgui.ImVec4(0.52, 0.55, 0.62, 1.0))
    pc(imgui.Col.FrameBg,         imgui.ImVec4(0.10, 0.115, 0.15, 1.0))
    pc(imgui.Col.FrameBgHovered,  imgui.ImVec4(0.14, 0.16, 0.21, 1.0))
    pc(imgui.Col.FrameBgActive,   imgui.ImVec4(0.17, 0.19, 0.25, 1.0))
    pc(imgui.Col.Button,          imgui.ImVec4(0.13, 0.15, 0.20, 1.0))
    pc(imgui.Col.ButtonHovered,   imgui.ImVec4(ar, ag, ab, 0.85))
    pc(imgui.Col.ButtonActive,    imgui.ImVec4(ar * 0.8, ag * 0.8, ab * 0.8, 1.0))
    pc(imgui.Col.Header,          imgui.ImVec4(ar * 0.35, ag * 0.35, ab * 0.35, 0.95))
    pc(imgui.Col.HeaderHovered,   imgui.ImVec4(ar * 0.45, ag * 0.45, ab * 0.45, 0.95))
    pc(imgui.Col.HeaderActive,    imgui.ImVec4(ar * 0.55, ag * 0.55, ab * 0.55, 1.0))
    pc(imgui.Col.CheckMark,       accent)
    pc(imgui.Col.SliderGrab,      accent)
    pc(imgui.Col.SliderGrabActive, accent)
    pc(imgui.Col.Separator,       imgui.ImVec4(ar * 0.4, ag * 0.4, ab * 0.4, 0.6))
    pc(imgui.Col.ScrollbarBg,     imgui.ImVec4(0.0, 0.0, 0.0, 0.25))
    pc(imgui.Col.ScrollbarGrab,   imgui.ImVec4(ar * 0.5, ag * 0.5, ab * 0.5, 0.8))
    pc(imgui.Col.PopupBg,         imgui.ImVec4(0.07, 0.08, 0.11, 0.98))

    imgui.Begin('TriggerHighlightWin', nil,
      imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize)

    -- состояние виджетов -> настройки (каждый кадр, без задержек)
    cfg.enabled  = ui.enabled[0]
    cfg.notify   = ui.notify[0]
    local rem = math.floor(ui.remember[0] or cfg.remember)
    if rem < 5 then rem = 5 elseif rem > 100 then rem = 100 end
    cfg.remember = rem
    ui.remember[0] = rem
    while #log > cfg.remember do table.remove(log) end
    if ui.selLog then
      local found = false
      for _, e in ipairs(log) do
        if e == ui.selLog then found = true break end
      end
      if not found then ui.selLog = nil end
    end
    local mh = rgbToHex(ui.markerRGB[0], ui.markerRGB[1], ui.markerRGB[2])
    local bh = rgbToHex(ui.bodyRGB[0], ui.bodyRGB[1], ui.bodyRGB[2])
    if mh ~= cfg.markerHex or bh ~= cfg.bodyHex then
      cfg.markerHex = mh
      cfg.bodyHex = bh
      applyColors()
    end
    local snap = settingsSnapshot()
    if snap ~= savedSnapshot then
      savedSnapshot = snap
      saveSettings()
    end

    -- ===== шапка =====
    imgui.SetWindowFontScale(1.30)
    imgui.TextColored(accent, 'TRIGGER HIGHLIGHT')
    imgui.SetWindowFontScale(1.0)
    local closeX = imgui.GetCursorPosX() + imgui.GetContentRegionAvail().x - 26.0
    imgui.SameLine(closeX)
    if imgui.Button('X', imgui.ImVec2(26.0, 26.0)) then
      ui.open[0] = false
    end
    imgui.Separator()

    -- ===== строка переключателя =====
    imgui.Checkbox('Подсветка в чате', ui.enabled)
    imgui.SameLine()
    if ui.enabled[0] then
      imgui.TextColored(imgui.ImVec4(0.35, 0.95, 0.45, 1.0), 'ВКЛ')
    else
      imgui.TextColored(imgui.ImVec4(0.95, 0.40, 0.40, 1.0), 'ВЫКЛ')
    end
    imgui.SameLine()
    imgui.TextDisabled(('· срабатываний: %d · в журнале: %d'):format(totalHits, #log))

    -- ===== две колонки: слова | журнал =====
    imgui.Columns(2, '##trigcols', false)
    imgui.SetColumnOffset(1, 264.0)

    -- ЛЕВАЯ: слова-триггеры
    imgui.TextColored(accentDim, 'СЛОВА-ТРИГГЕРЫ')
    imgui.SameLine()
    imgui.TextDisabled(('(%d)'):format(#words))
    imgui.BeginChild('##wordslist', imgui.ImVec2(250.0, 170.0), true)
    if #words == 0 then
      imgui.TextUnformatted('список пуст')
    end
    for i, w in ipairs(words) do
      if imgui.Selectable(w .. '##w' .. i, ui.selWord[0] == i - 1) then
        ui.selWord[0] = i - 1
      end
    end
    imgui.EndChild()

    if ui.focusInput then
      imgui.SetKeyboardFocusHere()
      ui.focusInput = false
    end
    imgui.PushItemWidth(214.0)
    local wordTyped = imgui.InputTextWithHint('##newword', 'новое слово...',
      ui.word, ffi.sizeof(ui.word), imgui.InputTextFlags.EnterReturnsTrue)
    imgui.PopItemWidth()
    imgui.SameLine()
    if imgui.Button('+', imgui.ImVec2(26.0, 0.0)) then
      wordTyped = true
    end
    if wordTyped then
      addWordFromInput()
    end

    if ui.selWord[0] >= 0 and ui.selWord[0] < #words then
      if imgui.Button('Удалить выбранное', imgui.ImVec2(250.0, 0.0)) then
        local idx = ui.selWord[0] + 1
        local _, removed = delWordAt(idx)
        if removed then setStatus('удалено: ' .. removed) end
      end
    else
      imgui.TextDisabled('выберите слово для удаления')
    end
    local yEndLeft = imgui.GetCursorPosY()

    -- ПРАВАЯ: журнал
    imgui.NextColumn()
    imgui.TextColored(accentDim, 'ЖУРНАЛ СРАБАТЫВАНИЙ')
    imgui.SameLine()
    imgui.TextDisabled(('(%d)'):format(#log))
    imgui.BeginChild('##loglist', imgui.ImVec2(0.0, 170.0), true)
    if #log == 0 then
      imgui.TextUnformatted('журнал пуст')
    end
    for i, e in ipairs(log) do
      local label = ('%s  %s[%s]  %s##e%d'):format(e.time, e.nick, e.id or '?', e.word, i)
      if imgui.Selectable(label, ui.selLog == e) then
        ui.selLog = e
      end
    end
    imgui.EndChild()

    imgui.BeginChild('##logdetail', imgui.ImVec2(0.0, 42.0), true)
    if ui.selLog then
      imgui.PushTextWrapPos(0.0)
      imgui.TextUnformatted(ui.selLog.time .. '  ' .. ui.selLog.text)
      imgui.PopTextWrapPos()
    else
      imgui.TextDisabled('выберите запись, чтобы увидеть текст')
    end
    imgui.EndChild()

    if imgui.Button('Скопировать ID', imgui.ImVec2(130.0, 0.0)) then copyLogId() end
    imgui.SameLine()
    if imgui.Button('Ник', imgui.ImVec2(75.0, 0.0)) then copyLogNick() end
    imgui.SameLine()
    if imgui.Button('Очистить', imgui.ImVec2(110.0, 0.0)) then clearLogUi() end

    local yEndRight = imgui.GetCursorPosY()
    imgui.Columns(1, nil, false)
    imgui.SetCursorPosY(math.max(yEndLeft, yEndRight) + 6.0)

    -- ===== настройки =====
    imgui.TextColored(accentDim, 'НАСТРОЙКИ')
    imgui.Checkbox('Уведомление в чате', ui.notify)
    imgui.SameLine()
    imgui.PushItemWidth(200.0)
    imgui.SliderInt('Память журнала', ui.remember, 5, 100, '%d')
    imgui.PopItemWidth()

    imgui.PushItemWidth(150.0)
    imgui.ColorEdit3('Метка [!]', ui.markerRGB)
    imgui.SameLine()
    imgui.ColorEdit3('Цвет текста', ui.bodyRGB)
    imgui.PopItemWidth()

    -- ===== подвал: статус или подсказка =====
    imgui.Separator()
    if ui.status ~= '' and (os.clock() - ui.statusT) < 3.0 then
      imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.45, 0.95, 0.55, 1.0))
      imgui.TextUnformatted(ui.status)
      imgui.PopStyleColor()
    else
      imgui.TextDisabled('ESC или /trig — закрыть меню')
    end

    imgui.End()
    imgui.PopStyleColor(np)
    imgui.PopStyleVar(7)
  end

  menuCond = function()
    return ui.open[0] or ui.anim > 0.005
  end

  menuFrame = imgui.OnFrame(menuCond, drawMenu)
end

----------------------------------------------------------------
-- Закрытие по ESC
----------------------------------------------------------------

local function chatBlocked()
  if type(sampIsChatInputActive) == 'function' and sampIsChatInputActive() then return true end
  if type(sampIsDialogActive) == 'function' and sampIsDialogActive() then return true end
  if type(isPauseMenuActive) == 'function' and isPauseMenuActive() then return true end
  return false
end

function onWindowMessage(msg, wparam, lparam)
  if not MENU_OK then return end
  if msg == 0x100 and wparam == 0x1B and ui and ui.open[0] then -- WM_KEYDOWN, VK_ESCAPE
    if not chatBlocked() then
      ui.open[0] = false
      if type(consumeWindowMessage) == 'function' then
        consumeWindowMessage(true, false)
      end
    end
  end
end

----------------------------------------------------------------
-- Обработчики SAMP.Lua
----------------------------------------------------------------

if sampev then

  function sampev.onServerMessage(color, text)
    if not cfg.enabled then return end

    local plain = stripColors(toUtf8(text))
    local norm  = normalize(plain)
    if #norm == 0 then return end

    local hit = findTrigger(norm)
    if not hit then return end

    local nick, id = extractPlayer(plain)
    local entry = {
      time = os.date('%H:%M:%S'),
      word = hit,
      nick = nick or '?',
      id   = id,
      text = plain,
    }
    lastHit = entry
    totalHits = totalHits + 1
    pushLog(entry)

    if cfg.notify then
      pushMsg(('[ТРИГГЕР] слово: %s | автор: %s | /trig — меню'):format(
        hit, id and (entry.nick .. '[' .. id .. ']') or entry.nick))
    end

    -- перекрашиваем сработавшееся сообщение
    return { color, cfg.marker .. cfg.bodyColor .. text }
  end

  function sampev.onSendCommand(cmd)
    local name, args = cmd:match('^/([^ \t]+)[ \t]*(.*)$')
    if not name then return end
    name = asciiLower(name)
    args = toUtf8(args or '')

    if name == 'trig' then
      if MENU_OK then
        ui.open[0] = not ui.open[0]
        if ui.open[0] then ui.focusInput = true end
        return false
      end
      cfg.enabled = not cfg.enabled
      pushMsg(('[ТРИГГЕР] подсветка %s'):format(cfg.enabled and 'ВКЛЮЧЕНА' or 'ВЫКЛЮЧЕНА'))
      return false
    end

    -- Команды настройки нужны только как запасной вариант,
    -- если меню недоступно (нет mimgui).
    if MENU_OK then return end

    if name == 'trigadd' then
      local word = trimAscii(args)
      if word == '' then
        pushMsg('[ТРИГГЕР] использование: /trigadd слово')
        return false
      end
      local ok, msg = addWord(word)
      pushMsg('[ТРИГГЕР] ' .. msg)
      return false

    elseif name == 'trigdel' then
      local word = lowerRu(trimAscii(args))
      if word == '' then
        pushMsg('[ТРИГГЕР] использование: /trigdel слово')
        return false
      end
      for i = #words, 1, -1 do
        if lowerRu(words[i]) == word then
          local _, removed = delWordAt(i)
          pushMsg('[ТРИГГЕР] удалено: ' .. tostring(removed))
          return false
        end
      end
      pushMsg('[ТРИГГЕР] слово не найдено: ' .. word)
      return false

    elseif name == 'triglist' then
      pushMsg(('[ТРИГГЕР] слов в списке: %d (файл: trigger_words.txt)'):format(#words))
      for _, w in ipairs(words) do pushMsg('  - ' .. w) end
      return false

    elseif name == 'trigid' then
      if lastHit and lastHit.id then
        setClipboardText(tostring(lastHit.id))
        pushMsg(('[ТРИГГЕР] ID %d скопирован (автор: %s)'):format(lastHit.id, lastHit.nick))
      else
        pushMsg('[ТРИГГЕР] ID последнего нарушителя неизвестен')
      end
      return false

    elseif name == 'triglog' then
      if #log == 0 then
        pushMsg('[ТРИГГЕР] журнал пуст')
      else
        pushMsg(('[ТРИГГЕР] последние срабатывания (%d):'):format(#log))
        for _, e in ipairs(log) do
          pushMsg(('  %s | %s[%s] | слово: %s | %s'):format(
            e.time, e.nick, e.id or '?', e.word, utf8Trim(e.text, 60)))
        end
      end
      return false

    elseif name == 'trigclear' then
      clearLog()
      pushMsg('[ТРИГГЕР] журнал очищен')
      return false
    end
  end
end

----------------------------------------------------------------
-- Главный поток
----------------------------------------------------------------

function main()
  if not isSampLoaded() then
    print('[TriggerHighlight] SA-MP не обнаружен, скрипт остановлен.')
    return
  end

  if not sampev then
    print('[TriggerHighlight] НЕ НАЙДЕНА библиотека SAMP.Lua!')
    print('[TriggerHighlight] Скопируйте папку "samp" из SAMP.Lua в moonloader/lib/')
    while true do wait(1000) end
  end

  if not MENU_OK then
    print('[TriggerHighlight] mimgui не найден — меню недоступно.')
    print('[TriggerHighlight] Работают команды: /trig, /trigadd, /trigdel, /triglist, /trigid, /triglog, /trigclear')
    print('[TriggerHighlight] Установите mimgui: github.com/THE-FYP/mimgui')
  end

  while not isSampAvailable() do wait(300) end

  loadWords()

  while true do
    wait(0)
    if #queue > 0 then
      local msg = table.remove(queue, 1)
      if type(sampAddChatMessage) == 'function' then
        sampAddChatMessage(fromUtf8(msg), cfg.notifyColor)
      else
        print(msg)
      end
    end
  end
end

----------------------------------------------------------------
-- Внутренний интерфейс для тестов и отладки
----------------------------------------------------------------

TRIGGER_INTERNAL = {
  menuReady = MENU_OK,
  ui = ui,
  isOpen = function()
    return MENU_OK and ui and ui.open[0] or false
  end,
  cond = function()
    if menuCond then return menuCond() end
    return false
  end,
  draw = function()
    if menuFrame then drawMenu({}) end
  end,
  setWordInput = function(s)
    if MENU_OK then imgui.StrCopy(ui.word, tostring(s or '')) end
  end,
  setStatus = setStatus,
  addWord = addWord,
  delWordAt = delWordAt,
  clearLog = clearLog,
  copyLogId = copyLogId,
  copyLogNick = copyLogNick,
  addWordFromInput = addWordFromInput,
  saveSettings = saveSettings,
  words = function() return words end,
  log = function() return log end,
  getLastHit = function() return lastHit end,
  cfg = cfg,
}
