# Installiert Read und Write fuer den angemeldeten Benutzer, ohne Adminrechte.
# Wird vom Setup-Assistenten "Read & Write Setup.exe" aus einem entpackten Ordner gestartet.
param([switch]$NichtStarten, [switch]$KeinDesktop, [switch]$KeinAutostart)
# 1) Laufende Fassung beenden, alte Fassung "Auto Reading" entfernen
# 2) Python suchen, falls noetig ueber winget oder python.org nachinstallieren
# 3) Sprach-Engine und Spracherkennung einrichten, Sprachmodell laden
# 4) Programm nach %LOCALAPPDATA%\Programs\Read und Write kopieren
# 5) Desktop-Symbol, Startmenue, Autostart und Eintrag unter Apps anlegen
# 6) Read und Write starten
$ErrorActionPreference = "Continue"
$version = "5.7"
$quelle = Split-Path -Parent $MyInvocation.MyCommand.Path
$ziel = Join-Path $env:LOCALAPPDATA "Programs\Read und Write"
$protokoll = Join-Path $env:TEMP "read-und-write-installation.txt"
Set-Content $protokoll "Installation $version $(Get-Date)" -Encoding UTF8
[Console]::OutputEncoding = [Text.Encoding]::UTF8
function Meldung($t) { [Console]::Out.WriteLine($t); [Console]::Out.Flush(); Add-Content $protokoll $t -Encoding UTF8 }

Meldung "Read & Write $version wird installiert."
Meldung "Laufende Fassung wird beendet."

# 1) Laufende Fassungen beenden, damit Dateien ersetzt werden koennen
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match "Auto-Reading\.ps1|Read-und-Write\.ps1" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "Programs\\(Auto Reading|Read und Write)\\(speak|hoeren)\.py" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
Start-Sleep -Milliseconds 800

$startmenue = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$autostart = Join-Path $startmenue "Startup"
$desktop = [Environment]::GetFolderPath("Desktop")

# Fruehere Fassung "Auto Reading" entfernen, ihre Einstellungen uebernehmen
$alt = Join-Path $env:LOCALAPPDATA "Programs\Auto Reading"
$datenAlt = Join-Path $env:APPDATA "Auto Reading"
$daten = Join-Path $env:APPDATA "Read und Write"
if ((Test-Path $datenAlt) -and -not (Test-Path $daten)) { Copy-Item $datenAlt $daten -Recurse -Force }
foreach ($n in @("Auto Reading.lnk", "Read & Write.lnk", "Read und Write.lnk")) {
  foreach ($o in @($desktop, $startmenue, $autostart)) {
    $f = Join-Path $o $n
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
  }
}
if (Test-Path $alt) { Remove-Item $alt -Recurse -Force -ErrorAction SilentlyContinue; Meldung "Alte Fassung Auto Reading entfernt." }
Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AutoReading" -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path $datenAlt) { Remove-Item $datenAlt -Recurse -Force -ErrorAction SilentlyContinue }

# 2) Python suchen. Der Microsoft-Store-Platzhalter zaehlt nicht.
# Bevorzugt werden Fassungen, fuer die alle Sprachpakete sicher bereitstehen.
function Finde-Python {
  $kandidaten = @()
  foreach ($v in @("312","311","313","310","314")) {
    $kandidaten += "$env:LOCALAPPDATA\Programs\Python\Python$v\python.exe"
    $kandidaten += "$env:ProgramFiles\Python$v\python.exe"
  }
  foreach ($p in $kandidaten) { if (Test-Path $p) { return $p } }
  $py = Get-Command py -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
  if ($py) {
    $p = (& $py.Source -3 -c "import sys; print(sys.executable)" 2>$null)
    if ($p -and (Test-Path $p)) { return $p.Trim() }
  }
  $c = Get-Command python -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
  if ($c) { return $c.Source }
  return ""
}

# Python 3.12 nur fuer diesen Benutzer installieren: zuerst ueber winget,
# geht das nicht, direkt von python.org
function Installiere-Python {
  $p312 = "$env:LOCALAPPDATA\Programs\Python\Python312\python.exe"
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($winget) {
    try { & $winget.Source install --id Python.Python.3.12 -e --scope user --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null } catch {}
    if (Test-Path $p312) { return $p312 }
  }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $datei = Join-Path $env:TEMP "python-3.12.10-amd64.exe"
    Meldung "Python wird von python.org geladen."
    (New-Object Net.WebClient).DownloadFile("https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe", $datei)
    $p = Start-Process $datei -ArgumentList "/quiet InstallAllUsers=0 PrependPath=0 Include_test=0 Include_doc=0 Shortcuts=0" -PassThru
    $p.WaitForExit(600000) | Out-Null
    Remove-Item $datei -Force -ErrorAction SilentlyContinue
  } catch { Add-Content $protokoll ("python.org: " + $_.Exception.Message) -Encoding UTF8 }
  if (Test-Path $p312) { return $p312 }
  return ""
}

# Sprachpakete in das gefundene Python laden und pruefen.
# Ergebnis: 2 = alles da, 1 = nur Stimmen, 0 = nichts
function Richte-Pakete-Ein($py) {
  & $py -m pip --version 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { & $py -m ensurepip --user 2>&1 | Out-Null }
  & $py -m pip install --user --upgrade --disable-pip-version-check --quiet --no-warn-script-location edge-tts faster-whisper sounddevice numpy vosk 2>&1 | Out-File -Append $protokoll -Encoding UTF8
  $stufe = 0
  $null = & $py -c "import edge_tts" 2>$null
  if ($LASTEXITCODE -eq 0) { $stufe = 1 }
  $null = & $py -c "import faster_whisper, sounddevice, vosk" 2>$null
  if ($LASTEXITCODE -eq 0 -and $stufe -eq 1) { $stufe = 2 }
  return $stufe
}

$python = Finde-Python
if ($python -eq "") {
  Meldung "Python fehlt und wird jetzt automatisch installiert, das dauert ein bis zwei Minuten."
  $python = Installiere-Python
}
if ($python -eq "") {
  Meldung "HINWEIS: Python konnte nicht installiert werden."
  Meldung "Read & Write liest dann mit der Windows-Stimme vor, Diktieren geht ohne Python nicht."
} else {
  Meldung "Python: $python"
  # 3) Sprach-Engine und Spracherkennung
  Meldung "Stimmen und Spracherkennung werden eingerichtet, beim ersten Mal einige Minuten."
  $stufe = Richte-Pakete-Ein $python
  if ($stufe -lt 2 -and $python -notmatch "Python312") {
    # Fuer manche Python-Fassungen fehlen Pakete: dann ein eigenes Python 3.12
    Meldung "Passendes Python 3.12 wird ergänzt."
    $p2 = Installiere-Python
    if ($p2 -ne "") {
      $s2 = Richte-Pakete-Ein $p2
      if ($s2 -gt $stufe) { $python = $p2; $stufe = $s2; Meldung "Python: $python" }
    }
  }
  if ($stufe -ge 1) { Meldung "Stimmen bereit." } else { Meldung "HINWEIS: Stimmen fehlen, Read & Write nutzt die Windows-Stimme." }
  if ($stufe -ge 2) {
    Meldung "Sprachmodell wird geladen, beim ersten Mal etwa zwei Minuten."
    $env:HF_HUB_DISABLE_SYMLINKS_WARNING = "1"
    $null = & $python -c "import vosk; vosk.SetLogLevel(-1); vosk.Model(lang='de'); from faster_whisper import WhisperModel; WhisperModel('small', device='cpu', compute_type='int8'); WhisperModel('base', device='cpu', compute_type='int8')" 2>$null
    if ($LASTEXITCODE -eq 0) { Meldung "Spracherkennung bereit." } else { Meldung "HINWEIS: Sprachmodell wird beim ersten Diktat geladen." }
  } else { Meldung "HINWEIS: Offline-Diktat nicht verfügbar, online diktieren geht trotzdem." }
}

# 4) Programm kopieren
New-Item -ItemType Directory -Force -Path $ziel | Out-Null
$dateien = @("Read-und-Write.ps1", "Read & Write.exe", "speak.py", "hoeren.py", "read-und-write.ico",
             "Deinstallieren.ps1", "Anleitung.html",
             "stimme-katja.mp3", "stimme-seraphina.mp3", "stimme-conrad.mp3", "stimme-florian.mp3")
foreach ($f in $dateien) { Copy-Item (Join-Path $quelle $f) $ziel -Force }
Set-Content (Join-Path $ziel "python.txt") -Value $python -Encoding UTF8
Set-Content (Join-Path $ziel "version.txt") -Value $version -Encoding ASCII
# Herkunftsmarke aus dem Internet entfernen, damit Windows nicht bei jedem Start fragt
Get-ChildItem $ziel -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
# Dateien frueherer Fassungen entfernen
foreach ($alt in @("Read-und-Write.vbs", "hoeren_win.py", "Anleitung.txt")) { Remove-Item (Join-Path $ziel $alt) -Force -ErrorAction SilentlyContinue }
if (-not (Test-Path (Join-Path $ziel "Read & Write.exe"))) { Meldung "FEHLER: Dateien konnten nicht kopiert werden."; exit 1 }
Meldung "Programm liegt in $ziel"

# 5) Verknuepfungen
$ws = New-Object -ComObject WScript.Shell
$exe = Join-Path $ziel "Read & Write.exe"
$ico = Join-Path $ziel "read-und-write.ico"
New-Item -ItemType Directory -Force -Path $autostart | Out-Null
$orte = @($startmenue)
if (-not $KeinDesktop) { $orte += $desktop }
if (-not $KeinAutostart) { $orte += $autostart }
foreach ($o in $orte) {
  $l = $ws.CreateShortcut((Join-Path $o "Read & Write.lnk"))
  $l.TargetPath = $exe
  $l.WorkingDirectory = $ziel
  $l.IconLocation = "$exe,0"
  $l.Description = "Read & Write, schwebender Knopf zum Vorlesen und Diktieren"
  $l.Save()
}
# Gleiche App-Kennung wie das Fenster: so landen angeheftetes Symbol und
# laufendes Fenster auf einem einzigen Platz in der Taskleiste
try {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class LnkKennung {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class CShellLink {}
    [StructLayout(LayoutKind.Sequential, Pack=4)] public struct PK { public Guid f; public uint p; }
    [StructLayout(LayoutKind.Explicit, Size=16)] public struct PV { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out uint c);
        int GetAt(uint i, out PK k);
        int GetValue(ref PK k, out PV v);
        int SetValue(ref PK k, ref PV v);
        int Commit();
    }
    public static void Setzen(string lnk, string id) {
        object link = new CShellLink();
        IPersistFile pf = (IPersistFile)link;
        pf.Load(lnk, 2);
        IPropertyStore ps = (IPropertyStore)link;
        PK k = new PK(); k.f = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.p = 5;
        PV v = new PV(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(id);
        ps.SetValue(ref k, ref v);
        ps.Commit();
        pf.Save(lnk, true);
        Marshal.FreeCoTaskMem(v.p);
        Marshal.ReleaseComObject(link);
    }
}
"@
  $angeheftet = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
  # Angeheftetes Symbol der frueheren Fassung zeigt ins Leere, weg damit
  Remove-Item (Join-Path $angeheftet "Auto Reading.lnk") -Force -ErrorAction SilentlyContinue
  $lnks = @($orte | ForEach-Object { Join-Path $_ "Read & Write.lnk" })
  if (Test-Path (Join-Path $angeheftet "Read & Write.lnk")) { $lnks += (Join-Path $angeheftet "Read & Write.lnk") }
  foreach ($f in $lnks) { if (Test-Path $f) { [LnkKennung]::Setzen($f, "APirzadeh.ReadUndWrite") } }
  Meldung "Taskleisten-Kennung gesetzt."
} catch { Meldung ("HINWEIS: Taskleisten-Kennung " + $_.Exception.Message) }
try { Start-Process "$env:WINDIR\System32\ie4uinit.exe" -ArgumentList "-show" -WindowStyle Hidden -Wait } catch {}
Meldung "Verknüpfungen angelegt."

# Eintrag unter Einstellungen, Apps, damit man es normal deinstallieren kann
$reg = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ReadUndWrite"
New-Item -Path $reg -Force | Out-Null
$deinst = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $ziel "Deinstallieren.ps1") + '"'
$werte = @{
  DisplayName = "Read & Write"
  DisplayVersion = $version
  Publisher = "A.Pirzadeh"
  DisplayIcon = $exe
  InstallLocation = $ziel
  UninstallString = $deinst
  QuietUninstallString = $deinst + " -Still"
}
foreach ($k in $werte.Keys) { Set-ItemProperty -Path $reg -Name $k -Value $werte[$k] }
Set-ItemProperty -Path $reg -Name NoModify -Value 1 -Type DWord
Set-ItemProperty -Path $reg -Name NoRepair -Value 1 -Type DWord
$groesse = [int]((Get-ChildItem $ziel -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
Set-ItemProperty -Path $reg -Name EstimatedSize -Value $groesse -Type DWord
Meldung "Unter Einstellungen, Apps eingetragen."

# 6) Starten, ausser der Setup-Assistent startet selbst
if (-not $NichtStarten) { Start-Process $exe -WorkingDirectory $ziel }
Meldung "Installation abgeschlossen."
exit 0
