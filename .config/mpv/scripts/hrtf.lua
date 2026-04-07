-- hrtf.lua
-- Менеджер HRTF для mpv
--
-- Горячие клавиши:
--   h          — вкл/выкл HRTF
--   k / l      — предыдущий / следующий профиль
--   Shift+k    — gain −
--   Shift+l    — gain +
--   Shift+h    — перекалибровать текущий профиль
--   Ctrl+h     — перекалибровать все профили

local mp      = require "mp"
local utils   = require "mp.utils"
local options = require "mp.options"
local msg     = mp.msg

-- ─────────────────────────────────────────────────────────────────────────────
-- Настройки (hrtf.conf)
-- ─────────────────────────────────────────────────────────────────────────────

local opts    = {
    hrtf_dir    = "~~/hrtf",
    test_file   = "~~/test_calib.flac",
    target_tp   = -1.0,
    gain_step   = 0.5,
    osd_timeout = 4,
}

options.read_options(opts, "hrtf")

-- ─────────────────────────────────────────────────────────────────────────────
-- Состояние
-- ─────────────────────────────────────────────────────────────────────────────

local profiles    = {}
local cur         = 0
local enabled     = false
local gain_cache  = {}
local offset      = {}
local initialized = false

-- ─────────────────────────────────────────────────────────────────────────────
-- Утилиты
-- ─────────────────────────────────────────────────────────────────────────────

local function expand(p)
    return mp.command_native({ "expand-path", p })
end

local function hrtf_dir()
    return expand(opts.hrtf_dir)
end

local function gain_file(path)
    return path .. ".gain"
end

local function get_offset(path)
    return offset[path] or 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Персистентное состояние
-- ─────────────────────────────────────────────────────────────────────────────

local function state_path()
    return utils.join_path(expand("~~/"), "hrtf_state.json")
end

local function save_state()
    local name = (cur > 0 and profiles[cur]) and profiles[cur].name or ""
    local f = io.open(state_path(), "w")
    if not f then
        msg.warn("HRTF: не удалось сохранить состояние"); return
    end
    f:write(string.format('{"profile":"%s","enabled":%s}\n',
        name:gsub('"', '\\"'), enabled and "true" or "false"))
    f:close()
end

local function load_state()
    local f = io.open(state_path(), "r")
    if not f then return nil, nil end
    local raw = f:read("*a"); f:close()
    local profile = raw:match('"profile"%s*:%s*"([^"]*)"')
    local en      = raw:match('"enabled"%s*:%s*(true|false)')
    return profile, (en == "true")
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Сканирование профилей
-- ─────────────────────────────────────────────────────────────────────────────

local function scan()
    local dir   = hrtf_dir()
    local files = utils.readdir(dir, "files")
    profiles    = {}
    if not files then
        msg.warn("HRTF: директория не найдена: " .. dir)
        return
    end
    for _, f in ipairs(files) do
        if f:lower():match("%.sofa$") then
            table.insert(profiles, { name = f, path = utils.join_path(dir, f) })
        end
    end
    table.sort(profiles, function(a, b) return a.name < b.name end)

    for _, p in ipairs(profiles) do
        local gf = io.open(gain_file(p.path), "r")
        if gf then
            local g = tonumber(gf:read("*a")); gf:close()
            if g then gain_cache[p.path] = g end
        end
    end

    msg.info(string.format("HRTF: найдено %d профилей", #profiles))
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Калибровка
-- ─────────────────────────────────────────────────────────────────────────────

local function calibrate(path, force)
    if not force and gain_cache[path] then return gain_cache[path] end

    if not force then
        local gf = io.open(gain_file(path), "r")
        if gf then
            local g = tonumber(gf:read("*a")); gf:close()
            if g then
                gain_cache[path] = g; return g
            end
        end
    end

    local name = path:match("([^/\\]+)$") or path
    mp.osd_message("HRTF: калибровка " .. name .. "…", 60)

    local test = expand(opts.test_file)
    local src
    local probe = io.open(test, "r")
    if probe then
        probe:close(); src = "amovie=" .. test
    else
        src = "anoisesrc=color=pink:d=15"
    end

    local sofa = path:gsub("'", "'\\''")
    local result = utils.subprocess({
        args = {
            "ffmpeg", "-nostats", "-hide_banner",
            "-f", "lavfi", "-i", src,
            "-filter_complex",
            string.format(
                "sofalizer=sofa='%s':gain=0:normalize=disabled,ebur128=peak=true:metadata=1",
                sofa),
            "-f", "null", "-",
        },
        capture_stderr = true,
        max_size = 2 * 1024 * 1024,
    })

    local tp = nil
    for line in (result.stderr or ""):gmatch("[^\r\n]+") do
        local m = line:match("Peak:%s+([%-%d%.]+)%s+dBFS")
            or line:match("TP[K]?:%s*([%-%d%.]+)")
        if m then
            local n = tonumber(m)
            if n and (tp == nil or n > tp) then tp = n end
        end
    end

    local g = math.max(-40, math.min(40, opts.target_tp - (tp or 0)))

    local gf = io.open(gain_file(path), "w")
    if gf then
        gf:write(string.format("%.2f", g)); gf:close()
    end

    gain_cache[path] = g
    mp.osd_message(string.format(
        "HRTF: калибровка завершена\nTP: %.2f → Gain: %.2f dB", tp or 0, g), 5)
    return g
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Применение фильтра
-- ─────────────────────────────────────────────────────────────────────────────

local function apply()
    if not enabled or cur == 0 or #profiles == 0 then
        mp.set_property("af", "")
        return
    end

    local p      = profiles[cur]
    local base   = calibrate(p.path, false)
    local total  = base + get_offset(p.path)
    local sofa   = p.path:gsub("'", "'\\''")
    local filter = string.format(
        "lavfi=[sofalizer=sofa='%s':gain=%.2f:normalize=disabled:type=freq]",
        sofa, total)

    local ok     = mp.set_property("af", filter)
    if ok == false then
        msg.error("HRTF: ошибка установки фильтра")
        mp.osd_message("HRTF: ошибка sofalizer — проверь путь к файлу", 6)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- OSD
-- ─────────────────────────────────────────────────────────────────────────────

local function osd()
    if not enabled then
        mp.osd_message("HRTF: выключен", opts.osd_timeout)
        return
    end
    if #profiles == 0 then
        mp.osd_message("HRTF: нет профилей в " .. hrtf_dir(), opts.osd_timeout)
        return
    end
    local p    = profiles[cur]
    local base = gain_cache[p.path] or 0
    local off  = get_offset(p.path)
    mp.osd_message(string.format(
        "HRTF  [%d/%d]  %s\n" ..
        "Gain: %.1f dB  (база %.1f  смещение %.1f)\n" ..
        "h: вкл/выкл  k/l: профиль  S+k/l: gain  S+h: рекал  C+h: все",
        cur, #profiles, p.name, base + off, base, off), opts.osd_timeout)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Горячие клавиши
-- ─────────────────────────────────────────────────────────────────────────────

mp.add_key_binding("h", "hrtf-toggle", function()
    if #profiles == 0 then
        mp.osd_message("HRTF: нет профилей", 3); return
    end
    enabled = not enabled
    if enabled and cur == 0 then cur = 1 end
    apply(); osd(); save_state()
end)

mp.add_key_binding("k", "hrtf-prev", function()
    if #profiles == 0 then return end
    if not enabled then enabled = true end
    cur = (cur - 2) % #profiles + 1
    apply(); osd(); save_state()
end)

mp.add_key_binding("l", "hrtf-next", function()
    if #profiles == 0 then return end
    if not enabled then enabled = true end
    cur = cur % #profiles + 1
    apply(); osd(); save_state()
end)

mp.add_key_binding("K", "hrtf-gain-down", function()
    if cur == 0 then return end
    local path = profiles[cur].path
    offset[path] = get_offset(path) - opts.gain_step
    apply(); osd()
end)

mp.add_key_binding("L", "hrtf-gain-up", function()
    if cur == 0 then return end
    local path = profiles[cur].path
    offset[path] = get_offset(path) + opts.gain_step
    apply(); osd()
end)

mp.add_key_binding("H", "hrtf-recal-current", function()
    if cur == 0 then
        mp.osd_message("HRTF: профиль не выбран", 3); return
    end
    local p = profiles[cur]
    gain_cache[p.path] = nil
    os.remove(gain_file(p.path))
    calibrate(p.path, true)
    apply(); osd()
end)

mp.add_key_binding("ctrl+h", "hrtf-recal-all", function()
    if #profiles == 0 then return end
    mp.osd_message(string.format("HRTF: перекалибровка всех (%d)…", #profiles), 60)
    for _, p in ipairs(profiles) do
        gain_cache[p.path] = nil
        os.remove(gain_file(p.path))
        calibrate(p.path, true)
    end
    apply()
    mp.osd_message("HRTF: все профили перекалиброваны", 4)
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Инициализация
-- ─────────────────────────────────────────────────────────────────────────────

mp.register_event("start-file", function()
    if initialized then return end
    initialized = true

    scan()

    local saved_profile, saved_enabled = load_state()
    if saved_enabled ~= nil then enabled = saved_enabled end

    if saved_profile and saved_profile ~= "" then
        for i, p in ipairs(profiles) do
            if p.name == saved_profile then
                cur = i; break
            end
        end
    end
    if cur == 0 and #profiles > 0 then cur = 1 end

    if enabled then apply() end

    msg.info(string.format("HRTF: %d профилей, текущий: %s, включён: %s",
        #profiles,
        cur > 0 and profiles[cur].name or "нет",
        tostring(enabled)))
end)
