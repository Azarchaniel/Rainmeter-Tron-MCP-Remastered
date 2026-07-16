param(
    [Parameter(Mandatory=$true)][string]$ApiKey,
    [Parameter(Mandatory=$true)][string]$Location,
    [string]$Language = 'sk',
    [ValidateRange(1,14)][int]$ForecastDays = 5,
    [ValidateRange(1,20)][int]$MaxAlerts = 10
)

$ErrorActionPreference = 'Stop'
$RegistryPath = 'HKCU:\Software\TronMCP\WeatherAstro2'
$mutex = New-Object System.Threading.Mutex($false, 'Local\TronMCP_WeatherAstro2_Backend')
$hasMutex = $false


function Invoke-Utf8JsonRequest {
    param(
        [Parameter(Mandatory=$true)][string]$Uri,
        [int]$TimeoutSec = 25,
        [hashtable]$Headers = @{}
    )

    # Windows PowerShell 5.1 may decode application/json using an incorrect
    # legacy code page when the server does not explicitly include charset=UTF-8.
    # Download raw bytes and decode them as UTF-8 before parsing the JSON.
    $request = [System.Net.HttpWebRequest]::Create($Uri)
    $request.Method = 'GET'
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $request.Accept = 'application/json'

    foreach ($headerName in $Headers.Keys) {
        if ($headerName -ieq 'User-Agent') {
            $request.UserAgent = [string]$Headers[$headerName]
        } else {
            $request.Headers[[string]$headerName] = [string]$Headers[$headerName]
        }
    }

    $response = $null
    $stream = $null
    $memory = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        $stream = $response.GetResponseStream()
        $memory = New-Object System.IO.MemoryStream
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
        $json = (New-Object System.Text.UTF8Encoding($false,$true)).GetString($bytes)
        return $json | ConvertFrom-Json
    }
    finally {
        if ($memory) { $memory.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

function Ensure-Key {
    if (-not (Test-Path -LiteralPath $RegistryPath)) { New-Item -Path $RegistryPath | Out-Null }
}
function Set-StringValue {
    param([string]$Name, [AllowEmptyString()][string]$Value)
    New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}
function Set-DWordValue {
    param([string]$Name, [int]$Value)
    New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}
function Normalize([double]$Value,[double]$Modulo) {
    $r = $Value % $Modulo
    if ($r -lt 0) { $r += $Modulo }
    return $r
}
function Convert-To24Hour([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '--:--' }
    $d = [datetime]::MinValue
    if ([datetime]::TryParse($Text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AllowWhiteSpaces,[ref]$d)) { return $d.ToString('HH:mm') }
    return $Text
}
function Convert-ApiDateTime([string]$Text) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $d = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($Text,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AllowWhiteSpaces,[ref]$d)) { return $d.ToLocalTime().ToString('dd.MM. HH:mm') }
    return $Text
}
function Shorten-Text([string]$Text,[int]$MaxLength) {
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $clean = ($Text -replace '\s+',' ').Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    $candidate = $clean.Substring(0,$MaxLength)
    $space = $candidate.LastIndexOf(' ')
    if ($space -ge [Math]::Floor($MaxLength * 0.55)) { $candidate = $candidate.Substring(0,$space) }
    return $candidate.TrimEnd() + '...'
}
function Get-MoonData {
    $reference = [datetime]::SpecifyKind([datetime]'2000-01-06T18:14:00',[DateTimeKind]::Utc)
    $month = 29.530588853
    $age = Normalize (([datetime]::UtcNow - $reference).TotalDays) $month
    $fraction = $age / $month
    $index = [Math]::Min(29,[int][Math]::Floor($age))
    $illumination = (1.0 - [Math]::Cos(2.0 * [Math]::PI * $fraction)) / 2.0
    if ($fraction -lt 0.0339 -or $fraction -ge 0.9661) { $phase = 'Nov' }
    elseif ($fraction -lt 0.2161) { $phase = 'Dorastajúci kosák' }
    elseif ($fraction -lt 0.2839) { $phase = 'Prvá štvrť' }
    elseif ($fraction -lt 0.4661) { $phase = 'Dorastajúci Mesiac' }
    elseif ($fraction -lt 0.5339) { $phase = 'Spln' }
    elseif ($fraction -lt 0.7161) { $phase = 'Cúvajúci Mesiac' }
    elseif ($fraction -lt 0.7839) { $phase = 'Posledná štvrť' }
    else { $phase = 'Cúvajúci kosák' }

    $full = $month / 2.0
    if ($age -lt $full) { $days = $full - $age } else { $days = $month - $age + $full }
    [pscustomobject]@{ Index=$index; Phase=$phase; Illumination=[int][Math]::Round($illumination*100.0); DaysToFull=[int][Math]::Ceiling($days) }
}
function Get-TronIcon([int]$Code,[bool]$IsDay) {
    $s = if ($IsDay) { 'd' } else { 'n' }
    switch ($Code) {
        1000 { "01$s" } 1003 { "02$s" } 1006 { "03$s" } 1009 { "04$s" }
        {$_ -in 1012,1015,1018,1021,1024,1027,1030,1033,1036,1039,1042,1045,1048,1135,1147} { "50$s" }
        {$_ -in 1063,1072,1150,1153,1168,1171,1198,1201} { "09$s" }
        {$_ -in 1066,1069,1114,1117,1204,1207,1210,1213,1216,1219,1222,1225,1237,1249,1252,1255,1258,1261,1264} { "13$s" }
        1087 { "11$s" }
        {$_ -in 1180,1183,1186,1189,1192,1195,1240,1243,1246} { "10$s" }
        {$_ -in 1273,1276,1279,1282} { "11$s" }
        default { "03$s" }
    }
}

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) { exit 0 }
    Ensure-Key
    if ([string]::IsNullOrWhiteSpace($ApiKey) -or $ApiKey -eq 'PUT_NEW_KEY_HERE') { throw 'WeatherAPI key is not configured.' }

    $q = [Uri]::EscapeDataString($Location)
    $url = "https://api.weatherapi.com/v1/forecast.json?key=$ApiKey&q=$q&days=$ForecastDays&lang=$Language&alerts=yes&aqi=no"
    $data = Invoke-Utf8JsonRequest -Uri $url -TimeoutSec 25 -Headers @{ 'User-Agent'='Rainmeter TronMCP WeatherAstro2' }
    if ($null -eq $data.current -or $null -eq $data.forecast.forecastday) { throw 'Incomplete WeatherAPI response.' }

    $c = [Globalization.CultureInfo]::InvariantCulture
    $current = $data.current
    $days = @($data.forecast.forecastday)
    $today = $days[0]
    $moon = Get-MoonData
    $snapshot = @{}

    $snapshot.Location = "$($data.location.name)"
    $snapshot.Condition = [string]$current.condition.text
    $snapshot.Icon = Get-TronIcon ([int]$current.condition.code) ([bool]$current.is_day)
    $snapshot.Temp = [Math]::Round([double]$current.temp_c).ToString($c)
    $snapshot.FeelsLike = [Math]::Round([double]$current.feelslike_c).ToString($c)
    $snapshot.Min = [Math]::Round([double]$today.day.mintemp_c).ToString($c)
    $snapshot.Max = [Math]::Round([double]$today.day.maxtemp_c).ToString($c)
    $snapshot.RainChance = [Math]::Round([double]$today.day.daily_chance_of_rain).ToString($c)
    $snapshot.Precip = [Math]::Round([double]$today.day.totalprecip_mm,1).ToString('0.0',$c)
    $snapshot.Wind = [Math]::Round([double]$current.wind_kph).ToString($c)
    $snapshot.Sunrise = Convert-To24Hour ([string]$today.astro.sunrise)
    $snapshot.Sunset = Convert-To24Hour ([string]$today.astro.sunset)
    $snapshot.MoonPhase = $moon.Phase
    $snapshot.MoonIllumination = $moon.Illumination.ToString($c)
    $snapshot.DaysToFull = $moon.DaysToFull.ToString($c)
    $snapshot.LastUpdate = [datetime]::Now.ToString('HH:mm')
    $snapshot.ForecastCount = $days.Count.ToString($c)

    for ($i=1; $i -le $ForecastDays; $i++) {
        if ($i -le $days.Count) {
            $item = $days[$i-1]
            $date = [datetime]::ParseExact([string]$item.date,'yyyy-MM-dd',$c)
            $snapshot["Forecast${i}Date"] = $date.ToString('yyyy-MM-dd')
            $snapshot["Forecast${i}Day"] = $date.ToString('ddd',[Globalization.CultureInfo]::GetCultureInfo('cs-CZ'))
            $snapshot["Forecast${i}Condition"] = [string]$item.day.condition.text
            $snapshot["Forecast${i}Icon"] = Get-TronIcon ([int]$item.day.condition.code) $true
            $snapshot["Forecast${i}Min"] = [Math]::Round([double]$item.day.mintemp_c).ToString($c)
            $snapshot["Forecast${i}Max"] = [Math]::Round([double]$item.day.maxtemp_c).ToString($c)
            $snapshot["Forecast${i}RainChance"] = [Math]::Round([double]$item.day.daily_chance_of_rain).ToString($c)
            $snapshot["Forecast${i}Precip"] = [Math]::Round([double]$item.day.totalprecip_mm,1).ToString('0.0',$c)
            $snapshot["Forecast${i}Sunrise"] = Convert-To24Hour ([string]$item.astro.sunrise)
            $snapshot["Forecast${i}Sunset"] = Convert-To24Hour ([string]$item.astro.sunset)
        } else {
            foreach ($field in 'Date','Day','Condition','Icon','Min','Max','RainChance','Precip','Sunrise','Sunset') { $snapshot["Forecast${i}${field}"] = '' }
        }
    }

    $alerts = @(
        $data.alerts.alert |
            Where-Object {
                $null -ne $_ -and (
                    -not [string]::IsNullOrWhiteSpace([string]$_.headline) -or
                    -not [string]::IsNullOrWhiteSpace([string]$_.event) -or
                    -not [string]::IsNullOrWhiteSpace([string]$_.desc)
                )
            } |
            Group-Object {
                (
                    [string]$_.headline + "|" +
                    [string]$_.event + "|" +
                    [string]$_.effective + "|" +
                    [string]$_.expires
                ).ToLowerInvariant()
            } |
            ForEach-Object { $_.Group | Select-Object -First 1 }
    )
    $alertCount = [Math]::Min($alerts.Count,$MaxAlerts)
    $snapshot.AlertCount = $alertCount.ToString($c)

    for ($i=1; $i -le $MaxAlerts; $i++) {
        if ($i -le $alertCount) {
            $a = $alerts[$i-1]
            $title = [string]$a.headline
            if ([string]::IsNullOrWhiteSpace($title)) { $title = [string]$a.event }
            $body = [string]$a.desc
            if ([string]::IsNullOrWhiteSpace($body)) { $body = [string]$a.instruction }
            $snapshot["Alert${i}Title"] = Shorten-Text $title 80
            $snapshot["Alert${i}Text"] = Shorten-Text $body 350
            $snapshot["Alert${i}Event"] = [string]$a.event
            $snapshot["Alert${i}Severity"] = [string]$a.severity
            $snapshot["Alert${i}Urgency"] = [string]$a.urgency
            $snapshot["Alert${i}Areas"] = Shorten-Text ([string]$a.areas) 180
            $snapshot["Alert${i}Effective"] = Convert-ApiDateTime ([string]$a.effective)
            $snapshot["Alert${i}Expires"] = Convert-ApiDateTime ([string]$a.expires)
            $snapshot["Alert${i}Instruction"] = Shorten-Text ([string]$a.instruction) 350
        } else {
            foreach ($field in 'Title','Text','Event','Severity','Urgency','Areas','Effective','Expires','Instruction') { $snapshot["Alert${i}${field}"] = '' }
        }
    }

    if ($alertCount -gt 0) {
        $snapshot.AlertTitle = $snapshot.Alert1Title
        $snapshot.AlertText = $snapshot.Alert1Text
        $snapshot.AlertExpires = $snapshot.Alert1Expires
    } else {
        $snapshot.AlertTitle = ''
        $snapshot.AlertText = ''
        $snapshot.AlertExpires = ''
    }

    foreach ($key in $snapshot.Keys) { Set-StringValue $key ([string]$snapshot[$key]) }
    Set-DWordValue 'AlertCountNumeric' $alertCount
    Set-DWordValue 'MoonIndex' $moon.Index
    Set-DWordValue 'ForecastCountNumeric' $days.Count
    Remove-ItemProperty -Path $RegistryPath -Name 'LastError' -ErrorAction SilentlyContinue
}
catch {
    Ensure-Key
    Set-StringValue 'LastError' $_.Exception.Message
    Set-StringValue 'LastErrorTime' ([datetime]::Now.ToString('s'))
    throw
}
finally {
    if ($hasMutex) { $mutex.ReleaseMutex() | Out-Null }
    $mutex.Dispose()
}
