local index = 1
local initialized = false

local function getCount()
    local measure = SKIN:GetMeasure('MeasureAlertCount')
    if not measure then
        return 0
    end

    local count = math.floor(tonumber(measure:GetStringValue()) or 0)
    if count < 0 then count = 0 end
    return count
end

local function applyIndex()
    local count = getCount()

    if count <= 0 then
        index = 1
    elseif index > count then
        index = 1
    elseif index < 1 then
        index = count
    end

    SKIN:Bang('!SetVariable', 'AlertIndex', tostring(index))
    SKIN:Bang('!UpdateMeasureGroup', 'AlertDynamicMeasures')
    SKIN:Bang('!UpdateMeterGroup', 'AlertMeters')
    SKIN:Bang('!Redraw')
end

function Initialize()
    index = tonumber(SKIN:GetVariable('AlertIndex', '1')) or 1
    applyIndex()
    initialized = true
end

function Update()
    local count = getCount()

    if count > 1 then
        if initialized then
            index = index + 1
        end
        applyIndex()
    elseif count == 1 then
        index = 1
        applyIndex()
    end

    initialized = true
    return index
end

function Next()
    local count = getCount()
    if count <= 0 then return end

    index = index + 1
    if index > count then index = 1 end
    applyIndex()
end

function Previous()
    local count = getCount()
    if count <= 0 then return end

    index = index - 1
    if index < 1 then index = count end
    applyIndex()
end
