-- Gakuran Auto Rhythm - Optimized with UI
if not (game.GameId == 9199655655 or game.PlaceId == 128736949265057) then
    return warn("Gakuran only")
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

-- ============ CONFIG ============
local CONFIG = {
    -- Hit window in pixels around the receptor Y. Auto-scales with note velocity.
    baseHitWindow = 18,
    -- Prediction lead time in seconds. Press this early to compensate for input latency.
    predictionLead = 0.028,
    -- Extra hold time for long notes after the tail passes (seconds).
    longNoteReleaseBuffer = 0.02,
    -- Minimum time between presses in the same lane (seconds).
    laneDebounce = 0.045,
    -- Short note hold duration (seconds).
    shortNoteHold = 0.04,
    -- Keycodes for 2-lane and 4-lane layouts (virtual key byte codes).
    keys2Lane = {70, 74},            -- F, J
    keys4Lane = {88, 67, 78, 77},    -- X, C, N, M
    -- How often to re-scan receptor positions (seconds).
    receptorRefresh = 0.5,
}

-- ============ STATE ============
local state = {
    enabled = false,
    receptors = {},        -- {[index] = {x = ..., y = ..., key = ...}}
    lastRefresh = 0,
    laneLastPress = {},    -- [laneIndex] = tick()
    activeHolds = {},      -- [laneIndex] = {releaseAt = time, note = noteInstance}
    noteTrack = {},        -- [noteInstance] = {lastY = ..., lastTime = ..., velocity = ...}
}

-- ============ KEY HELPERS ============
-- Matcha exposes keypress/keyrelease globally. Fallback to VirtualInputManager.
local function pressKey(vkey)
    if keypress then
        keypress(vkey)
    else
        game:GetService("VirtualInputManager"):SendKeyEvent(true, vkey, false, game)
    end
end

local function releaseKey(vkey)
    if keyrelease then
        keyrelease(vkey)
    else
        game:GetService("VirtualInputManager"):SendKeyEvent(false, vkey, false, game)
    end
end

-- ============ RHYTHM UI DISCOVERY ============
local function findRhythmRoot()
    local pg = LocalPlayer:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local ui = pg:FindFirstChild("RhythmServiceUI")
    if not ui then return nil end
    return ui:FindFirstChild("RhythmRoot")
end

local function refreshReceptors()
    state.receptors = {}
    local root = findRhythmRoot()
    if not root then return end
    local receptorsFolder = root:FindFirstChild("Receptors")
    if not receptorsFolder then return end

    -- Collect receptors and sort left-to-right by X
    local list = {}
    for _, r in ipairs(receptorsFolder:GetChildren()) do
        if r:IsA("GuiObject") then
            table.insert(list, r)
        end
    end
    table.sort(list, function(a, b)
        return a.AbsolutePosition.X < b.AbsolutePosition.X
    end)

    local n = #list
    local keys
    if n == 2 then
        keys = CONFIG.keys2Lane
    elseif n == 4 then
        keys = CONFIG.keys4Lane
    else
        -- Fallback: distribute 4-lane keys, or use first n keys from a default set
        keys = {}
        local default = {88, 67, 78, 77, 86, 66}
        for i = 1, n do keys[i] = default[i] or default[#default] end
    end

    for i, r in ipairs(list) do
        local size = r.AbsoluteSize
        state.receptors[i] = {
            x = r.AbsolutePosition.X + size.X / 2,
            y = r.AbsolutePosition.Y,
            key = keys[i],
            width = size.X,
        }
    end
end

-- ============ NOTE SCANNING ============
local function scanNotes()
    local root = findRhythmRoot()
    if not root then return {} end
    local lanes = root:FindFirstChild("Lanes")
    if not lanes then return {} end

    local notes = {}
    for _, lane in ipairs(lanes:GetChildren()) do
        for _, note in ipairs(lane:GetChildren()) do
            if note.Name == "NoteTemplate" and note:IsA("GuiObject") then
                local pos = note.AbsolutePosition
                local size = note.AbsoluteSize
                local tail = note:FindFirstChild("Tail")
                local tailH = 0
                if tail and tail:IsA("GuiObject") then
                    tailH = tail.AbsoluteSize.Y
                end
                table.insert(notes, {
                    instance = note,
                    x = pos.X + size.X / 2,
                    y = pos.Y,
                    height = size.Y,
                    tailHeight = tailH,
                    isLong = tailH > 1,
                })
            end
        end
    end
    return notes
end

-- ============ MAIN UPDATE ============
local function updateNoteVelocity(note)
    local now = tick()
    local tracked = state.noteTrack[note.instance]
    if tracked then
        local dt = now - tracked.lastTime
        if dt > 0 then
            local dy = note.y - tracked.lastY
            -- Only track downward motion (notes falling)
            if dy > 0 then
                tracked.velocity = dy / dt
            end
        end
        tracked.lastY = note.y
        tracked.lastTime = now
    else
        state.noteTrack[note.instance] = {
            lastY = note.y,
            lastTime = now,
            velocity = 0,
        }
    end
    return state.noteTrack[note.instance]
end

local function cleanupTracked(activeNotes)
    -- Remove entries for notes that no longer exist
    for inst in pairs(state.noteTrack) do
        if not inst.Parent then
            state.noteTrack[inst] = nil
        end
    end
end

local function tryHit(note, receptor, laneIndex)
    local now = tick()
    if state.laneLastPress[laneIndex] and (now - state.laneLastPress[laneIndex]) < CONFIG.laneDebounce then
        return
    end

    -- Compute time until this note reaches the receptor Y
    local tracked = state.noteTrack[note.instance]
    local velocity = tracked and tracked.velocity or 0

    -- If we know the velocity, use predictive timing. Otherwise use a fixed window.
    local shouldHit = false
    if velocity > 10 then
        -- timeUntilHit = distance / velocity
        local distance = receptor.y - note.y
        local timeUntilHit = distance / velocity
        -- Press when the note is predicted to hit within the lead window
        if timeUntilHit <= CONFIG.predictionLead and timeUntilHit > -0.05 then
            shouldHit = true
        end
    else
        -- Fallback: pixel window
        if math.abs(note.y - receptor.y) <= CONFIG.baseHitWindow then
            shouldHit = true
        end
    end

    if not shouldHit then return end

    -- Press
    pressKey(receptor.key)
    state.laneLastPress[laneIndex] = now

    if note.isLong then
        -- Compute release time: when the tail bottom reaches the receptor Y
        local totalHeight = note.height + note.tailHeight
        local tailBottomY = note.y + totalHeight
        local travelToRelease
        if velocity > 10 then
            travelToRelease = (receptor.y - tailBottomY) / velocity
        else
            travelToRelease = 0.15 -- fallback
        end
        local releaseAt = now + math.max(0, travelToRelease) + CONFIG.longNoteReleaseBuffer
        state.activeHolds[laneIndex] = {
            releaseAt = releaseAt,
            key = receptor.key,
        }
    else
        -- Short note: schedule release
        task.delay(CONFIG.shortNoteHold, function()
            -- Only release if no long note has taken over this lane
            if not state.activeHolds[laneIndex] or state.activeHolds[laneIndex].key ~= receptor.key then
                releaseKey(receptor.key)
            end
        end)
    end
end

local function processHolds()
    local now = tick()
    for laneIndex, hold in pairs(state.activeHolds) do
        if now >= hold.releaseAt then
            releaseKey(hold.key)
            state.activeHolds[laneIndex] = nil
        end
    end
end

-- ============ UI ============
local function createUI()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "MatchaAutoRhythm"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

    local frame = Instance.new("Frame")
    frame.Name = "Main"
    frame.Size = UDim2.new(0, 240, 0, 130)
    frame.Position = UDim2.new(0, 20, 0, 20)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
    frame.BackgroundTransparency = 0.1
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = screenGui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(80, 200, 140)
    stroke.Thickness = 1
    stroke.Transparency = 0.4
    stroke.Parent = frame

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 30)
    title.BackgroundTransparency = 1
    title.Text = "Auto Rhythm"
    title.TextColor3 = Color3.fromRGB(80, 200, 140)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 15
    title.Parent = frame

    local toggle = Instance.new("TextButton")
    toggle.Size = UDim2.new(1, -20, 0, 36)
    toggle.Position = UDim2.new(0, 10, 0, 38)
    toggle.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
    toggle.BorderSizePixel = 0
    toggle.Text = "Disabled"
    toggle.TextColor3 = Color3.fromRGB(220, 220, 220)
    toggle.Font = Enum.Font.GothamBold
    toggle.TextSize = 14
    toggle.Parent = frame

    local toggleCorner = Instance.new("UICorner")
    toggleCorner.CornerRadius = UDim.new(0, 6)
    toggleCorner.Parent = toggle

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -20, 0, 40)
    status.Position = UDim2.new(0, 10, 0, 80)
    status.BackgroundTransparency = 1
    status.Text = "Idle"
    status.TextColor3 = Color3.fromRGB(160, 160, 170)
    status.Font = Enum.Font.Gotham
    status.TextSize = 12
    status.TextWrapped = true
    status.Parent = frame

    local function setEnabled(on)
        state.enabled = on
        if on then
            toggle.Text = "Enabled"
            toggle.BackgroundColor3 = Color3.fromRGB(40, 120, 80)
            status.Text = "Scanning rhythm UI..."
            refreshReceptors()
            state.lastRefresh = tick()
        else
            toggle.Text = "Disabled"
            toggle.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
            status.Text = "Idle"
            -- Release all held keys
            for laneIndex, hold in pairs(state.activeHolds) do
                releaseKey(hold.key)
            end
            state.activeHolds = {}
            state.noteTrack = {}
        end
    end

    toggle.MouseButton1Click:Connect(function()
        setEnabled(not state.enabled)
    end)

    return status
end

-- ============ START ============
local statusLabel = createUI()

local accumulated = 0
RunService.Heartbeat:Connect(function(dt)
    if not state.enabled then return end

    -- Periodic receptor refresh
    local now = tick()
    if now - state.lastRefresh > CONFIG.receptorRefresh then
        refreshReceptors()
        state.lastRefresh = now
    end

    if next(state.receptors) == nil then
        statusLabel.Text = "Waiting for rhythm UI..."
        return
    end

    local notes = scanNotes()
    cleanupTracked(notes)

    -- Update velocities
    for _, note in ipairs(notes) do
        updateNoteVelocity(note)
    end

    -- Match notes to receptors and attempt hits
    for _, note in ipairs(notes) do
        local bestLane = nil
        local bestDist = math.huge
        for i, receptor in pairs(state.receptors) do
            local dx = math.abs(note.x - receptor.x)
            if dx < bestDist and dx < 30 then
                bestDist = dx
                bestLane = i
            end
        end
        if bestLane then
            tryHit(note, state.receptors[bestLane], bestLane)
        end
    end

    processHolds()

    statusLabel.Text = string.format("Lanes: %d | Notes: %d | Holds: %d",
        (function() local n=0 for _ in pairs(state.receptors) do n=n+1 end return n end)(),
        #notes,
        (function() local n=0 for _ in pairs(state.activeHolds) do n=n+1 end return n end)()
    )
end)

print("[Matcha Auto Rhythm] Loaded. Toggle in the UI.")