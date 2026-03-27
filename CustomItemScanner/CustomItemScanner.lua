local ADDON_NAME = "CustomItemScanner"

local frame = CreateFrame("Frame")
local scanner = {}

scanner.running = false
scanner.currentID = 50000
scanner.startID = 50000
scanner.maxID = 1000000
scanner.endID = 1000000
scanner.batchSize = 100
scanner.delay = 0.10
scanner.elapsed = 0
scanner.pass = 1
scanner.maxPasses = 1
scanner.useServerRequests = true
scanner.maxServerRequestsPerTick = 5
scanner.serverRequestsThisTick = 0

scanner.chunkSize = 10000
scanner.chunkStart = 0
scanner.chunkEnd = 0
scanner.chunkCooldown = 3.0
scanner.chunkTimer = 0
scanner.paused = false
scanner.chunkNumber = 0
scanner.totalChunks = 0

local visibleRows = 16
local rowHeight = 18
local rows = {}
local sortedItemIDs = {}
local searchText = ""
local qualityFilter = nil
local listDirty = true
local scrollFrame
local UpdateWindow
local settingsFocusEdits = {}
local settingsWindow
local RefreshSettingsFields

if not CustomItemScannerDB then
    CustomItemScannerDB = {}
end

if not CustomItemScannerDB.items then
    CustomItemScannerDB.items = {}
end

if not CustomItemScannerDB.minimapAngle then
    CustomItemScannerDB.minimapAngle = 220
end

if not CustomItemScannerDB.settings then
    CustomItemScannerDB.settings = {}
end

local SETTINGS_DEFAULTS = {
    batchSize = 100,
    delay = 0.10,
    useServerRequests = true,
    maxServerRequestsPerTick = 5,
    chunkSize = 10000,
    chunkCooldown = 3.0,
}

local function ApplySettingsToScanner()
    if not CustomItemScannerDB.settings then
        CustomItemScannerDB.settings = {}
    end
    local s = CustomItemScannerDB.settings
    for k, v in pairs(SETTINGS_DEFAULTS) do
        if s[k] == nil then
            s[k] = v
        end
    end
    scanner.batchSize = math.max(1, math.min(500, math.floor(tonumber(s.batchSize) or SETTINGS_DEFAULTS.batchSize)))
    scanner.delay = math.max(0.01, math.min(2.0, tonumber(s.delay) or SETTINGS_DEFAULTS.delay))
    scanner.useServerRequests = s.useServerRequests and true or false
    scanner.maxServerRequestsPerTick = math.max(0, math.min(50, math.floor(tonumber(s.maxServerRequestsPerTick) or SETTINGS_DEFAULTS.maxServerRequestsPerTick)))
    scanner.chunkSize = math.max(100, math.min(1000000, math.floor(tonumber(s.chunkSize) or SETTINGS_DEFAULTS.chunkSize)))
    scanner.chunkCooldown = math.max(0, math.min(120, tonumber(s.chunkCooldown) or SETTINGS_DEFAULTS.chunkCooldown))
    s.batchSize = scanner.batchSize
    s.delay = scanner.delay
    s.useServerRequests = scanner.useServerRequests
    s.maxServerRequestsPerTick = scanner.maxServerRequestsPerTick
    s.chunkSize = scanner.chunkSize
    s.chunkCooldown = scanner.chunkCooldown
end

ApplySettingsToScanner()

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[CustomItemScanner]|r " .. msg)
end

local function BuildSortedList()
    if not listDirty then
        return
    end
    listDirty = false

    for i = #sortedItemIDs, 1, -1 do
        sortedItemIDs[i] = nil
    end

    local filter = strlower(searchText or "")
    local useFilter = filter ~= ""
    local useQuality = qualityFilter ~= nil

    for itemID, data in pairs(CustomItemScannerDB.items) do
        local passesQuality = (not useQuality) or (data.rarity == qualityFilter)
        if passesQuality then
            if not useFilter then
                table.insert(sortedItemIDs, itemID)
            else
                local name = strlower(data.name or "")
                if string.find(name, filter, 1, true) then
                    table.insert(sortedItemIDs, itemID)
                end
            end
        end
    end

    table.sort(sortedItemIDs, function(a, b)
        return a < b
    end)
end

local function CountFound()
    local count = 0
    for _ in pairs(CustomItemScannerDB.items) do
        count = count + 1
    end
    return count
end

local function SaveItem(itemID, itemName, itemLink, rarity, level, minLevel, itemType, itemSubType, stackCount, equipLoc, texture, sellPrice)
    if not CustomItemScannerDB.items[itemID] then
        CustomItemScannerDB.items[itemID] = {
            id = itemID,
            name = itemName,
            link = itemLink,
            rarity = rarity,
            level = level,
            minLevel = minLevel,
            type = itemType,
            subtype = itemSubType,
            stack = stackCount,
            equipLoc = equipLoc,
            texture = texture,
            sellPrice = sellPrice,
        }

        listDirty = true
        Print("Found: " .. (itemLink or itemName or ("item:" .. itemID)) .. " |cffaaaaaa(ID: " .. itemID .. ")|r")
    end
end

local scanTooltip = CreateFrame("GameTooltip", "CustomItemScannerScanTooltip", UIParent, "GameTooltipTemplate")

local function RequestItem(itemID)
    scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTooltip:SetHyperlink("item:" .. itemID .. ":0:0:0:0:0:0:0")
    scanTooltip:Hide()
end

local function ScanOneItem(itemID)
    if scanner.useServerRequests and scanner.serverRequestsThisTick < scanner.maxServerRequestsPerTick then
        RequestItem(itemID)
        scanner.serverRequestsThisTick = scanner.serverRequestsThisTick + 1
    end
    local itemName, itemLink, rarity, level, minLevel, itemType, itemSubType, stackCount, equipLoc, texture, sellPrice = GetItemInfo(itemID)

    if itemName then
        SaveItem(itemID, itemName, itemLink, rarity, level, minLevel, itemType, itemSubType, stackCount, equipLoc, texture, sellPrice)
        return true
    end

    return false
end

local function StartNextChunk()
    scanner.chunkNumber = scanner.chunkNumber + 1
    scanner.chunkStart = scanner.startID + (scanner.chunkNumber - 1) * scanner.chunkSize
    scanner.chunkEnd = math.min(scanner.chunkStart + scanner.chunkSize - 1, scanner.endID)
    scanner.currentID = scanner.chunkStart
    scanner.maxID = scanner.chunkEnd
    scanner.paused = false
    scanner.elapsed = 0
    scanner.serverRequestsThisTick = 0
    Print("Chunk " .. scanner.chunkNumber .. "/" .. scanner.totalChunks .. ": scanning " .. scanner.chunkStart .. " - " .. scanner.chunkEnd)
end

local function StartScan(startID, endID)
    startID = tonumber(startID) or 50000
    endID = tonumber(endID) or 1000000
    if endID < startID then
        startID, endID = endID, startID
    end

    scanner.startID = startID
    scanner.endID = endID
    scanner.running = true
    scanner.elapsed = 0
    scanner.pass = 1
    scanner.paused = false
    scanner.chunkTimer = 0
    scanner.chunkNumber = 0
    scanner.totalChunks = math.ceil((endID - startID + 1) / scanner.chunkSize)
    listDirty = true

    StartNextChunk()
end

local function StopScan()
    scanner.running = false
    scanner.paused = false
end

-- ==================== MAIN WINDOW ====================

local mainWindow = CreateFrame("Frame", "CustomItemScannerWindow", UIParent)
mainWindow:SetWidth(700)
mainWindow:SetHeight(460)
mainWindow:SetPoint("CENTER")
mainWindow:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
mainWindow:SetBackdropColor(0, 0, 0, 1)
mainWindow:EnableMouse(true)
mainWindow:SetMovable(true)
mainWindow:SetClampedToScreen(true)
mainWindow:RegisterForDrag("LeftButton")
mainWindow:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
mainWindow:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)
mainWindow:Hide()

tinsert(UISpecialFrames, "CustomItemScannerWindow")

local title = mainWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -12)
title:SetText("Custom Item Scanner")

local closeButton = CreateFrame("Button", nil, mainWindow, "UIPanelCloseButton")
closeButton:SetPoint("TOPRIGHT", -5, -5)

local statusText = mainWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
statusText:SetPoint("TOPLEFT", 16, -30)
statusText:SetText("Status: Idle")

local infoText = mainWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
infoText:SetPoint("TOPLEFT", 16, -50)
infoText:SetText("Listed: 0")

local totalDiscoveredText = mainWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
totalDiscoveredText:SetPoint("TOPRIGHT", -40, -50)
totalDiscoveredText:SetJustifyH("RIGHT")
totalDiscoveredText:SetText("Total discovered: 0")

-- ==================== RANGE CONTROLS ====================

local rangeFrame = CreateFrame("Frame", nil, mainWindow)
rangeFrame:SetPoint("TOPLEFT", 16, -78)
rangeFrame:SetWidth(680)
rangeFrame:SetHeight(30)

local startLabel = rangeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
startLabel:SetPoint("LEFT", 0, 0)
startLabel:SetText("Start ID:")

local startEdit = CreateFrame("EditBox", nil, rangeFrame, "InputBoxTemplate")
startEdit:SetPoint("LEFT", startLabel, "RIGHT", 8, 0)
startEdit:SetWidth(80)
startEdit:SetHeight(20)
startEdit:SetNumeric(true)
startEdit:SetAutoFocus(false)
startEdit:SetText("50000")

local endLabel = rangeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
endLabel:SetPoint("LEFT", startEdit, "RIGHT", 20, 0)
endLabel:SetText("End ID:")

local endEdit = CreateFrame("EditBox", nil, rangeFrame, "InputBoxTemplate")
endEdit:SetPoint("LEFT", endLabel, "RIGHT", 8, 0)
endEdit:SetWidth(80)
endEdit:SetHeight(20)
endEdit:SetNumeric(true)
endEdit:SetAutoFocus(false)
endEdit:SetText("1000000")

local searchLabel = rangeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
searchLabel:SetPoint("LEFT", endEdit, "RIGHT", 18, 0)
searchLabel:SetText("Search:")

local searchEdit = CreateFrame("EditBox", nil, rangeFrame, "InputBoxTemplate")
searchEdit:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
searchEdit:SetWidth(130)
searchEdit:SetHeight(20)
searchEdit:SetAutoFocus(false)
searchEdit:SetText("")

local qualityLabel = rangeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
qualityLabel:SetPoint("LEFT", searchEdit, "RIGHT", 16, 0)
qualityLabel:SetText("Quality:")

local qualityDropDown = CreateFrame("Frame", "CustomItemScannerQualityDropDown", rangeFrame, "UIDropDownMenuTemplate")
qualityDropDown:SetPoint("LEFT", qualityLabel, "RIGHT", -8, -3)
UIDropDownMenu_SetWidth(110, qualityDropDown)

local qualityOptions = {
    { text = "All", value = -1 },
    { text = "|cff9d9d9dPoor|r", value = 0 },
    { text = "|cffffffffCommon|r", value = 1 },
    { text = "|cff1eff00Uncommon|r", value = 2 },
    { text = "|cff0070ddRare|r", value = 3 },
    { text = "|cffa335eeEpic|r", value = 4 },
    { text = "|cffff8000Legendary|r", value = 5 },
    { text = "|cffe6cc80Artifact|r", value = 6 },
}

local function SetQualityDropDownText(text)
    getglobal("CustomItemScannerQualityDropDownText"):SetText(text)
end

local function OnQualitySelected(value, text)
    if value == -1 then
        qualityFilter = nil
    else
        qualityFilter = value
    end
    SetQualityDropDownText(text)
    listDirty = true
    FauxScrollFrame_SetOffset(scrollFrame, 0)
    UpdateWindow()
end

UIDropDownMenu_Initialize(qualityDropDown, function(self, level)
    for _, option in ipairs(qualityOptions) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = option.text
        info.func = function()
            OnQualitySelected(option.value, option.text)
        end
        local isSelected
        if option.value == -1 then
            isSelected = (qualityFilter == nil)
        else
            isSelected = (qualityFilter == option.value)
        end
        info.checked = isSelected
        UIDropDownMenu_AddButton(info, level)
    end
end)
SetQualityDropDownText("All")

local function ApplyTextboxBackdrop(editBox)
    -- TBC sometimes renders InputBoxTemplate middle texture as transparent.
    -- Use an explicit backdrop so all three textboxes look identical.
    editBox:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    editBox:SetBackdropColor(0, 0, 0, 0.85)
end

ApplyTextboxBackdrop(startEdit)
ApplyTextboxBackdrop(endEdit)
ApplyTextboxBackdrop(searchEdit)

local function ClearFocus()
    startEdit:ClearFocus()
    endEdit:ClearFocus()
    searchEdit:ClearFocus()
    for _, eb in ipairs(settingsFocusEdits) do
        eb:ClearFocus()
    end
end

startEdit:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

startEdit:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
end)

startEdit:SetScript("OnEditFocusGained", function(self)
    self:HighlightText()
end)

startEdit:SetScript("OnEditFocusLost", function(self)
    self:HighlightText(0, 0)
end)

endEdit:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

endEdit:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
end)

endEdit:SetScript("OnEditFocusGained", function(self)
    self:HighlightText()
end)

endEdit:SetScript("OnEditFocusLost", function(self)
    self:HighlightText(0, 0)
end)

searchEdit:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)

searchEdit:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
end)

searchEdit:SetScript("OnEditFocusGained", function(self)
    self:HighlightText()
end)

searchEdit:SetScript("OnEditFocusLost", function(self)
    self:HighlightText(0, 0)
end)

searchEdit:SetScript("OnTextChanged", function(self)
    searchText = self:GetText() or ""
    listDirty = true
    FauxScrollFrame_SetOffset(scrollFrame, 0)
    UpdateWindow()
end)

mainWindow:SetScript("OnMouseDown", function()
    ClearFocus()
end)

-- ==================== HEADERS ====================

local headerY = -118

local headerID = mainWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
headerID:SetPoint("TOPLEFT", 20, headerY)
headerID:SetText("ID")

local headerName = mainWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
headerName:SetPoint("TOPLEFT", 100, headerY)
headerName:SetText("Item")

local headerType = mainWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
headerType:SetPoint("TOPLEFT", 470, headerY)
headerType:SetText("Type")

local headerLevel = mainWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
headerLevel:SetPoint("TOPLEFT", 610, headerY)
headerLevel:SetText("iLvl")

-- ==================== SCROLL FRAME ====================

scrollFrame = CreateFrame("ScrollFrame", "CustomItemScannerScrollFrame", mainWindow, "FauxScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", 16, -133)
scrollFrame:SetPoint("BOTTOMRIGHT", -30, 60)

-- ==================== ROWS ====================

local function CreateRow(index)
    local row = CreateFrame("Button", nil, mainWindow)
    row:SetWidth(650)
    row:SetHeight(rowHeight)
    row:SetPoint("TOPLEFT", 18, -135 - ((index - 1) * rowHeight))

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    if math.fmod(index, 2) == 0 then
        row.bg:SetTexture(1, 1, 1, 0.04)
    else
        row.bg:SetTexture(0, 0, 0, 0)
    end

    row.idText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.idText:SetPoint("LEFT", 4, 0)
    row.idText:SetWidth(75)
    row.idText:SetJustifyH("LEFT")

    row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.nameText:SetPoint("LEFT", 85, 0)
    row.nameText:SetWidth(370)
    row.nameText:SetJustifyH("LEFT")

    row.typeText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.typeText:SetPoint("LEFT", 455, 0)
    row.typeText:SetWidth(130)
    row.typeText:SetJustifyH("LEFT")

    row.levelText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.levelText:SetPoint("LEFT", 595, 0)
    row.levelText:SetWidth(45)
    row.levelText:SetJustifyH("LEFT")

    row:SetScript("OnClick", function(self)
        if self.itemLink then
            DEFAULT_CHAT_FRAME:AddMessage(self.itemLink)
        elseif self.itemName then
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[CustomItemScanner]|r " .. self.itemName .. " (ID: " .. self.itemID .. ")")
        end
        ClearFocus()
    end)

    row:SetScript("OnEnter", function(self)
        if self.itemLink then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.itemLink)
            GameTooltip:Show()
        end
    end)

    row:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return row
end

for i = 1, visibleRows do
    rows[i] = CreateRow(i)
end

-- ==================== UPDATE WINDOW ====================

UpdateWindow = function()
    BuildSortedList()

    local totalItems = #sortedItemIDs
    local offset = FauxScrollFrame_GetOffset(scrollFrame)

    FauxScrollFrame_Update(scrollFrame, totalItems, visibleRows, rowHeight)

    for i = 1, visibleRows do
        local row = rows[i]
        local index = offset + i
        local itemID = sortedItemIDs[index]

        if itemID then
            local data = CustomItemScannerDB.items[itemID]

            row.itemID = itemID
            row.itemLink = data.link
            row.itemName = data.name

            row.idText:SetText(tostring(itemID))
            row.nameText:SetText(data.link or data.name or ("item:" .. itemID))
            row.typeText:SetText(data.type or "")
            row.levelText:SetText(tostring(data.level or ""))

            row:Show()
        else
            row.itemID = nil
            row.itemLink = nil
            row.itemName = nil

            row.idText:SetText("")
            row.nameText:SetText("")
            row.typeText:SetText("")
            row.levelText:SetText("")

            row:Hide()
        end
    end

    local storedTotal = CountFound()
    totalDiscoveredText:SetText("Total discovered: " .. storedTotal)

    if searchText ~= "" or qualityFilter ~= nil then
        infoText:SetText("Listed: " .. totalItems .. " (matching filters)")
    else
        infoText:SetText("Listed: " .. totalItems)
    end

    if scanner.running and not scanner.paused then
        local mode = scanner.useServerRequests and "server" or "cache"
        statusText:SetText("Status: [" .. mode .. "] chunk " .. scanner.chunkNumber .. "/" .. scanner.totalChunks .. "  ID " .. scanner.currentID .. " / " .. scanner.chunkEnd)
    elseif not scanner.running then
        statusText:SetText("Status: Idle")
    end
end

scrollFrame:SetScript("OnVerticalScroll", function(self, offset)
    local newOffset = math.floor((offset / rowHeight) + 0.5)
    if newOffset ~= FauxScrollFrame_GetOffset(self) then
        FauxScrollFrame_SetOffset(self, newOffset)
        UpdateWindow()
    end
end)

-- ==================== BUTTONS ====================

local buttonY = 20

local refreshButton = CreateFrame("Button", nil, mainWindow, "UIPanelButtonTemplate")
refreshButton:SetWidth(90)
refreshButton:SetHeight(22)
refreshButton:SetPoint("BOTTOMLEFT", 16, buttonY)
refreshButton:SetText("Refresh")
refreshButton:SetScript("OnClick", function()
    ClearFocus()
    listDirty = true
    UpdateWindow()
end)

local clearButton = CreateFrame("Button", nil, mainWindow, "UIPanelButtonTemplate")
clearButton:SetWidth(90)
clearButton:SetHeight(22)
clearButton:SetPoint("LEFT", refreshButton, "RIGHT", 8, 0)
clearButton:SetText("Clear")
clearButton:SetScript("OnClick", function()
    CustomItemScannerDB.items = {}
    ClearFocus()
    listDirty = true
    UpdateWindow()
    Print("Saved item list cleared.")
end)

local startButton = CreateFrame("Button", nil, mainWindow, "UIPanelButtonTemplate")
startButton:SetWidth(90)
startButton:SetHeight(22)
startButton:SetPoint("LEFT", clearButton, "RIGHT", 8, 0)
startButton:SetText("Start Scan")
startButton:SetScript("OnClick", function()
    ClearFocus()

    local startID = tonumber(startEdit:GetText()) or 50000
    local endID = tonumber(endEdit:GetText()) or 1000000

    StartScan(startID, endID)
    UpdateWindow()
    Print("Scan started from " .. startID .. " to " .. endID)
end)

local stopButton = CreateFrame("Button", nil, mainWindow, "UIPanelButtonTemplate")
stopButton:SetWidth(90)
stopButton:SetHeight(22)
stopButton:SetPoint("LEFT", startButton, "RIGHT", 8, 0)
stopButton:SetText("Stop")
stopButton:SetScript("OnClick", function()
    ClearFocus()
    StopScan()
    UpdateWindow()
    Print("Scan stopped.")
end)

-- ==================== SETTINGS WINDOW ====================

settingsWindow = CreateFrame("Frame", "CustomItemScannerSettingsWindow", UIParent)
settingsWindow:SetWidth(440)
settingsWindow:SetHeight(360)
settingsWindow:SetPoint("CENTER")
settingsWindow:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true,
    tileSize = 16,
    edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 }
})
settingsWindow:SetBackdropColor(0, 0, 0, 1)
settingsWindow:EnableMouse(true)
settingsWindow:SetMovable(true)
settingsWindow:SetClampedToScreen(true)
settingsWindow:RegisterForDrag("LeftButton")
settingsWindow:SetScript("OnDragStart", function(self)
    self:StartMoving()
end)
settingsWindow:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)
settingsWindow:SetFrameStrata("DIALOG")
settingsWindow:Hide()

tinsert(UISpecialFrames, "CustomItemScannerSettingsWindow")

local settingsTitle = settingsWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
settingsTitle:SetPoint("TOP", 0, -14)
settingsTitle:SetText("Scanner settings")

local settingsClose = CreateFrame("Button", nil, settingsWindow, "UIPanelCloseButton")
settingsClose:SetPoint("TOPRIGHT", -5, -5)
settingsClose:SetScript("OnClick", function()
    ClearFocus()
    RefreshSettingsFields()
    settingsWindow:Hide()
end)

local function MakeSettingsRow(parent, y, labelText, editWidth)
    local lab = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lab:SetPoint("TOPLEFT", 24, y)
    lab:SetText(labelText)
    local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    eb:SetPoint("TOPLEFT", 220, y + 2)
    eb:SetWidth(editWidth or 90)
    eb:SetHeight(20)
    eb:SetAutoFocus(false)
    ApplyTextboxBackdrop(eb)
    tinsert(settingsFocusEdits, eb)
    eb:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    eb:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    return eb
end

local settingsBatchEdit = MakeSettingsRow(settingsWindow, -52, "IDs per tick (batch):", 70)
settingsBatchEdit:SetNumeric(true)

local settingsDelayEdit = MakeSettingsRow(settingsWindow, -52 - 28, "Seconds between ticks:", 70)

local settingsChunkEdit = MakeSettingsRow(settingsWindow, -52 - 56, "Chunk size (IDs per pause):", 70)
settingsChunkEdit:SetNumeric(true)

local settingsCooldownEdit = MakeSettingsRow(settingsWindow, -52 - 84, "Chunk cooldown (seconds):", 70)

local settingsMaxSrvEdit = MakeSettingsRow(settingsWindow, -52 - 112, "Max server requests per tick:", 70)
settingsMaxSrvEdit:SetNumeric(true)

local settingsServerCheck = CreateFrame("CheckButton", nil, settingsWindow, "UICheckButtonTemplate")
settingsServerCheck:SetPoint("TOPLEFT", 24, -52 - 140)
local srvLabel = settingsWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
srvLabel:SetPoint("LEFT", settingsServerCheck, "RIGHT", 4, 0)
srvLabel:SetText("Server request assist (hyperlink)")

local settingsHelp = settingsWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
settingsHelp:SetPoint("TOPLEFT", 24, -52 - 175)
settingsHelp:SetWidth(392)
settingsHelp:SetJustifyH("LEFT")
settingsHelp:SetText("Lower batch size and delay for stability. Disable server assist for very large scans. Chunking splits long ranges with pauses.")

RefreshSettingsFields = function()
    if not CustomItemScannerDB.settings then
        CustomItemScannerDB.settings = {}
    end
    local s = CustomItemScannerDB.settings
    for k, v in pairs(SETTINGS_DEFAULTS) do
        if s[k] == nil then
            s[k] = v
        end
    end
    settingsBatchEdit:SetText(tostring(s.batchSize))
    settingsDelayEdit:SetText(tostring(s.delay))
    settingsChunkEdit:SetText(tostring(s.chunkSize))
    settingsCooldownEdit:SetText(tostring(s.chunkCooldown))
    settingsMaxSrvEdit:SetText(tostring(s.maxServerRequestsPerTick))
    settingsServerCheck:SetChecked(s.useServerRequests)
end

local function SaveSettingsFromFields()
    if not CustomItemScannerDB.settings then
        CustomItemScannerDB.settings = {}
    end
    local s = CustomItemScannerDB.settings
    s.batchSize = tonumber(settingsBatchEdit:GetText()) or SETTINGS_DEFAULTS.batchSize
    s.delay = tonumber(settingsDelayEdit:GetText()) or SETTINGS_DEFAULTS.delay
    s.chunkSize = tonumber(settingsChunkEdit:GetText()) or SETTINGS_DEFAULTS.chunkSize
    s.chunkCooldown = tonumber(settingsCooldownEdit:GetText()) or SETTINGS_DEFAULTS.chunkCooldown
    s.maxServerRequestsPerTick = tonumber(settingsMaxSrvEdit:GetText()) or SETTINGS_DEFAULTS.maxServerRequestsPerTick
    local chk = settingsServerCheck:GetChecked()
    s.useServerRequests = (chk == true or chk == 1)
    ApplySettingsToScanner()
    Print("Scanner settings saved.")
end

local function ResetSettingsToDefaults()
    for k, v in pairs(SETTINGS_DEFAULTS) do
        CustomItemScannerDB.settings[k] = v
    end
    ApplySettingsToScanner()
    RefreshSettingsFields()
    Print("Settings reset to defaults.")
end

local settingsOk = CreateFrame("Button", nil, settingsWindow, "UIPanelButtonTemplate")
settingsOk:SetWidth(100)
settingsOk:SetHeight(24)
settingsOk:SetPoint("BOTTOMRIGHT", -24, 24)
settingsOk:SetText("OK")
settingsOk:SetScript("OnClick", function()
    ClearFocus()
    SaveSettingsFromFields()
    settingsWindow:Hide()
    if UpdateWindow then
        UpdateWindow()
    end
end)

local settingsCancel = CreateFrame("Button", nil, settingsWindow, "UIPanelButtonTemplate")
settingsCancel:SetWidth(100)
settingsCancel:SetHeight(24)
settingsCancel:SetPoint("RIGHT", settingsOk, "LEFT", -10, 0)
settingsCancel:SetText("Cancel")
settingsCancel:SetScript("OnClick", function()
    ClearFocus()
    RefreshSettingsFields()
    settingsWindow:Hide()
end)

local settingsDefaultsBtn = CreateFrame("Button", nil, settingsWindow, "UIPanelButtonTemplate")
settingsDefaultsBtn:SetWidth(100)
settingsDefaultsBtn:SetHeight(24)
settingsDefaultsBtn:SetPoint("BOTTOMLEFT", 24, 24)
settingsDefaultsBtn:SetText("Defaults")
settingsDefaultsBtn:SetScript("OnClick", function()
    ClearFocus()
    ResetSettingsToDefaults()
end)

local settingsButton = CreateFrame("Button", nil, mainWindow, "UIPanelButtonTemplate")
settingsButton:SetWidth(100)
settingsButton:SetHeight(22)
settingsButton:SetPoint("BOTTOMRIGHT", mainWindow, "BOTTOMRIGHT", -16, 20)
settingsButton:SetText("Settings")
settingsButton:SetScript("OnClick", function()
    ClearFocus()
    RefreshSettingsFields()
    settingsWindow:Show()
end)

-- ==================== MINIMAP BUTTON ====================

local function SetMinimapButtonPosition(button, angle)
    local radians = math.rad(angle)
    local radius = 80
    local x = math.cos(radians) * radius
    local y = math.sin(radians) * radius
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local minimapButton = CreateFrame("Button", "CustomItemScannerMinimapButton", Minimap)
minimapButton:SetWidth(31)
minimapButton:SetHeight(31)
minimapButton:SetFrameStrata("MEDIUM")
minimapButton:SetFrameLevel(8)
minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
minimapButton:RegisterForClicks("LeftButtonUp")
minimapButton:RegisterForDrag("LeftButton")

local miniBG = minimapButton:CreateTexture(nil, "BACKGROUND")
miniBG:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
miniBG:SetWidth(20)
miniBG:SetHeight(20)
miniBG:SetPoint("TOPLEFT", 7, -5)

local miniIcon = minimapButton:CreateTexture(nil, "ARTWORK")
miniIcon:SetWidth(20)
miniIcon:SetHeight(20)
miniIcon:SetPoint("TOPLEFT", 7, -5)
miniIcon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_20")
miniIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local miniBorder = minimapButton:CreateTexture(nil, "OVERLAY")
miniBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
miniBorder:SetWidth(53)
miniBorder:SetHeight(53)
miniBorder:SetPoint("TOPLEFT")

SetMinimapButtonPosition(minimapButton, CustomItemScannerDB.minimapAngle)

minimapButton:SetScript("OnDragStart", function(self)
    self.isDragging = true
    self:SetScript("OnUpdate", function(btn)
        local mx, my = Minimap:GetCenter()
        local cx, cy = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        cx = cx / scale
        cy = cy / scale

        local angle = math.deg(math.atan2(cy - my, cx - mx))
        if angle < 0 then
            angle = angle + 360
        end

        CustomItemScannerDB.minimapAngle = angle
        SetMinimapButtonPosition(btn, angle)
    end)
end)

minimapButton:SetScript("OnDragStop", function(self)
    self.isDragging = nil
    self:SetScript("OnUpdate", nil)
end)

minimapButton:SetScript("OnClick", function()
    ClearFocus()

    if mainWindow:IsShown() then
        mainWindow:Hide()
    else
        mainWindow:Show()
        UpdateWindow()
    end
end)

minimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Custom Item Scanner")
    GameTooltip:AddLine("|cff00ff00Left-click|r to toggle window", 1, 1, 1)
    GameTooltip:AddLine("|cff00ff00Left-drag|r to move icon", 1, 1, 1)
    GameTooltip:Show()
end)

minimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

-- ==================== SCANNING LOOP ====================

frame:SetScript("OnUpdate", function(self, elapsed)
    if not scanner.running then
        return
    end

    if scanner.paused then
        scanner.chunkTimer = scanner.chunkTimer + elapsed
        if scanner.chunkTimer < scanner.chunkCooldown then
            if mainWindow:IsShown() then
                local remaining = math.ceil(scanner.chunkCooldown - scanner.chunkTimer)
                statusText:SetText("Status: Cooldown " .. remaining .. "s before chunk " .. (scanner.chunkNumber + 1) .. "/" .. scanner.totalChunks)
            end
            return
        end
        StartNextChunk()
    end

    scanner.elapsed = scanner.elapsed + elapsed
    if scanner.elapsed < scanner.delay then
        return
    end
    scanner.elapsed = 0
    scanner.serverRequestsThisTick = 0

    local processed = 0

    while processed < scanner.batchSize and scanner.currentID <= scanner.maxID do
        ScanOneItem(scanner.currentID)
        scanner.currentID = scanner.currentID + 1
        processed = processed + 1
    end

    if mainWindow:IsShown() then
        UpdateWindow()
    end

    if scanner.currentID > scanner.maxID then
        if scanner.chunkEnd < scanner.endID then
            scanner.paused = true
            scanner.chunkTimer = 0
            Print("Chunk " .. scanner.chunkNumber .. "/" .. scanner.totalChunks .. " done. Cooling down " .. scanner.chunkCooldown .. "s...")
        else
            scanner.running = false
            UpdateWindow()
            Print("Scan finished. Found " .. CountFound() .. " items.")
        end
    end
end)

-- ==================== SLASH COMMANDS ====================

SLASH_CUSTOMITEMSCANNER1 = "/cis"
SlashCmdList["CUSTOMITEMSCANNER"] = function(msg)
    local cmd, arg1, arg2 = strsplit(" ", msg)
    cmd = strlower(cmd or "")

    if cmd == "start" then
        local s = tonumber(arg1) or 50000
        local e = tonumber(arg2) or 1000000

        StartScan(s, e)
        UpdateWindow()
        Print("Scan started from " .. s .. " to " .. e)

    elseif cmd == "stop" then
        StopScan()
        UpdateWindow()
        Print("Scan stopped.")

    elseif cmd == "show" then
        mainWindow:Show()
        UpdateWindow()

    elseif cmd == "hide" then
        mainWindow:Hide()

    elseif cmd == "toggle" then
        if mainWindow:IsShown() then
            mainWindow:Hide()
        else
            mainWindow:Show()
            UpdateWindow()
        end

    elseif cmd == "refresh" then
        listDirty = true
        UpdateWindow()

    elseif cmd == "clear" then
        CustomItemScannerDB.items = {}
        listDirty = true
        UpdateWindow()
        Print("Saved item list cleared.")

    elseif cmd == "count" then
        Print("Found items: " .. CountFound())

    elseif cmd == "settings" then
        ClearFocus()
        RefreshSettingsFields()
        settingsWindow:Show()

    elseif cmd == "server" then
        if not CustomItemScannerDB.settings then
            CustomItemScannerDB.settings = {}
        end
        local mode = strlower(arg1 or "")
        if mode == "on" then
            scanner.useServerRequests = true
            CustomItemScannerDB.settings.useServerRequests = true
            Print("Server request mode enabled. Use smaller ranges to avoid client instability.")
        elseif mode == "off" then
            scanner.useServerRequests = false
            CustomItemScannerDB.settings.useServerRequests = false
            Print("Server request mode disabled (cache-only mode).")
        else
            Print("Server mode is currently: " .. (scanner.useServerRequests and "ON" or "OFF"))
            Print("Usage: /cis server on | off")
        end

    else
        Print("Commands: /cis show | hide | settings | toggle | start [from] [to] | stop | refresh | clear | count | server on|off")
    end
end

Print("CustomItemScanner loaded. Click the minimap icon or type /cis show")
