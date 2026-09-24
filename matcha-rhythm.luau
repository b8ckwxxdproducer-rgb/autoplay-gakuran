-- ============================================================
-- GAKURAN AUTO RHYTHM (Matcha) v2
-- Press RIGHT SHIFT to toggle ON/OFF.
-- ============================================================

if not (game.GameId == 9199655655 or game.PlaceId == 128736949265057) then
    return warn("[Auto Rhythm] Gakuran only.")
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

-- ============ CONFIG ============
local CONFIG = {
    predictionLead        = 0.028,
    baseHitWindow         = 20,
    longNoteReleaseBuffer = 0.02,
    laneDebounce          = 0.045,
    shortNoteHold         = 0.04,
    receptorRefresh       = 0.5,
    laneMatchTolerance    = 40,
    longNoteMinHeight     = 60,   -- px; notes taller than this are long notes
    -- KEYBINDS: Change these to match the keys you press in Gakuran.
    -- Order: leftmost lane -> rightmost lane.
    keys2Lane = {70, 74},              -- F, J
    keys4Lane = {68, 70, 74, 75},      -- D, F, J, K
}

-- ============ STATE ============
local state = {
    enabled       = true,
    receptors     = {},
    lastRefresh   = 0,
    laneLastPress = {},
    activeHolds   = {},
    noteTrack     = {},
}

local VIM = game:GetService("VirtualInputManager")
local function pressKey(vk)
    if keypress then keypress(vk) else VIM:SendKeyEvent(true, vk, false, game) end
end
local function releaseKey(vk)
    if keyrelease then keyrelease(vk) else VIM:SendKeyEvent(false, vk, false, game) end
end

-- ============ TOGGLE ============
UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.KeyCode == Enum.KeyCode.RightShift then
        state.enabled = not state.enabled
        print("[Auto Rhythm] " .. (state.enabled and "ENABLED" or "DISABLED"))
        if not state.enabled then
            for _, h in pairs(state.activeHolds) do releaseKey(h.key) end
            state.activeHolds = {}
        end
    end
end)

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
        -- Only match "Receptor1", "Receptor2", etc., not ReceptorVisual/Glow/Outline
        if r:IsA("GuiObject") and r.Name:match("^Receptor%d+$") then
            table.insert(list, r)
        end
    end
    table.sort(list, function(a, b)
        return a.AbsolutePosition.X < b.AbsolutePosition.X
    end)

    local n = #list
    local keys
    if n == 2 then keys = CONFIG.keys2Lane
    elseif n == 4 then keys = CONFIG.keys4Lane
    else
        local def = {68, 70, 74, 75, 71, 72}
        keys = {}
        for i = 1, n do keys[i] = def[i] or def[#def] end
    end

    for i, r in ipairs(list) do
        local p, s = r.AbsolutePosition, r.AbsoluteSize
        state.receptors[i] = { x = p.X + s.X / 2, y = p.Y, key = keys[i] }
    end
end

-- ============ NOTES ============
local function isInOffscreenPool(obj, root)
    local p = obj.Parent
    while p and p ~= root do
        if p.Name == "OffscreenPool" then return true end
        p = p.Parent
    end
    return false
end

local function scanNotes()
    local root = findRhythmRoot()
    if not root then return {} end

    local out = {}
    for _, v in ipairs(root:GetDescendants()) do
        if v.Name == "NoteTemplate" and v:IsA("GuiObject") then
            if not isInOffscreenPool(v, root) and v.Visible then
                local p, s = v.AbsolutePosition, v.AbsoluteSize
                if s.Y > 0 and p.Y > -100 then
                    table.insert(out, {
                        instance   = v,
                        x          = p.X + s.X / 2,
                        y          = p.Y,
                        height     = s.Y,
                        isLong     = s.Y >= CONFIG.longNoteMinHeight,
                    })
                end
            end
        end
    end
    return out
end

-- ============ VELOCITY ============
local function updateVelocity(note)
    local now = tick()
    local t = state.noteTrack[note.instance]
    if t then
        local dt = now - t.lastTime
        if dt > 0 then
            local dy = note.y - t.lastY
            -- If the note jumped UP, it was recycled from the pool
            if dy < -50 then
                t.velocity = 0
            elseif dy > 0 then
                t.velocity = dy / dt
            end
        end
        t.lastY, t.lastTime = note.y, now
    else
        state.noteTrack[note.instance] = { lastY = note.y, lastTime = now, velocity = 0 }
    end
    return state.noteTrack[note.instance]
end

-- ============ HIT ============
local function tryHit(note, receptor, laneIndex)
    local now = tick()
    if state.laneLastPress[laneIndex] and
       (now - state.laneLastPress[laneIndex]) < CONFIG.laneDebounce then
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
        local tailBottom = note.y + note.height
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
    for _, n in ipairs(notes) do updateVelocity(n) end

    for _, n in ipairs(notes) do
        local bestLane, bestDist = nil, math.huge
        for i, r in pairs(state.receptors) do
            local dx = math.abs(n.x - r.x)
            if dx < bestDist and dx <= CONFIG.laneMatchTolerance then
                bestDist, bestLane = dx, i
            end
        end
        if bestLane then
            tryHit(n, state.receptors[bestLane], bestLane)
        end
    end

    processHolds()
end)

print("[Auto Rhythm] Loaded. Press RIGHT SHIFT to toggle.")
