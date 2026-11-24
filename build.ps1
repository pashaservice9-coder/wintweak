<#
.SYNOPSIS
    Baut aus src\tweak.src.ps1 (lesbar, mit Umlauten) die Datei tweak.ps1 (reines ASCII).
.DESCRIPTION
    Warum? "irm ... | iex" scheitert, wenn die Datei mit einem UTF-8-BOM beginnt.
    Ohne BOM liest Windows PowerShell 5.1 lokale Dateien aber als ANSI und zerstört
    die Umlaute. Reines ASCII funktioniert in beiden Fällen.

    Umwandlung (über den PowerShell-Tokenizer, Code bleibt unverändert):
      'Text mit Umlaut'    ->  ('Text mit Umlaut'-Teile + [char]0x00E4 + ...)
      "Text mit Umlaut"    ->  "Text $([char]0x00E4) ..."
      @' XAML '@           ->  XML-Entities (&#x00E4;)
      Kommentare           ->  ae / oe / ue / ss

    Aufruf:  powershell -ExecutionPolicy Bypass -File .\build.ps1
#>
param(
    [string]$Source = (Join-Path $PSScriptRoot 'src\tweak.src.ps1'),
    [string]$Out    = (Join-Path $PSScriptRoot 'tweak.ps1')
)
$ErrorActionPreference = 'Stop'

$text = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8)
$tokens = $null; $parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Host ("Zeile {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
    throw 'Quelldatei enthaelt Syntaxfehler.'
}

function Test-Ascii([string]$s) { return $s -notmatch '[^\x00-\x7F]' }

function ConvertTo-Translit([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) {
        $code = [int]$c
        if ($code -lt 128) { [void]$sb.Append($c); continue }
        switch ($code) {
            0xE4 { [void]$sb.Append('ae') } 0xF6 { [void]$sb.Append('oe') } 0xFC { [void]$sb.Append('ue') }
            0xC4 { [void]$sb.Append('Ae') } 0xD6 { [void]$sb.Append('Oe') } 0xDC { [void]$sb.Append('Ue') }
            0xDF { [void]$sb.Append('ss') }
            default { [void]$sb.Append('?') }
        }
    }
    return $sb.ToString()
}

function Convert-Token($tok) {
    $raw = $tok.Extent.Text
    if (Test-Ascii $raw) { return $raw }
    $kind = $tok.Kind.ToString()
    switch ($kind) {
        'Comment' { return ConvertTo-Translit $raw }
        'StringLiteral' {
            # 'abc' -> ('ab'+[char]0x00E4+'c')
            $inner = $raw.Substring(1, $raw.Length - 2)
            $sb = New-Object System.Text.StringBuilder
            [void]$sb.Append("('")
            foreach ($c in $inner.ToCharArray()) {
                if ([int]$c -lt 128) { [void]$sb.Append($c) }
                else { [void]$sb.Append(("'+[char]0x{0:X4}+'" -f [int]$c)) }
            }
            [void]$sb.Append("')")
            return $sb.ToString()
        }
        'HereStringLiteral' {
            # Nur für XAML gedacht: Umlaute als XML-Entities
            $sb = New-Object System.Text.StringBuilder
            foreach ($c in $raw.ToCharArray()) {
                if ([int]$c -lt 128) { [void]$sb.Append($c) } else { [void]$sb.Append(('&#x{0:X4};' -f [int]$c)) }
            }
            return $sb.ToString()
        }
        { $_ -in 'StringExpandable', 'HereStringExpandable' } {
            $start = $tok.Extent.StartOffset
            $end = $tok.Extent.EndOffset
            $nested = @($tok.NestedTokens | Where-Object { $_ } | Sort-Object { $_.Extent.StartOffset })
            $sb = New-Object System.Text.StringBuilder
            $pos = $start
            $ni = 0
            while ($pos -lt $end) {
                while ($ni -lt $nested.Count -and $nested[$ni].Extent.StartOffset -lt $pos) { $ni++ }
                if ($ni -lt $nested.Count -and $nested[$ni].Extent.StartOffset -eq $pos -and $nested[$ni].Extent.EndOffset -gt $pos) {
                    [void]$sb.Append((Convert-Token $nested[$ni]))
                    $pos = $nested[$ni].Extent.EndOffset
                    $ni++
                    continue
                }
                $c = $text[$pos]
                if ([int]$c -lt 128) { [void]$sb.Append($c) } else { [void]$sb.Append(('$([char]0x{0:X4})' -f [int]$c)) }
                $pos++
            }
            return $sb.ToString()
        }
        default {
            throw ("Nicht-ASCII-Zeichen ausserhalb eines Strings (Zeile {0}): {1}" -f $tok.Extent.StartLineNumber, $raw)
        }
    }
}

# Ersetzungen von hinten nach vorne, damit die Offsets gültig bleiben
$result = $text
foreach ($tok in ($tokens | Sort-Object { $_.Extent.StartOffset } -Descending)) {
    if (Test-Ascii $tok.Extent.Text) { continue }
    $new = Convert-Token $tok
    $result = $result.Substring(0, $tok.Extent.StartOffset) + $new + $result.Substring($tok.Extent.EndOffset)
}

$header = "# =====================================================================`r`n" +
          "#  GENERIERT von build.ps1 aus src\tweak.src.ps1 - bitte dort bearbeiten.`r`n" +
          "# =====================================================================`r`n"
$result = $header + $result.TrimStart([char]0xFEFF)

if (-not (Test-Ascii $result)) { throw 'Ergebnis enthaelt noch Nicht-ASCII-Zeichen.' }
$check = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($result, [ref]$null, [ref]$check)
if ($check.Count -gt 0) {
    $check | ForEach-Object { Write-Host ("Zeile {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
    throw 'Erzeugte Datei enthaelt Syntaxfehler.'
}

[IO.File]::WriteAllText($Out, $result, [Text.Encoding]::ASCII)
Write-Host "OK: $Out erstellt ($([math]::Round($result.Length / 1KB)) KB, reines ASCII)." -ForegroundColor Green
