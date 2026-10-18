-- Per-machine Hyprland settings. Copy to ~/.config/hypr/local.lua and edit;
-- local.lua is never committed. hyprland.lua reads the table this returns.
-- `hyprctl monitors` lists output names and modes.

return {
    -- Dual KTC H27T22S 2560x1440 — left portrait, right landscape (matching i3/xrandr layout)
    -- transform 1 = rotate left (90°)
    -- Leave empty (or delete) to auto-place monitors; the spanned wallpaper needs this filled in.
    monitors = {
        {
            output    = "DP-4",
            mode      = "2560x1440@180",
            position  = "0x0",
            scale     = 1,
            transform = 1,
        },
        {
            output    = "DP-3",
            mode      = "2560x1440@180",
            position  = "1440x500",
            scale     = 1,
            transform = 0,
        },
    },

    -- workspace -> output pinning (workspace 1 on the portrait monitor, matching i3)
    workspaces = {
        ["1"] = "DP-4",
    },

    -- turns on the NVIDIA env block in hyprland.lua
    nvidia = true,

    -- any extra env vars for this machine
    env = {},
}
