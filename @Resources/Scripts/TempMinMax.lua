local sourceMeasure
local minMeter
local maxMeter
local decimals
local suffix
local minValue
local maxValue

function Initialize()
    local sourceName = SELF:GetOption('SourceMeasure', '')
    minMeter = SELF:GetOption('MinMeter', '')
    maxMeter = SELF:GetOption('MaxMeter', '')
    decimals = tonumber(SELF:GetOption('Decimals', '1')) or 1

    local useDegree = tonumber(SELF:GetOption('DegreeSymbol', '0')) or 0
    suffix = SELF:GetOption('Suffix', '')

    -- Vyhneme sa problému s UTF-8 znakom ° v Lua súbore.
    if useDegree == 1 then
        suffix = string.char(176) .. suffix
    end

    sourceMeasure = SKIN:GetMeasure(sourceName)

    if sourceMeasure == nil then
        SKIN:Bang(
            '!Log',
            'MinMaxTracker: measure "' .. sourceName .. '" neexistuje.',
            'Error'
        )
    end
end

local function ReadNumber()
    if sourceMeasure == nil then
        return nil
    end

    -- Registry measure môže vracať desatinnú čiarku.
    local raw = sourceMeasure:GetStringValue()

    if raw == nil or raw == '' then
        return nil
    end

    raw = raw:gsub(',', '.')
    raw = raw:gsub('[^%d%.%-]', '')

    return tonumber(raw)
end

local function FormatValue(value)
    return string.format('%.' .. decimals .. 'f%s', value, suffix)
end

function Update()
    local value = ReadNumber()

    if value == nil or value <= 0 then
        return 0
    end

    if minValue == nil or value < minValue then
        minValue = value
    end

    if maxValue == nil or value > maxValue then
        maxValue = value
    end

    if minMeter ~= '' then
        SKIN:Bang('!SetOption', minMeter, 'Text', FormatValue(minValue))
        SKIN:Bang('!UpdateMeter', minMeter)
    end

    if maxMeter ~= '' then
        SKIN:Bang('!SetOption', maxMeter, 'Text', FormatValue(maxValue))
        SKIN:Bang('!UpdateMeter', maxMeter)
    end

    SKIN:Bang('!Redraw')

    return value
end