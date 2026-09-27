--[[
  Trigger Highlight v1.1
  Подсветка слов-триггеров в чате для администрации (GTA:SA / SA-MP, Arizona RP)

  Требования: MoonLoader + SAMP.Lua (папка samp -> moonloader/lib/)
  Файл со словами: moonloader/trigger_words.txt (создаётся при первом запуске)

  Кодировка: скрипт и файл слов — UTF-8; чат SA-MP работает в CP1251,
  поэтому всё автоматически конвертируется на границе (вход и вывод).

  Команды (локальные, на сервер НЕ отправляются):
    /trig       - включить/выключить подсветку
    /trigadd X  - добавить слово-триггер
    /trigdel X  - удалить слово-триггер
    /triglist   - список слов
    /trigid     - скопировать ID последнего нарушителя в буфер обмена
    /triglog    - последние срабатывания
    /trigclear  - очистить журнал
]]

script_name('Trigger Highlight')
script_description('Подсветка слов-триггеров в чате для администрации')
script_author('JengasZ')
script_version('1.1.0')

local eventsOk, sampev = pcall(require, 'samp.events')
if not eventsOk then sampev = nil end

-- ======================== НАСТРОЙКИ ========================
local cfg = {
  enabled     = true,           -- подсветка включена при старте
  marker      = '{FF2222}[!] ', -- метка в начале сработавшего сообщения
  bodyColor   = '{FF8888}',     -- цвет подсветки текста сообщения
  notify      = true,           -- доп. строка-уведомление с деталями
  notifyColor = 0xFFFF4444,     -- цвет уведомления (ARGB)
  remember    = 20,             -- сколько срабатываний помнить в журнале
}
-- ===========================================================

local WORDS_FILE = (getWorkingDirectory():gsub('\\+$', '')) .. '\\trigger_words.txt'

local FILE_HEADER = {
  '# Слова-триггеры: по одному на строку.',
  '# Строки, начинающиеся с #, игнорируются.',
  '# Регистр не важен, пробелы/знаки внутри сообщения игнорируются.',
}

local DEFAULT_WORDS = {
  'реклама',
  'discord.gg',
  'слово-пример',
}

local words  = {}
local queue  = {}   -- очередь строк для вывода в чат
local log    = {}   -- журнал срабатываний (новые в начале)
local lastHit = nil

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
-- Утилиты
----------------------------------------------------------------

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
    pushLog(entry)

    if cfg.notify then
      pushMsg(('[ТРИГГЕР] слово: %s | автор: %s | /trigid - копировать ID'):format(
        hit, id and (entry.nick .. '[' .. id .. ']') or entry.nick))
    end

    -- перекрашиваем сработавшее сообщение
    return { color, cfg.marker .. cfg.bodyColor .. text }
  end

  function sampev.onSendCommand(cmd)
    local name, args = cmd:match('^/([^ \t]+)[ \t]*(.*)$')
    if not name then return end
    name = asciiLower(name)
    args = toUtf8(args or '')

    if name == 'trig' then
      cfg.enabled = not cfg.enabled
      pushMsg(('[ТРИГГЕР] подсветка %s'):format(cfg.enabled and 'ВКЛЮЧЕНА' or 'ВЫКЛЮЧЕНА'))
      return false

    elseif name == 'trigadd' then
      local word = trimAscii(args)
      if word == '' then
        pushMsg('[ТРИГГЕР] использование: /trigadd слово')
        return false
      end
      local n = lowerRu(word)
      for _, w in ipairs(words) do
        if lowerRu(w) == n then
          pushMsg('[ТРИГГЕР] уже есть в списке: ' .. w)
          return false
        end
      end
      words[#words + 1] = word
      saveWords()
      pushMsg('[ТРИГГЕР] добавлено: ' .. word)
      return false

    elseif name == 'trigdel' then
      local word = lowerRu(trimAscii(args or ''))
      if word == '' then
        pushMsg('[ТРИГГЕР] использование: /trigdel слово')
        return false
      end
      for i = #words, 1, -1 do
        if lowerRu(words[i]) == word then
          local removed = table.remove(words, i)
          saveWords()
          pushMsg('[ТРИГГЕР] удалено: ' .. removed)
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
      log = {}
      lastHit = nil
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
