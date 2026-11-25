-- Style.lua
-- Shared visual design system: colour tokens, flat panels, buttons, text, bars, stepper, fades, positioning

local _, ns = ...
local Addon = _G.RCPT or ns

local Style = {}
Addon.Style = Style

local floor = math.floor

-- Textured StatusBar fill (tinted by SetStatusBarColor); the same file Blizzard bars use
-- (e.g. Blizzard_AchievementUI/Mainline/Blizzard_AchievementUI.xml BarTexture).
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local DEFAULT_FADE = 0.15
local BOUNDS_MARGIN = 40 -- px of a frame that must stay inside the screen

------------------------------------------------------------------------
-- Colours
------------------------------------------------------------------------

-- Each colour is readable both as c.r/c.g/c.b/c.a and as c[1]..c[4].
local function C(r, g, b, a)
    a = a or 1
    return { r = r, g = g, b = b, a = a, r, g, b, a }
end

Style.colors = {
    bg       = C(0.05, 0.06, 0.08, 0.94),
    bgRaised = C(0.10, 0.11, 0.14, 1),
    border   = C(0, 0, 0, 1),
    edge     = C(1, 1, 1, 0.06),
    accent   = C(0, 0.80, 1),
    ready    = C(0.30, 0.90, 0.45),
    fail     = C(1, 0.30, 0.30),
    wait     = C(1, 0.82, 0),
    idle     = C(0.45, 0.47, 0.52),
    text     = C(0.92, 0.93, 0.95),
    textDim  = C(0.62, 0.65, 0.70),
}
local colors = Style.colors

-- Accepts a colour name or a table ({r=,g=,b=[,a=]} or {r,g,b[,a]}); unknown names fall back to `text`.
function Style.Color(c)
    if type(c) == "string" then c = colors[c] end
    if type(c) ~= "table" then c = colors.text end
    return c.r or c[1] or 1, c.g or c[2] or 1, c.b or c[3] or 1, c.a or c[4] or 1
end
local Color = Style.Color

local function Byte(v)
    v = floor(v * 255 + 0.5)
    if v < 0 then return 0 elseif v > 255 then return 255 end
    return v
end

function Style.Hex(c)
    local r, g, b = Color(c)
    return string.format("ff%02x%02x%02x", Byte(r), Byte(g), Byte(b))
end

function Style.Colorize(c, text)
    return "|c" .. Style.Hex(c) .. tostring(text or "") .. "|r"
end

local function Tex(owner, layer, sublevel, c)
    local t = owner:CreateTexture(nil, layer, nil, sublevel)
    t:SetColorTexture(Color(c))
    return t
end

------------------------------------------------------------------------
-- Panel
------------------------------------------------------------------------

-- Four 1px edge textures around `owner` (inside its rect), so the fill between them keeps
-- its own alpha. Returns a handle with SetColorTexture/Show/Hide over all four edges.
local function CreateEdges(owner, layer, sublevel, c)
    local edges = {}
    local function Edge(p1, p2, horizontal)
        local t = Tex(owner, layer, sublevel, c)
        t:SetPoint(p1)
        t:SetPoint(p2)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
        edges[#edges + 1] = t
        return t
    end
    edges.top = Edge("TOPLEFT", "TOPRIGHT", true)
    edges.bottom = Edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    edges.left = Edge("TOPLEFT", "BOTTOMLEFT", false)
    edges.right = Edge("TOPRIGHT", "BOTTOMRIGHT", false)
    function edges:SetColorTexture(...)
        for i = 1, #self do self[i]:SetColorTexture(...) end
    end
    function edges:Show() for i = 1, #self do self[i]:Show() end end
    function edges:Hide() for i = 1, #self do self[i]:Hide() end end
    return edges
end

-- Layering (Sprint-Bar style): a 1px border ring at BACKGROUND -8, the background
-- inset 1px at -7 (its alpha shows through: nothing opaque sits behind it), then a
-- 1px top hairline and the accent strip.
function Style.CreatePanel(name, parent, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", name, parent or UIParent)
    if opts.width then f:SetWidth(opts.width) end
    if opts.height then f:SetHeight(opts.height) end
    if opts.strata then f:SetFrameStrata(opts.strata) end

    f.border = CreateEdges(f, "BACKGROUND", -8, "border")

    f.bg = Tex(f, "BACKGROUND", -7, "bg")
    f.bg:SetPoint("TOPLEFT", 1, -1)
    f.bg:SetPoint("BOTTOMRIGHT", -1, 1)

    local accent = opts.accent
    if accent == nil then accent = "left" end

    if accent ~= "top" then
        f.edge = Tex(f, "BORDER", -1, "edge")
        f.edge:SetPoint("TOPLEFT", 1, -1)
        f.edge:SetPoint("TOPRIGHT", -1, -1)
        f.edge:SetHeight(1)
    end

    if accent == "left" or accent == "top" then
        local bar = Tex(f, "BORDER", 1, "accent")
        bar:SetPoint("TOPLEFT", 1, -1)
        if accent == "left" then
            bar:SetPoint("BOTTOMLEFT", 1, 1)
            bar:SetWidth(3)
        else
            bar:SetPoint("TOPRIGHT", -1, -1)
            bar:SetHeight(3)
        end
        f.accentBar = bar
    end

    function f:SetAccent(c)
        if self.accentBar then self.accentBar:SetColorTexture(Color(c)) end
    end

    return f
end

------------------------------------------------------------------------
-- Button
------------------------------------------------------------------------

-- Fills are opaque (the border texture fills behind them). `default` is a step lighter
-- than `bgRaised` so it reads against panel `bg`; `success` is the `ready` token darkened.
local VARIANTS = {
    default = { fill = C(0.17, 0.18, 0.22, 1), border = colors.border, text = "text", edge = true },
    primary = { fill = C(0, 0.36, 0.45, 1), border = colors.border, text = "text", edge = true },
    success = { fill = C(colors.ready.r * 0.45, colors.ready.g * 0.45, colors.ready.b * 0.45, 1),
                border = colors.border, text = "text", edge = true },
    danger  = { fill = C(0.45, 0.13, 0.13, 1), border = colors.border, text = "text", edge = true },
    ghost   = { fill = C(0, 0, 0, 0), border = C(0, 0, 0, 0), text = "textDim", edge = false },
}

local function RestyleButton(btn)
    local v = VARIANTS[btn.variant] or VARIANTS.default
    local enabled = btn:IsEnabled()
    local dim = enabled and 1 or 0.45
    local r, g, b, a = Color(v.fill)
    btn.fill:SetColorTexture(r * dim, g * dim, b * dim, a)
    r, g, b, a = Color(v.border)
    btn.border:SetColorTexture(r, g, b, a)
    if v.edge then btn.edge:Show() else btn.edge:Hide() end
    btn.label:SetTextColor(Color(enabled and v.text or "idle"))
    btn.highlight:SetAlpha(enabled and 1 or 0)
end

-- State visuals are engine-driven so a caller's SetScript("OnEnter"/"OnLeave"/
-- "OnMouseDown"/...) can never break them: hover = the button's HighlightTexture,
-- pressed = its PushedTexture plus SetPushedTextOffset, disabled = Enable/
-- Disable/SetEnabled wrapped on the instance to restyle after the native call.
-- No scripts other than the caller's own are set on the button.
function Style.CreateButton(parent, text, opts)
    opts = opts or {}
    local height = opts.height or 22
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(opts.width or 80, height)
    btn:RegisterForClicks("LeftButtonUp")
    btn:SetMotionScriptsWhileDisabled(true)

    btn.border = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    btn.border:SetAllPoints(btn)

    btn.fill = btn:CreateTexture(nil, "BACKGROUND", nil, -7)
    btn.fill:SetPoint("TOPLEFT", 1, -1)
    btn.fill:SetPoint("BOTTOMRIGHT", -1, 1)

    btn.edge = Tex(btn, "BORDER", -1, "edge")
    btn.edge:SetPoint("TOPLEFT", 1, -1)
    btn.edge:SetPoint("TOPRIGHT", -1, -1)
    btn.edge:SetHeight(1)

    local pushed = Tex(btn, "ARTWORK", 7, C(0, 0, 0, 0.35))
    pushed:SetPoint("TOPLEFT", 1, -1)
    pushed:SetPoint("BOTTOMRIGHT", -1, 1)
    btn:SetPushedTexture(pushed)
    btn.pushed = pushed

    local hl = Tex(btn, "HIGHLIGHT", 0, C(1, 1, 1, 0.12))
    hl:SetAllPoints(btn)
    btn:SetHighlightTexture(hl, "ADD")
    btn.highlight = hl

    local label = btn:CreateFontString(nil, "OVERLAY", height < 20 and "GameFontHighlightSmall" or "GameFontHighlight")
    label:SetPoint("CENTER", 0, 0)
    btn:SetFontString(label)
    btn:SetPushedTextOffset(1, -1)
    btn.label = label
    btn:SetText(text or "")

    local nativeEnable, nativeDisable = btn.Enable, btn.Disable
    function btn:Enable() nativeEnable(self); RestyleButton(self) end
    function btn:Disable() nativeDisable(self); RestyleButton(self) end
    function btn:SetEnabled(enabled)
        if enabled then self:Enable() else self:Disable() end
    end
    function btn:SetVariant(v)
        self.variant = VARIANTS[v] and v or "default"
        RestyleButton(self)
    end

    btn:SetVariant(opts.variant)
    return btn
end

------------------------------------------------------------------------
-- Text and bar
------------------------------------------------------------------------

local FONTS = {
    huge  = "GameFontHighlightHuge",
    title = "GameFontHighlightLarge",
    body  = "GameFontHighlight",
    small = "GameFontHighlightSmall",
}

function Style.CreateText(parent, kind, colorName)
    local fs = parent:CreateFontString(nil, "OVERLAY", FONTS[kind] or FONTS.body)
    fs:SetTextColor(Color(colorName or "text"))
    return fs
end

-- GameTooltip on enter/leave. Hooks (never replaces) the region's scripts, so a caller's
-- own OnEnter/OnLeave keep working; calling it again only updates the text. Call it after
-- any SetScript("OnEnter"/"OnLeave") on the region: SetScript drops existing hooks.
-- `text` may be a string or a function returning one (read at hover time).
function Style.SetTooltip(region, title, text)
    if not region or not region.HookScript then return end
    region._rcptTipTitle, region._rcptTipText = title, text
    if region._rcptTipHooked then return end
    region._rcptTipHooked = true
    region:HookScript("OnEnter", function(self)
        local tip = GameTooltip
        local t = self._rcptTipTitle
        if not tip or not t or t == "" then return end
        local body = self._rcptTipText
        if type(body) == "function" then
            local ok, res = pcall(body)
            body = ok and res or nil
        end
        tip:SetOwner(self, "ANCHOR_TOP")
        tip:SetText(t, 1, 1, 1, 1, true)
        if type(body) == "string" and body ~= "" then
            local r, g, b = Color("textDim")
            tip:AddLine(body, r, g, b, true)
        end
        tip:Show()
    end)
    region:HookScript("OnLeave", function(self)
        local tip = GameTooltip
        if tip and tip:IsOwned(self) then tip:Hide() end
    end)
end

-- Textured StatusBar with a 1px border, a centred small label and optional tick markers.
-- Default height 10 (opts.height is honoured). Fields: bar.text, bar.bg, bar.border.
-- Methods: SetBarColor(c), SetLabel(str), AddTick(fraction, colorName), ClearTicks().
function Style.CreateBar(parent, opts)
    opts = opts or {}
    local bar = CreateFrame("StatusBar", nil, parent)
    bar:SetSize(opts.width or 200, opts.height or 10)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)

    bar.border = Tex(bar, "BACKGROUND", -8, "border")
    bar.border:SetPoint("TOPLEFT", -1, 1)
    bar.border:SetPoint("BOTTOMRIGHT", 1, -1)
    bar.bg = Tex(bar, "BACKGROUND", -7, "bgRaised")
    bar.bg:SetAllPoints(bar)

    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    bar.text:SetTextColor(Color("text"))
    bar.text:SetShadowColor(0, 0, 0, 1)
    bar.text:SetShadowOffset(1, -1)
    bar.text:SetText("")

    -- Ticks: pooled 1px textures above the fill, below the label; positioned by fraction
    -- of the bar width and re-laid out when the bar is resized.
    bar.ticks = {}
    local used = 0

    local function LayoutTicks(self)
        local w = self:GetWidth() or 0
        for i = 1, used do
            local t = self.ticks[i]
            local x = floor(w * t._fraction + 0.5) - 1 -- 2px marker centred on the fraction
            if x < 0 then x = 0 elseif x > w - 2 then x = math.max(0, w - 2) end
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", self, "TOPLEFT", x, 0)
            t:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", x, 0)
        end
    end

    function bar:SetBarColor(c)
        self:SetStatusBarColor(Color(c))
    end

    function bar:SetLabel(str)
        self.text:SetText(str or "")
    end

    function bar:AddTick(fraction, colorName)
        if type(fraction) ~= "number" or fraction ~= fraction then return nil end
        if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
        used = used + 1
        local t = self.ticks[used]
        if not t then
            t = self:CreateTexture(nil, "OVERLAY", nil, -1)
            t:SetWidth(2)
            self.ticks[used] = t
        end
        t._fraction = fraction
        t:SetColorTexture(Color(colorName or "text"))
        t:Show()
        LayoutTicks(self)
        return t
    end

    function bar:ClearTicks()
        for i = 1, #self.ticks do self.ticks[i]:Hide() end
        used = 0
    end

    bar:HookScript("OnSizeChanged", LayoutTicks)

    bar:SetBarColor("accent")
    return bar
end

------------------------------------------------------------------------
-- Animation: fades and pulse
------------------------------------------------------------------------

-- Alpha animations set alpha absolutely while playing (Blizzard relies on this:
-- an alpha="0" texture shown by a 1->1 Alpha anim). The groups deliberately do
-- not use SetToFinalAlpha: when a group finishes or stops, the frame falls back
-- to its own SetAlpha value, and every exit path puts that back to 1 so a later
-- plain Show() is visible. Fade-in holds SetAlpha(from) only while playing, so
-- no frame renders at full alpha before the first animation tick. Alpha keys
-- are linear, so GetProgress gives the visible alpha when a fade is interrupted.
local function GetFader(frame)
    local f = frame._rcptFade
    if f then return f end
    f = { from = 0 }

    local function Restore() frame:SetAlpha(1) end
    f.inGroup = frame:CreateAnimationGroup()
    f.inAnim = f.inGroup:CreateAnimation("Alpha")
    f.inAnim:SetToAlpha(1)
    f.inGroup:SetScript("OnFinished", Restore)
    f.inGroup:SetScript("OnStop", Restore)

    f.outGroup = frame:CreateAnimationGroup()
    f.outAnim = f.outGroup:CreateAnimation("Alpha")
    f.outAnim:SetToAlpha(0)
    f.outGroup:SetScript("OnFinished", function()
        frame:Hide()
        frame:SetAlpha(1)
    end)

    -- Hiding a frame stops its animation groups without a reliable OnFinished; never leave a
    -- stale alpha behind. Safe from the fade-out's own Hide(): a finished group is not playing,
    -- so Stop() is a no-op there, and the alpha is already 1.
    frame:HookScript("OnHide", function()
        f.inGroup:Stop()
        f.outGroup:Stop()
        frame:SetAlpha(1)
    end)

    frame._rcptFade = f
    return f
end

-- Visible alpha of a frame, accounting for an in-flight fade.
local function CurrentAlpha(frame, f)
    if f.outGroup:IsPlaying() then return f.from * (1 - f.outGroup:GetProgress()) end
    if f.inGroup:IsPlaying() then return f.from + (1 - f.from) * f.inGroup:GetProgress() end
    return frame:GetAlpha()
end

function Style.FadeIn(frame, seconds)
    if not frame then return end
    seconds = seconds or DEFAULT_FADE
    local f = GetFader(frame)
    local shown = frame:IsShown()
    if shown and f.inGroup:IsPlaying() then return end

    local from = shown and CurrentAlpha(frame, f) or 0
    f.outGroup:Stop()
    f.inGroup:Stop()
    frame:SetAlpha(1)
    frame:Show()
    if from >= 0.99 or seconds <= 0 then return end

    f.from = from
    f.inAnim:SetFromAlpha(from)
    f.inAnim:SetDuration(seconds * (1 - from))
    frame:SetAlpha(from)
    f.inGroup:Play()
    -- Groups do not play while the frame is not visible (e.g. hidden parent): show it solid instead.
    if not f.inGroup:IsPlaying() then frame:SetAlpha(1) end
end

function Style.FadeOut(frame, seconds)
    if not frame then return end
    seconds = seconds or DEFAULT_FADE
    local f = GetFader(frame)
    if not frame:IsShown() then
        f.inGroup:Stop()
        f.outGroup:Stop()
        frame:SetAlpha(1)
        return
    end
    -- seconds <= 0: hide now, cancelling any fade (including a fade-out in flight).
    if seconds <= 0 then
        f.inGroup:Stop()
        f.outGroup:Stop()
        frame:SetAlpha(1)
        frame:Hide()
        return
    end
    if f.outGroup:IsPlaying() then return end

    local from = CurrentAlpha(frame, f)
    f.inGroup:Stop()
    frame:SetAlpha(1)
    if from <= 0.01 then
        frame:Hide()
        return
    end

    f.from = from
    f.outAnim:SetFromAlpha(from)
    f.outAnim:SetDuration(seconds * from)
    f.outGroup:Play()
    -- Groups do not play while the frame is not visible (e.g. hidden parent): hide it directly.
    if not f.outGroup:IsPlaying() then
        frame:SetAlpha(1)
        frame:Hide()
    end
end

function Style.Pulse(region)
    if not region then return end
    local ag = region._rcptPulse
    if not ag then
        ag = region:CreateAnimationGroup()
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(1)
        a:SetToAlpha(0.35)
        a:SetDuration(0.6)
        a:SetSmoothing("IN_OUT")
        ag:SetLooping("BOUNCE")
        region._rcptPulse = ag
    end
    if not ag:IsPlaying() then ag:Play() end
end

function Style.StopPulse(region)
    local ag = region and region._rcptPulse
    if ag and ag:IsPlaying() then ag:Stop() end
end

------------------------------------------------------------------------
-- Stepper
------------------------------------------------------------------------

local STEP_COLORS = { idle = "idle", active = "wait", done = "ready", fail = "fail" }
local STEP_LABEL_HEIGHT = 12
local STEP_ICON_SIZE = 12
-- Stepper state -> Style.StatusAtlas state ("idle" shows no icon).
local STEP_ICON_STATE = { done = "ready", fail = "notready", active = "waiting" }

function Style.CreateStepper(parent, labels, opts)
    opts = opts or {}
    labels = labels or {}
    local n = math.max(#labels, 1)
    local width = opts.width or 280
    local segH = opts.segmentHeight or 3
    local gap = opts.gap or 4
    local segW = (width - gap * (n - 1)) / n

    local s = CreateFrame("Frame", nil, parent)
    s.height = segH + 3 + STEP_LABEL_HEIGHT
    s:SetSize(width, s.height)
    s.segments, s.labels, s.icons = {}, {}, {}

    for i = 1, n do
        local seg = s:CreateTexture(nil, "ARTWORK")
        seg:SetPoint("TOPLEFT", s, "TOPLEFT", (i - 1) * (segW + gap), 0)
        seg:SetSize(segW, segH)
        local lbl = Style.CreateText(s, "small", "idle")
        lbl:SetPoint("TOP", seg, "BOTTOM", 0, -3)
        lbl:SetWidth(segW)
        lbl:SetJustifyH("CENTER")
        lbl:SetWordWrap(false)
        lbl:SetText(labels[i] or "")
        -- Status atlas left of the label text (ready / decline / pending mark).
        local icon = s:CreateTexture(nil, "OVERLAY")
        icon:SetSize(STEP_ICON_SIZE, STEP_ICON_SIZE)
        icon:Hide()
        s.segments[i], s.labels[i] = seg, lbl
        s.icons[i] = icon
    end

    function s:SetStep(i, state)
        local seg, lbl, icon = self.segments[i], self.labels[i], self.icons[i]
        if not seg then return end
        seg._rcptStepState = state
        local c = STEP_COLORS[state] or "idle"
        seg:SetColorTexture(Color(c))
        lbl:SetTextColor(Color(c))
        if state == "active" then Style.Pulse(seg) else Style.StopPulse(seg) end

        -- Shift the centred label right by half the icon so icon + text stay centred.
        local atlas = STEP_ICON_STATE[state] and Style.StatusAtlas(STEP_ICON_STATE[state])
        local shift = 0
        if atlas then
            icon:SetAtlas(atlas)
            icon:ClearAllPoints()
            local tw = lbl:GetStringWidth() or 0
            shift = floor((STEP_ICON_SIZE + 2) / 2)
            if tw > 0 then
                icon:SetPoint("RIGHT", lbl, "CENTER", -(tw / 2) - 2, 0)
            else
                icon:SetPoint("RIGHT", lbl, "LEFT", -2, 0)
            end
            icon:Show()
        else
            icon:Hide()
        end
        lbl:ClearAllPoints()
        lbl:SetPoint("TOP", seg, "BOTTOM", shift, -3)
    end

    -- Hiding a frame stops its animation groups: restart the pulse of every "active" segment on show.
    s:HookScript("OnShow", function(self)
        for i = 1, #self.segments do
            local seg = self.segments[i]
            if seg._rcptStepState == "active" then Style.Pulse(seg) end
        end
    end)

    function s:Reset()
        for i = 1, #self.segments do self:SetStep(i, "idle") end
    end

    s:Reset()
    return s
end

------------------------------------------------------------------------
-- Movement and positions (always relative to UIParent)
------------------------------------------------------------------------

-- Fraction of a frame's width/height at which each anchor point sits.
local ANCHORS = {
    TOPLEFT = { 0, 1 }, TOP = { 0.5, 1 }, TOPRIGHT = { 1, 1 },
    LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 }, RIGHT = { 1, 0.5 },
    BOTTOMLEFT = { 0, 0 }, BOTTOM = { 0.5, 0 }, BOTTOMRIGHT = { 1, 0 },
}

local function Round(v) return floor(v * 10 + 0.5) / 10 end

-- frame units -> UIParent units factor (SetPoint offsets are in the frame's own units).
local function ScaleToParent(frame)
    local fe, ue = frame:GetEffectiveScale(), UIParent:GetEffectiveScale()
    if not fe or not ue or fe <= 0 or ue <= 0 then return 1 end
    return fe / ue
end

-- Saved positions are in UIParent units, so they survive a frame scale change.
local function Anchor(frame, point, relativePoint, x, y)
    local k = ScaleToParent(frame)
    frame:ClearAllPoints()
    frame:SetPoint(point, UIParent, relativePoint, x / k, y / k)
end

-- TOP-anchored position: point "TOP" on UIParent's BOTTOMLEFT, x = the frame's centre x,
-- y = its top edge, both in UIParent units. A frame anchored this way grows downwards only.
function Style.GetPosition(frame)
    if not frame then return nil end
    local cx = frame:GetCenter()
    local top = frame:GetTop()
    if not cx or not top then return nil end
    local k = ScaleToParent(frame)
    return { point = "TOP", relativePoint = "BOTTOMLEFT", x = Round(cx * k), y = Round(top * k) }
end

local function IsFiniteNumber(v)
    return type(v) == "number" and v == v and v > -1e6 and v < 1e6
end

-- Frame rect (left, bottom, w, h) in UIParent units for `pos`. Positions saved before the
-- TOP format (CENTER/CENTER, written at frame scale 1) are read as UIParent units too.
local function RectFor(frame, pos)
    local k = ScaleToParent(frame)
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    local w, h = (frame:GetWidth() or 0) * k, (frame:GetHeight() or 0) * k
    local rel, pt = ANCHORS[pos.relativePoint], ANCHORS[pos.point]
    local ax, ay = rel[1] * sw + pos.x, rel[2] * sh + pos.y
    return ax - pt[1] * w, ay - pt[2] * h, w, h
end

local function IsOnScreen(frame, pos)
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    local left, bottom, w, h = RectFor(frame, pos)
    local mx, my = math.min(BOUNDS_MARGIN, w), math.min(BOUNDS_MARGIN, h)
    return left + w >= mx and left <= sw - mx and bottom + h >= my and bottom <= sh - my
end

function Style.ApplyPosition(frame, pos)
    if not frame or type(pos) ~= "table" then return false end
    if not ANCHORS[pos.point] or not ANCHORS[pos.relativePoint] then return false end
    if not IsFiniteNumber(pos.x) or not IsFiniteNumber(pos.y) then return false end
    if not IsOnScreen(frame, pos) then return false end
    local left, bottom, w, h = RectFor(frame, pos)
    if w > 0 and h > 0 then
        -- Re-anchor any saved point (old CENTER ones included) by TOP.
        Anchor(frame, "TOP", "BOTTOMLEFT", left + w / 2, bottom + h)
    else
        Anchor(frame, pos.point, pos.relativePoint, pos.x, pos.y)
    end
    return true
end

local function IsLocked()
    local cfg = _G.RCPT_Config
    return type(cfg) == "table" and cfg.lockFrames == true
end

-- Drag to move; refused while RCPT_Config.lockFrames is true (read at drag start),
-- unless opts.ignoreLock (dialogs stay movable when frames are locked).
function Style.MakeMovable(frame, onMoved, opts)
    local ignoreLock = type(opts) == "table" and opts.ignoreLock == true
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not ignoreLock and IsLocked() then return end
        self._rcptMoving = true
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        if not self._rcptMoving then return end
        self._rcptMoving = nil
        self:StopMovingOrSizing()
        self:SetUserPlaced(false) -- we persist positions ourselves, not layout-cache
        local pos = Style.GetPosition(self)
        if pos then Anchor(self, pos.point, pos.relativePoint, pos.x, pos.y) end
        if onMoved then onMoved(self) end
    end)
    -- Hidden mid-drag: OnDragStop may not come, so stop moving here.
    frame:HookScript("OnHide", function(self)
        if self._rcptMoving then
            self._rcptMoving = nil
            self:StopMovingOrSizing()
            self:SetUserPlaced(false)
        end
    end)
end

------------------------------------------------------------------------
-- Ready-check status icons
------------------------------------------------------------------------

-- Atlases the live ready-check frame uses (READY_CHECK_*_TEXTURE in ReadyCheck.lua).
local STATUS_ATLAS = {
    ready = "UI-LFG-ReadyMark",
    notready = "UI-LFG-DeclineMark",
    waiting = "UI-LFG-PendingMark",
}
local STATUS_FILE = {
    ready = "Interface\\RaidFrame\\ReadyCheck-Ready",
    notready = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    waiting = "Interface\\RaidFrame\\ReadyCheck-Waiting",
}

-- Inline markup for FontStrings; "" for an unknown state.
function Style.StatusIcon(state, size)
    local atlas = STATUS_ATLAS[state]
    if not atlas then return "" end
    size = size or 14
    return string.format("|A:%s:%d:%d:0:0|a", atlas, size, size)
end

-- Atlas name for texture:SetAtlas(), or nil.
function Style.StatusAtlas(state)
    return STATUS_ATLAS[state]
end

-- File path for texture:SetTexture(), or nil.
function Style.StatusTexture(state)
    return STATUS_FILE[state]
end

------------------------------------------------------------------------
-- Dialog
------------------------------------------------------------------------

-- Centred, movable panel; ESC closes it when `name` is given (UISpecialFrames needs a global name).
-- opts: width, height, title, onMoved. Fields: title, closeButton, content. Method: SetTitle(text).
function Style.CreateDialog(name, opts)
    opts = opts or {}
    local d = Style.CreatePanel(name, UIParent, {
        width = opts.width or 360, height = opts.height or 240, strata = "DIALOG", accent = "top",
    })
    d:SetPoint("CENTER")
    d:SetToplevel(true)
    Style.MakeMovable(d, opts.onMoved, { ignoreLock = true })

    d.title = Style.CreateText(d, "title", "text")
    d.title:SetPoint("TOPLEFT", 12, -12)
    d.title:SetPoint("TOPRIGHT", -32, -12)
    d.title:SetJustifyH("LEFT")

    d.closeButton = Style.CreateButton(d, "x", { width = 20, height = 18, variant = "ghost" })
    d.closeButton:SetPoint("TOPRIGHT", -6, -8)
    d.closeButton:SetScript("OnClick", function() d:Hide() end)

    d.content = CreateFrame("Frame", nil, d)
    d.content:SetPoint("TOPLEFT", 12, -38)
    d.content:SetPoint("BOTTOMRIGHT", -12, 12)

    function d:SetTitle(text) self.title:SetText(text or "") end
    d:SetTitle(opts.title)

    if name and UISpecialFrames then
        local listed = false
        for _, v in ipairs(UISpecialFrames) do
            if v == name then listed = true break end
        end
        if not listed then table.insert(UISpecialFrames, name) end
    end

    d:Hide()
    return d
end

return Style
