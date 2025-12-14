-- OptionsBuilder.lua
-- Minimal, modular options panel builder for WoW addons.
-- Provides a simple fluent API to add controls and handle layout.

local OptionsBuilder = {}
OptionsBuilder.__index = OptionsBuilder

-- Create a new builder.
-- name: panel name
-- parent: UIParent or other frame
-- opts: table {leftX = number, rightX = number, startY = number, width = number}
function OptionsBuilder.New(name, parent, opts)
    opts = opts or {}
    local panel = CreateFrame("Frame", name, parent or UIParent)
    panel.name = name

    local self = setmetatable({}, OptionsBuilder)
    self.panel = panel
    self.leftX = opts.leftX or 16
    self.rightX = opts.rightX or 300
    self.x = self.leftX
    self.y = opts.startY or -60
    self.col = "left"
    self.spacing = opts.spacing or 36
    self.width = opts.width or 220
    return self
end

-- Internal: place frame at current cursor and advance
function OptionsBuilder:_place(frame, col)
    local x = (col == "right") and self.rightX or self.leftX
    frame:SetPoint("TOPLEFT", self.panel, "TOPLEFT", x, self.y)
    self.y = self.y - self.spacing
    return frame
end

-- Title and subtitle
function OptionsBuilder:AddTitle(text)
    local title = self.panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(text)
    return title
end

function OptionsBuilder:AddSubtitle(text)
    local subtitle = self.panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetText(text)
    self:_place(subtitle, "left")
    return subtitle
end

-- Add a section header (larger than subtitle) and advance the layout cursor
-- text: string title for the section
function OptionsBuilder:AddSection(text)
    local sec = self.panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    sec:SetText(text)
    self:_place(sec, "left")
    -- add a little extra spacing after a section header
    self.y = self.y - (self.spacing * 0.25)
    return sec
end

-- Add a checkbutton (left column)
-- opts: {label=string, get=function->bool, set=function(bool)}
function OptionsBuilder:AddCheck(name, opts)
    opts = opts or {}
    local cb = CreateFrame("CheckButton", name, self.panel, "InterfaceOptionsCheckButtonTemplate")
    cb.Text:SetText(opts.label or name)
    self:_place(cb, "left")
    if opts.get then cb:SetChecked(not not opts.get()) end
    if opts.set then cb:SetScript("OnClick", function(self) opts.set(self:GetChecked() and true or false) end) end
    return cb
end

-- Add a slider on right column
-- opts: {min=number,max=number,step=number,label=string,get=set functions}
function OptionsBuilder:AddSlider(name, opts)
    opts = opts or {}
    local s = CreateFrame("Slider", name, self.panel, "OptionsSliderTemplate")
    s:SetWidth(self.width)
    s:SetMinMaxValues(opts.min or 1, opts.max or 100)
    s:SetValueStep(opts.step or 1)
    s.Text = _G[s:GetName() .. "Text"]
    s.Low = _G[s:GetName() .. "Low"]
    s.High = _G[s:GetName() .. "High"]
    if opts.label then s.Text:SetText(opts.label) end
    self:_place(s, "right")
    if opts.get then
        local v = opts.get()
        if v then s:SetValue(v) end
    end
    if opts.set then
        s:SetScript("OnValueChanged", function(self, v)
            local val = math.floor(v + 0.5)
            opts.set(val)
            if self.Value then self.Value:SetText(tostring(val)) end
        end)
    end
    -- numeric display
    do
        local fs = self.panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", s, "RIGHT", 8, 0)
        fs:SetText(tostring(opts.get and opts.get() or ""))
        s.Value = fs
    end
    return s
end

-- Add an editbox (left column)
function OptionsBuilder:AddEditBox(name, opts)
    opts = opts or {}
    local eb = CreateFrame("EditBox", name, self.panel, "InputBoxTemplate")
    eb:SetSize(opts.width or 260, 22)
    self:_place(eb, "left")
    eb:SetAutoFocus(false)
    if opts.get then eb:SetText(opts.get() or "") end
    if opts.onEnter then eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end) end
    if opts.onSave then eb:SetScript("OnEditFocusLost", function(self) opts.onSave(self:GetText() or "") end) end
    return eb
end

-- Add a button on right column
function OptionsBuilder:AddButton(name, label, width, onClick)
    local btn = CreateFrame("Button", name, self.panel, "UIPanelButtonTemplate")
    btn:SetSize(width or 140, 22)
    btn:SetText(label or name)
    self:_place(btn, "right")
    if onClick then btn:SetScript("OnClick", onClick) end
    return btn
end

-- Register panel with Interface Options APIs and return panel
function OptionsBuilder:Finish()
    if InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(self.panel)
    else
        if LoadAddOn then pcall(LoadAddOn, "Blizzard_InterfaceOptions") end
        if InterfaceOptions_AddCategory then
            InterfaceOptions_AddCategory(self.panel)
        elseif Settings and Settings.RegisterCanvasLayoutCategory then
            local category = Settings.RegisterCanvasLayoutCategory(self.panel, self.panel.name)
            Settings.RegisterAddOnCategory(category)
        elseif InterfaceOptionsFramePanelContainer then
            self.panel:SetParent(InterfaceOptionsFramePanelContainer)
        end
    end
    return self.panel
end

return OptionsBuilder

-- Export globally for file-load order flexibility
_G.RCPT_OptionsBuilder = OptionsBuilder
