param(
    [string]$IgnoredCsv = ""
)

$ErrorActionPreference = "Stop"

$RegistryPath = "HKCU:\Software\TronMCP\TopProcesses"
$SampleMilliseconds = 1000
$TopCount = 7

function Set-RegistryString {
    param([string]$Name, [string]$Value)
    New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType String -Force | Out-Null
}

function Set-RegistryDWord {
    param([string]$Name, [int]$Value)
    New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

function Set-RegistryQWord {
    param([string]$Name, [long]$Value)
    New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType QWord -Force | Out-Null
}

$mutex = New-Object System.Threading.Mutex($false, "Local\TronMCP_TopProcesses")
$hasMutex = $false

try {
    $hasMutex = $mutex.WaitOne(0)
    if (-not $hasMutex) {
        # Previous sampling pass is still running. Keep the current registry values.
        exit 0
    }

    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        New-Item -Path $RegistryPath | Out-Null
    }

    $ignored = @{}
    if (-not [string]::IsNullOrWhiteSpace($IgnoredCsv)) {
        foreach ($item in ($IgnoredCsv -split ',')) {
            $name = $item.Trim()
            if ($name) {
                $ignored[$name.ToLowerInvariant()] = $true
                if ($name.EndsWith(".exe", [StringComparison]::OrdinalIgnoreCase)) {
                    $ignored[$name.Substring(0, $name.Length - 4).ToLowerInvariant()] = $true
                }
            }
        }
    }

    # Ignore the sampler itself by default.
    $ignored["powershell"] = $true
    $ignored["powershell.exe"] = $true
    $ignored["pwsh"] = $true
    $ignored["pwsh.exe"] = $true

    $logicalProcessors = [Environment]::ProcessorCount
    if ($logicalProcessors -lt 1) { $logicalProcessors = 1 }

    $first = @{}
    foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $first[$process.Id] = [double]$process.CPU
        } catch {}
    }

    $startTime = [DateTime]::UtcNow
    Start-Sleep -Milliseconds $SampleMilliseconds
    $elapsedSeconds = ([DateTime]::UtcNow - $startTime).TotalSeconds
    if ($elapsedSeconds -le 0) { $elapsedSeconds = $SampleMilliseconds / 1000.0 }

    $cpuRows = foreach ($process in (Get-Process -ErrorAction SilentlyContinue)) {
        try {
            if (-not $first.ContainsKey($process.Id)) { continue }

            $name = [string]$process.ProcessName
            if ($ignored.ContainsKey($name.ToLowerInvariant())) { continue }

            $deltaCpu = [double]$process.CPU - [double]$first[$process.Id]
            if ($deltaCpu -lt 0) { continue }

            # Windows CPU percentage normalized to 0..100 across all logical processors.
            $percent = ($deltaCpu / $elapsedSeconds / $logicalProcessors) * 100.0
            if ($percent -lt 0) { $percent = 0 }
            if ($percent -gt 100) { $percent = 100 }

            [pscustomobject]@{
                Name = $name + ".exe"
                CpuPercent = $percent
            }
        } catch {}
    }

    # Combine multiple instances with the same executable name.
    $cpuTop = $cpuRows |
        Group-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                CpuPercent = ($_.Group | Measure-Object CpuPercent -Sum).Sum
            }
        } |
        Sort-Object CpuPercent -Descending |
        Select-Object -First $TopCount

    $ramTop = Get-Process -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $name = [string]$_.ProcessName
                if ($ignored.ContainsKey($name.ToLowerInvariant())) { return }

                [pscustomobject]@{
                    Name = $name + ".exe"
                    Bytes = [long]$_.WorkingSet64
                }
            } catch {}
        } |
        Group-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Name = $_.Name
                Bytes = [long](($_.Group | Measure-Object Bytes -Sum).Sum)
            }
        } |
        Sort-Object Bytes -Descending |
        Select-Object -First $TopCount

    # Build the complete new snapshot in memory first.
    $snapshot = @{}

    for ($i = 1; $i -le $TopCount; $i++) {
        if ($i -le @($cpuTop).Count) {
            $cpu = @($cpuTop)[$i - 1]
            $snapshot["CPUName$i"] = [string]$cpu.Name
            $snapshot["CPUValue$i"] = [int][Math]::Round(
                [Math]::Min(100.0, [double]$cpu.CpuPercent) * 100.0
            )
        }

        if ($i -le @($ramTop).Count) {
            $ram = @($ramTop)[$i - 1]
            $snapshot["RAMName$i"] = [string]$ram.Name
            $snapshot["RAMValue$i"] = [long]$ram.Bytes
        }
    }

    # Commit only valid new values. Old values remain visible until replaced.
    # Missing rows are intentionally not overwritten with empty strings or zeros.
    for ($i = 1; $i -le $TopCount; $i++) {
        if ($snapshot.ContainsKey("CPUName$i")) {
            Set-RegistryString "CPUName$i" $snapshot["CPUName$i"]
            Set-RegistryDWord "CPUValue$i" $snapshot["CPUValue$i"]
        }

        if ($snapshot.ContainsKey("RAMName$i")) {
            Set-RegistryString "RAMName$i" $snapshot["RAMName$i"]
            Set-RegistryQWord "RAMValue$i" $snapshot["RAMValue$i"]
        }
    }

    Set-RegistryString "LastUpdate" ([DateTime]::Now.ToString("s"))
    Remove-ItemProperty -Path $RegistryPath -Name "LastError" -ErrorAction SilentlyContinue
}
catch {
    if (-not (Test-Path -LiteralPath $RegistryPath)) {
        New-Item -Path $RegistryPath | Out-Null
    }
    Set-RegistryString "LastError" $_.Exception.ToString()
    throw
}
finally {
    if ($hasMutex) {
        $mutex.ReleaseMutex() | Out-Null
    }
    $mutex.Dispose()
}
