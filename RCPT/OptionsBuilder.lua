-- OptionsBuilder.lua
-- Generic, declarative builder: schema rows -> Blizzard Settings API category.
--
-- Builder.Register(categoryName, schema, ctx) -> category | nil, reason
--
-- ctx = {
--   dbs   = { [dbName] = { get = function() return liveTable end, defaults = defaultsTable }, ... },
--   debug = function(msg)            -- optional; failures are reported through it
--   prefix = "RCPT"                  -- optional; variable-name prefix (default "RCPT")
-- }
--
-- Row types (see Options.lua for a full schema):
--   { type = "header",   label = }
--   { type = "check",    db = , key = , label = , tooltip = , onChange = }
--   { type = "slider",   ..., min = , max = , step = , format = function(v) }
--   { type = "dropdown", ..., options = { {value, label[, tooltip]}, ... } | function -> that }
--   { type = "button",   label = , buttonText = string | function -> string, tooltip = , onClick = function(button) }
--     (a function buttonText is evaluated each time the row is laid out; onClick gets the Button)
--   Every row type also takes `tooltip`; headers show it on hover.
-- `db` is a dbName found in ctx.dbs, or a function returning the live table
-- (then `defaults = {...}` may be given on the row).
--
-- Settings are proxies that read/write the live saved-variable table on every
-- access, so a replaced SavedVariables table never leaves a stale binding.

local Builder = {}

Builder.settings = {}   -- variable name -> setting object
Builder.category = nil

local refreshing = false -- true while Refresh() pushes values; suppresses onChange

local function Noop(_) end

local function SettingsAvailable()
    return type(Settings) == "table"
        and type(Settings.RegisterVerticalLayoutCategory) == "function"
        and type(Settings.RegisterProxySetting) == "function"
        and type(Settings.RegisterAddOnCategory) == "function"
end

local function VarType(kind)
    local vt = Settings.VarType
    if kind == "check" then return (vt and vt.Boolean) or "boolean" end
    if kind == "dropdown" then return (vt and vt.String) or "string" end
    return (vt and vt.Number) or "number"
end

-- Resolve a row's db spec -> getter, defaults table, name used in the variable id.
local function ResolveDB(row, ctx)
    local spec = row.db
    if type(spec) == "string" then
        local entry = ctx.dbs and ctx.dbs[spec]
        if type(entry) ~= "table" or type(entry.get) ~= "function" then
            error("unknown db '" .. spec .. "'")
        end
        return entry.get, entry.defaults or {}, spec
    elseif type(spec) == "function" then
        return spec, row.defaults or {}, row.dbName or "custom"
    end
    error("row has no valid db")
end

-- Add one value-backed row (check / slider / dropdown). Returns the setting.
local function AddValueRow(category, row, ctx, usedVars)
    local key = row.key
    if type(key) ~= "string" then error("row has no key") end
    if type(row.label) ~= "string" then error("row '" .. key .. "' has no label") end

    local getTbl, defaults, dbName = ResolveDB(row, ctx)
    local variable = (ctx.prefix or "RCPT") .. "_" .. dbName .. "_" .. key
    if usedVars[variable] then error("duplicate variable " .. variable) end

    local default = defaults[key]
    local function GetValue()
        local t = getTbl()
        local v = nil
        if type(t) == "table" then v = t[key] end -- note: false is a valid stored value
        if v == nil then v = default end
        return v
    end
    local function SetValue(v)
        local t = getTbl()
        if type(t) == "table" then t[key] = v end
    end

    -- Sliders store whole multiples of step from min (guards float drift).
    if row.type == "slider" and type(row.step) == "number" and row.step > 0 and type(row.min) == "number" then
        local raw = SetValue
        SetValue = function(v)
            if type(v) == "number" then
                v = row.min + math.floor((v - row.min) / row.step + 0.5) * row.step
            end
            raw(v)
        end
    end

    local setting = Settings.RegisterProxySetting(category, variable, VarType(row.type), row.label,
        default, GetValue, SetValue)
    usedVars[variable] = true

    if type(row.onChange) == "function" then
        local onChange = row.onChange
        setting:SetValueChangedCallback(function(_, value)
            if refreshing then return end
            local ok, err = pcall(onChange, value, setting)
            if not ok and ctx.debug then ctx.debug("onChange for " .. variable .. " failed: " .. tostring(err)) end
        end)
    end

    if row.type == "check" then
        Settings.CreateCheckbox(category, setting, row.tooltip)
    elseif row.type == "slider" then
        local opts = Settings.CreateSliderOptions(row.min, row.max, row.step)
        local mixin = MinimalSliderWithSteppersMixin
        if type(opts.SetLabelFormatter) == "function" and mixin and mixin.Label and mixin.Label.Right then
            -- Always set a Right label formatter: MinimalSlider hides the value text without one.
            -- A nil format function falls back to Blizzard's default (unmodified number).
            pcall(opts.SetLabelFormatter, opts, mixin.Label.Right,
                type(row.format) == "function" and row.format or nil)
        end
        Settings.CreateSlider(category, setting, opts, row.tooltip)
    else -- dropdown
        local source = row.options
        local function GetOptions()
            local list = type(source) == "function" and source() or source
            local container = Settings.CreateControlTextContainer()
            for _, o in ipairs(list or {}) do
                container:Add(o.value or o[1], o.label or o[2], o.tooltip or o[3])
            end
            return container:GetData()
        end
        Settings.CreateDropdown(category, setting, GetOptions, row.tooltip)
    end

    return setting, variable
end

function Builder.Register(categoryName, schema, ctx)
    if not SettingsAvailable() then return nil, "Settings API unavailable" end
    if type(schema) ~= "table" then return nil, "no schema" end
    ctx = ctx or {}
    local debug = ctx.debug or Noop
    if Builder.category then return Builder.category end -- already registered

    local category, layout
    local ok, err = pcall(function()
        category, layout = Settings.RegisterVerticalLayoutCategory(categoryName)
    end)
    if not ok or not category then
        return nil, "category creation failed: " .. tostring(err)
    end

    local usedVars = {}
    for i, row in ipairs(schema) do
        local rowOk, rowErr = pcall(function()
            local t = row.type
            if t == "header" then
                if layout and type(layout.AddInitializer) == "function"
                    and type(CreateSettingsListSectionHeaderInitializer) == "function" then
                    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(row.label, row.tooltip))
                end
            elseif t == "button" then
                if layout and type(layout.AddInitializer) == "function"
                    and type(CreateSettingsButtonInitializer) == "function" then
                    local onClick = row.onClick
                    layout:AddInitializer(CreateSettingsButtonInitializer(row.label, row.buttonText or row.label,
                        function(button)
                            if type(onClick) ~= "function" then return end
                            local clickOk, clickErr = pcall(onClick, button)
                            if not clickOk then debug("button '" .. tostring(row.label) .. "' failed: " .. tostring(clickErr)) end
                        end, row.tooltip, true))
                end
            elseif t == "check" or t == "slider" or t == "dropdown" then
                local setting, variable = AddValueRow(category, row, ctx, usedVars)
                Builder.settings[variable] = setting
            else
                error("unknown row type '" .. tostring(t) .. "'")
            end
        end)
        if not rowOk then
            local msg = "Options row " .. i .. " (" .. tostring(row.key or row.label) .. ") failed: " .. tostring(rowErr)
            if _G.RCPT and type(_G.RCPT.Print) == "function" then _G.RCPT.Print(msg) else print("|cff00ccff[RCPT]|r " .. msg) end
        end
    end

    local regOk, regErr = pcall(Settings.RegisterAddOnCategory, category)
    if not regOk then
        Builder.settings = {}
        return nil, "RegisterAddOnCategory failed: " .. tostring(regErr)
    end

    Builder.category = category
    return category
end

-- Re-read every registered value (after slash commands or presets changed the
-- saved table) so open controls update. Does not write and does not fire onChange.
function Builder.Refresh()
    refreshing = true
    for _, setting in pairs(Builder.settings) do
        pcall(setting.NotifyUpdate, setting)
    end
    refreshing = false
end

-- Push one external value: Builder.SetValue(variableName, value).
function Builder.SetValue(variable, value)
    local setting = Builder.settings[variable]
    if not setting then return false end
    refreshing = true
    local ok = pcall(setting.SetValue, setting, value)
    refreshing = false
    return ok
end

function Builder.GetSetting(variable)
    return Builder.settings[variable]
end

_G.RCPT_OptionsBuilder = Builder
if _G.RCPT then _G.RCPT.OptionsBuilder = Builder end

return Builder
