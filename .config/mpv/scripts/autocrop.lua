-- autocrop.lua
-- Обрезает чёрные поля по нажатию c.
-- Анализирует кадры через ffmpeg cropdetect вокруг текущей позиции,
-- применяет vf crop. Повторное нажатие снимает crop.
--
-- c — переключить crop

local mp    = require "mp"
local utils = require "mp.utils"
local msg   = mp.msg

-- ─────────────────────────────────────────────────────────────────────────────
-- Настройки (autocrop.conf)
-- ─────────────────────────────────────────────────────────────────────────────

local opts = {
    -- порог яркости для «чёрного» пикселя (0–255)
    black_threshold = 65,
    -- количество кадров для анализа
    frames          = 30,
    -- сколько секунд захватывать для анализа
    scan_duration   = 5,
}

require("mp.options").read_options(opts, "autocrop")

-- ─────────────────────────────────────────────────────────────────────────────
-- Состояние
-- ─────────────────────────────────────────────────────────────────────────────

local cropped = false   -- активен ли crop прямо сейчас
local crop_vf = nil     -- строка фильтра, которую применили

-- ─────────────────────────────────────────────────────────────────────────────
-- Детект через ffmpeg
-- ─────────────────────────────────────────────────────────────────────────────

-- Возвращает строку "w:h:x:y" или nil при неудаче
local function detect_crop(path, time_pos)
    -- Начинаем немного раньше текущей позиции, чтобы захватить больше кадров
    local ss = math.max(0, time_pos - 2)

    local result = utils.subprocess({
        args = {
            "ffmpeg", "-nostats", "-hide_banner",
            "-ss", string.format("%.3f", ss),
            "-i", path,
            "-vf", string.format(
                "cropdetect=%d:2:0", opts.black_threshold),
            "-frames:v", tostring(opts.frames),
            "-t", tostring(opts.scan_duration),
            "-f", "null", "-",
        },
        capture_stderr = true,
        max_size = 1024 * 1024,
    })

    -- cropdetect пишет строки вида:
    --   [Parsed_cropdetect_0 @ ...] x1:0 x2:1919 y1:140 y2:939 w:1920 h:800 x:0 y:140 pts:...
    -- Берём параметры из последней такой строки (наиболее стабильные)
    local w, h, x, y
    for line in (result.stderr or ""):gmatch("[^\r\n]+") do
        local lw, lh, lx, ly = line:match("w:(%d+)%s+h:(%d+)%s+x:(%d+)%s+y:(%d+)")
        if lw then w, h, x, y = lw, lh, lx, ly end
    end

    if not w then return nil end
    return string.format("%s:%s:%s:%s", w, h, x, y)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Применение / снятие
-- ─────────────────────────────────────────────────────────────────────────────

local function apply_crop(crop_params)
    local filter = string.format("lavfi=[crop=%s]", crop_params)
    local ok = mp.set_property("vf", filter)
    if ok == false then
        msg.error("autocrop: ошибка применения vf crop")
        mp.osd_message("Crop: ошибка применения фильтра", 4)
        return false
    end
    crop_vf  = filter
    cropped  = true
    return true
end

local function remove_crop()
    mp.set_property("vf", "")
    crop_vf = nil
    cropped = false
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Основная логика
-- ─────────────────────────────────────────────────────────────────────────────

local function toggle_crop()
    -- Снимаем crop
    if cropped then
        remove_crop()
        mp.osd_message("Crop: выключен", 2)
        return
    end

    local path = mp.get_property("path")
    if not path then
        mp.osd_message("Crop: нет активного файла", 3)
        return
    end

    -- Не работаем на потоках и дисках без seekable
    local seekable = mp.get_property_bool("seekable")
    if not seekable then
        mp.osd_message("Crop: файл не поддерживает перемотку", 3)
        return
    end

    local time_pos = mp.get_property_number("time-pos") or 0

    mp.osd_message("Crop: анализ кадров…", 10)

    local crop_params = detect_crop(path, time_pos)

    if not crop_params then
        mp.osd_message("Crop: не удалось определить поля\n(попробуй в другом месте видео)", 4)
        return
    end

    -- Парсим для OSD
    local w, h, x, y = crop_params:match("(%d+):(%d+):(%d+):(%d+)")

    -- Проверяем: если crop почти совпадает с размером видео — поля не нашлись
    local vw = mp.get_property_number("width")  or 0
    local vh = mp.get_property_number("height") or 0

    local cropped_area = tonumber(w) * tonumber(h)
    local total_area   = vw * vh

    if total_area > 0 and cropped_area / total_area > 0.98 then
        mp.osd_message("Crop: чёрные поля не обнаружены", 3)
        return
    end

    local ok = apply_crop(crop_params)
    if ok then
        mp.osd_message(string.format(
            "Crop: включён  %sx%s  (смещение %s,%s)\nc: выключить",
            w, h, x, y), 4)
    end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Сбрасываем crop при смене файла
-- ─────────────────────────────────────────────────────────────────────────────

mp.register_event("start-file", function()
    -- vf сбрасывается mpv сам при смене файла, синхронизируем состояние
    cropped = false
    crop_vf = nil
end)

-- ─────────────────────────────────────────────────────────────────────────────
-- Горячая клавиша
-- ─────────────────────────────────────────────────────────────────────────────

mp.add_key_binding("c", "autocrop-toggle", toggle_crop)
