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
    self.startY = opts.startY or -60
    self.y = self.startY
    self.col = "left"
    self.spacing = opts.spacing or 36
    self.width = opts.width or 220
    -- create a ScrollFrame and a scroll child so option controls can be scrolled
    local name = panel:GetName() or "OptionsPanel"
    local scroll = CreateFrame("ScrollFrame", name .. "ScrollFrame", panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -24, 0)
    local content = CreateFrame("Frame", name .. "ScrollChild", scroll)
    -- anchor content so its top-left lines up with panel's leftX/startY coordinates
    content:SetPoint("TOPLEFT", panel, "TOPLEFT", self.leftX, self.startY)
    content:SetWidth((self.rightX - self.leftX) + self.width)
    scroll:SetScrollChild(content)
    self.scroll = scroll
    self.content = content

    return self
end

-- Internal: place frame at current cursor and advance
function OptionsBuilder:_place(frame, col)
    -- Ensure we have a scroll content frame to anchor to; fall back to panel
    local parentForPlacement = self.content or self.panel
    local xOffset = (col == "right") and (self.rightX - self.leftX) or 0
    frame:SetPoint("TOPLEFT", parentForPlacement, "TOPLEFT", xOffset, self.y - self.startY)
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
    local subtitle = (self.content or self.panel):CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetText(text)
    self:_place(subtitle, "left")
    return subtitle
end

-- Add a section header (larger than subtitle) and advance the layout cursor
-- text: string title for the section
function OptionsBuilder:AddSection(text)
    local sec = (self.content or self.panel):CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
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
    local cb = CreateFrame("CheckButton", name, self.content or self.panel, "InterfaceOptionsCheckButtonTemplate")
    cb.Text:SetText(opts.label or name)
    self:_place(cb, "left")
    if opts.get then cb:SetChecked(not not opts.get()) end
    if opts.set then cb:SetScript("OnClick", function(self) opts.set(self:GetChecked() and true or false) end) end
    return cb
end

-- Add a slider (left column)
-- opts: {min=number,max=number,step=number,label=string,get=set functions}
function OptionsBuilder:AddSlider(name, opts)
    opts = opts or {}
    local s = CreateFrame("Slider", name, self.content or self.panel, "OptionsSliderTemplate")
    s:SetWidth(self.width)
    s:SetMinMaxValues(opts.min or 1, opts.max or 100)
    s:SetValueStep(opts.step or 1)
    s.Text = _G[s:GetName() .. "Text"]
    s.Low = _G[s:GetName() .. "Low"]
    s.High = _G[s:GetName() .. "High"]
    -- show actual range values on the ends of the slider
    if s.Low then s.Low:SetText(tostring(opts.min or 1)) end
    if s.High then s.High:SetText(tostring(opts.max or 100)) end
    if opts.label then s.Text:SetText(opts.label) end
    -- add a little vertical padding before and after the slider
    self.y = self.y - 5
    self:_place(s, "left")
    self.y = self.y - 5
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
        local fs = (self.content or self.panel):CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", s, "RIGHT", 8, 0)
        fs:SetText(tostring(opts.get and opts.get() or ""))
        s.Value = fs
    end
    return s
end

-- Add an editbox (left column)
function OptionsBuilder:AddEditBox(name, opts)
    opts = opts or {}
    local eb = CreateFrame("EditBox", name, self.content or self.panel, "InputBoxTemplate")

    if opts.label then
        local lbl = (self.content or self.panel):CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        lbl:SetText(opts.label)
        self:_place(lbl, "left")
        -- move cursor back a bit so the editbox sits closer to the label
        self.y = self.y + (self.spacing * 0.5)
        eb:SetSize(opts.width or 260, 22)
        -- anchor the editbox right under the label to avoid overlaps
        eb:SetPoint("TOPLEFT", self.content or self.panel, "TOPLEFT", 0, self.y - self.startY)
        -- advance the cursor as _place would
        self.y = self.y - self.spacing
    else
        eb:SetSize(opts.width or 260, 22)
        self:_place(eb, "left")
    end
    eb:SetAutoFocus(false)
    if opts.get then
        eb:SetText(tostring(opts.get() or ""))
        eb:ClearFocus()
        if eb.SetCursorPosition then eb:SetCursorPosition(0) end
        -- provide a refresh helper so callers can update the box later
        eb.Refresh = function()
            eb:SetText(tostring(opts.get() or ""))
            if eb.SetCursorPosition then eb:SetCursorPosition(0) end
        end
    end
    if opts.onEnter then eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end) end
    if opts.onSave then eb:SetScript("OnEditFocusLost", function(self) opts.onSave(self:GetText() or "") end) end
    return eb
end

-- Add a button on right column
function OptionsBuilder:AddButton(name, label, width, onClick)
    local btn = CreateFrame("Button", name, self.content or self.panel, "UIPanelButtonTemplate")
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
    -- finalize content height so scroll works when content exceeds visible area
    if self.content then
        local usedHeight = (self.startY - self.y) + 40
        if usedHeight < 1 then usedHeight = 1 end
        self.content:SetHeight(usedHeight)
    end

    return self.panel
end

-- Export globally for file-load order flexibility
_G.RCPT_OptionsBuilder = OptionsBuilder
if _G.RCPT then _G.RCPT.OptionsBuilder = OptionsBuilder end

return OptionsBuilder
