--[[--
Flashcard file discovery logic. Pure Lua, dependency-free.

Recursively searches a root directory for `flashcards.md` files, returning
`{ theme = path, ... }` where `theme` is the basename of the directory containing
the file.
--]]

local Discovery = {}

--[[
find(root, lfs, log_warn_fn) -> { [theme_name] = filepath }
Normalizes root so it carries a trailing slash.
`lfs` is passed in (e.g. KOReader's libkoreader-lfs or standard LuaFileSystem)
`log_warn_fn` is an optional logging callback: `function(msg, ...)`
--]]
function Discovery.find(root, lfs, log_warn_fn)
    if not root or type(root) ~= "string" or root == "" then
        return {}
    end
    if not lfs then
        return {}
    end

    -- Normalize root to always have a trailing slash
    root = root:gsub("/+$", "") .. "/"

    local themes = {}
    local function walk(dir)
        -- NOTE: lfs.dir returns a (closure, state) pair and generic-for wires
        -- them together, so pcall-guard the WHOLE loop, never just lfs.dir
        local entries = {}
        local ok, err = pcall(function()
            for f in lfs.dir(dir) do
                if f ~= "." and f ~= ".." then
                    entries[#entries + 1] = f
                end
            end
        end)
        if not ok then
            if log_warn_fn then
                log_warn_fn(string.format("cannot list %q: %s", dir, tostring(err)))
            end
            return
        end
        table.sort(entries)
        for _, name in ipairs(entries) do
            local path = dir .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                if name:sub(1, 1) ~= "." then
                    walk(path .. "/")
                end
            elseif attr and attr.mode == "file" and name == "flashcards.md" then
                local theme = dir:sub(1, -2):match("([^/]+)$") or name
                themes[theme] = path
            end
        end
    end

    walk(root)
    return themes
end

return Discovery
