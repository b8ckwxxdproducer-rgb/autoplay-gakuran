-- ============================================================
-- GAKURAN AUTO RHYTHM (Matcha) - Console Toggle Version
-- Press RIGHT SHIFT to toggle ON/OFF.
-- ============================================================

-- Security gate
if not (game.GameId == 9199655655 or game.PlaceId == 128736949265057) then
    return warn("[Auto Rhythm] Gakuran only.")
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

-- ============ NOTIFICATION SYSTEM ============
local function notifyUser(title, text)
    -- Method 1: Roblox's built-in notification system
    local success, err = pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = title,
            Text = text,
            Duration = 3
        })
    end)
    if success then return end

    -- Method 2: Matcha's built-in notify function (if available)
    if notify then
        pcall(function() notify(text, title, 3) end)
        return
    end

    -- Method 3: Fallback to console
    print(string.format("[%s] %s", title, text))
end

-- ============ CONFIG ============
local CONFIG = {
    baseHitWindow       = 18,
    predictionLead      = 0.028,
    longNoteReleaseBuffer = 0.02,
    laneDebounce        = 0.045,
    shortNoteHold       = 0.04,
    receptorRefresh     = 0.5,
    laneMatchTolerance  = 30,
    keys2Lane = {70, 74},              -- F, J
    keys4Lane = {88, 67, 78, 77},      -- X, C, N, M
}

-- ============ STATE ============
local state = {
    enabled       = true, -- Starts enabled by default
    receptors     = {},
    lastRefresh   = 0,
    laneLastPress = {},
    activeHolds   = {},
    noteTrack     = {},
}

-- ============ TOGGLE KEYBIND ============
if UserInputService then
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Enum.KeyCode.RightShift then
            state.enabled = not state.enabled
            if state.enabled then
                notifyUser("Auto Rhythm", "ENABLED")
            else
                notifyUser("Auto Rhythm", "DISABLED")
                for _, h in pairs(state.activeHolds) do
                    if keyrelease then keyrelease(h.key) else game:GetService("VirtualInputManager"):SendKeyEvent(false, h.key, false, game) end
                end
                state.activeHolds = {}
                state.noteTrack = {}
            end
        end
    end)
    notifyUser("Auto Rhythm", "Loaded. Press RIGHT SHIFT to toggle.")
else
    notifyUser("Auto Rhythm", "Loaded. Script is always ON.")
end

-- ============ KEY PRESS HELPERS ============
local VIM = game:GetService("VirtualInputManager")
local function pressKey(vk)
    if keypress then keypress(vk) else VIM:SendKeyEvent(true, vk, false, game) end
end
local function releaseKey(vk)
    if keyrelease then keyrelease(vk) else VIM:SendKeyEvent(false, vk, false, game) end
end

-- ============ DISCOVERY ============
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
    local folder = root:FindFirstChild("Receptors")
    if not folder then return end

    local list = {}
    for _, r in ipairs(folder:GetChildren()) do
        if r:IsA("GuiObject") then table.insert(list, r) end
    end
    table.sort(list, function(a, b) return a.AbsolutePosition.X < b.AbsolutePosition.X end)

    local n = #list
    local keys
    if n == 2 then keys = CONFIG.keys2Lane
    elseif n == 4 then keys = CONFIG.keys4Lane
    else
        local def = {88, 67, 78, 77, 86, 66}
        keys = {}
        for i = 1, n do keys[i] = def[i] or def[#def] end
    end

    for i, r in ipairs(list) do
        local p, s = r.AbsolutePosition, r.AbsoluteSize
        state.receptors[i] = { x = p.X + s.X / 2, y = p.Y, key = keys[i] }
    end
end

-- ============ NOTE SCAN ============
local function scanNotes()
    local root = findRhythmRoot()
    if not root then return {} end
    local lanes = root:FindFirstChild("Lanes")
    if not lanes then return {} end

    local out = {}
    for _, lane in ipairs(lanes:GetChildren()) do
        for _, note in ipairs(lane:GetChildren()) do
            if note.Name == "NoteTemplate" and note:IsA("GuiObject") then
                local p, s = note.AbsolutePosition, note.AbsoluteSize
                local tail = note:FindFirstChild("Tail")
                local tailH = (tail and tail:IsA("GuiObject")) and tail.AbsoluteSize.Y or 0
                table.insert(out, {
                    instance   = note,
                    x          = p.X + s.X / 2,
                    y          = p.Y,
                    height     = s.Y,
                    tailHeight = tailH,
                    isLong     = tailH > 1,
                })
            end
        end
    end
    return out
end

-- ============ VELOCITY TRACKING ============
local function updateVelocity(note)
    local now = tick()
    local t = state.noteTrack[note.instance]
    if t then
        local dt = now - t.lastTime
        if dt > 0 then
            local dy = note.y - t.lastY
            if dy > 0 then t.velocity = dy / dt end
        end
        t.lastY, t.lastTime = note.y, now
    else
        state.noteTrack[note.instance] = { lastY = note.y, lastTime = now, velocity = 0 }
    end
    return state.noteTrack[note.instance]
end

local function cleanupTracks()
    for inst in pairs(state.noteTrack) do
        if not inst.Parent then state.noteTrack[inst] = nil end
    end
end

-- ============ HIT LOGIC ============
local function tryHit(note, receptor, laneIndex)
    local now = tick()
    if state.laneLastPress[laneIndex] and (now - state.laneLastPress[laneIndex]) < CONFIG.laneDebounce then
        return
    end

    local t = state.noteTrack[note.instance]
    local vel = t and t.velocity or 0
    local shouldHit = false

    if vel > 10 then
        local timeToHit = (receptor.y - note.y) / vel
        if timeToHit <= CONFIG.predictionLead and timeToHit > -0.05 then
            shouldHit = true
        end
    else
        if math.abs(note.y - receptor.y) <= CONFIG.baseHitWindow then
            shouldHit = true
        end
    end
    if not shouldHit then return end

    pressKey(receptor.key)
    state.laneLastPress[laneIndex] = now

    if note.isLong then
        local tailBottom = note.y + note.height + note.tailHeight
        local travel = vel > 10 and (receptor.y - tailBottom) / vel or 0.15
        state.activeHolds[laneIndex] = {
            releaseAt = now + math.max(0, travel) + CONFIG.longNoteReleaseBuffer,
            key = receptor.key,
        }
    else
        task.delay(CONFIG.shortNoteHold, function()
            local h = state.activeHolds[laneIndex]
            if not h or h.key ~= receptor.key then
                releaseKey(receptor.key)
            end
        end)
    end
end

local function processHolds()
    local now = tick()
    for lane, h in pairs(state.activeHolds) do
        if now >= h.releaseAt then
            releaseKey(h.key)
            state.activeHolds[lane] = nil
        end
    end
end

-- ============ MAIN LOOP ============
RunService.Heartbeat:Connect(function()
    if not state.enabled then return end

    local now = tick()
    if now - state.lastRefresh > CONFIG.receptorRefresh then
        refreshReceptors()
        state.lastRefresh = now
    end

    local laneCount = 0
    for _ in pairs(state.receptors) do laneCount = laneCount + 1 end
    if laneCount == 0 then return end

    local notes = scanNotes()
    cleanupTracks()
    for _, n in ipairs(notes) do updateVelocity(n) end

    for _, n in ipairs(notes) do
        local bestLane, bestDist = nil, math.huge
        for i, r in pairs(state.receptors) do
            local dx = math.abs(n.x - r.x)
            if dx < bestDist and dx <= CONFIG.laneMatchTolerance then
                bestDist, bestLane = dx, i
            end
        end
        if bestLane then tryHit(n, state.receptors[bestLane], bestLane) end
    end

    processHolds()
end)
