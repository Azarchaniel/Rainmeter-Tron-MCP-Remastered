param(
    [Parameter(Mandatory=$true)][string]$FeedsFile,
    [int]$MaxItems = 7
)

$ErrorActionPreference = "Stop"
$RegistryPath = "HKCU:\Software\TronMCP\NewsHub"

function Ensure-Key {
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        New-Item -Path $RegistryPath | Out-Null
    }
}

function Set-StringValue {
    param([string]$Name, [string]$Value)
    New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Clean-Text {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
    return [System.Net.WebUtility]::HtmlDecode(($Text -replace '\s+', ' ').Trim())
}


function Shorten-Title {
    param([string]$Text, [int]$MaxLength = 65)
    $clean = Clean-Text $Text
    if ($clean.Length -le $MaxLength) { return $clean }
    $candidate = $clean.Substring(0, $MaxLength)
    $lastSpace = $candidate.LastIndexOf(" ")
    if ($lastSpace -ge 40) { $candidate = $candidate.Substring(0, $lastSpace) }
    return $candidate.TrimEnd() + "..."
}

function Get-NodeText {
    param($Node, [string]$XPath)
    $m = $Node.SelectSingleNode($XPath)
    if ($null -eq $m) { return "" }
    return Clean-Text ([string]$m.InnerText)
}

function Get-Link {
    param($Node)
    $links = @($Node.SelectNodes("./*[local-name()='link']"))
    foreach ($m in $links) {
        if ($m.Attributes["rel"] -and $m.Attributes["rel"].Value -eq "alternate" -and $m.Attributes["href"]) {
            return [string]$m.Attributes["href"].Value
        }
    }
    foreach ($m in $links) {
        if ($m.Attributes["href"]) { return [string]$m.Attributes["href"].Value }
        if (-not [string]::IsNullOrWhiteSpace($m.InnerText)) { return $m.InnerText.Trim() }
    }
    return ""
}

function Get-DateValue {
    param($Node)
    $candidates = @(
        "./*[local-name()='pubDate']",
        "./*[local-name()='published']",
        "./*[local-name()='updated']",
        "./*[local-name()='date']"
    )
    foreach ($xpath in $candidates) {
        $value = Get-NodeText $Node $xpath
        if ($value) {
            $parsed = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($value, [ref]$parsed)) {
                return $parsed
            }
        }
    }
    return [DateTimeOffset]::MinValue
}

try {
    Ensure-Key

    if (-not (Test-Path -LiteralPath $FeedsFile)) {
        throw "Feeds file not found: $FeedsFile"
    }

    $feeds = foreach ($line in Get-Content -LiteralPath $FeedsFile -Encoding UTF8) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }

        $parts = $trimmed -split '\|', 2
        if ($parts.Count -ne 2) { continue }

        [pscustomobject]@{
            Name = $parts[0].Trim()
            Url  = $parts[1].Trim()
        }
    }

    if (@($feeds).Count -eq 0) {
        throw "Feeds.txt does not contain any valid Name|URL entries."
    }

    $allItems = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($feed in $feeds) {
        try {
            $response = Invoke-WebRequest `
                -Uri $feed.Url `
                -UseBasicParsing `
                -Headers @{ "User-Agent" = "Mozilla/5.0 Rainmeter News Hub" } `
                -TimeoutSec 20

            [xml]$xml = $response.Content

            $nodes = @($xml.SelectNodes("/*[local-name()='rss']/*[local-name()='channel']/*[local-name()='item']"))
            if ($nodes.Count -eq 0) {
                $nodes = @($xml.SelectNodes("/*[local-name()='feed']/*[local-name()='entry']"))
            }

            foreach ($node in $nodes) {
                $title = Shorten-Title (Get-NodeText $node "./*[local-name()='title']") 65
                $link = Get-Link $node
                if (-not $title -or -not $link) { continue }

                $allItems.Add([pscustomobject]@{
                    Source = $feed.Name
                    Title  = $title
                    Link   = $link
                    Date   = Get-DateValue $node
                })
            }
        }
        catch {
            $errors.Add("$($feed.Name): $($_.Exception.Message)")
        }
    }

    if ($allItems.Count -eq 0) {
        throw "No articles could be loaded. " + ($errors -join " | ")
    }

    # Remove duplicates, preferring the newest occurrence.
    $deduped = $allItems |
        Sort-Object Date -Descending |
        Group-Object { if ($_.Link) { $_.Link.ToLowerInvariant() } else { $_.Title.ToLowerInvariant() } } |
        ForEach-Object { $_.Group | Sort-Object Date -Descending | Select-Object -First 1 } |
        Sort-Object Date -Descending |
        Select-Object -First $MaxItems

    $snapshot = @{}
    $previousSource = $null
    $index = 1

    foreach ($item in $deduped) {
        # Group chronologically adjacent items from the same source:
        # only the first item in a consecutive run shows the source label.
        $sourceLabel = if ($item.Source -eq $previousSource) { " " } else { [string]$item.Source }

        $snapshot["Source$index"] = $sourceLabel
        $snapshot["Title$index"] = $item.Title
        $snapshot["Link$index"] = $item.Link

        $previousSource = $item.Source
        $index++
    }

    while ($index -le $MaxItems) {
        $snapshot["Source$index"] = " "
        $snapshot["Title$index"] = ""
        $snapshot["Link$index"] = ""
        $index++
    }

    # Atomic-style commit: write only after all feeds were downloaded and merged.
    foreach ($key in $snapshot.Keys) {
        Set-StringValue $key ([string]$snapshot[$key])
    }

    Set-StringValue "LastUpdate" ([DateTime]::Now.ToString("HH:mm"))
    Set-StringValue "Status" "NEWS HUB"

    if ($errors.Count -gt 0) {
        Set-StringValue "LastError" ($errors -join " | ")
    } else {
        Remove-ItemProperty -Path $RegistryPath -Name "LastError" -ErrorAction SilentlyContinue
    }
}
catch {
    Ensure-Key
    Set-StringValue "Status" "NEWS HUB"
    Set-StringValue "LastError" $_.Exception.Message
    throw
}
