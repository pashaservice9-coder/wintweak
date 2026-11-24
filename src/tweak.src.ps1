<#
.SYNOPSIS
    WinTweak - Windows 10/11 Tweak-Tool mit grafischer Oberfläche (WPF).
.DESCRIPTION
    Start als Einzeiler:   irm https://DEINE-URL/tweak.ps1 | iex
    Start lokal:           powershell -ExecutionPolicy Bypass -File .\tweak.ps1

    Jeder Tweak sichert vor der Änderung den Originalwert in
    %ProgramData%\WinTweak\backup.json und kann einzeln rückgängig gemacht werden.
#>

# =====================================================================
#  KONFIGURATION
# =====================================================================
# Wird benutzt, um das Skript nach "irm | iex" mit Adminrechten neu zu laden.
# Nach dem Hochladen auf GitHub hier die eigene Raw-URL eintragen.
$WinTweakUrl = https://github.com/pashaservice9-coder/wintweak.git

# Zentraler Zustand. Ein Hashtable statt vieler Variablen vermeidet Scope-Probleme
# in WPF-Event-Handlern und beim Start über "irm | iex".
$WT = @{
    Version  = '1.0.0'
    SelfTest = ($env:WINTWEAK_SELFTEST -eq '1')   # Nur für Entwicklung: baut die GUI, zeigt sie aber nicht an
}

# =====================================================================
#  START: ADMINRECHTE, STA-MODUS, WINDOWS POWERSHELL 5.1
# =====================================================================
$wtIsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$wtIsSta   = [Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA
$wtIsWinPS = $PSVersionTable.PSEdition -ne 'Core'

if (-not $WT.SelfTest -and -not ($wtIsAdmin -and $wtIsSta -and $wtIsWinPS)) {
    Write-Host 'WinTweak wird mit Administratorrechten neu gestartet ...' -ForegroundColor Cyan
    if ($PSCommandPath) {
        $wtArgs = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    } else {
        $wtArgs = "-NoProfile -ExecutionPolicy Bypass -STA -Command `"irm '$WinTweakUrl' | iex`""
    }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $wtArgs -ErrorAction Stop }
    catch { Write-Host 'Abgebrochen: WinTweak benötigt Administratorrechte.' -ForegroundColor Red }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$WT.Dir              = Join-Path $env:ProgramData 'WinTweak'
$WT.BackupFile       = Join-Path $WT.Dir 'backup.json'
$WT.LogFile          = Join-Path $env:TEMP ('WinTweak_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
$WT.Backup           = @{}
$WT.Tweaks           = New-Object System.Collections.ArrayList
$WT.Rows             = @{}
$WT.Panels           = @{}
$WT.RestartNeeded    = @{}
$WT.RestorePointDone = $false
$WT.GuidRx           = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
$WT.UltimateGuid     = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$WT.HighPerfGuid     = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$WT.OwnPlanGuid      = '5f2c3a1e-77b4-4d1a-9c3e-0a1b2c3d4e5f'   # eigener Plan "WinTweak Ultimative Leistung"
$WT.Categories       = @('Latenz & Input', 'Gaming', 'System & Dienste', 'Datenschutz', 'Netzwerk', 'Energie')
$WT.BrushConv        = New-Object Windows.Media.BrushConverter

# Native Windows-Funktionen (Timer-Auflösung lesen, Mauseinstellungen sofort übernehmen)
try {
    Add-Type -Namespace WinTweak -Name Native -ErrorAction Stop -MemberDefinition @'
[DllImport("ntdll.dll")]
public static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint CurrentResolution);
[DllImport("user32.dll", SetLastError = true)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);
'@
} catch { }   # Typ existiert bereits (zweiter Start in derselben Sitzung)

# =====================================================================
#  LOGGING
# =====================================================================
function Write-WTLog {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '[{0:HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Msg
    try { Add-Content -Path $WT.LogFile -Value $line -Encoding UTF8 } catch { }
    if ($WT.LogBox) {
        $WT.LogBox.AppendText($line + "`r`n")
        $WT.LogBox.ScrollToEnd()
    } else {
        Write-Host $line
    }
}

# Lässt WPF neu zeichnen, damit Log und Fortschrittsbalken während langer Aktionen sichtbar bleiben
function Update-WTUi {
    if ($WT.Window) { $WT.Window.Dispatcher.Invoke([Action]{ }, [Windows.Threading.DispatcherPriority]::Background) }
}

# Startet ein externes Programm (powercfg, bcdedit) und wirft bei Fehlern eine Ausnahme
function Invoke-WTNative {
    param([string]$Exe, [string[]]$ArgList)
    $out = & $Exe @ArgList 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ('{0} {1} fehlgeschlagen: {2}' -f $Exe, ($ArgList -join ' '), (($out | Out-String).Trim()))
    }
    return $out
}

# =====================================================================
#  BACKUP-SYSTEM
#  Aufbau der backup.json:  { "TweakId": [ {Kind, Key, ...Originalwert...}, ... ] }
#  Pro Schlüssel wird nur der ERSTE Originalwert gespeichert, damit mehrfaches
#  Anwenden den echten Ursprungszustand nicht überschreibt.
# =====================================================================
function Import-WTBackup {
    $WT.Backup = @{}
    if (-not (Test-Path $WT.BackupFile)) { return }
    try {
        $json = Get-Content -Path $WT.BackupFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) {
            $list = New-Object System.Collections.ArrayList
            foreach ($e in @($p.Value)) {
                $h = @{}
                foreach ($q in $e.PSObject.Properties) { $h[$q.Name] = $q.Value }
                [void]$list.Add($h)
            }
            $WT.Backup[$p.Name] = $list
        }
    } catch {
        Write-WTLog "Backup-Datei konnte nicht gelesen werden: $($_.Exception.Message)" 'WARN'
    }
}

function Save-WTBackup {
    if (-not (Test-Path $WT.Dir)) { New-Item -ItemType Directory -Path $WT.Dir -Force | Out-Null }
    $WT.Backup | ConvertTo-Json -Depth 8 | Set-Content -Path $WT.BackupFile -Encoding UTF8
}

function Add-WTBackupEntry {
    param([string]$Id, [hashtable]$Entry, [string]$Key)
    if (-not $WT.Backup.ContainsKey($Id)) { $WT.Backup[$Id] = New-Object System.Collections.ArrayList }
    foreach ($e in $WT.Backup[$Id]) { if ($e.Key -eq $Key) { return } }   # Original bereits gesichert
    $Entry.Key = $Key
    [void]$WT.Backup[$Id].Add($Entry)
    Save-WTBackup
}

# Stellt einen einzelnen gesicherten Eintrag wieder her
function Restore-WTEntry {
    param([hashtable]$e)
    switch ($e.Kind) {
        'Reg' {
            if ($e.Existed) {
                if (-not (Test-Path -LiteralPath $e.Path)) { New-Item -Path $e.Path -Force | Out-Null }
                $v = $e.Value
                if ($e.Type -eq 'Binary')      { $v = [byte[]]@($v) }
                if ($e.Type -eq 'MultiString') { $v = [string[]]@($v) }
                New-ItemProperty -LiteralPath $e.Path -Name $e.Name -Value $v -PropertyType $e.Type -Force -ErrorAction Stop | Out-Null
            } elseif (Test-Path -LiteralPath $e.Path) {
                Remove-ItemProperty -LiteralPath $e.Path -Name $e.Name -ErrorAction SilentlyContinue
            }
        }
        'Bcd' {
            if ($null -eq $e.Value -or $e.Value -eq '') { & bcdedit /deletevalue '{current}' $e.Name 2>&1 | Out-Null }
            else { Invoke-WTNative 'bcdedit' @('/set', '{current}', $e.Name, [string]$e.Value) | Out-Null }
        }
        'PowerScheme' {
            Invoke-WTNative 'powercfg' @('/setactive', $e.Guid) | Out-Null
        }
        'PowerValue' {
            Invoke-WTNative 'powercfg' @('/setacvalueindex', $e.Scheme, $e.Sub, $e.Setting, [string]$e.AC) | Out-Null
            Invoke-WTNative 'powercfg' @('/setdcvalueindex', $e.Scheme, $e.Sub, $e.Setting, [string]$e.DC) | Out-Null
            Invoke-WTNative 'powercfg' @('/setactive', (Get-WTActiveScheme)) | Out-Null
        }
        'Dns' {
            Set-DnsClientServerAddress -InterfaceAlias $e.Alias -ResetServerAddresses -ErrorAction Stop
            $list = @(("$($e.V4),$($e.V6)") -split '[,\s]+' | Where-Object { $_ })
            if ($list.Count -gt 0) { Set-DnsClientServerAddress -InterfaceAlias $e.Alias -ServerAddresses $list -ErrorAction Stop }
            Clear-DnsClientCache -ErrorAction SilentlyContinue
        }
    }
}

# Macht alle gesicherten Änderungen eines Tweaks rückgängig (in umgekehrter Reihenfolge)
function Restore-WTBackup {
    param([string]$Id)
    if (-not $WT.Backup.ContainsKey($Id) -or $WT.Backup[$Id].Count -eq 0) {
        Write-WTLog "Keine Sicherung für '$Id' vorhanden - nichts zu tun." 'WARN'
        return
    }
    $entries = @($WT.Backup[$Id])
    [array]::Reverse($entries)
    $failed = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        try { Restore-WTEntry $e }
        catch {
            Write-WTLog "Wiederherstellen fehlgeschlagen ($($e.Key)): $($_.Exception.Message)" 'ERROR'
            [void]$failed.Add($e)
        }
    }
    if ($failed.Count -gt 0) { $WT.Backup[$Id] = $failed } else { $WT.Backup.Remove($Id) }
    Save-WTBackup
}

# =====================================================================
#  HELFER: REGISTRY, BCDEDIT, POWERCFG
# =====================================================================
function Get-WTReg {
    param([string]$Path, [string]$Name)
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($k.GetValueNames() -contains $Name) {
            return $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
        }
    } catch { }
    return $null
}

# Setzt einen Registry-Wert und sichert vorher den Originalzustand
function Set-WTReg {
    param([string]$Id, [string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    $entry = @{ Kind = 'Reg'; Path = $Path; Name = $Name; Existed = $false; Value = $null; Type = $null }
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($k.GetValueNames() -contains $Name) {
            $entry.Existed = $true
            $entry.Value   = $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $entry.Type    = $k.GetValueKind($Name).ToString()
        }
    } catch { }
    Add-WTBackupEntry -Id $Id -Entry $entry -Key "Reg|$Path|$Name"
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
}

# Kurzform für einen Registry-Wert in Tweak-Definitionen
function New-RV {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord')
    @{ P = $Path; N = $Name; V = $Value; T = $Type }
}

function Get-WTBcd {
    param([string]$Name)
    $out = & bcdedit /enum '{current}' 2>$null
    foreach ($l in $out) {
        if ($l -match "^$Name\s+(\S+)") {
            $v = $Matches[1]
            if ($v -match '^(Yes|Ja)$')  { return 'Yes' }
            if ($v -match '^(No|Nein)$') { return 'No' }
            return $v
        }
    }
    return $null
}

function Set-WTBcd {
    param([string]$Id, [string]$Name, [string]$Value)
    Add-WTBackupEntry -Id $Id -Entry @{ Kind = 'Bcd'; Name = $Name; Value = (Get-WTBcd $Name) } -Key "Bcd|$Name"
    if ($Value) { Invoke-WTNative 'bcdedit' @('/set', '{current}', $Name, $Value) | Out-Null }
    else { & bcdedit /deletevalue '{current}' $Name 2>&1 | Out-Null }
}

function Get-WTActiveScheme {
    $o = (& powercfg /getactivescheme) -join ' '
    if ($o -match $WT.GuidRx) { return $Matches[0] }
    return $null
}

# Liest den AC/DC-Wert einer Energieeinstellung (die letzten zwei Hex-Werte der Ausgabe)
function Get-WTPowerValue {
    param([string]$Sub, [string]$Setting)
    $o = (& powercfg /qh SCHEME_CURRENT $Sub $Setting 2>$null) -join "`n"
    $m = [regex]::Matches($o, '0x([0-9a-fA-F]{8})')
    if ($m.Count -ge 2) {
        return @{
            AC = [Convert]::ToUInt32($m[$m.Count - 2].Groups[1].Value, 16)
            DC = [Convert]::ToUInt32($m[$m.Count - 1].Groups[1].Value, 16)
        }
    }
    return $null
}

function Set-WTPowerValue {
    param([string]$Id, [string]$Sub, [string]$Setting, [int]$Value)
    $scheme = Get-WTActiveScheme
    $cur = Get-WTPowerValue $Sub $Setting
    if ($cur) {
        Add-WTBackupEntry -Id $Id -Key "Power|$scheme|$Sub|$Setting" -Entry @{
            Kind = 'PowerValue'; Scheme = $scheme; Sub = $Sub; Setting = $Setting; AC = $cur.AC; DC = $cur.DC }
    }
    Invoke-WTNative 'powercfg' @('/setacvalueindex', $scheme, $Sub, $Setting, [string]$Value) | Out-Null
    Invoke-WTNative 'powercfg' @('/setdcvalueindex', $scheme, $Sub, $Setting, [string]$Value) | Out-Null
    Invoke-WTNative 'powercfg' @('/setactive', $scheme) | Out-Null
}

# Übernimmt die Mauseinstellungen aus der Registry sofort (ohne Abmelden)
function Sync-WTMouse {
    $p = 'HKCU:\Control Panel\Mouse'
    $arr = [int[]]@([int](Get-WTReg $p 'MouseThreshold1'), [int](Get-WTReg $p 'MouseThreshold2'), [int](Get-WTReg $p 'MouseSpeed'))
    try { [void][WinTweak.Native]::SystemParametersInfo(4, 0, $arr, 2) } catch { }   # 4 = SPI_SETMOUSE
}

function Get-WTTimerText {
    try {
        [uint32]$mn = 0; [uint32]$mx = 0; [uint32]$cu = 0
        [void][WinTweak.Native]::NtQueryTimerResolution([ref]$mn, [ref]$mx, [ref]$cu)
        return ('Aktuelle Timer-Auflösung: {0:N3} ms   (gröbste {1:N3} ms, feinste {2:N3} ms)' -f ($cu / 10000), ($mn / 10000), ($mx / 10000))
    } catch { return 'Timer-Auflösung: nicht verfügbar' }
}

function Get-WTAdapters {
    @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
}

function Get-WTServiceValues {
    param([string[]]$Names, [int]$Start)
    foreach ($n in $Names) {
        $p = "HKLM:\SYSTEM\CurrentControlSet\Services\$n"
        if (Test-Path $p) { New-RV $p 'Start' $Start }
    }
}

function Get-WTGpuMsiPaths {
    foreach ($d in @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue)) {
        "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.InstanceId)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
    }
}

# =====================================================================
#  TWEAK-DEFINITIONEN
#  Jeder Tweak: Id, Category, Name, Description, Risk, Recommended, Restart,
#               Apply/Undo/Check-Scriptblock (erhalten den Tweak als $t).
#  Ohne eigenes Undo wird automatisch die Sicherung wiederhergestellt.
# =====================================================================
function Add-WTTweak {
    param(
        [string]$Id, [string]$Category, [string]$Name, [string]$Description,
        [ValidateSet('Sicher', 'Mittel', 'Fortgeschritten')][string]$Risk = 'Sicher',
        [switch]$Recommended, [string]$Restart = '',
        [scriptblock]$Apply, [scriptblock]$Undo, [scriptblock]$Check, $Data
    )
    if (-not $Undo) { $Undo = { param($t) Restore-WTBackup $t.Id } }
    [void]$WT.Tweaks.Add(@{
        Id = $Id; Category = $Category; Name = $Name; Description = $Description; Risk = $Risk
        Recommended = [bool]$Recommended; Restart = $Restart
        Apply = $Apply; Undo = $Undo; Check = $Check; Data = $Data
    })
}

# Tweak, der nur aus Registry-Werten besteht
function Add-WTRegTweak {
    param(
        [string]$Id, [string]$Category, [string]$Name, [string]$Description,
        [string]$Risk = 'Sicher', [switch]$Recommended, [string]$Restart = '',
        [object[]]$Values, [scriptblock]$Check
    )
    if (-not $Check) {
        $Check = {
            param($t)
            if (@($t.Data).Count -eq 0) { return $false }
            foreach ($v in $t.Data) { if ("$(Get-WTReg $v.P $v.N)" -ne "$($v.V)") { return $false } }
            return $true
        }
    }
    Add-WTTweak -Id $Id -Category $Category -Name $Name -Description $Description -Risk $Risk `
        -Recommended:$Recommended -Restart $Restart -Data @($Values) -Check $Check `
        -Apply { param($t) foreach ($v in $t.Data) { Set-WTReg -Id $t.Id -Path $v.P -Name $v.N -Value $v.V -Type $v.T } }
}

# ---------------- LATENZ & INPUT ----------------
Add-WTTweak -Id 'MouseAccelOff' -Category 'Latenz & Input' -Recommended `
    -Name 'Mausbeschleunigung aus' `
    -Description 'Deaktiviert "Zeigerbeschleunigung verbessern". Gleiche Handbewegung = gleiche Zeigerstrecke. Wirkt sofort.' `
    -Data @((New-RV 'HKCU:\Control Panel\Mouse' 'MouseSpeed' '0' 'String'),
            (New-RV 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' '0' 'String'),
            (New-RV 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' '0' 'String')) `
    -Apply { param($t) foreach ($v in $t.Data) { Set-WTReg -Id $t.Id -Path $v.P -Name $v.N -Value $v.V -Type $v.T }; Sync-WTMouse } `
    -Undo  { param($t) Restore-WTBackup $t.Id; Sync-WTMouse } `
    -Check { param($t) "$(Get-WTReg 'HKCU:\Control Panel\Mouse' 'MouseSpeed')" -eq '0' }

Add-WTRegTweak -Id 'StickyKeysOff' -Category 'Latenz & Input' -Recommended -Restart 'Abmelden' `
    -Name 'Einrastfunktion / Filtertasten / Umschalttasten-Kürzel aus' `
    -Description 'Kein Popup mehr, wenn im Spiel 5x Shift gedrückt oder Shift lange gehalten wird.' `
    -Values @((New-RV 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'),
              (New-RV 'HKCU:\Control Panel\Accessibility\Keyboard Response' 'Flags' '122' 'String'),
              (New-RV 'HKCU:\Control Panel\Accessibility\ToggleKeys' 'Flags' '58' 'String'))

$wtMm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
Add-WTRegTweak -Id 'MmcssGaming' -Category 'Latenz & Input' -Risk 'Mittel' -Restart 'Neustart' `
    -Name 'MMCSS: Spiele priorisieren (SystemResponsiveness / NetworkThrottling)' `
    -Description 'Reserviert weniger CPU-Zeit für Hintergrundaufgaben und hebt die Netzwerkdrosselung auf. Effekt meist gering.' `
    -Values @((New-RV $wtMm 'SystemResponsiveness' 10),
              (New-RV $wtMm 'NetworkThrottlingIndex' -1),
              (New-RV "$wtMm\Tasks\Games" 'GPU Priority' 8),
              (New-RV "$wtMm\Tasks\Games" 'Priority' 6),
              (New-RV "$wtMm\Tasks\Games" 'Scheduling Category' 'High' 'String'),
              (New-RV "$wtMm\Tasks\Games" 'SFIO Priority' 'High' 'String'))

Add-WTTweak -Id 'DynamicTickOff' -Category 'Latenz & Input' -Risk 'Fortgeschritten' -Restart 'Neustart' `
    -Name 'Dynamic Tick deaktivieren (bcdedit)' `
    -Description 'bcdedit /set disabledynamictick yes. Kann den Stromverbrauch erhöhen; der Nutzen ist umstritten und auf vielen PCs nicht messbar.' `
    -Apply { param($t) Set-WTBcd -Id $t.Id -Name 'disabledynamictick' -Value 'yes' } `
    -Check { param($t) (Get-WTBcd 'disabledynamictick') -eq 'Yes' }

Add-WTTweak -Id 'PlatformClockDefault' -Category 'Latenz & Input' -Risk 'Fortgeschritten' -Restart 'Neustart' `
    -Name 'HPET-Erzwingung entfernen (useplatformclock löschen)' `
    -Description 'Entfernt einen alten "HPET an"-Tweak. Erzwungenes HPET erhöht auf modernen PCs meist die Latenz. Ist der Wert nicht gesetzt, ist dieser Tweak bereits aktiv.' `
    -Apply { param($t) Set-WTBcd -Id $t.Id -Name 'useplatformclock' -Value '' } `
    -Check { param($t) $null -eq (Get-WTBcd 'useplatformclock') }

$wtGpuNames = (@(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue) | ForEach-Object { $_.FriendlyName }) -join ', '
if (-not $wtGpuNames) { $wtGpuNames = 'keine erkannt' }
Add-WTTweak -Id 'GpuMsiMode' -Category 'Latenz & Input' -Risk 'Fortgeschritten' -Restart 'Neustart' `
    -Name 'MSI-Modus (Message Signaled Interrupts) für Grafikkarte' `
    -Description "Bei aktuellen NVIDIA/AMD-Treibern meist schon aktiv. Grafikkarte(n): $wtGpuNames" `
    -Apply { param($t) foreach ($p in @(Get-WTGpuMsiPaths)) { Set-WTReg -Id $t.Id -Path $p -Name 'MSISupported' -Value 1 } } `
    -Check {
        param($t)
        $paths = @(Get-WTGpuMsiPaths)
        if ($paths.Count -eq 0) { return $false }
        foreach ($p in $paths) { if ((Get-WTReg $p 'MSISupported') -ne 1) { return $false } }
        return $true
    }

# ---------------- GAMING ----------------
Add-WTRegTweak -Id 'GameDvrOff' -Category 'Gaming' -Recommended `
    -Name 'Game DVR / Hintergrundaufnahme aus' `
    -Description 'Stoppt die ständige Hintergrund-Videoaufnahme der Xbox Game Bar. Spart FPS und verhindert Ruckler.' `
    -Values @((New-RV 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0),
              (New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0),
              (New-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' 'AllowGameDVR' 0))

Add-WTRegTweak -Id 'GameModeOn' -Category 'Gaming' -Recommended `
    -Name 'Spielmodus einschalten' `
    -Description 'Windows priorisiert das laufende Spiel und verschiebt Updates/Treiberinstallationen.' `
    -Values @((New-RV 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1),
              (New-RV 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1)) `
    -Check { param($t) $v = Get-WTReg 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled'; ($null -eq $v) -or ($v -eq 1) }

Add-WTRegTweak -Id 'HagsOn' -Category 'Gaming' -Recommended -Restart 'Neustart' `
    -Name 'Hardwarebeschleunigte GPU-Planung (HAGS) einschalten' `
    -Description 'Meist etwas weniger Latenz, nötig für DLSS Frame Generation. Bei Rucklern oder Problemen wieder rückgängig machen.' `
    -Values @((New-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2))

Add-WTRegTweak -Id 'FsoOff' -Category 'Gaming' -Risk 'Mittel' `
    -Name 'Vollbildoptimierungen global aus' `
    -Description 'Erzwingt echtes exklusives Vollbild in älteren DirectX-Spielen. Bei modernen Spielen oft ohne Vorteil, besser pro Spiel testen.' `
    -Values @((New-RV 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2),
              (New-RV 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2),
              (New-RV 'HKCU:\System\GameConfigStore' 'GameDVR_HonorUserFSEBehaviorMode' 1),
              (New-RV 'HKCU:\System\GameConfigStore' 'GameDVR_DXGIHonorFSEWindowsCompatible' 1))

Add-WTRegTweak -Id 'VbsOff' -Category 'Gaming' -Risk 'Fortgeschritten' -Restart 'Neustart' `
    -Name 'Kernisolierung / Speicher-Integrität (VBS/HVCI) aus' `
    -Description 'Bringt in manchen Spielen 5-10 % FPS, SENKT ABER DIE SICHERHEIT gegen Treiber-Malware. Manche Anti-Cheats (z. B. Vanguard, FACEIT) können HVCI verlangen.' `
    -Values @((New-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 0),
              (New-RV 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 0))

# ---------------- ENERGIE ----------------
Add-WTTweak -Id 'PowerPlanUltimate' -Category 'Energie' -Recommended `
    -Name 'Energiesparplan Ultimative Leistung aktivieren' `
    -Description 'Schaltet den versteckten Plan frei und aktiviert ihn (Fallback: Höchstleistung). Die CPU taktet nicht ständig herunter. Höherer Stromverbrauch.' `
    -Apply {
        param($t)
        Add-WTBackupEntry -Id $t.Id -Entry @{ Kind = 'PowerScheme'; Guid = (Get-WTActiveScheme) } -Key 'PowerScheme'
        $list = (& powercfg /list) -join "`n"
        $target = $null
        if ($list -match $WT.UltimateGuid)    { $target = $WT.UltimateGuid }
        elseif ($list -match $WT.OwnPlanGuid) { $target = $WT.OwnPlanGuid }
        else {
            & powercfg -duplicatescheme $WT.UltimateGuid $WT.OwnPlanGuid 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $target = $WT.OwnPlanGuid
                & powercfg -changename $WT.OwnPlanGuid 'WinTweak Ultimative Leistung' 2>&1 | Out-Null
            }
        }
        if ($target) { Invoke-WTNative 'powercfg' @('/setactive', $target) | Out-Null; return }
        Write-WTLog 'Ultimative Leistung nicht verfügbar - versuche Höchstleistung.' 'WARN'
        & powercfg /setactive $WT.HighPerfGuid 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Dieses Gerät (Modern Standby) erlaubt nur den ausbalancierten Plan.' }
    } `
    -Check { param($t) @($WT.UltimateGuid, $WT.OwnPlanGuid, $WT.HighPerfGuid) -contains (Get-WTActiveScheme) }

Add-WTTweak -Id 'UsbSuspendOff' -Category 'Energie' -Recommended `
    -Name 'Selektives USB-Energiesparen aus' `
    -Description 'Verhindert, dass Windows USB-Geräte (Maus, Tastatur, Headset) schlafen legt. Gilt für den aktiven Energiesparplan.' `
    -Apply { param($t) Set-WTPowerValue -Id $t.Id -Sub '2a737441-1930-4402-8d77-b2bebba308a3' -Setting '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' -Value 0 } `
    -Check { param($t) $v = Get-WTPowerValue '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; ($null -ne $v) -and ($v.AC -eq 0) }

Add-WTTweak -Id 'PcieAspmOff' -Category 'Energie' -Risk 'Mittel' `
    -Name 'PCI-Express Verbindungszustand-Energieverwaltung aus' `
    -Description 'Grafikkarte/SSD bleiben im vollen Leistungszustand. Auf Laptops kürzere Akkulaufzeit.' `
    -Apply { param($t) Set-WTPowerValue -Id $t.Id -Sub 'SUB_PCIEXPRESS' -Setting 'ASPM' -Value 0 } `
    -Check { param($t) $v = Get-WTPowerValue 'SUB_PCIEXPRESS' 'ASPM'; ($null -ne $v) -and ($v.AC -eq 0) }

Add-WTTweak -Id 'CoreParkingOff' -Category 'Energie' -Risk 'Fortgeschritten' `
    -Name 'Core Parking deaktivieren' `
    -Description 'Alle CPU-Kerne bleiben aktiv. Bei Ryzen X3D und Intel Hybrid-CPUs (P/E-Kerne) KANN das schaden, weil Windows Kerne gezielt parkt.' `
    -Apply { param($t) Set-WTPowerValue -Id $t.Id -Sub 'SUB_PROCESSOR' -Setting 'CPMINCORES' -Value 100 } `
    -Check { param($t) $v = Get-WTPowerValue 'SUB_PROCESSOR' 'CPMINCORES'; ($null -ne $v) -and ($v.AC -eq 100) }

# ---------------- SYSTEM & DIENSTE ----------------
Add-WTRegTweak -Id 'BackgroundAppsOff' -Category 'System & Dienste' -Risk 'Mittel' -Recommended `
    -Name 'Hintergrund-Apps deaktivieren' `
    -Description 'Store-Apps laufen nicht mehr im Hintergrund. Achtung: Store-Apps wie WhatsApp oder Mail zeigen dann evtl. keine Benachrichtigungen.' `
    -Values @((New-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' 'LetAppsRunInBackground' 2),
              (New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1))

Add-WTRegTweak -Id 'ServicesManual' -Category 'System & Dienste' -Restart 'Neustart' `
    -Name 'Unnötige Dienste auf Manuell (nicht deaktiviert)' `
    -Description 'Fax, Karten-Downloader, Demo-Modus, WAP-Push, Telemetrie (DiagTrack), Medienfreigabe. Sie starten nur noch bei Bedarf.' `
    -Values @(Get-WTServiceValues -Names @('Fax', 'MapsBroker', 'RetailDemo', 'dmwappushservice', 'DiagTrack', 'WMPNetworkSvc') -Start 3)

Add-WTRegTweak -Id 'XboxServicesManual' -Category 'System & Dienste' -Risk 'Mittel' -Restart 'Neustart' `
    -Name 'Xbox-Dienste auf Manuell (optional)' `
    -Description 'Nur sinnvoll, wenn du Game Pass / Xbox-App nicht nutzt. Der Controller-Dienst bleibt unangetastet.' `
    -Values @(Get-WTServiceValues -Names @('XblAuthManager', 'XblGameSave', 'XboxNetApiSvc') -Start 3)

Add-WTRegTweak -Id 'VfxMinAnimate' -Category 'System & Dienste' -Restart 'Abmelden' `
    -Name 'Visuell: Animation beim Minimieren/Maximieren aus' -Description 'Fenster öffnen und schließen ohne Animation.' `
    -Values @((New-RV 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'))

Add-WTRegTweak -Id 'VfxTaskbarAnim' -Category 'System & Dienste' -Restart 'Abmelden' `
    -Name 'Visuell: Taskleisten-Animationen aus' -Description 'Keine Animationen in der Taskleiste.' `
    -Values @((New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0))

Add-WTRegTweak -Id 'VfxTransparency' -Category 'System & Dienste' `
    -Name 'Visuell: Transparenzeffekte aus' -Description 'Startmenü, Taskleiste und Fenster ohne Transparenz. Spart etwas GPU-Last.' `
    -Values @((New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 0))

Add-WTRegTweak -Id 'VfxMenuDelay' -Category 'System & Dienste' -Restart 'Abmelden' `
    -Name 'Visuell: Menü-Verzögerung verkürzen' -Description 'Untermenüs öffnen nach 50 ms statt 400 ms.' `
    -Values @((New-RV 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '50' 'String'))

Add-WTRegTweak -Id 'VfxAeroPeek' -Category 'System & Dienste' -Restart 'Abmelden' `
    -Name 'Visuell: Aero Peek aus' -Description 'Keine Desktop-Vorschau beim Zeigen auf die Taskleisten-Ecke.' `
    -Values @((New-RV 'HKCU:\Software\Microsoft\Windows\DWM' 'EnableAeroPeek' 0))

# ---------------- DATENSCHUTZ ----------------
Add-WTRegTweak -Id 'TelemetryMin' -Category 'Datenschutz' -Recommended `
    -Name 'Telemetrie minimieren' `
    -Description 'Diagnosedaten auf das Minimum (Home/Pro: erforderliche Daten), keine maßgeschneiderten Erlebnisse, keine Feedback-Abfragen.' `
    -Values @((New-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0),
              (New-RV 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0),
              (New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0),
              (New-RV 'HKCU:\Software\Microsoft\Siuf\Rules' 'NumberOfSIUFInPeriod' 0))

Add-WTRegTweak -Id 'AdIdOff' -Category 'Datenschutz' -Recommended `
    -Name 'Werbe-ID aus' -Description 'Apps können dich nicht mehr über die Werbe-ID wiedererkennen.' `
    -Values @((New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0),
              (New-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo' 'DisabledByGroupPolicy' 1))

$wtCdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
Add-WTRegTweak -Id 'StartSuggestionsOff' -Category 'Datenschutz' -Recommended `
    -Name 'Vorschläge und Werbung im Startmenü aus' `
    -Description 'Keine App-Vorschläge, Tipps oder automatisch installierten Werbe-Apps.' `
    -Values @((New-RV $wtCdm 'SubscribedContent-338388Enabled' 0),
              (New-RV $wtCdm 'SubscribedContent-338389Enabled' 0),
              (New-RV $wtCdm 'SubscribedContent-353694Enabled' 0),
              (New-RV $wtCdm 'SubscribedContent-353696Enabled' 0),
              (New-RV $wtCdm 'SystemPaneSuggestionsEnabled' 0),
              (New-RV $wtCdm 'SilentInstalledAppsEnabled' 0),
              (New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'Start_IrisRecommendations' 0))

Add-WTRegTweak -Id 'BingSearchOff' -Category 'Datenschutz' -Recommended -Restart 'Abmelden' `
    -Name 'Bing-Websuche im Startmenü aus' -Description 'Die Windows-Suche sucht nur noch lokal und schickt deine Eingaben nicht an Bing.' `
    -Values @((New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0),
              (New-RV 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 1))

Add-WTRegTweak -Id 'CopilotRecallOff' -Category 'Datenschutz' -Recommended -Restart 'Abmelden' `
    -Name 'Copilot und Recall aus' -Description 'Deaktiviert Windows Copilot sowie Recall (Bildschirm-Schnappschüsse auf Copilot+ PCs).' `
    -Values @((New-RV 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1),
              (New-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1),
              (New-RV 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCopilotButton' 0),
              (New-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1),
              (New-RV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'AllowRecallEnablement' 0),
              (New-RV 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1))

# ---------------- NETZWERK (ein Tweak pro aktivem Adapter) ----------------
foreach ($wtA in (Get-WTAdapters)) {
    $p = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($wtA.InterfaceGuid)"
    Add-WTRegTweak -Id "Nagle_$($wtA.InterfaceGuid)" -Category 'Netzwerk' -Restart 'Neustart' `
        -Name "Nagle-Algorithmus aus: $($wtA.Name)" `
        -Description "Adapter: $($wtA.InterfaceDescription). Sendet kleine TCP-Pakete sofort. Hilft nur in manchen (älteren) Online-Spielen, schadet aber nicht." `
        -Values @((New-RV $p 'TcpAckFrequency' 1), (New-RV $p 'TCPNoDelay' 1))
}

# =====================================================================
#  AUTOSTART (wie im Task-Manager über "StartupApproved" - voll umkehrbar)
# =====================================================================
function Get-WTStartupItems {
    $approvedBaseCU = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $approvedBaseLM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $items = @()
    $regSources = @(
        @{ Reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Appr = "$approvedBaseCU\Run";   Scope = 'Benutzer' },
        @{ Reg = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Appr = "$approvedBaseLM\Run";   Scope = 'Alle Benutzer' },
        @{ Reg = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Appr = "$approvedBaseLM\Run32"; Scope = 'Alle Benutzer, 32-Bit' }
    )
    foreach ($s in $regSources) {
        if (-not (Test-Path $s.Reg)) { continue }
        $k = Get-Item -LiteralPath $s.Reg
        foreach ($n in $k.GetValueNames()) {
            if ($n) { $items += @{ Name = $n; Command = [string]$k.GetValue($n); Appr = $s.Appr; Scope = $s.Scope } }
        }
    }
    $folderSources = @(
        @{ Dir = [Environment]::GetFolderPath('Startup');       Appr = "$approvedBaseCU\StartupFolder"; Scope = 'Autostart-Ordner' },
        @{ Dir = [Environment]::GetFolderPath('CommonStartup'); Appr = "$approvedBaseLM\StartupFolder"; Scope = 'Autostart-Ordner (alle)' }
    )
    foreach ($s in $folderSources) {
        if (-not $s.Dir -or -not (Test-Path $s.Dir)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $s.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $items += @{ Name = $f.Name; Command = $f.FullName; Appr = $s.Appr; Scope = $s.Scope }
        }
    }
    foreach ($i in $items) {
        $v = Get-WTReg $i.Appr $i.Name
        $i.Enabled = -not (($v -is [byte[]]) -and $v.Length -gt 0 -and (($v[0] -band 1) -eq 1))
    }
    return $items
}

function Set-WTStartupItem {
    param([hashtable]$Item, [bool]$Enable)
    $bytes = New-Object byte[] 12
    if ($Enable) { $bytes[0] = 2 } else { $bytes[0] = 3 }
    Set-WTReg -Id "Autostart|$($Item.Name)" -Path $Item.Appr -Name $Item.Name -Value $bytes -Type 'Binary'
}

# =====================================================================
#  DEBLOAT (nur Liste - es wird nichts automatisch entfernt)
# =====================================================================
$WT.BloatList = [ordered]@{
    'Microsoft.BingNews'                     = 'Microsoft News'
    'Microsoft.BingWeather'                  = 'Wetter'
    'Microsoft.BingSearch'                   = 'Bing-Suche'
    'Microsoft.GetHelp'                      = 'Hilfe anfordern'
    'Microsoft.Getstarted'                   = 'Tipps'
    'Microsoft.MicrosoftSolitaireCollection' = 'Solitaire Collection'
    'Microsoft.WindowsFeedbackHub'           = 'Feedback-Hub'
    'Microsoft.MicrosoftOfficeHub'           = 'Microsoft 365 (Office-Hub)'
    'Microsoft.OutlookForWindows'            = 'Outlook (neu)'
    'Microsoft.Todos'                        = 'Microsoft To Do'
    'Microsoft.PowerAutomateDesktop'         = 'Power Automate'
    'Microsoft.WindowsMaps'                  = 'Karten'
    'Microsoft.People'                       = 'Kontakte'
    'Microsoft.YourPhone'                    = 'Smartphone-Link'
    'Microsoft.ZuneVideo'                    = 'Filme & TV'
    'Microsoft.549981C3F5F10'                = 'Cortana'
    'Microsoft.Copilot'                      = 'Copilot-App'
    'Microsoft.Windows.DevHome'              = 'Dev Home'
    'Clipchamp.Clipchamp'                    = 'Clipchamp'
    'MSTeams'                                = 'Microsoft Teams'
}

# =====================================================================
#  DNS
# =====================================================================
$WT.DnsProviders = [ordered]@{
    'Automatisch (Router / DHCP)'  = @()
    'Cloudflare (1.1.1.1)'         = @('1.1.1.1', '1.0.0.1', '2606:4700:4700::1111', '2606:4700:4700::1001')
    'Google (8.8.8.8)'             = @('8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844')
    'Quad9 (9.9.9.9, mit Malware-Filter)' = @('9.9.9.9', '149.112.112.112', '2620:fe::fe', '2620:fe::9')
}

function Set-WTDns {
    param([string[]]$Servers)
    $adapters = Get-WTAdapters
    if ($adapters.Count -eq 0) { throw 'Kein aktiver Netzwerkadapter gefunden.' }
    foreach ($a in $adapters) {
        $g  = $a.InterfaceGuid
        $v4 = [string](Get-WTReg "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$g" 'NameServer')
        $v6 = [string](Get-WTReg "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$g" 'NameServer')
        Add-WTBackupEntry -Id 'DNS' -Key "Dns|$g" -Entry @{ Kind = 'Dns'; Alias = $a.Name; V4 = $v4; V6 = $v6 }
        if (@($Servers).Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
        } else {
            try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $Servers -ErrorAction Stop }
            catch {
                # z. B. IPv6 auf dem Adapter deaktiviert -> nur IPv4 setzen
                Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($Servers | Where-Object { $_ -notmatch ':' }) -ErrorAction Stop
            }
        }
        Write-WTLog "DNS gesetzt für $($a.Name)"
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

function Get-WTDnsText {
    $lines = foreach ($a in (Get-WTAdapters)) {
        $s = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses })
        '{0}: {1}' -f $a.Name, ($(if ($s.Count) { $s -join ', ' } else { '-' }))
    }
    if (-not $lines) { return 'Kein aktiver Netzwerkadapter gefunden.' }
    return 'Aktuelle DNS-Server:  ' + ($lines -join '   |   ')
}

# =====================================================================
#  WIEDERHERSTELLUNGSPUNKT
# =====================================================================
function New-WTRestorePoint {
    if ($WT.RestorePointDone) { return $true }
    Write-WTLog 'Erstelle Wiederherstellungspunkt (kann bis zu einer Minute dauern) ...'
    Update-WTUi
    $freqKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $oldFreq = Get-WTReg $freqKey 'SystemRestorePointCreationFrequency'
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        # Windows erlaubt standardmäßig nur einen Punkt pro 24 h - kurz aufheben
        New-ItemProperty -Path $freqKey -Name 'SystemRestorePointCreationFrequency' -Value 0 -PropertyType DWord -Force | Out-Null
        Checkpoint-Computer -Description ('WinTweak {0:yyyy-MM-dd HH:mm}' -f (Get-Date)) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $WT.RestorePointDone = $true
        Write-WTLog 'Wiederherstellungspunkt erstellt.'
        return $true
    } catch {
        Write-WTLog "Wiederherstellungspunkt fehlgeschlagen: $($_.Exception.Message)" 'WARN'
        $r = [Windows.MessageBox]::Show(
            "Der Wiederherstellungspunkt konnte nicht erstellt werden:`n$($_.Exception.Message)`n`nDie Originalwerte jedes Tweaks werden trotzdem gesichert. Fortfahren?",
            'WinTweak', 'YesNo', 'Warning')
        if ("$r" -eq 'Yes') { $WT.RestorePointDone = $true; return $true }
        return $false
    } finally {
        if ($null -eq $oldFreq) { Remove-ItemProperty -Path $freqKey -Name 'SystemRestorePointCreationFrequency' -ErrorAction SilentlyContinue }
        else { New-ItemProperty -Path $freqKey -Name 'SystemRestorePointCreationFrequency' -Value $oldFreq -PropertyType DWord -Force | Out-Null }
    }
}

# =====================================================================
#  GUI-HELFER
# =====================================================================
function Get-WTBrush { param([string]$Color) $WT.BrushConv.ConvertFromString($Color) }

function New-WTText {
    param([string]$Text, [double]$Size = 13, [string]$Color = '#E6E6E6', [switch]$Bold)
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.Foreground = Get-WTBrush $Color
    $tb.TextWrapping = 'Wrap'
    if ($Bold) { $tb.FontWeight = [Windows.FontWeights]::SemiBold }
    return $tb
}

function New-WTHeading {
    param([string]$Text)
    $h = New-WTText $Text 17 '#FFFFFF' -Bold
    $h.Margin = [Windows.Thickness]::new(0, 18, 0, 6)
    return $h
}

function New-WTButton {
    param([string]$Text, [switch]$Primary)
    $b = New-Object Windows.Controls.Button
    $b.Content = $Text
    $b.Margin = [Windows.Thickness]::new(0, 6, 8, 0)
    if ($Primary) { $b.Style = $WT.Window.FindResource('Primary') }
    return $b
}

function New-WTBadge {
    param([string]$Text, [string]$Bg, [string]$Fg)
    $b = New-Object Windows.Controls.Border
    $b.Background = Get-WTBrush $Bg
    $b.CornerRadius = [Windows.CornerRadius]::new(4)
    $b.Padding = [Windows.Thickness]::new(7, 2, 7, 2)
    $b.Margin = [Windows.Thickness]::new(6, 0, 0, 0)
    $b.VerticalAlignment = 'Center'
    $tb = New-WTText $Text 11 $Fg
    $tb.TextWrapping = 'NoWrap'
    $b.Child = $tb
    return $b
}

# Eine Zeile pro Tweak: Checkbox (Name + Beschreibung) | Badges | Zustand
function New-WTRow {
    param([hashtable]$t)
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = Get-WTBrush '#2F3440'
    $border.BorderThickness = [Windows.Thickness]::new(0, 0, 0, 1)
    $border.Padding = [Windows.Thickness]::new(4, 9, 4, 9)

    $grid = New-Object Windows.Controls.Grid
    $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = [Windows.GridLength]::Auto
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = [Windows.GridLength]::new(115)
    $grid.ColumnDefinitions.Add($c0); $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)

    $cb = New-Object Windows.Controls.CheckBox
    $cb.VerticalContentAlignment = 'Top'
    $content = New-Object Windows.Controls.StackPanel
    [void]$content.Children.Add((New-WTText $t.Name 14 '#F3F4F6' -Bold))
    $desc = $t.Description
    if ($t.Restart) { $desc += "  ($($t.Restart) nötig)" }
    $d = New-WTText $desc 12 '#9CA3AF'
    $d.Margin = [Windows.Thickness]::new(0, 2, 12, 0)
    [void]$content.Children.Add($d)
    $cb.Content = $content
    $cb.ToolTip = $t.Description
    [Windows.Controls.Grid]::SetColumn($cb, 0)
    [void]$grid.Children.Add($cb)

    $badges = New-Object Windows.Controls.StackPanel
    $badges.Orientation = 'Horizontal'
    $badges.VerticalAlignment = 'Center'
    if ($t.Recommended) { [void]$badges.Children.Add((New-WTBadge 'Empfohlen' '#1E3A8A' '#BFDBFE')) }
    switch ($t.Risk) {
        'Sicher'          { [void]$badges.Children.Add((New-WTBadge 'Sicher' '#14532D' '#86EFAC')) }
        'Mittel'          { [void]$badges.Children.Add((New-WTBadge 'Mittel' '#713F12' '#FDE68A')) }
        'Fortgeschritten' { [void]$badges.Children.Add((New-WTBadge 'Fortgeschritten' '#7F1D1D' '#FCA5A5')) }
    }
    [Windows.Controls.Grid]::SetColumn($badges, 1)
    [void]$grid.Children.Add($badges)

    $status = New-WTText '...' 12 '#8A8F9C'
    $status.VerticalAlignment = 'Center'
    $status.TextAlignment = 'Right'
    [Windows.Controls.Grid]::SetColumn($status, 2)
    [void]$grid.Children.Add($status)

    $border.Child = $grid
    $WT.Rows[$t.Id] = @{ Tweak = $t; CheckBox = $cb; Status = $status }
    return $border
}

# Liest für jeden Tweak den aktuellen Zustand aus
function Update-WTStatus {
    foreach ($r in $WT.Rows.Values) {
        $state = $null
        try { $state = [bool](& $r.Tweak.Check $r.Tweak) } catch { $state = $null }
        if ($state -eq $true) {
            $r.Status.Text = [string][char]0x25CF + ' Aktiv'; $r.Status.Foreground = Get-WTBrush '#4ADE80'
        } elseif ($state -eq $false) {
            $r.Status.Text = [string][char]0x25CB + ' Nicht aktiv'; $r.Status.Foreground = Get-WTBrush '#8A8F9C'
        } else {
            $r.Status.Text = '? Unbekannt'; $r.Status.Foreground = Get-WTBrush '#FBBF24'
        }
        Update-WTUi
    }
}

function Set-WTBusy {
    param([bool]$Busy)
    foreach ($b in $WT.Buttons) { $b.IsEnabled = -not $Busy }
    if ($Busy) { $WT.Window.Cursor = [Windows.Input.Cursors]::Wait } else { $WT.Window.Cursor = $null }
}

function Show-WTRestartHint {
    if ($WT.RestartNeeded['Neustart']) {
        [void][Windows.MessageBox]::Show('Einige Änderungen werden erst nach einem NEUSTART des PCs wirksam.', 'WinTweak - Neustart nötig', 'OK', 'Information')
    } elseif ($WT.RestartNeeded['Abmelden']) {
        [void][Windows.MessageBox]::Show('Einige Änderungen werden erst nach dem Abmelden und erneuten Anmelden wirksam.', 'WinTweak - Abmelden nötig', 'OK', 'Information')
    }
    $WT.RestartNeeded = @{}
}

function Get-WTSelected {
    @($WT.Tweaks | Where-Object { $WT.Rows[$_.Id].CheckBox.IsChecked -eq $true })
}

# Wendet die ausgewählten Tweaks an oder macht sie rückgängig
function Invoke-WTSelected {
    param([ValidateSet('Apply', 'Undo')][string]$Mode)
    $sel = Get-WTSelected
    if ($sel.Count -eq 0) { [void][Windows.MessageBox]::Show('Bitte zuerst mindestens einen Tweak auswählen.', 'WinTweak'); return }

    if ($Mode -eq 'Apply') {
        $adv = @($sel | Where-Object { $_.Risk -eq 'Fortgeschritten' })
        if ($adv.Count -gt 0) {
            $txt = "Folgende Tweaks sind als FORTGESCHRITTEN markiert:`n`n" +
                   (($adv | ForEach-Object { '- ' + $_.Name }) -join "`n") +
                   "`n`nSie können Nebenwirkungen haben (Sicherheit, Stabilität, Akkulaufzeit). Trotzdem anwenden?"
            $r = [Windows.MessageBox]::Show($txt, 'WinTweak - Warnung', 'YesNo', 'Warning')
            if ("$r" -ne 'Yes') { Write-WTLog 'Abgebrochen.'; return }
        }
    } else {
        $r = [Windows.MessageBox]::Show("$($sel.Count) Tweak(s) rückgängig machen?", 'WinTweak', 'YesNo', 'Question')
        if ("$r" -ne 'Yes') { return }
    }

    Set-WTBusy $true
    try {
        if ($Mode -eq 'Apply' -and -not (New-WTRestorePoint)) { Write-WTLog 'Abgebrochen.'; return }
        $WT.Progress.Maximum = $sel.Count
        $WT.Progress.Value = 0
        $i = 0; $ok = 0; $err = 0
        foreach ($t in $sel) {
            $i++
            try {
                if ($Mode -eq 'Apply') { Write-WTLog "Wende an: $($t.Name)"; & $t.Apply $t | Out-Null }
                else { Write-WTLog "Rückgängig: $($t.Name)"; & $t.Undo $t | Out-Null }
                if ($t.Restart) { $WT.RestartNeeded[$t.Restart] = $true }
                $ok++
            } catch {
                $err++
                Write-WTLog "Fehler bei '$($t.Name)': $($_.Exception.Message)" 'ERROR'
            }
            $WT.Progress.Value = $i
            Update-WTUi
        }
        Write-WTLog "Fertig: $ok erfolgreich, $err Fehler. Lese Zustand neu ..."
        Update-WTStatus
        Update-WTUndoView
        Write-WTLog "Log-Datei: $($WT.LogFile)"
    } finally {
        Set-WTBusy $false
    }
    Show-WTRestartHint
}

function Save-WTProfile {
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.Filter = 'WinTweak-Profil (*.json)|*.json'
    $dlg.FileName = 'WinTweak-Profil.json'
    if ($dlg.ShowDialog() -ne $true) { return }
    $ids = @(Get-WTSelected | ForEach-Object { $_.Id })
    @{ Version = $WT.Version; Tweaks = $ids } | ConvertTo-Json | Set-Content -Path $dlg.FileName -Encoding UTF8
    Write-WTLog "Profil gespeichert: $($dlg.FileName) ($($ids.Count) Tweaks)"
}

function Import-WTProfile {
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Filter = 'WinTweak-Profil (*.json)|*.json'
    if ($dlg.ShowDialog() -ne $true) { return }
    try {
        $p = Get-Content -Path $dlg.FileName -Raw -Encoding UTF8 | ConvertFrom-Json
        $ids = @($p.Tweaks)
        foreach ($r in $WT.Rows.Values) { $r.CheckBox.IsChecked = ($ids -contains $r.Tweak.Id) }
        Write-WTLog "Profil geladen: $($dlg.FileName) ($($ids.Count) Tweaks)"
    } catch {
        Write-WTLog "Profil konnte nicht geladen werden: $($_.Exception.Message)" 'ERROR'
    }
}

function Update-WTUndoView {
    if (-not $WT.UndoList) { return }
    if ($WT.Backup.Count -eq 0) { $WT.UndoList.Text = 'Keine gesicherten Änderungen vorhanden.'; return }
    $lines = foreach ($id in ($WT.Backup.Keys | Sort-Object)) {
        $tw = $WT.Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        $name = $id
        if ($tw) { $name = $tw.Name }
        '- {0}   ({1} gesicherte Werte)' -f $name, @($WT.Backup[$id]).Count
    }
    $WT.UndoList.Text = $lines -join "`n"
}

function Update-WTStartupList {
    $WT.StartupPanel.Children.Clear()
    $items = @(Get-WTStartupItems)
    if ($items.Count -eq 0) { [void]$WT.StartupPanel.Children.Add((New-WTText 'Keine Autostart-Einträge gefunden.' 12 '#9CA3AF')); return }
    foreach ($it in $items) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.IsChecked = $it.Enabled
        $cb.Tag = $it
        $cb.Margin = [Windows.Thickness]::new(0, 3, 0, 3)
        $cb.Content = New-WTText ('{0}    [{1}]' -f $it.Name, $it.Scope) 13
        $cb.ToolTip = $it.Command
        [void]$WT.StartupPanel.Children.Add($cb)
    }
}

function Save-WTStartupChanges {
    $n = 0
    foreach ($cb in @($WT.StartupPanel.Children)) {
        if ($cb -isnot [Windows.Controls.CheckBox]) { continue }
        $it = $cb.Tag
        $want = ($cb.IsChecked -eq $true)
        if ($want -eq $it.Enabled) { continue }
        try {
            Set-WTStartupItem -Item $it -Enable $want
            $it.Enabled = $want
            $n++
            Write-WTLog ('Autostart {0}: {1}' -f ($(if ($want) { 'aktiviert' } else { 'deaktiviert' })), $it.Name)
        } catch { Write-WTLog "Autostart-Fehler bei $($it.Name): $($_.Exception.Message)" 'ERROR' }
    }
    Write-WTLog "$n Autostart-Einträge geändert."
    Update-WTUndoView
}

function Update-WTAppxList {
    $WT.AppxPanel.Children.Clear()
    Write-WTLog 'Suche installierte Apps ...'
    Update-WTUi
    $found = 0
    foreach ($name in $WT.BloatList.Keys) {
        $pkg = Get-AppxPackage -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pkg) { continue }
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Tag = $name
        $cb.Margin = [Windows.Thickness]::new(0, 3, 0, 3)
        $cb.Content = New-WTText ('{0}    ({1})' -f $WT.BloatList[$name], $name) 13
        [void]$WT.AppxPanel.Children.Add($cb)
        $found++
    }
    if ($found -eq 0) { [void]$WT.AppxPanel.Children.Add((New-WTText 'Keine der bekannten vorinstallierten Apps gefunden.' 12 '#9CA3AF')) }
    Write-WTLog "$found entfernbare Apps gefunden."
}

function Remove-WTSelectedAppx {
    $names = @($WT.AppxPanel.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] -and $_.IsChecked -eq $true } | ForEach-Object { $_.Tag })
    if ($names.Count -eq 0) { [void][Windows.MessageBox]::Show('Keine App ausgewählt.', 'WinTweak'); return }
    $r = [Windows.MessageBox]::Show("Diese Apps für den aktuellen Benutzer entfernen?`n`n$($names -join "`n")`n`nDas kann WinTweak NICHT automatisch rückgängig machen. Die Apps lassen sich aber über den Microsoft Store neu installieren.",
        'WinTweak - Apps entfernen', 'YesNo', 'Warning')
    if ("$r" -ne 'Yes') { return }
    Set-WTBusy $true
    try {
        foreach ($n in $names) {
            try { Get-AppxPackage -Name $n | Remove-AppxPackage -ErrorAction Stop; Write-WTLog "Entfernt: $n" }
            catch { Write-WTLog "Konnte $n nicht entfernen: $($_.Exception.Message)" 'ERROR' }
            Update-WTUi
        }
    } finally { Set-WTBusy $false }
    Update-WTAppxList
}

# =====================================================================
#  FENSTER (XAML)
# =====================================================================
[xml]$wtXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinTweak" Width="1060" Height="800" MinWidth="860" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#1B1D23" Foreground="#E6E6E6"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2E37"/>
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="BorderBrush" Value="#3A3F4B"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2563EB"/>
      <Setter Property="BorderBrush" Value="#2563EB"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="#23262E"/>
      <Setter Property="BorderBrush" Value="#23262E"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#A0A4AE"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="b" Background="Transparent" Padding="16,9" Margin="0,0,4,0" CornerRadius="8,8,0,0" Cursor="Hand">
              <ContentPresenter ContentSource="Header"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="b" Property="Background" Value="#23262E"/>
                <Setter Property="Foreground" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="150"/>
    </Grid.RowDefinitions>

    <DockPanel Grid.Row="0" Margin="0,0,0,14">
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Right" VerticalAlignment="Center">
        <Button x:Name="BtnSaveProfile" Content="Profil speichern"/>
        <Button x:Name="BtnLoadProfile" Content="Profil laden" Margin="0"/>
      </StackPanel>
      <StackPanel>
        <TextBlock Text="WinTweak" FontSize="26" FontWeight="SemiBold" Foreground="#FFFFFF"/>
        <TextBlock x:Name="SubTitle" Foreground="#8A8F9C" Margin="0,2,0,0"/>
      </StackPanel>
    </DockPanel>

    <TabControl x:Name="Tabs" Grid.Row="1"/>

    <DockPanel Grid.Row="2" Margin="0,14,0,10">
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left">
        <Button x:Name="BtnApply" Content="Ausgewählte anwenden" Style="{StaticResource Primary}"/>
        <Button x:Name="BtnUndo" Content="Ausgewählte rückgängig"/>
        <Button x:Name="BtnRecommended" Content="Empfohlen auswählen"/>
        <Button x:Name="BtnNone" Content="Alles abwählen"/>
      </StackPanel>
      <ProgressBar x:Name="Progress" Height="8" Margin="10,0,0,0" VerticalAlignment="Center"
                   Background="#2A2E37" Foreground="#3B82F6" BorderThickness="0"/>
    </DockPanel>

    <TextBox x:Name="LogBox" Grid.Row="3" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
             Background="#111317" Foreground="#9CA3AF" BorderBrush="#2A2E37" FontFamily="Consolas" FontSize="12" Padding="8"/>
  </Grid>
</Window>
'@

$WT.Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $wtXaml))
foreach ($n in 'Tabs', 'LogBox', 'Progress', 'SubTitle', 'BtnApply', 'BtnUndo', 'BtnRecommended', 'BtnNone', 'BtnSaveProfile', 'BtnLoadProfile') {
    $WT[$n] = $WT.Window.FindName($n)
}
$WT.Buttons = New-Object System.Collections.ArrayList
foreach ($b in @($WT.BtnApply, $WT.BtnUndo, $WT.BtnRecommended, $WT.BtnNone, $WT.BtnSaveProfile, $WT.BtnLoadProfile)) { [void]$WT.Buttons.Add($b) }

$wtOs = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$WT.SubTitle.Text = 'Version {0}   |   {1} (Build {2})   |   Backup: {3}' -f $WT.Version, $wtOs.Caption, $wtOs.BuildNumber, $WT.BackupFile

# ---------- Tabs mit Tweaks ----------
foreach ($cat in $WT.Categories) {
    $tab = New-Object Windows.Controls.TabItem
    $tab.Header = $cat
    $sv = New-Object Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    $panel = New-Object Windows.Controls.StackPanel
    $panel.Margin = [Windows.Thickness]::new(18, 10, 18, 18)
    $sv.Content = $panel
    $tab.Content = $sv
    [void]$WT.Tabs.Items.Add($tab)
    $WT.Panels[$cat] = $panel

    if ($cat -eq 'Latenz & Input') {
        $WT.TimerText = New-WTText (Get-WTTimerText) 12 '#93C5FD'
        $WT.TimerText.Margin = [Windows.Thickness]::new(0, 6, 0, 2)
        [void]$panel.Children.Add($WT.TimerText)
        [void]$panel.Children.Add((New-WTText 'Hinweis: Spiele setzen die Timer-Auflösung selbst. Ein dauerhafter Timer-Tweak ist deshalb nicht nötig und wird hier nur angezeigt.' 12 '#8A8F9C'))
    }

    $catTweaks = @($WT.Tweaks | Where-Object { $_.Category -eq $cat })
    if ($catTweaks.Count -eq 0) { [void]$panel.Children.Add((New-WTText 'Keine Tweaks in dieser Kategorie verfügbar.' 12 '#8A8F9C')) }
    foreach ($t in $catTweaks) { [void]$panel.Children.Add((New-WTRow $t)) }
}

# ---------- System & Dienste: Autostart + Debloat ----------
$sysPanel = $WT.Panels['System & Dienste']
[void]$sysPanel.Children.Add((New-WTHeading 'Autostart-Programme'))
[void]$sysPanel.Children.Add((New-WTText 'Haken = startet mit Windows. Haken entfernen und übernehmen, um ein Programm am Autostart zu hindern (wie im Task-Manager, umkehrbar).' 12 '#9CA3AF'))
$WT.StartupPanel = New-Object Windows.Controls.StackPanel
$WT.StartupPanel.Margin = [Windows.Thickness]::new(0, 8, 0, 4)
[void]$sysPanel.Children.Add($WT.StartupPanel)
$wtRow = New-Object Windows.Controls.WrapPanel
$btnStartupSave = New-WTButton 'Autostart-Änderungen übernehmen' -Primary
$btnStartupReload = New-WTButton 'Neu laden'
[void]$wtRow.Children.Add($btnStartupSave); [void]$wtRow.Children.Add($btnStartupReload)
[void]$sysPanel.Children.Add($wtRow)
$btnStartupSave.Add_Click({ Save-WTStartupChanges })
$btnStartupReload.Add_Click({ Update-WTStartupList })

[void]$sysPanel.Children.Add((New-WTHeading 'Vorinstallierte Apps entfernen (optional)'))
[void]$sysPanel.Children.Add((New-WTText 'Es wird nichts automatisch entfernt. Erst suchen, dann gezielt auswählen.' 12 '#9CA3AF'))
$WT.AppxPanel = New-Object Windows.Controls.StackPanel
$WT.AppxPanel.Margin = [Windows.Thickness]::new(0, 8, 0, 4)
[void]$sysPanel.Children.Add($WT.AppxPanel)
$wtRow = New-Object Windows.Controls.WrapPanel
$btnAppxScan = New-WTButton 'Installierte Apps suchen'
$btnAppxRemove = New-WTButton 'Ausgewählte Apps entfernen'
[void]$wtRow.Children.Add($btnAppxScan); [void]$wtRow.Children.Add($btnAppxRemove)
[void]$sysPanel.Children.Add($wtRow)
$btnAppxScan.Add_Click({ Update-WTAppxList })
$btnAppxRemove.Add_Click({ Remove-WTSelectedAppx })
[void]$WT.Buttons.Add($btnStartupSave); [void]$WT.Buttons.Add($btnAppxScan); [void]$WT.Buttons.Add($btnAppxRemove)

# ---------- Netzwerk: DNS ----------
$netPanel = $WT.Panels['Netzwerk']
[void]$netPanel.Children.Add((New-WTHeading 'DNS-Server'))
[void]$netPanel.Children.Add((New-WTText 'Gilt für alle aktiven Netzwerkadapter. Der vorherige Zustand wird gesichert.' 12 '#9CA3AF'))
$WT.DnsText = New-WTText (Get-WTDnsText) 12 '#93C5FD'
$WT.DnsText.Margin = [Windows.Thickness]::new(0, 6, 0, 6)
[void]$netPanel.Children.Add($WT.DnsText)
$wtRow = New-Object Windows.Controls.WrapPanel
$WT.DnsCombo = New-Object Windows.Controls.ComboBox
$WT.DnsCombo.Width = 300
$WT.DnsCombo.Margin = [Windows.Thickness]::new(0, 6, 8, 0)
$WT.DnsCombo.Padding = [Windows.Thickness]::new(8, 5, 8, 5)
foreach ($k in $WT.DnsProviders.Keys) { [void]$WT.DnsCombo.Items.Add($k) }
$WT.DnsCombo.SelectedIndex = 1
$btnDns = New-WTButton 'DNS übernehmen' -Primary
[void]$wtRow.Children.Add($WT.DnsCombo); [void]$wtRow.Children.Add($btnDns)
[void]$netPanel.Children.Add($wtRow)
[void]$WT.Buttons.Add($btnDns)
$btnDns.Add_Click({
    $choice = [string]$WT.DnsCombo.SelectedItem
    try {
        Write-WTLog "Setze DNS: $choice"
        Set-WTDns -Servers $WT.DnsProviders[$choice]
    } catch { Write-WTLog "DNS-Fehler: $($_.Exception.Message)" 'ERROR' }
    $WT.DnsText.Text = Get-WTDnsText
    Update-WTUndoView
})

# ---------- Tab: Rückgängig machen ----------
$tab = New-Object Windows.Controls.TabItem
$tab.Header = 'Rückgängig machen'
$sv = New-Object Windows.Controls.ScrollViewer
$sv.VerticalScrollBarVisibility = 'Auto'
$undoPanel = New-Object Windows.Controls.StackPanel
$undoPanel.Margin = [Windows.Thickness]::new(18, 10, 18, 18)
$sv.Content = $undoPanel
$tab.Content = $sv
[void]$WT.Tabs.Items.Add($tab)
[void]$undoPanel.Children.Add((New-WTHeading 'Gesicherte Originalwerte'))
[void]$undoPanel.Children.Add((New-WTText "Vor jeder Änderung speichert WinTweak den Originalwert in $($WT.BackupFile). Einzelne Tweaks machst du über Haken + Ausgewählte rückgängig rückgängig, hier geht alles auf einmal. Entfernte Apps lassen sich nur über den Microsoft Store wiederherstellen." 12 '#9CA3AF'))
$WT.UndoList = New-WTText '' 13 '#E6E6E6'
$WT.UndoList.Margin = [Windows.Thickness]::new(0, 10, 0, 10)
[void]$undoPanel.Children.Add($WT.UndoList)
$wtRow = New-Object Windows.Controls.WrapPanel
$btnUndoAll = New-WTButton 'Alle gesicherten Änderungen rückgängig machen' -Primary
$btnOpenBackup = New-WTButton 'Backup-Ordner öffnen'
$btnOpenLog = New-WTButton 'Log-Datei öffnen'
$btnRstrui = New-WTButton 'Systemwiederherstellung öffnen'
foreach ($b in @($btnUndoAll, $btnOpenBackup, $btnOpenLog, $btnRstrui)) { [void]$wtRow.Children.Add($b) }
[void]$undoPanel.Children.Add($wtRow)
[void]$WT.Buttons.Add($btnUndoAll)

$btnUndoAll.Add_Click({
    if ($WT.Backup.Count -eq 0) { [void][Windows.MessageBox]::Show('Es gibt keine gesicherten Änderungen.', 'WinTweak'); return }
    $r = [Windows.MessageBox]::Show("Alle $($WT.Backup.Count) gesicherten Änderungen rückgängig machen?", 'WinTweak', 'YesNo', 'Question')
    if ("$r" -ne 'Yes') { return }
    Set-WTBusy $true
    try {
        foreach ($id in @($WT.Backup.Keys)) {
            Write-WTLog "Rückgängig: $id"
            $tw = $WT.Tweaks | Where-Object { $_.Id -eq $id } | Select-Object -First 1
            try {
                if ($tw) { & $tw.Undo $tw | Out-Null; if ($tw.Restart) { $WT.RestartNeeded[$tw.Restart] = $true } }
                else { Restore-WTBackup $id }
            } catch { Write-WTLog "Fehler: $($_.Exception.Message)" 'ERROR' }
            Update-WTUi
        }
        $WT.RestartNeeded['Neustart'] = $true
        Update-WTStatus
        Update-WTUndoView
        Update-WTStartupList
        $WT.DnsText.Text = Get-WTDnsText
        Write-WTLog 'Alle gesicherten Änderungen wurden zurückgesetzt.'
    } finally { Set-WTBusy $false }
    Show-WTRestartHint
})
$btnOpenBackup.Add_Click({ if (-not (Test-Path $WT.Dir)) { New-Item -ItemType Directory -Path $WT.Dir -Force | Out-Null }; Start-Process explorer.exe $WT.Dir })
$btnOpenLog.Add_Click({ if (Test-Path $WT.LogFile) { Start-Process notepad.exe $WT.LogFile } })
$btnRstrui.Add_Click({ Start-Process rstrui.exe })

# ---------- Haupt-Buttons ----------
$WT.BtnApply.Add_Click({ Invoke-WTSelected -Mode 'Apply' })
$WT.BtnUndo.Add_Click({ Invoke-WTSelected -Mode 'Undo' })
$WT.BtnRecommended.Add_Click({
    foreach ($r in $WT.Rows.Values) { $r.CheckBox.IsChecked = $r.Tweak.Recommended }
    Write-WTLog 'Empfohlene Tweaks ausgewählt.'
})
$WT.BtnNone.Add_Click({ foreach ($r in $WT.Rows.Values) { $r.CheckBox.IsChecked = $false } })
$WT.BtnSaveProfile.Add_Click({ Save-WTProfile })
$WT.BtnLoadProfile.Add_Click({ Import-WTProfile })

# =====================================================================
#  START
# =====================================================================
Import-WTBackup
Write-WTLog "WinTweak $($WT.Version) gestartet. Log: $($WT.LogFile)"

$WT.Window.Add_ContentRendered({
    Write-WTLog 'Lese aktuellen Zustand aller Tweaks ...'
    Set-WTBusy $true
    try {
        Update-WTStatus
        Update-WTUndoView
        Update-WTStartupList
    } finally { Set-WTBusy $false }
    Write-WTLog "Bereit. $($WT.Tweaks.Count) Tweaks geladen. Tipp: Empfohlen auswählen und anwenden."
})

if ($WT.SelfTest) {
    # Entwicklertest: GUI-Aufbau und alle (nur lesenden) Checks ausführen, Fenster nicht anzeigen
    Update-WTStatus; Update-WTUndoView; Update-WTStartupList
    foreach ($r in $WT.Rows.Values) { Write-Host ('{0,-45} {1}' -f $r.Tweak.Id, $r.Status.Text) }
    Write-Host "SELFTEST OK: $($WT.Tweaks.Count) Tweaks, $($WT.Tabs.Items.Count) Tabs"
    return
}

[void]$WT.Window.ShowDialog()
