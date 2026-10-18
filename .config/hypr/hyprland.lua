-- author: pando.systems
-- Hyprland Lua config — ported from i3
-- https://wiki.hypr.land/Configuring/Start/


--------------------------
---- PER-MACHINE CONFIG ----
--------------------------

-- monitors, GPU and workspace pinning live in ~/.config/hypr/local.lua (not in git);
-- see local.example.lua. Without it: auto-placed monitors, no NVIDIA env, no wallpaper span.
local localConf = {}
do
    local path = os.getenv("HOME") .. "/.config/hypr/local.lua"
    local fh = io.open(path, "r")
    if fh then
        fh:close()
        localConf = dofile(path) or {}
    end
end


------------------
---- MONITORS ----
------------------

local monitors = localConf.monitors or {}

for _, m in ipairs(monitors) do
    hl.monitor({
        output    = m.output,
        mode      = m.mode,
        position  = m.position,
        scale     = tostring(m.scale),
        transform = m.transform,
    })
end

if #monitors == 0 then
    hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
end


-----------------------
---- WALLPAPER SPAN ---
-----------------------

-- wallpaper path comes from ~/.config/theme.conf (single source; see ~/.dotfiles/theme)
local function readThemeConf(key)
    local fh = io.open(os.getenv("HOME") .. "/.config/theme.conf", "r")
    if not fh then return nil end
    local val
    for line in fh:lines() do
        val = line:match("^%s*" .. key .. "%s*=%s*(.-)%s*$")
        if val then break end
    end
    fh:close()
    return val
end
local wallpaper = readThemeConf("wallpaper") or "~/Pictures/wallpapers/dancing-lion.png"
local cacheDir  = os.getenv("HOME") .. "/.cache/hyprpaper"
local confPath  = os.getenv("HOME") .. "/.config/hypr/hyprpaper.conf"

-- a video wallpaper (mp4/mkv/webm/mov) is cropped with ffmpeg and played by mpvpaper
-- instead of hyprpaper; everything else goes through magick + hyprpaper as before
local videoExts = { mp4 = true, mkv = true, webm = true, mov = true }
local isVideo   = videoExts[(wallpaper:match("%.(%w+)$") or ""):lower()] or false
local wallExt   = isVideo and "mp4" or "png"
local wallSpeed = tonumber(readThemeConf("wallpaper_speed")) or 1

-- commands that put the cached per-monitor files on screen (used on start and on reload)
local function wallpaperDaemonCmds()
    if not isVideo then return { "hyprpaper" } end
    local cmds = {}
    for _, m in ipairs(monitors) do
        cmds[#cmds + 1] = string.format(
            "mpvpaper -o 'no-audio loop-file=inf speed=%s' %s '%s/%s.%s'",
            wallSpeed, m.output, cacheDir, m.output, wallExt
        )
    end
    return cmds
end

-- (re)launch the daemon when its command line changed since last run (e.g. a new
-- wallpaper_speed) or when the caller forces it after regenerating the crops.
-- Kills both daemons so switching image <-> video doesn't leave the old one behind.
local function restartWallpaperDaemon(force)
    local cmds     = wallpaperDaemonCmds()
    local cmdStr   = table.concat(cmds, "\n")
    local cmdFile  = cacheDir .. "/.daemon"
    if not force then
        local f = io.open(cmdFile, "r")
        if f then
            local prev = f:read("*a")
            f:close()
            if prev == cmdStr then return end
        end
    end
    -- SIGKILL: hyprpaper blocks SIGTERM, so a plain killall leaves it running
    os.execute("killall -q -KILL hyprpaper mpvpaper")
    for _, cmd in ipairs(cmds) do
        os.execute(cmd .. " &")
    end
    local f = io.open(cmdFile, "w")
    f:write(cmdStr)
    f:close()
end

local function generateWallpaper()
    local home = os.getenv("HOME")
    local src  = wallpaper:gsub("^~", home)

    for _, m in ipairs(monitors) do
        local w, h = m.mode:match("^(%d+)x(%d+)")
        w, h = tonumber(w), tonumber(h)
        local x, y = m.position:match("^(%d+)x(%d+)")
        x, y = tonumber(x), tonumber(y)
        if m.transform == 1 or m.transform == 3 then
            w, h = h, w
        end
        m.ew, m.eh, m.ex, m.ey = w, h, x, y
    end

    local dw, dh = 0, 0
    for _, m in ipairs(monitors) do
        local right  = m.ex + m.ew
        local bottom = m.ey + m.eh
        if right  > dw then dw = right  end
        if bottom > dh then dh = bottom end
    end

    -- hash inputs to skip regeneration
    local hashParts = { src, dw, dh }
    for _, m in ipairs(monitors) do
        hashParts[#hashParts + 1] = m.output
        hashParts[#hashParts + 1] = m.ew
        hashParts[#hashParts + 1] = m.eh
        hashParts[#hashParts + 1] = m.ex
        hashParts[#hashParts + 1] = m.ey
    end
    local hashStr  = table.concat(hashParts, "|")
    local hashFile = cacheDir .. "/.hash"
    local f = io.open(hashFile, "r")
    if f then
        local prev = f:read("*a")
        f:close()
        if prev == hashStr then
            restartWallpaperDaemon(false)
            return
        end
    end

    os.execute("mkdir -p " .. cacheDir)

    if isVideo then
        -- single ffmpeg pass: cover-scale to the full span, then split and crop one
        -- stream per monitor (same geometry as the magick path below)
        local filters = { string.format(
            "[0:v]scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d,split=%d",
            dw, dh, dw, dh, #monitors
        ) }
        for i in ipairs(monitors) do
            filters[1] = filters[1] .. string.format("[s%d]", i)
        end
        local outputs = {}
        for i, m in ipairs(monitors) do
            filters[#filters + 1] = string.format(
                "[s%d]crop=%d:%d:%d:%d[o%d]", i, m.ew, m.eh, m.ex, m.ey, i
            )
            outputs[#outputs + 1] = string.format(
                "-map '[o%d]' -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -an '%s/%s.%s'",
                i, cacheDir, m.output, wallExt
            )
        end
        os.execute(string.format(
            "ffmpeg -y -loglevel error -i '%s' -filter_complex \"%s\" %s",
            src, table.concat(filters, ";"), table.concat(outputs, " ")
        ))
    else
        local fullPath = cacheDir .. "/full.png"
        os.execute(string.format(
            "magick '%s' -resize %dx%d^ -gravity center -extent %dx%d '%s'",
            src, dw, dh, dw, dh, fullPath
        ))

        for _, m in ipairs(monitors) do
            local cropPath = cacheDir .. "/" .. m.output .. ".png"
            os.execute(string.format(
                "magick '%s' -crop %dx%d+%d+%d +repage '%s'",
                fullPath, m.ew, m.eh, m.ex, m.ey, cropPath
            ))
        end

        -- write hyprpaper.conf
        f = io.open(confPath, "w")
        for _, m in ipairs(monitors) do
            f:write(string.format(
                "wallpaper {\n    monitor = %s\n    path = %s/%s.png\n    fit_mode = cover\n}\n\n",
                m.output, cacheDir, m.output
            ))
        end
        f:write("splash = false\n")
        f:close()
    end

    -- write hash
    f = io.open(hashFile, "w")
    f:write(hashStr)
    f:close()

    -- crops changed, so the running daemon (if any) is showing stale files
    restartWallpaperDaemon(true)
end

-- the span crop needs real geometry, so it only runs once local.lua lists monitors
if #monitors > 0 then
    generateWallpaper()
end


---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "kitty"
local fileManager = "nemo"
local menu        = "~/.config/rofi/launchers/type-6/launcher.sh"
local menuRun     = "rofi -show run"


-------------------
---- AUTOSTART ----
-------------------

hl.on("hyprland.start", function()
    for _, cmd in ipairs(wallpaperDaemonCmds()) do
        hl.exec_cmd(cmd)
    end
    hl.exec_cmd("waybar")
    hl.exec_cmd("dunst")
    hl.exec_cmd("nm-applet --indicator")
    hl.exec_cmd("blueman-applet")
    hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
end)


-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")

-- Qt apps -> qt6ct (session-wide so GUI-launched apps get it, not just terminal).
-- GTK is themed via settings.ini/dconf; see ~/.dotfiles/theme.
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")

-- NVIDIA — see https://wiki.hypr.land/Nvidia/  (enabled by `nvidia = true` in local.lua)
-- Requires the OPEN kernel modules (nvidia-open-dkms) on 50-series.
-- Driver 555+ gives explicit sync, which kills almost all Wayland flicker/stutter.
if localConf.nvidia then
    -- hardware video decode; needs libva-nvidia-driver
    hl.env("LIBVA_DRIVER_NAME", "nvidia")
    hl.env("__GLX_VENDOR_LIBRARY_NAME", "nvidia")
    -- VRR / G-Sync allowance for fullscreen games (pairs with misc.vrr = 2 below).
    hl.env("__GL_GSYNC_ALLOWED", "1")
    hl.env("__GL_VRR_ALLOWED", "1")
    -- Optional, pairs with libva-nvidia-driver for direct HW decode:
    -- hl.env("NVD_BACKEND", "direct")
    -- Optional, can speed up GBM but is known to break some Electron/Firefox apps; try if needed:
    -- hl.env("GBM_BACKEND", "nvidia-drm")
end

-- any extra per-machine env from local.lua
for k, v in pairs(localConf.env or {}) do
    hl.env(k, tostring(v))
end

-- Proton: set session-wide so you DON'T need per-game Steam launch options.
-- Fixes borderless-fullscreen sizing and mouse click-through in Wine/Proton games.
-- (Steam must be (re)started inside this session to inherit it.)
hl.env("PROTON_NO_WM_DECORATION", "1")
-- Experimental native-Wayland Proton (no XWayland). Lower latency, but currently
-- breaks the Steam overlay and Steam Input — leave OFF unless you want to test it:
-- hl.env("PROTON_ENABLE_WAYLAND", "1")


-----------------------
---- LOOK AND FEEL ----
-----------------------

hl.config({
    general = {
        gaps_in  = 5,
        gaps_out = 10,

        border_size = 2,

        col = {
            active_border   = "rgb(ffffff)",
            inactive_border = "rgb(2d393e)",
        },

        resize_on_border = false,
        allow_tearing = false,
        layout = "dwindle",
    },

    decoration = {
        rounding       = 0,
        rounding_power = 2,

        active_opacity   = 1.0,
        inactive_opacity = 0.7,

        shadow = {
            enabled      = true,
            range        = 4,
            render_power = 3,
            color        = 0xee1a1a1a,
        },

        blur = {
            enabled   = true,
            size      = 3,
            passes    = 1,
            vibrancy  = 0.1696,
        },
    },

    animations = {
        enabled = true,
    },
})

-- Curves and animations (default)
hl.curve("easeOutQuint",   { type = "bezier", points = { {0.23, 1},    {0.32, 1}    } })
hl.curve("easeInOutCubic", { type = "bezier", points = { {0.65, 0.05}, {0.36, 1}    } })
hl.curve("linear",         { type = "bezier", points = { {0, 0},       {1, 1}       } })
hl.curve("almostLinear",   { type = "bezier", points = { {0.5, 0.5},   {0.75, 1}    } })
hl.curve("quick",          { type = "bezier", points = { {0.15, 0},    {0.1, 1}     } })
hl.curve("easy",           { type = "spring", mass = 1, stiffness = 71.2633, dampening = 15.8273644 })

hl.animation({ leaf = "global",        enabled = true,  speed = 10,   bezier = "default" })
hl.animation({ leaf = "border",        enabled = true,  speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows",       enabled = true,  speed = 4.79, spring = "easy" })
hl.animation({ leaf = "windowsIn",     enabled = true,  speed = 4.1,  spring = "easy",         style = "popin 87%" })
hl.animation({ leaf = "windowsOut",    enabled = true,  speed = 1.49, bezier = "linear",       style = "popin 87%" })
hl.animation({ leaf = "fadeIn",        enabled = true,  speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut",       enabled = true,  speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade",          enabled = true,  speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers",        enabled = true,  speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn",      enabled = true,  speed = 4,    bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut",     enabled = true,  speed = 1.5,  bezier = "linear",       style = "fade" })
hl.animation({ leaf = "fadeLayersIn",  enabled = true,  speed = 1.79, bezier = "almostLinear" })
hl.animation({ leaf = "fadeLayersOut", enabled = true,  speed = 1.39, bezier = "almostLinear" })
hl.animation({ leaf = "workspaces",    enabled = true,  speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesIn",  enabled = true,  speed = 1.21, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "workspacesOut", enabled = true,  speed = 1.94, bezier = "almostLinear", style = "fade" })
hl.animation({ leaf = "zoomFactor",    enabled = true,  speed = 7,    bezier = "quick" })


-----------------
---- LAYOUTS ----
-----------------

hl.config({
    dwindle = {
        preserve_split = true,
    },

    master = {
        new_status = "master",
    },

    scrolling = {
        fullscreen_on_one_column = true,
    },
})


----------------
----  MISC  ----
----------------

hl.config({
    misc = {
        force_default_wallpaper = 0,
        disable_hyprland_logo   = true,
        -- VRR only while a fullscreen app is focused. "1" (always-on) can flicker
        -- the desktop on NVIDIA; "2" is the safe choice. Set to 0 if you see issues.
        vrr = 2,
    },
})


---------------
---- INPUT ----
---------------

hl.config({
    input = {
        kb_layout  = "us",
        follow_mouse = 1,
        sensitivity = 0,
    },
})


---------------------
---- KEYBINDINGS ----
---------------------

local mainMod = "SUPER"

-- Core
hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.window.close())
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd("~/.config/rofi/powermenu/type-1/powermenu.sh"))

-- Launchers (Super+U = drun like i3 rofi launcher, Super+D = dmenu-style run)
hl.bind(mainMod .. " + U", hl.dsp.exec_cmd(menu))
hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(menuRun))

-- Layout
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mainMod .. " + SHIFT + Space", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mainMod .. " + V", hl.dsp.layout("togglesplit"))
hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())

-- Move focus (vim-style, matching i3: j=left k=down l=up ;=right)
hl.bind(mainMod .. " + J", hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + K", hl.dsp.focus({ direction = "down" }))
hl.bind(mainMod .. " + L", hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + semicolon", hl.dsp.focus({ direction = "right" }))

-- Move focus (arrow keys)
hl.bind(mainMod .. " + left",  hl.dsp.focus({ direction = "left" }))
hl.bind(mainMod .. " + down",  hl.dsp.focus({ direction = "down" }))
hl.bind(mainMod .. " + up",    hl.dsp.focus({ direction = "up" }))
hl.bind(mainMod .. " + right", hl.dsp.focus({ direction = "right" }))

-- Move windows (vim-style)
hl.bind(mainMod .. " + SHIFT + J", hl.dsp.window.move({ direction = "left" }))
hl.bind(mainMod .. " + SHIFT + K", hl.dsp.window.move({ direction = "down" }))
hl.bind(mainMod .. " + SHIFT + L", hl.dsp.window.move({ direction = "up" }))
hl.bind(mainMod .. " + SHIFT + semicolon", hl.dsp.window.move({ direction = "right" }))

-- Move windows (arrow keys)
hl.bind(mainMod .. " + SHIFT + left",  hl.dsp.window.move({ direction = "left" }))
hl.bind(mainMod .. " + SHIFT + down",  hl.dsp.window.move({ direction = "down" }))
hl.bind(mainMod .. " + SHIFT + up",    hl.dsp.window.move({ direction = "up" }))
hl.bind(mainMod .. " + SHIFT + right", hl.dsp.window.move({ direction = "right" }))

-- Resize (Super+Alt + vim keys / arrows, hold to repeat)
hl.bind(mainMod .. " + ALT + J",         hl.dsp.window.resize({ x = -40, y = 0 }),  { repeating = true })
hl.bind(mainMod .. " + ALT + K",         hl.dsp.window.resize({ x = 0, y = 40 }),   { repeating = true })
hl.bind(mainMod .. " + ALT + L",         hl.dsp.window.resize({ x = 0, y = -40 }),  { repeating = true })
hl.bind(mainMod .. " + ALT + semicolon", hl.dsp.window.resize({ x = 40, y = 0 }),   { repeating = true })
hl.bind(mainMod .. " + ALT + left",      hl.dsp.window.resize({ x = -40, y = 0 }),  { repeating = true })
hl.bind(mainMod .. " + ALT + down",      hl.dsp.window.resize({ x = 0, y = 40 }),   { repeating = true })
hl.bind(mainMod .. " + ALT + up",        hl.dsp.window.resize({ x = 0, y = -40 }),  { repeating = true })
hl.bind(mainMod .. " + ALT + right",     hl.dsp.window.resize({ x = 40, y = 0 }),   { repeating = true })

-- Workspaces
for i = 1, 10 do
    local key = i % 10
    hl.bind(mainMod .. " + " .. key,             hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key,     hl.dsp.window.move({ workspace = i }))
end

-- Scratchpad (special workspace)
hl.bind(mainMod .. " + S",         hl.dsp.workspace.toggle_special("magic"))
hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))

-- Mouse scroll workspaces
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up",   hl.dsp.focus({ workspace = "e-1" }))

-- Mouse move/resize
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Volume (pactl, matching i3 binds with 10% steps)
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ +10%"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("pactl set-sink-volume @DEFAULT_SINK@ -10%"), { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("pactl set-sink-mute @DEFAULT_SINK@ toggle"), { locked = true })
hl.bind("XF86AudioMicMute",     hl.dsp.exec_cmd("pactl set-source-mute @DEFAULT_SOURCE@ toggle"), { locked = true })

-- Media keys
hl.bind("XF86AudioNext",  hl.dsp.exec_cmd("playerctl next"),       { locked = true })
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPlay",  hl.dsp.exec_cmd("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPrev",  hl.dsp.exec_cmd("playerctl previous"),   { locked = true })


--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

-- Pin workspaces to outputs (from local.lua, e.g. { ["1"] = "DP-4" })
for ws, output in pairs(localConf.workspaces or {}) do
    hl.workspace_rule({ workspace = tostring(ws), monitor = output })
end

-- Window rules
hl.window_rule({
    name  = "anemone-gate-ws1",
    match = { title = "Anemone Gate" },
    workspace = "1",
})

hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },
    no_focus = true,
})
