# WinTweak

Windows-10/11-Tweak-Tool mit grafischer Oberfläche. Ein einziges PowerShell-Skript, das sich mit einem Befehl starten lässt.

## Start

PowerShell öffnen und eingeben:

```powershell
irm https://raw.githubusercontent.com/DEIN-NAME/wintweak/main/tweak.ps1 | iex
```

Das Skript fragt automatisch nach Administratorrechten (UAC) und öffnet die Oberfläche.

Lokal (ohne Internet):

```powershell
powershell -ExecutionPolicy Bypass -File .\tweak.ps1
```

## Bedienung

1. Tab wählen, Haken bei den gewünschten Tweaks setzen (oder **Empfohlen auswählen**).
2. **Ausgewählte anwenden** klicken.
3. Vor dem ersten Anwenden wird automatisch ein **Wiederherstellungspunkt** erstellt.
4. Rechts in jeder Zeile steht der aktuelle Zustand (**● Aktiv** / **○ Nicht aktiv**).
5. Am Ende erscheint ein Hinweis, wenn ein Neustart oder Abmelden nötig ist.

Badges: **Sicher** (ohne Risiko) · **Mittel** (kleine Nebenwirkungen möglich) · **Fortgeschritten** (zeigt vor dem Anwenden eine Warnung).

Mit **Profil speichern / laden** kannst du deine Auswahl als JSON sichern und auf anderen PCs wiederverwenden.

## Alle Tweaks

### Latenz & Input
| Tweak | Risiko | Wirkung |
|---|---|---|
| Mausbeschleunigung aus ⭐ | Sicher | 1:1-Mausbewegung, wirkt sofort |
| Einrastfunktion-/Filtertasten-Kürzel aus ⭐ | Sicher | Kein Popup bei 5x Shift |
| MMCSS: Spiele priorisieren | Mittel | SystemResponsiveness 10, NetworkThrottlingIndex aus, Games-Task auf hohe Priorität |
| Dynamic Tick deaktivieren | Fortgeschritten | `bcdedit disabledynamictick yes`, Nutzen umstritten |
| HPET-Erzwingung entfernen | Fortgeschritten | löscht `useplatformclock` (alter, meist schädlicher Tweak) |
| MSI-Modus für Grafikkarte | Fortgeschritten | MSISupported=1, bei aktuellen Treibern meist schon aktiv |
| *Info:* Timer-Auflösung | – | wird nur angezeigt, nicht verändert |

### Gaming
| Tweak | Risiko | Wirkung |
|---|---|---|
| Game DVR / Hintergrundaufnahme aus ⭐ | Sicher | keine ständige Hintergrundaufnahme |
| Spielmodus einschalten ⭐ | Sicher | Windows priorisiert das Spiel |
| HAGS einschalten ⭐ | Sicher | GPU-Planung durch die Grafikkarte, nötig für Frame Generation |
| Vollbildoptimierungen global aus | Mittel | echtes exklusives Vollbild in älteren Spielen |
| Kernisolierung / Speicher-Integrität aus | Fortgeschritten | +FPS, **aber weniger Sicherheit** |

### System & Dienste
| Tweak | Risiko | Wirkung |
|---|---|---|
| Hintergrund-Apps deaktivieren ⭐ | Mittel | Store-Apps laufen nicht im Hintergrund |
| Unnötige Dienste auf Manuell | Sicher | Fax, MapsBroker, RetailDemo, dmwappushservice, DiagTrack, WMPNetworkSvc |
| Xbox-Dienste auf Manuell | Mittel | nur ohne Game Pass sinnvoll |
| Visuelle Effekte (5 einzelne Tweaks) | Sicher | Animationen, Transparenz, Menü-Verzögerung, Aero Peek |
| Autostart-Liste | – | Programme einzeln am Autostart hindern (umkehrbar) |
| Vorinstallierte Apps entfernen | – | nur nach Suche und Auswahl, **nicht** automatisch umkehrbar |

### Datenschutz
Telemetrie minimieren ⭐ · Werbe-ID aus ⭐ · Vorschläge im Startmenü aus ⭐ · Bing-Suche aus ⭐ · Copilot und Recall aus ⭐

### Netzwerk
| Tweak | Risiko | Wirkung |
|---|---|---|
| Nagle-Algorithmus aus (pro Adapter) | Sicher | TcpAckFrequency=1, TCPNoDelay=1, hilft nur in manchen Spielen |
| DNS-Auswahl | – | Cloudflare, Google, Quad9 oder Automatisch |

### Energie
| Tweak | Risiko | Wirkung |
|---|---|---|
| Ultimative Leistung ⭐ | Sicher | versteckten Plan freischalten und aktivieren (Fallback: Höchstleistung) |
| Selektives USB-Energiesparen aus ⭐ | Sicher | keine USB-Aussetzer |
| PCIe-Energieverwaltung aus | Mittel | weniger Akkulaufzeit auf Laptops |
| Core Parking deaktivieren | Fortgeschritten | kann bei Ryzen X3D / Intel P+E-Kernen schaden |

⭐ = wird von **Empfohlen auswählen** markiert.

## Alles rückgängig machen

- **Einzeln:** Haken setzen und auf **Ausgewählte rückgängig** klicken.
- **Alles:** Tab **Rückgängig machen**, dann auf **Alle gesicherten Änderungen rückgängig machen** klicken.
- **Notfall:** **Systemwiederherstellung öffnen** und den Punkt `WinTweak <Datum>` wählen.

Die Originalwerte liegen in `C:\ProgramData\WinTweak\backup.json`. Pro Wert wird nur der *erste* Originalzustand gespeichert, sodass mehrfaches Anwenden nichts überschreibt.
Logs liegen unter `%TEMP%\WinTweak_*.log`.

## Auf GitHub hosten (damit `irm | iex` funktioniert)

1. Auf github.com ein **öffentliches** Repository anlegen, z. B. `wintweak`.
2. In `src/tweak.src.ps1` ganz oben bei `$WinTweakUrl` deine spätere Raw-URL eintragen:
   `https://raw.githubusercontent.com/DEIN-NAME/wintweak/main/tweak.ps1`
   (Wird gebraucht, damit sich das Skript beim Start aus `irm | iex` mit Adminrechten neu laden kann.)
3. `build.ps1` ausführen (siehe unten). Dadurch wird `tweak.ps1` neu erzeugt.
4. Alle Dateien hochladen (**Add file → Upload files**): `tweak.ps1`, `build.ps1`, `README.md` und den Ordner `src`.
5. Fertig. Starten mit:
   ```powershell
   irm https://raw.githubusercontent.com/DEIN-NAME/wintweak/main/tweak.ps1 | iex
   ```

**Kurze URL (optional):** Mit einer eigenen Domain (z. B. über Cloudflare) eine Weiterleitung von `deinedomain.de/win` auf die Raw-URL einrichten. Dann reicht `irm deinedomain.de/win | iex`.

## Projektaufbau und Build

| Datei | Zweck |
|---|---|
| `src/tweak.src.ps1` | **Hier wird bearbeitet.** Lesbarer Quellcode mit Umlauten (UTF-8 mit BOM). |
| `build.ps1` | Erzeugt daraus `tweak.ps1` |
| `tweak.ps1` | Die Datei, die per `irm | iex` geladen wird. Reines ASCII, nicht von Hand bearbeiten. |

```powershell
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

**Warum ein Build?** `irm | iex` bricht ab, wenn die Datei mit einem UTF-8-BOM beginnt. Ohne BOM liest Windows PowerShell 5.1 lokale Dateien dagegen als ANSI und zerstört die Umlaute. Der Build wandelt alle Umlaute in `[char]0x00E4` bzw. XML-Entities um. Dadurch funktioniert die Datei in beiden Fällen. Der Build prüft das Ergebnis außerdem auf Syntaxfehler.

**Testen ohne Änderungen am System:** Der folgende Befehl baut die komplette Oberfläche auf und liest nur den Zustand aller Tweaks aus. Er ändert nichts und zeigt kein Fenster an:

```powershell
$env:WINTWEAK_SELFTEST='1'; powershell -STA -ExecutionPolicy Bypass -File .\tweak.ps1; $env:WINTWEAK_SELFTEST=$null
```

## Neue Tweaks hinzufügen

In `src/tweak.src.ps1` (danach `build.ps1` ausführen). Ein reiner Registry-Tweak braucht nur einen Eintrag:

```powershell
Add-WTRegTweak -Id 'MeinTweak' -Category 'Gaming' -Risk 'Sicher' -Restart 'Neustart' `
    -Name 'Name in der Liste' -Description 'Was der Tweak macht' `
    -Values @((New-RV 'HKCU:\Software\Pfad' 'WertName' 1))
```

Backup, Rückgängig machen und die Statusanzeige funktionieren dann automatisch. Für komplexere Tweaks gibt es `Add-WTTweak` mit eigenen `-Apply`-, `-Undo`- und `-Check`-Scriptblöcken.
