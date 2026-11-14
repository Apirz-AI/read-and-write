param([switch]$Selbsttest)
# -Selbsttest: prueft alle Funktionen ohne Maus und ohne Ton, schreibt das
# Ergebnis nach %TEMP%\read-und-write-selbsttest.txt und beendet sich.
# Laeuft neben einer offenen Fassung, ohne deren Einstellungen zu aendern.
if ($Selbsttest) {
  $mutex = New-Object System.Threading.Mutex($false, "ReadUndWriteSelbsttest")
} else {
# Alte Instanzen zuerst beenden. Sonst blockiert der Mutex den neuen Start
# und das alte Fenster mit altem Text bleibt sichtbar.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match "Auto-Reading\.ps1|Read-und-Write\.ps1|Sprechknopf\.ps1" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
Start-Sleep -Milliseconds 400
$mutex = New-Object System.Threading.Mutex($false, "AutoReadingV4")
}
$neu = $false
try { $neu = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $neu = $true }
if (-not $neu) { exit 0 }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Speech, System.Windows.Forms, System.Drawing

# Eigene App-Kennung fuer die Taskleiste. Ohne sie zeigt Windows das blaue
# PowerShell-Symbol, weil das Fenster zum Prozess powershell.exe gehoert.
# Muss vor dem ersten Fenster gesetzt werden.
try {
  Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AppKennung {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string id);
}
"@
  [AppKennung]::SetCurrentProcessExplicitAppUserModelID("APirzadeh.ReadUndWrite") | Out-Null
} catch {}

# --- Windows-Simulationsstimme als Rueckfall ---
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$de = $synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo } | Where-Object { $_.Culture.Name -like "de*" -and $_.Enabled } | Select-Object -First 1
if (-not $de) { $de = $synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo } | Where-Object { $_.Enabled } | Select-Object -First 1 }
if ($de) { $synth.SelectVoice($de.Name) }
$synth.Rate = 0
$synth.Volume = 100

$base = Split-Path -Parent $MyInvocation.MyCommand.Path
# Python suchen: zuerst der Pfad, den die Installation gefunden hat,
# dann die ueblichen Orte. Der Microsoft-Store-Platzhalter zaehlt nicht.
$script:py = ""
$script:pyVor = @()
$pyDatei = Join-Path $base "python.txt"
if (Test-Path $pyDatei) {
  try {
    $p = (Get-Content $pyDatei -Raw).Trim()
    if ($p -ne "" -and (Test-Path $p)) { $script:py = $p }
  } catch {}
}
if ($script:py -eq "") {
  $kandidaten = @()
  foreach ($v in @("314","313","312","311","310")) {
    $kandidaten += "$env:LOCALAPPDATA\Programs\Python\Python$v\python.exe"
    $kandidaten += "$env:ProgramFiles\Python$v\python.exe"
  }
  foreach ($p in $kandidaten) { if (Test-Path $p) { $script:py = $p; break } }
}
if ($script:py -eq "") {
  foreach ($k in @("py", "python")) {
    $c = Get-Command $k -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch "WindowsApps" } | Select-Object -First 1
    if ($c) { $script:py = $c.Source; if ($k -eq "py") { $script:pyVor = @("-3") }; break }
  }
}
$script:speakpy = Join-Path $base "speak.py"
# Sprechdienst: ein dauerhaft laufender Python-Prozess, siehe speak.py
$script:worker = $null
$script:job = $null          # Ordner des laufenden Vorlese-Auftrags
$script:jobNr = 1            # naechster abzuspielender Teil
$script:jobZaehler = 0
$script:mp3Wartet = $false
$script:mp3Start = [DateTime]::MinValue
$script:engine = ""
$script:clipNr = 0
$script:aktTeil = 0          # Teil, der gerade klingt
$script:synthStart = [DateTime]::MinValue
# Vorlese-Tempo in Prozent, 100 ist normal
$script:tempoStufen = @(70, 80, 90, 100, 110, 120, 135, 150, 175, 200)
$script:tempo = 100
$script:tick = 0
$script:lastSave = 0
$script:clipCache = ""
$script:clipGeprueft = [DateTime]::MinValue
$daten = Join-Path $env:APPDATA "Read und Write"
if ($Selbsttest) { $daten = Join-Path $env:TEMP "read-und-write-selbsttest-daten" }
# Einstellungen aus der frueheren Fassung "Auto Reading" einmalig uebernehmen
$datenAlt = Join-Path $env:APPDATA "Auto Reading"
if (-not (Test-Path $daten) -and (Test-Path $datenAlt)) { try { Copy-Item $datenAlt $daten -Recurse -Force } catch {} }
try { New-Item -ItemType Directory -Path $daten -Force | Out-Null } catch {}
$posFile = Join-Path $daten "position.txt"
$stimmenDatei = Join-Path $daten "stimme.txt"
$autoDatei = Join-Path $daten "auto.txt"
$tempoDatei = Join-Path $daten "tempo.txt"
$script:stimme = "de-DE-FlorianMultilingualNeural"
if (Test-Path $stimmenDatei) {
  try {
    $s = (Get-Content $stimmenDatei -Raw).Trim()
    if ($s -ne "") { $script:stimme = $s }
  } catch {}
}
# Reste alter Laeufe wegraeumen
try {
  Get-ChildItem $env:TEMP -Filter "auto-reading-*" -ErrorAction SilentlyContinue | Where-Object { $_.Name -match "^auto-reading-(job-|\d+\.mp3)" -and $_.LastWriteTime -lt (Get-Date).AddMinutes(-5) } | ForEach-Object { try { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
} catch {}

if (Test-Path $tempoDatei) {
  try {
    $t = [int]((Get-Content $tempoDatei -Raw).Trim())
    if ($t -ge 50 -and $t -le 250) { $script:tempo = $t }
  } catch {}
}

# Tempo fuer die Online-Stimme, 100 Prozent entspricht dem bisherigen Klang -5%
function Tempo-Netz {
  $r = $script:tempo - 105
  if ($r -ge 0) { return "+$r%" } else { return "$r%" }
}

# Tempo fuer die Windows-Stimme, Bereich -10 bis 10
function Tempo-Windows {
  $r = [int][math]::Round(($script:tempo - 100) / 10)
  return [math]::Max(-10, [math]::Min(10, $r))
}

function Kurz-Name($voll) {
  $k = $voll -replace "^de-DE-([A-Za-z]+).*$",'$1'
  $k -replace "Multilingual|Neural", ""
}

# Arbeitsflaeche des Bildschirms, auf dem der Punkt x,y liegt, in WPF-Einheiten.
# So bleibt der Knopf auch auf einem zweiten Bildschirm stehen, statt auf den
# Hauptbildschirm zurueckzuspringen. Liegt der Punkt auf keinem Bildschirm,
# nimmt Windows den naechstgelegenen.
function Flaeche($x, $y) {
  try {
    $f = 1.0
    try { $f = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width / [System.Windows.SystemParameters]::PrimaryScreenWidth } catch {}
    if ($f -le 0) { $f = 1.0 }
    $pt = New-Object System.Drawing.Point ([int]($x * $f)), ([int]($y * $f))
    $w = [System.Windows.Forms.Screen]::FromPoint($pt).WorkingArea
    return (New-Object System.Windows.Rect ($w.X / $f), ($w.Y / $f), ($w.Width / $f), ($w.Height / $f))
  } catch { return [System.Windows.SystemParameters]::WorkArea }
}

function Log-Zeile($text) {
  try { "$(Get-Date -Format 'HH:mm:ss') $text" | Add-Content (Join-Path $env:TEMP "auto-reading-log.txt") -Encoding ASCII } catch {}
}

# --- Stimmenauswahl ---
function Set-Stimme($name, $menue, $kurz) {
  $script:stimme = $name
  try { $name | Set-Content $stimmenDatei -Encoding ASCII } catch {}
  foreach ($m in @($MiKatja, $MiSeraphina, $MiConrad, $MiFlorian)) { $m.IsChecked = ($m -eq $menue) }
  $BtnSpeak.ToolTip = "Stimme: " + $kurz + " - klicken zum Vorlesen"
  # Laeuft gerade ein Vorlesen, an derselben Stelle mit der neuen Stimme weiter
  if ($state.Speaking -and $script:job -and ($script:engine -eq "mp3" -or $script:engine -eq "teilwin" -or $script:mp3Wartet)) {
    $rest = Rest-Ab-Hier
    if ($rest -ne "") {
      Log-Zeile "stimme $kurz, weiter ab aktueller stelle"
      $merk = $state.LastClip
      Start-Sprechen $rest
      $state.LastClip = $merk
      return
    }
  }
  Stop-Sprechen
  # Hoerprobe abspielen, aber den Vorlese-Knopf bedienbar lassen
  $probe = Join-Path $base ("stimme-" + $kurz.ToLower() + ".mp3")
  if (Test-Path $probe) {
    try { $script:player.Close() } catch {}
    try {
      $script:player.Open((New-Object System.Uri $probe))
      $script:player.Play()
      $script:engine = "probe"
      $state.Speaking = $false
      $state.Pausiert = $false
      Log-Zeile "stimme $kurz"
    } catch {}
  }
}

# Zwei Abspieler im Wechsel: waehrend einer spricht, laedt der andere schon
# den naechsten Teil. So entsteht zwischen den Teilen keine Ladepause.
$script:spieler = @((New-Object System.Windows.Media.MediaPlayer), (New-Object System.Windows.Media.MediaPlayer))
$script:player = $script:spieler[0]
$script:vorNr = 0            # Teil, der im anderen Abspieler bereitliegt

function Anderer-Spieler {
  if ([object]::ReferenceEquals($script:player, $script:spieler[0])) { return $script:spieler[1] }
  return $script:spieler[0]
}

function Vorladen {
  if (-not $script:job -or $script:engine -ne "mp3" -or $script:vorNr -eq $script:jobNr) { return }
  $f = Join-Path $script:job ("{0:D3}.mp3" -f $script:jobNr)
  if (Test-Path $f) {
    try {
      (Anderer-Spieler).Open((New-Object System.Uri $f))
      $script:vorNr = $script:jobNr
    } catch {}
  }
}

foreach ($sp in $script:spieler) {
  $sp.Volume = 1
  $sp.add_MediaEnded({
  param($quelle, $e)
  # Nur der Abspieler, der gerade dran ist, darf weiterschalten
  if (-not [object]::ReferenceEquals($quelle, $script:player)) { return }
  if ($script:engine -eq "mp3" -and $script:job) {
    # Teil zu Ende: sofort den naechsten Teil nachschieben
    $script:mp3Wartet = $true
    Naechster-Teil
  } elseif ($script:engine -eq "probe") {
    $script:engine = ""
    $state.Speaking = $false
    $state.Pausiert = $false
    Set-Symbol "aus"
  }
  })
}

$state = @{
  Auto = $false
  LastClip = ""
  Speaking = $false
  Pausiert = $false
  Engine = ""
}

function Get-ClipText {
  for ($i = 0; $i -lt 3; $i++) {
    try {
      if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        return [System.Windows.Forms.Clipboard]::GetText()
      }
      return ""
    } catch {
      Start-Sleep -Milliseconds 60
    }
  }
  return ""
}

# Waehrend des Vorlesens wird aus dem Lautsprecher Pause/Weiter und aus dem
# Mikrofon Stopp. So bleiben es immer vier gleich grosse Felder.
function Set-Symbol($zustand) {
  $lesen = ($zustand -eq "an" -or $zustand -eq "pause")
  $sicht = $(if ($lesen) { "Visible" } else { "Collapsed" })
  foreach ($el in @($BtnZurueck, $TrennZurueck, $BtnVor, $TrennVor)) { $el.Visibility = $sicht }
  # Beim Vorlesen sechs Felder, sonst vier, alle gleich gross
  $script:knopfBreite = $(if ($lesen) { 199 } else { 133 })
  if (-not $script:textOffen) { $win.Width = $script:knopfBreite }
  if ($lesen) {
    $BtnSpeak.Visibility = "Collapsed"
    $BtnPause.Visibility = "Visible"
    $BtnMikro.Visibility = "Collapsed"
    $BtnStopp.Visibility = "Visible"
    if ($zustand -eq "an") { $PauseIcon.Text = [char]0xE769; $PauseIcon.Foreground = "#FF5252" }
    else { $PauseIcon.Text = [char]0xE768; $PauseIcon.Foreground = "#7ED67E" }
  } else {
    $BtnSpeak.Visibility = "Visible"
    $BtnPause.Visibility = "Collapsed"
    $BtnMikro.Visibility = "Visible"
    $BtnStopp.Visibility = "Collapsed"
  }
}

# --- Rueckfall auf die Windows-Stimme ---
function Sprich-Fallback($text) {
  try { $synth.SpeakAsyncCancelAll() } catch {}
  try { $synth.Rate = Tempo-Windows } catch {}
  $script:synthStart = [DateTime]::Now
  try { $synth.SpeakAsync($text) | Out-Null } catch {}
  $script:engine = "windows"
  $state.Engine = "windows"
  $state.Speaking = $true
  $state.Pausiert = $false
  Set-Symbol "an"
  Log-Zeile "rueckfall windows-stimme"
}

# --- Sprechdienst starten oder pruefen ---
function Worker-Bereit {
  if ($script:py -eq "") { return $false }
  try { if ($script:worker -and -not $script:worker.HasExited) { return $true } } catch {}
  try {
    $si = New-Object System.Diagnostics.ProcessStartInfo
    $si.FileName = $script:py
    $a = ""
    foreach ($v in $script:pyVor) { $a += $v + " " }
    $si.Arguments = $a + "-u `"" + $script:speakpy + "`""
    $si.WorkingDirectory = $base
    $si.UseShellExecute = $false
    $si.CreateNoWindow = $true
    $si.RedirectStandardInput = $true
    $script:worker = [System.Diagnostics.Process]::Start($si)
    $script:worker.StandardInput.AutoFlush = $true
    Log-Zeile "sprechdienst gestartet"
    return $true
  } catch {
    Log-Zeile ("sprechdienst " + $_.Exception.Message)
    $script:worker = $null
    return $false
  }
}

function Worker-Senden($zeile) {
  try { $script:worker.StandardInput.WriteLine($zeile); return $true } catch { return $false }
}

function Worker-Ende {
  try { $script:worker.StandardInput.Close() } catch {}
  try { if (-not $script:worker.WaitForExit(800)) { $script:worker.Kill() } } catch {}
  $script:worker = $null
}

# --- Vorlesen starten, ohne die Oberflaeche zu blockieren ---
# Der Sprechdienst liefert den Text in Teilen 001.mp3, 002.mp3 ...
# Der erste Teil ist kurz und nach rund einer Sekunde da, der Rest
# entsteht, waehrend schon gesprochen wird.
function Start-Sprechen($text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  Stop-Sprechen
  $state.LastClip = $text
  $state.Engine = "netz"
  $state.Speaking = $true
  $state.Pausiert = $false
  Set-Symbol "an"
  if (-not (Internet-Da)) {
    Log-Zeile "kein netz, windows-stimme"
    Sprich-Fallback $text
    return
  }
  if (-not (Worker-Bereit)) {
    Log-Zeile "kein sprechdienst"
    Sprich-Fallback $text
    return
  }
  $script:jobZaehler++
  $ordner = Join-Path $env:TEMP ("auto-reading-job-" + $PID + "-" + $script:jobZaehler)
  try {
    New-Item -ItemType Directory -Force -Path $ordner | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ordner "text.txt"), $text, [System.Text.UTF8Encoding]::new($false))
  } catch {
    Sprich-Fallback $text
    return
  }
  $script:job = $ordner
  $script:jobNr = 1
  $script:aktTeil = 0
  $script:mp3Wartet = $true
  $script:mp3Start = [DateTime]::Now
  $zeile = $ordner + "`t" + $script:stimme + "`t" + (Tempo-Netz)
  if (-not (Worker-Senden $zeile)) {
    # Dienst war weg, einmal neu starten
    $script:worker = $null
    if (-not ((Worker-Bereit) -and (Worker-Senden $zeile))) {
      $script:mp3Wartet = $false
      $script:job = $null
      Sprich-Fallback $text
    }
  }
}

function Ende-Sprechen {
  $alt = $script:job
  $script:job = $null
  $script:mp3Wartet = $false
  $script:engine = ""
  $state.Speaking = $false
  $state.Pausiert = $false
  $state.Engine = ""
  Set-Symbol "aus"
  $script:vorNr = 0
  foreach ($sp in $script:spieler) { try { $sp.Close() } catch {} }
  if ($alt) { try { Remove-Item $alt -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
}

# --- Naechsten fertigen Teil abspielen ---
# Reihenfolge ist fest: es wird immer genau auf Teil jobNr gewartet.
# Ein Teil, den die Online-Stimme nicht liefern konnte (.fehlt), wird mit
# der Windows-Stimme gelesen, danach geht es normal weiter.
function Naechster-Teil {
  if (-not $script:job -or $state.Pausiert) { return }
  $basis = Join-Path $script:job ("{0:D3}" -f $script:jobNr)
  $anzahl = 0
  try { if (Test-Path (Join-Path $script:job "anzahl")) { $anzahl = [int](Get-Content (Join-Path $script:job "anzahl") -Raw) } } catch {}
  if ($anzahl -gt 0 -and $script:jobNr -gt $anzahl) {
    Ende-Sprechen
    return
  }
  if (Test-Path ($basis + ".mp3")) {
    try {
      if ($script:vorNr -eq $script:jobNr) {
        # Liegt schon bereit: nur umschalten und abspielen
        $alt = $script:player
        $script:player = Anderer-Spieler
        $script:player.Play()
        try { $alt.Close() } catch {}
      } else {
        $script:player.Open((New-Object System.Uri ($basis + ".mp3")))
        $script:player.Play()
      }
      $script:vorNr = 0
      $script:engine = "mp3"
      $state.Engine = "netz"
      $state.Speaking = $true
      $script:mp3Wartet = $false
      if ($script:jobNr -eq 1) { Log-Zeile ("erster teil nach " + [int](((Get-Date) - $script:mp3Start).TotalMilliseconds) + " ms, " + $script:stimme + " " + (Tempo-Netz)) }
      $script:aktTeil = $script:jobNr
      $script:jobNr++
      Vorladen
      return
    } catch {
      Log-Zeile ("mp3-fehler " + $_.Exception.Message)
    }
  }
  if (Test-Path ($basis + ".fehlt")) {
    $t = ""
    try { $t = [System.IO.File]::ReadAllText($basis + ".txt", [System.Text.Encoding]::UTF8) } catch {}
    Log-Zeile ("teil " + $script:jobNr + " mit windows-stimme")
    $script:aktTeil = $script:jobNr
    $script:jobNr++
    if ($t -ne "") {
      try { $synth.SpeakAsyncCancelAll() } catch {}
      try { $synth.Rate = Tempo-Windows } catch {}
      $script:synthStart = [DateTime]::Now
      try { $synth.SpeakAsync($t) | Out-Null } catch {}
      $script:engine = "teilwin"
      $state.Engine = "windows"
      $state.Speaking = $true
      $script:mp3Wartet = $false
    }
    return
  }
  if (Test-Path (Join-Path $script:job "ende")) {
    if ($script:jobNr -eq 1) {
      Log-Zeile "rueckfall, keine online-stimme"
      $t = $state.LastClip
      Ende-Sprechen
      Sprich-Fallback $t
    } else {
      Ende-Sprechen
    }
    return
  }
  $dienstWeg = $true
  try { $dienstWeg = $script:worker.HasExited } catch {}
  $wartet = ((Get-Date) - $script:mp3Start).TotalSeconds
  if ($dienstWeg -or ($script:jobNr -eq 1 -and $wartet -gt 25)) {
    # Dienst weg: den restlichen Text mit der Windows-Stimme fertig lesen
    Log-Zeile "sprechdienst antwortet nicht, rest mit windows-stimme"
    $rest = Rest-Text $script:jobNr
    if ($rest -eq "") { $rest = $state.LastClip }
    $script:worker = $null
    Ende-Sprechen
    Sprich-Fallback $rest
  }
}

# Text ab Teil nr bis zum Ende, aus den Teiltexten des Sprechdienstes
function Rest-Text($nr) {
  if (-not $script:job) { return "" }
  $teile = @()
  $i = [math]::Max(1, $nr)
  while ($true) {
    $f = Join-Path $script:job ("{0:D3}.txt" -f $i)
    if (-not (Test-Path $f)) { break }
    try { $teile += [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8) } catch { break }
    $i++
  }
  return ($teile -join " ")
}

# Text ab der Stelle, die gerade klingt: der laufende Teil wird anhand der
# Abspielposition auf den Anfang des aktuellen Satzteils (letztes Komma oder
# Satzende) gekuerzt. So muss man
# nach einem Stimm- oder Tempowechsel nichts doppelt hoeren.
function Rest-Ab-Hier {
  if (-not $script:job) { return "" }
  if ($script:mp3Wartet -or $script:aktTeil -lt 1) { return (Rest-Text ([math]::Max(1, $script:jobNr))) }
  $ab = $script:aktTeil
  $erster = ""
  try { $erster = [System.IO.File]::ReadAllText((Join-Path $script:job ("{0:D3}.txt" -f $ab)), [System.Text.Encoding]::UTF8) } catch {}
  if ($erster -ne "" -and $script:engine -eq "mp3") {
    try {
      $d = $script:player.NaturalDuration
      if ($d.HasTimeSpan -and $d.TimeSpan.TotalSeconds -gt 0) {
        $pos = [int]($erster.Length * ($script:player.Position.TotalSeconds / $d.TimeSpan.TotalSeconds))
        $start = 0
        foreach ($m in [regex]::Matches($erster, '[.!?:;,]\s')) { if ($m.Index + 2 -le $pos) { $start = $m.Index + 2 } }
        $erster = $erster.Substring($start)
      }
    } catch {}
  }
  return (($erster + " " + (Rest-Text ($ab + 1))).Trim())
}

# Vor- und Zurueckspulen im laufenden Teil, an den Grenzen in den
# vorigen oder naechsten Teil
function Spulen($sek) {
  if (-not $script:job -or $script:engine -ne "mp3" -or $script:mp3Wartet) { return }
  $p = $script:player
  $jetzt = $p.Position.TotalSeconds
  $neu = $jetzt + $sek
  $dauer = 0
  try { if ($p.NaturalDuration.HasTimeSpan) { $dauer = $p.NaturalDuration.TimeSpan.TotalSeconds } } catch {}
  if ($neu -lt 0) {
    if ($jetzt -lt 2 -and $script:aktTeil -gt 1) {
      try { $p.Stop() } catch {}
      $script:jobNr = $script:aktTeil - 1
      $script:vorNr = 0
      $script:mp3Wartet = $true
      Naechster-Teil
    } else {
      $p.Position = [TimeSpan]::Zero
    }
    return
  }
  if ($dauer -gt 0 -and $neu -ge $dauer - 0.3) {
    try { $p.Stop() } catch {}
    $script:mp3Wartet = $true
    Naechster-Teil
    return
  }
  $p.Position = [TimeSpan]::FromSeconds($neu)
}

# --- Tempo einstellen ---
# Laeuft gerade eine Wiedergabe, geht es ab dem aktuellen Teil im neuen
# Tempo weiter, statt von vorn anzufangen.
function Set-Tempo($neu) {
  $neu = [math]::Max($script:tempoStufen[0], [math]::Min($script:tempoStufen[-1], [int]$neu))
  $script:tempo = $neu
  try { "$neu" | Set-Content $tempoDatei -Encoding ASCII } catch {}
  Tempo-Anzeige
  if ($state.Speaking -and $script:job -and ($script:engine -eq "mp3" -or $script:engine -eq "teilwin" -or $script:mp3Wartet)) {
    $rest = Rest-Ab-Hier
    if ($rest -ne "") {
      $merk = $state.LastClip
      Start-Sprechen $rest
      $state.LastClip = $merk
    }
  } elseif ($state.Speaking -and $state.Engine -eq "windows") {
    try { $synth.Rate = Tempo-Windows } catch {}
  }
}

function Tempo-Schritt($richtung) {
  $st = $script:tempoStufen
  $i = 0
  for ($k = 0; $k -lt $st.Count; $k++) {
    if ([math]::Abs($st[$k] - $script:tempo) -lt [math]::Abs($st[$i] - $script:tempo)) { $i = $k }
  }
  $i = [math]::Max(0, [math]::Min($st.Count - 1, $i + $richtung))
  Set-Tempo $st[$i]
}

function Tempo-Anzeige {
  try { $TempoText.Text = "Tempo " + $script:tempo + " %" } catch {}
  try {
    foreach ($m in $MiTempo.Items) { $m.IsChecked = ([int]$m.Tag -eq $script:tempo) }
    $MiTempo.Header = "Geschwindigkeit: " + $script:tempo + " %"
  } catch {}
}

function Anhalten {
  if ($state.Engine -eq "windows") { try { $synth.Pause() } catch {} }
  else { try { $script:player.Pause() } catch {} }
  $state.Pausiert = $true
  Set-Symbol "pause"
}

function Fortsetzen {
  $state.Pausiert = $false
  Set-Symbol "an"
  if ($state.Engine -eq "windows") { try { $synth.Resume() } catch {} }
  elseif ($script:mp3Wartet) { Naechster-Teil }
  else { try { $script:player.Play() } catch {} }
}

# Gespeichert wird immer die Lage des kleinen Knopfes. Solange das
# Textfenster offen ist, kann das grosse Fenster verschoben sein, damit es
# auf den Bildschirm passt. Beim Zuklappen springt der Knopf zurueck.
$script:textOffen = $false
$script:knopfX = 0
$script:knopfY = 0
$script:textDx = 0
$script:knopfBreite = 133
function Save-Position {
  try {
    if ($script:textOffen) { $x = $script:knopfX; $y = $script:knopfY }
    else { $x = $win.Left; $y = $win.Top }
    "$([int]$x);$([int]$y)" | Set-Content $posFile -Encoding ASCII
  } catch {}
}

function Textfenster($an) {
  try {
    if ($an) {
      $t = Get-ClipText
      if (-not [string]::IsNullOrWhiteSpace($t)) { $Klartext.Text = $t }
      if (-not $script:textOffen) { $script:knopfX = $win.Left; $script:knopfY = $win.Top }
      $script:textOffen = $true
      $TextZone.Visibility = "Visible"
      # Die Zeile muss fest sein, sonst waechst das Textfeld mit dem Text
      # und laesst sich nicht mehr scrollen.
      $ZeilenRow.Height = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
      try { if ($script:handle -ne [IntPtr]::Zero) { [TaskbarHelper]::OhneFokus($script:handle, $false) } } catch {}
      $win.Width = 420
      $win.Height = 340
      # Das grosse Fenster so legen, dass es ganz sichtbar ist. Der Knopf
      # bleibt stehen, das Fenster klappt nach rechts auf. Nur wenn rechts
      # kein Platz ist, nach links. Nach oben, wenn unten kein Platz ist.
      $wa = Flaeche ($script:knopfX + 20) ($script:knopfY + 16)
      $nx = $script:knopfX
      if ($nx + 420 -gt $wa.Right - 4) { $nx = $script:knopfX + $script:knopfBreite - 420 }
      if ($nx -lt $wa.Left) { $nx = $wa.Left }
      $script:textDx = $script:knopfX - $nx
      $ny = $script:knopfY
      if ($ny + 340 -gt $wa.Bottom - 5) { $ny = $script:knopfY + 32 - 340 }
      if ($ny -lt $wa.Top) { $ny = $wa.Top }
      $win.Left = $nx
      $win.Top = $ny
      # Fenster aktivieren, sonst laeuft das Mausrad an einem anderen Fenster
      try { $win.Activate() } catch {}
      try { if ($script:handle -ne [IntPtr]::Zero) { [TaskbarHelper]::Aktiv($script:handle) } } catch {}
      try { $Klartext.Focus() } catch {}
      try { $Klartext.CaretIndex = 0; $Klartext.ScrollToHome() } catch {}
    } else {
      $TextZone.Visibility = "Collapsed"
      try { if ($script:handle -ne [IntPtr]::Zero) { [TaskbarHelper]::OhneFokus($script:handle, $true) } } catch {}
      $ZeilenRow.Height = [System.Windows.GridLength]::new(0, [System.Windows.GridUnitType]::Auto)
      $win.Width = $script:knopfBreite
      $win.Height = 32
      if ($script:textOffen) {
        $script:textOffen = $false
        $win.Left = $script:knopfX
        $win.Top = $script:knopfY
      }
      Save-Position
    }
  } catch {}
}

function Stop-Sprechen {
  if ($script:job) { Worker-Senden "STOP" | Out-Null }
  foreach ($sp in $script:spieler) { try { $sp.Stop() } catch {} }
  try { $synth.SpeakAsyncCancelAll() } catch {}
  Ende-Sprechen
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class TaskbarHelper {
    [DllImport("user32.dll", EntryPoint="GetWindowLong")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint="SetWindowLong")]
    static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll", EntryPoint="SendMessage")]
    static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", EntryPoint="SetWindowPos")]
    static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll", EntryPoint="SetForegroundWindow")]
    static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", EntryPoint="BringWindowToTop")]
    static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("shell32.dll", EntryPoint="SHChangeNotify")]
    static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
    public static void Show(IntPtr h) {
        int ex = GetWindowLong(h, -20);
        SetWindowLong(h, -20, ex | 0x00040000);
    }
    // Ohne Fokus: Klicks auf den Knopf nehmen dem Textfeld, in dem man
    // gerade schreibt, nicht den Fokus weg. Fuer das Textfenster wieder aus.
    public static void OhneFokus(IntPtr h, bool an) {
        int ex = GetWindowLong(h, -20);
        if (an) ex |= 0x08000000; else ex &= ~0x08000000;
        SetWindowLong(h, -20, ex);
    }
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    public static void SetIcon(IntPtr h, IntPtr gross, IntPtr klein) {
        SendMessage(h, 0x0080, (IntPtr)1, gross);
        SendMessage(h, 0x0080, (IntPtr)0, klein);
        SHChangeNotify(0x08000000, 0x0000, IntPtr.Zero, IntPtr.Zero);
    }
    public static void InDenVordergrund(IntPtr h) {
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }
    public static void Aktiv(IntPtr h) {
        BringWindowToTop(h);
        SetForegroundWindow(h);
    }
    // Zaehlt jede Aenderung der Zwischenablage, kostet praktisch nichts
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vk);
    // Wurde seit der letzten Abfrage eine Maustaste gedrueckt?
    public static bool LinksUnten() { return (GetAsyncKeyState(0x01) & 0x8000) != 0; }
    public static bool MausGedrueckt() {
        bool g = false;
        foreach (int vk in new int[] { 0x01, 0x02, 0x04 }) { if ((GetAsyncKeyState(vk) & 0x8001) != 0) g = true; }
        return g;
    }

    // --- Windows-Spracheingabe (wie Windows-Taste + H) ohne sichtbares Fenster ---
    [DllImport("user32.dll")]
    static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    public static void Spracheingabe() {
        keybd_event(0x5B, 0, 0, UIntPtr.Zero);
        keybd_event(0x48, 0, 0, UIntPtr.Zero);
        keybd_event(0x48, 0, 2, UIntPtr.Zero);
        keybd_event(0x5B, 0, 2, UIntPtr.Zero);
    }
    delegate bool EnumCb(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumCb cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint k, byte a, uint f);
    [DllImport("user32.dll", EntryPoint="SetWindowPos", SetLastError=true)] static extern bool FensterSchieben(IntPtr h, IntPtr nach, int x, int y, int cx, int cy, uint f);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    static int altX = int.MinValue, altY = int.MinValue;
    // Das Fenster "Windows-Eingabeerfahrung" von TextInputHost zeigt die
    // Spracheingabe an. Es wird waehrend des Diktats aus dem Bildschirm
    // geschoben und durchsichtig gemacht: es hoert weiter zu, man sieht es nur nicht.
    public static string EingabeUnsichtbar(int pid, bool unsichtbar) {
        string bericht = "";
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != (uint)pid) return true;
            var c = new System.Text.StringBuilder(64);
            GetClassName(h, c, 64);
            if (c.ToString() != "Windows.UI.Core.CoreWindow") return true;
            RECT r; GetWindowRect(h, out r);
            int ex = GetWindowLong(h, -20);
            if (unsichtbar) {
                if (r.L > -20000) { altX = r.L; altY = r.T; }
                bool ok = FensterSchieben(h, IntPtr.Zero, -32000, -32000, 0, 0, 0x0001 | 0x0004 | 0x0010);
                int fehler = Marshal.GetLastWin32Error();
                if ((ex & 0x80000) == 0) SetWindowLong(h, -20, ex | 0x80000);
                SetLayeredWindowAttributes(h, 0, 0, 2);
                RECT n; GetWindowRect(h, out n);
                bericht += "weg " + ok + "/" + fehler + " " + r.L + "," + r.T + " -> " + n.L + "," + n.T + "; ";
            } else {
                if (altX != int.MinValue && r.L <= -20000) FensterSchieben(h, IntPtr.Zero, altX, altY, 0, 0, 0x0001 | 0x0004 | 0x0010);
                if ((ex & 0x80000) != 0) {
                    SetLayeredWindowAttributes(h, 0, 255, 2);
                    SetWindowLong(h, -20, ex & ~0x80000);
                }
                bericht += "sichtbar; ";
            }
            return true;
        }, IntPtr.Zero);
        return bericht;
    }
}

// Taskleisten-Eigenschaften des Fensters: eigene App-Kennung, Symbol und
// Startbefehl. Damit zeigt Windows unten das Auto-Reading-Symbol und nicht
// PowerShell, auch beim Anheften.
public static class FensterApp {
    [StructLayout(LayoutKind.Sequential, Pack=4)]
    public struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit, Size=16)]
    public struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out uint c);
        int GetAt(uint i, out PROPERTYKEY k);
        int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
        int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
        int Commit();
    }
    [DllImport("shell32.dll")]
    static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore ps);
    static readonly Guid FMT = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    static void Setze(IPropertyStore ps, uint pid, string wert) {
        PROPERTYKEY k = new PROPERTYKEY(); k.fmtid = FMT; k.pid = pid;
        PROPVARIANT v = new PROPVARIANT(); v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(wert);
        ps.SetValue(ref k, ref v);
        Marshal.FreeCoTaskMem(v.p);
    }
    public static void Setzen(IntPtr h, string id, string befehl, string symbol, string name) {
        Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        IPropertyStore ps;
        if (SHGetPropertyStoreForWindow(h, ref iid, out ps) != 0 || ps == null) return;
        Setze(ps, 5, id);
        Setze(ps, 2, befehl);
        Setze(ps, 3, symbol);
        Setze(ps, 4, name);
        ps.Commit();
        Marshal.ReleaseComObject(ps);
    }
}
"@

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Read &amp; Write" Width="133" Height="32"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="True">
  <Window.Resources>
    <Style x:Key="Flach" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Cursor" Value="Arrow"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Rahmen" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Rahmen" Property="Background" Value="#525252"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Rahmen" Property="Background" Value="#6E6E6E"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border Background="#2B2B2B" CornerRadius="8" BorderBrush="#3D3D3D" BorderThickness="1">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="32"/>
        <RowDefinition x:Name="ZeilenRow" Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid x:Name="Bar" Cursor="Arrow">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="32"/>
        <ColumnDefinition Width="1"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="32"/>
        <ColumnDefinition Width="1"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="32"/>
        <ColumnDefinition Width="1"/>
        <ColumnDefinition Width="32"/>
      </Grid.ColumnDefinitions>
      <Rectangle x:Name="GripHit" Width="32" Height="32" Fill="Transparent"
                 HorizontalAlignment="Center" VerticalAlignment="Center"
                 Cursor="SizeAll" ToolTip="Ziehen zum Verschieben"/>
      <Rectangle Width="3" Height="14" RadiusX="1.5" RadiusY="1.5" Fill="#8A8A8A"
                 HorizontalAlignment="Center" VerticalAlignment="Center" IsHitTestVisible="False"/>
      <Rectangle Grid.Column="1" Width="1" Fill="#3A3A3A" Margin="0,8,0,8"/>
      <Button x:Name="BtnZurueck" Grid.Column="2" Width="32" Style="{StaticResource Flach}" Visibility="Collapsed"
              VerticalAlignment="Stretch" VerticalContentAlignment="Center" ToolTip="10 Sekunden zurück">
        <TextBlock Text="&#xEB9E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Foreground="#E8E8E8"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Button>
      <Rectangle x:Name="TrennZurueck" Grid.Column="3" Width="1" Fill="#3A3A3A" Margin="0,8,0,8" Visibility="Collapsed"/>
      <Button x:Name="BtnSpeak" Grid.Column="4" Style="{StaticResource Flach}"
              VerticalAlignment="Stretch" VerticalContentAlignment="Center"
              ToolTip="Kopierten Text vorlesen">
        <TextBlock x:Name="SpkIcon" Text="&#xE767;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                   FontSize="16" Foreground="#F2F2F2"
                   TextOptions.TextRenderingMode="Grayscale"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Button>
      <Button x:Name="BtnPause" Grid.Column="4" Style="{StaticResource Flach}" Visibility="Collapsed"
              VerticalAlignment="Stretch" VerticalContentAlignment="Center"
              ToolTip="Pause oder weiter">
        <TextBlock x:Name="PauseIcon" Text="&#xE769;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                   FontSize="14" Foreground="#FF5252"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Button>
      <Rectangle Grid.Column="5" Width="1" Fill="#3A3A3A" Margin="0,8,0,8"/>
      <Button x:Name="BtnVor" Grid.Column="6" Width="32" Style="{StaticResource Flach}" Visibility="Collapsed"
              VerticalAlignment="Stretch" VerticalContentAlignment="Center" ToolTip="10 Sekunden vor">
        <TextBlock Text="&#xEB9D;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="14" Foreground="#E8E8E8"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Button>
      <Rectangle x:Name="TrennVor" Grid.Column="7" Width="1" Fill="#3A3A3A" Margin="0,8,0,8" Visibility="Collapsed"/>
      <Button x:Name="BtnMikro" Grid.Column="8" Style="{StaticResource Flach}"
              VerticalAlignment="Stretch" VerticalContentAlignment="Center"
              ToolTip="Diktieren: in ein Textfeld klicken, dann hier klicken und sprechen. Nochmal klicken beendet.">
        <TextBlock x:Name="MikroIcon" Text="&#xE720;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                   FontSize="16" Foreground="#F2F2F2"
                   TextOptions.TextRenderingMode="Grayscale"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Button>
      <Button x:Name="BtnStopp" Grid.Column="8" Style="{StaticResource Flach}" Visibility="Collapsed"
              VerticalAlignment="Stretch" VerticalContentAlignment="Center"
              ToolTip="Vorlesen ganz stoppen">
        <TextBlock Text="&#xE71A;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                   FontSize="14" Foreground="#E8E8E8"
                   HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Button>
      <Rectangle Grid.Column="9" Width="1" Fill="#3A3A3A" Margin="0,8,0,8"/>
      <Button x:Name="BtnDots" Grid.Column="10" Content="&#x2022;&#x2022;&#x2022;" FontSize="10" FontWeight="Bold"
              Foreground="White" Style="{StaticResource Flach}" Padding="0" Margin="0,0,0,2"
              VerticalAlignment="Stretch" VerticalContentAlignment="Center"
              HorizontalAlignment="Stretch" HorizontalContentAlignment="Center" ToolTip="Menü">
        <Button.ContextMenu>
          <ContextMenu x:Name="KnopfMenue" Placement="Bottom" HorizontalOffset="0" VerticalOffset="6" StaysOpen="True">
            <MenuItem x:Name="MiAuto" Header="Auto-Vorlesen" IsCheckable="True" IsChecked="False"/>
            <MenuItem x:Name="MiStopp" Header="Stopp"/>
            <MenuItem x:Name="MiText" Header="Text zeigen" IsCheckable="True" IsChecked="False"/>
            <MenuItem x:Name="MiTempo" Header="Geschwindigkeit"/>
            <MenuItem x:Name="MiDiktat" Header="Diktieren">
              <MenuItem x:Name="MiOnline" Header="Online: Windows-Spracheingabe" IsCheckable="True"
                        ToolTip="Schnell und genau, braucht Internet. Es öffnet sich das Diktierfenster von Windows."/>
              <MenuItem x:Name="MiOffline" Header="Offline: auf diesem Rechner" IsCheckable="True"
                        ToolTip="Ohne Internet, alles bleibt auf dem Rechner. Schreibt Wort für Wort live mit und bessert jeden Satz danach aus."/>
              <Separator/>
              <MenuItem Header="Ohne Internet wird automatisch offline diktiert" IsEnabled="False"/>
            </MenuItem>
            <Separator/>
            <MenuItem x:Name="MiKatja" Header="Stimme Katja  (Frau, klar)" IsCheckable="True"/>
            <MenuItem x:Name="MiConrad" Header="Stimme Conrad  (Mann, klar)" IsCheckable="True"/>
            <MenuItem x:Name="MiSeraphina" Header="Stimme Seraphina  (Frau, lebendig)" IsCheckable="True"/>
            <MenuItem x:Name="MiFlorian" Header="Stimme Florian  (Mann, lebendig)" IsCheckable="True"/>
            <Separator/>
            <MenuItem x:Name="MiAnleitung" Header="Anleitung"/>
            <MenuItem x:Name="MiExit" Header="Beenden"/>
          </ContextMenu>
        </Button.ContextMenu>
      </Button>
      </Grid>
      <Grid x:Name="TextZone" Grid.Row="1" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBox x:Name="Klartext" Margin="8,4,8,4" AcceptsReturn="True" TextWrapping="Wrap"
                 VerticalScrollBarVisibility="Visible" HorizontalScrollBarVisibility="Disabled"
                 Background="#1E1E1E" Foreground="#E8E8E8"
                 BorderBrush="#3D3D3D" BorderThickness="1" FontSize="12" Padding="4"
                 ToolTip="Zwischenspeicher, hier schreiben oder einsetzen. Mausrad scrollt, Bild auf und ab blättert."/>
        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Margin="8,0,0,8">
          <Button x:Name="BtnLangsamer" Width="26" Height="24" Style="{StaticResource Flach}" ToolTip="Langsamer vorlesen">
            <TextBlock Text="&#xE738;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="#E8E8E8"/>
          </Button>
          <TextBlock x:Name="TempoText" Text="Tempo 100 %" Width="78" TextAlignment="Center" VerticalAlignment="Center"
                     FontSize="12" Foreground="#E8E8E8" ToolTip="Vorlese-Geschwindigkeit, bleibt gespeichert"/>
          <Button x:Name="BtnSchneller" Width="26" Height="24" Style="{StaticResource Flach}" ToolTip="Schneller vorlesen">
            <TextBlock Text="&#xE710;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="11" Foreground="#E8E8E8"/>
          </Button>
        </StackPanel>
        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="8,0,10,8">
          <Button x:Name="BtnUebernehmen" Content="Vorlesen" MinWidth="80" Style="{StaticResource Flach}"
                  FontSize="12" Foreground="#E8E8E8" ToolTip="Text aus diesem Feld vorlesen, er wird dabei auch in die Zwischenablage kopiert"/>
          <Button x:Name="BtnTextZu" Content="Zuklappen" MinWidth="80" Margin="6,0,0,0" Style="{StaticResource Flach}"
                  FontSize="12" Foreground="#E8E8E8"/>
        </StackPanel>
      </Grid>
    </Grid>
  </Border>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [System.Windows.Markup.XamlReader]::Load($reader)
$BtnSpeak = $win.FindName("BtnSpeak")
$BtnDots = $win.FindName("BtnDots")
$BtnMikro = $win.FindName("BtnMikro")
$MikroIcon = $win.FindName("MikroIcon")
$Bar = $win.FindName("Bar")
$GripHit = $win.FindName("GripHit")
$SpkIcon = $win.FindName("SpkIcon")
$BtnPause = $win.FindName("BtnPause")
$BtnStopp = $win.FindName("BtnStopp")
$BtnZurueck = $win.FindName("BtnZurueck")
$BtnVor = $win.FindName("BtnVor")
$TrennZurueck = $win.FindName("TrennZurueck")
$TrennVor = $win.FindName("TrennVor")
$PauseIcon = $win.FindName("PauseIcon")
$MiAuto = $win.FindName("MiAuto")
$MiStopp = $win.FindName("MiStopp")
$MiText = $win.FindName("MiText")
$MiKatja = $win.FindName("MiKatja")
$MiSeraphina = $win.FindName("MiSeraphina")
$MiConrad = $win.FindName("MiConrad")
$MiFlorian = $win.FindName("MiFlorian")
$MiExit = $win.FindName("MiExit")
$MiAnleitung = $win.FindName("MiAnleitung")
# Das Menue am Drei-Punkte-Knopf verankern, damit es direkt daneben aufgeht
$KnopfMenue = $BtnDots.ContextMenu
if (-not $KnopfMenue) { try { $KnopfMenue = $win.FindName("KnopfMenue") } catch {} }
if ($KnopfMenue) {
  try {
    $KnopfMenue.PlacementTarget = $BtnDots
    $KnopfMenue.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
  } catch {}
}
$TextZone = $win.FindName("TextZone")
$ZeilenRow = $win.FindName("ZeilenRow")
$Klartext = $win.FindName("Klartext")
$BtnUebernehmen = $win.FindName("BtnUebernehmen")
$BtnTextZu = $win.FindName("BtnTextZu")
$BtnLangsamer = $win.FindName("BtnLangsamer")
$BtnSchneller = $win.FindName("BtnSchneller")
$TempoText = $win.FindName("TempoText")
$MiTempo = $win.FindName("MiTempo")
$MiDiktat = $win.FindName("MiDiktat")
$MiOnline = $win.FindName("MiOnline")
$MiOffline = $win.FindName("MiOffline")
# Untermenue Geschwindigkeit mit allen Stufen
foreach ($st in $script:tempoStufen) {
  $mi = New-Object System.Windows.Controls.MenuItem
  $mi.Header = "$st %" + $(if ($st -eq 100) { "  normal" } else { "" })
  $mi.Tag = $st
  $mi.IsCheckable = $true
  $mi.Add_Click({ param($s, $e) Set-Tempo ([int]$s.Tag) })
  [void]$MiTempo.Items.Add($mi)
}
Tempo-Anzeige
try { $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]((Join-Path $base "read-und-write.ico"))) } catch {}
# Das Lautsprecher-Zeichen im Knopf ist die Windows-Schrift Segoe Fluent Icons,
# Zeichen E767, also exakt das Windows-Lautstaerke-Symbol, gestochen scharf.
$script:iconGross = [IntPtr]::Zero
$script:iconKlein = [IntPtr]::Zero
try {
  $icoPfad = Join-Path $base "read-und-write.ico"
  # Groessen passend zur Bildschirm-Skalierung, damit nichts unscharf hochgerechnet wird
  $ig = [System.Windows.Forms.SystemInformation]::IconSize.Width
  $ik = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
  $script:iconGross = (New-Object System.Drawing.Icon($icoPfad, $ig, $ig)).Handle
  $script:iconKlein = (New-Object System.Drawing.Icon($icoPfad, $ik, $ik)).Handle
} catch {}
foreach ($m in @($MiKatja, $MiSeraphina, $MiConrad, $MiFlorian)) {
  if ($script:stimme -like ("*" + $m.Header.ToString().Split(" ")[1] + "*")) { $m.IsChecked = $true }
  else { $m.IsChecked = $false }
}
$BtnSpeak.ToolTip = "Stimme: " + (Kurz-Name $script:stimme) + " - klicken zum Vorlesen"
if (Test-Path $autoDatei) {
  try { if ((Get-Content $autoDatei -Raw).Trim() -eq "an") { $state.Auto = $true; $MiAuto.IsChecked = $true } } catch {}
}

$wa = [System.Windows.SystemParameters]::WorkArea
$win.Left = $wa.Right - $win.Width - 24
$win.Top = $wa.Bottom - $win.Height - 70
if (Test-Path $posFile) {
  try {
    $p = (Get-Content $posFile -Raw).Split(";")
    $x = [double]$p[0]; $y = [double]$p[1]
    $wa = Flaeche ($x + 20) ($y + 16)
    if ($x -ge $wa.Left -and $x -le $wa.Right - $win.Width - 4 -and $y -ge $wa.Top -and $y -le $wa.Bottom - $win.Height - 5) { $win.Left = $x; $win.Top = $y }
  } catch {}
}

$script:handle = [IntPtr]::Zero

# Kein Absturz bei Fehlern im Betrieb, der Knopf laeuft weiter
try {
  [System.Windows.Threading.Dispatcher]::CurrentDispatcher.add_UnhandledException({
    param($sender, $args)
    try { $args.Handled = $true } catch {}
    try { Log-Zeile ("abgefangen " + $args.Exception.Message) } catch {}
  })
} catch {}

# Nur der Greifbereich zieht das Fenster. Ein Zieh-Handler auf der ganzen
# Leiste wuerde die Klicks auf die Schaltflaechen verschlucken, weil das
# Mausrad und die Maustaste dann im Fenster hängen bleiben.
$GripHit.Add_MouseLeftButtonDown({
  param($s,$e)
  try { $win.DragMove() } catch {}
  # Wurde bei offenem Textfenster gezogen, gilt die neue Lage auch fuer den Knopf
  if ($script:textOffen) {
    $script:knopfX = $win.Left + $script:textDx
    $script:knopfY = $win.Top
  }
  Save-Position
})
# Diktieren ueber den Hoer-Dienst hoeren.py: nimmt das Mikrofon selbst auf und
# schreibt mit dem Sprachmodell Whisper lokal mit, ohne Windows-Diktierfenster.
# Er tippt jeden erkannten Satz in das Feld, in dem der Cursor steht, und folgt
# jedem Klick in ein anderes Feld. Der Dienst bleibt nach dem ersten Start
# geladen, damit jedes weitere Diktat sofort beginnt.
# Farbe des Mikrofons: orange = Sprachmodell laedt, rot = hoert zu.
$script:diktat = $false
$script:hoerer = $null
$script:hoerZustand = Join-Path $env:TEMP "auto-reading-hoeren.txt"
$script:hoerZuletzt = ""
function Diktat-Anzeige {
  $z = $script:hoerZuletzt
  if (-not $script:diktat) {
    $MikroIcon.Foreground = "#F2F2F2"
    $BtnMikro.ToolTip = "Diktieren: in ein Textfeld klicken, dann hier klicken und sprechen. Nochmal klicken beendet."
  } elseif ($z -eq "laedt" -or $z -eq "") {
    $MikroIcon.Foreground = "#FFB74D"
    $BtnMikro.ToolTip = "Sprachmodell wird geladen, beim allerersten Mal dauert das etwa zwei Minuten"
  } else {
    $MikroIcon.Foreground = "#FF5252"
    $BtnMikro.ToolTip = "Hört zu, klicken zum Beenden"
  }
}
function Hoerer-Senden($befehl) {
  try { $script:hoerer.StandardInput.WriteLine($befehl); return $true } catch { return $false }
}
# Startet den Hoer-Dienst, ohne zuzuhoeren. Wird kurz nach dem App-Start
# aufgerufen, damit das Sprachmodell beim ersten Klick schon geladen ist.
function Hoerer-Starten {
  if ($script:py -eq "") { return $false }
  $laeuft = $false
  try { $laeuft = ($script:hoerer -and -not $script:hoerer.HasExited) } catch {}
  if (-not $laeuft) {
    try { Remove-Item $script:hoerZustand -Force -ErrorAction SilentlyContinue } catch {}
    $script:hoerZuletzt = ""
    try {
      $si = New-Object System.Diagnostics.ProcessStartInfo
      $si.FileName = $script:py
      $a = ""
      foreach ($v in $script:pyVor) { $a += $v + " " }
      $si.Arguments = $a + "-u `"" + (Join-Path $base "hoeren.py") + "`""
      $si.WorkingDirectory = $base
      $si.UseShellExecute = $false
      $si.CreateNoWindow = $true
      $si.RedirectStandardInput = $true
      $si.EnvironmentVariables["HF_HUB_DISABLE_SYMLINKS_WARNING"] = "1"
      # Im Selbsttest nichts tippen, nur protokollieren
      if ($Selbsttest) { $si.EnvironmentVariables["HOEREN_TEST"] = "1" }
      $script:hoerer = [System.Diagnostics.Process]::Start($si)
      $script:hoerer.StandardInput.AutoFlush = $true
    } catch {
      Log-Zeile ("diktat " + $_.Exception.Message)
      $script:hoerer = $null
      return $false
    }
  }
  return $true
}
function Diktat-Start {
  if ($script:py -eq "") {
    [System.Windows.MessageBox]::Show("Zum Diktieren wird Python gebraucht. Bitte Read & Write neu installieren.", "Read & Write") | Out-Null
    return
  }
  if (-not (Hoerer-Starten)) { return }
  $script:hoerZuletzt = ""
  try { $script:hoerZuletzt = (Get-Content $script:hoerZustand -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).Trim() } catch {}
  if (Hoerer-Senden "START") {
    $script:diktat = $true
    Log-Zeile "diktat an"
  }
  Diktat-Anzeige
}
function Diktat-Stopp {
  $script:diktat = $false
  Hoerer-Senden "STOP" | Out-Null
  Diktat-Anzeige
  Log-Zeile "diktat aus"
}
function Hoerer-Ende {
  $p = $script:hoerer
  $script:hoerer = $null
  if ($p) {
    try { $p.StandardInput.Close() } catch {}
    try { if (-not $p.WaitForExit(1500)) { $p.Kill() } } catch {}
  }
}
# Vom Timer aufgerufen: Zustand anzeigen, bei Fehlern den Grund melden
function Diktat-Pruefen {
  if (-not $script:diktat -or $script:onlineOffen) { return }
  $z = ""
  try { $z = (Get-Content $script:hoerZustand -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).Trim() } catch {}
  if ($z -ne $script:hoerZuletzt) { $script:hoerZuletzt = $z; Diktat-Anzeige }
  $weg = $true
  try { $weg = $script:hoerer.HasExited } catch {}
  if (-not $weg -and $z -notlike "fehler*") { return }
  $script:diktat = $false
  Hoerer-Ende
  Diktat-Anzeige
  Log-Zeile ("diktat beendet: " + $z)
  if ($z -like "fehler*") {
    [System.Windows.MessageBox]::Show("Diktieren hat nicht geklappt: " + $z.Substring(7), "Read & Write") | Out-Null
  }
}
# --- Wahl der Diktat-Art ---
# Online:  Windows-Spracheingabe wie Windows-Taste + H, mit ihrem eigenen Fenster.
#          Schnell und genau, braucht Internet. Der Knopf ist dann nur der Ausloeser,
#          ein- und ausgeschaltet wird im Windows-Fenster oder per erneutem Klick.
# Offline: Whisper auf dem Rechner, hoeren.py. Ohne Internet, etwas langsamer.
# Ist Online gewaehlt, aber kein Internet da, wird automatisch offline diktiert.
$diktatDatei = Join-Path $daten "diktat.txt"
$script:diktatOnline = $true
if (Test-Path $diktatDatei) { try { $script:diktatOnline = ((Get-Content $diktatDatei -Raw).Trim() -notin @("whisper", "offline")) } catch {} }
function Diktat-Wahl-Anzeige {
  $MiOnline.IsChecked = $script:diktatOnline
  $MiOffline.IsChecked = -not $script:diktatOnline
  $MiDiktat.Header = "Diktieren: " + $(if ($script:diktatOnline) { "online" } else { "offline" })
}
function Diktat-Wahl($online) {
  # Wird Offline gewaehlt, das Windows-Diktierfenster auf jeden Fall schliessen,
  # auch wenn es von Hand geoeffnet oder schon wieder geschlossen wurde
  $warOffen = $script:onlineOffen
  if (-not $warOffen -and $script:diktat) { Diktat-Stopp }
  if ($warOffen -or (-not $online -and $script:diktatOnline)) { Online-Aus $true }
  $script:diktatOnline = $online
  try { $(if ($online) { "online" } else { "offline" }) | Set-Content $diktatDatei -Encoding ASCII } catch {}
  Diktat-Wahl-Anzeige
  if (-not $online) { Hoerer-Starten | Out-Null }
}
Diktat-Wahl-Anzeige
$MiOnline.Add_Click({ Diktat-Wahl $true })
$MiOffline.Add_Click({ Diktat-Wahl $false })
$script:testOhneNetz = $false
function Internet-Da {
  if ($script:testOhneNetz) { return $false }
  try { return [System.Net.NetworkInformation.NetworkInterface]::GetIsNetworkAvailable() } catch { return $true }
}
# Fruehere Fassungen haben das Fenster der Windows-Eingabe verschoben: sicherheitshalber zurueck
try { $p = Get-Process TextInputHost -ErrorAction SilentlyContinue | Select-Object -First 1; if ($p) { [TaskbarHelper]::EingabeUnsichtbar([int]$p.Id, $false) | Out-Null } } catch {}

# Online-Diktat: der Knopf oeffnet die Windows-Spracheingabe und schliesst sie
# beim zweiten Klick wieder, samt Fenster. Rot heisst: Windows-Fenster ist offen.
$script:onlineOffen = $false
function Online-An {
  [TaskbarHelper]::Spracheingabe()
  $script:onlineOffen = $true
  $script:diktat = $true
  $script:hoerZuletzt = "hoert"
  Diktat-Anzeige
  Log-Zeile "online-diktat an"
}
# Schliesst das Windows-Diktierfenster sicher, egal ob es gerade offen ist.
# Windows+H schaltet nur um: war das Fenster schon von Hand geschlossen, wuerde
# es dadurch wieder aufgehen. Deshalb wird die Windows-Eingabe (TextInputHost)
# beendet. Windows startet sie von selbst neu, das Diktierfenster bleibt zu.
function Eingabe-Schliessen {
  if ($Selbsttest) { return }
  try { Get-Process TextInputHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
}
$script:onlineZu = New-Object System.Windows.Threading.DispatcherTimer
$script:onlineZu.Interval = [TimeSpan]::FromMilliseconds(700)
$script:onlineZu.Add_Tick({ $script:onlineZu.Stop(); Eingabe-Schliessen })
# sofort: ohne Wartezeit schliessen. Sonst bekommt Windows kurz Zeit, die
# letzten gesprochenen Woerter noch zu schreiben.
function Online-Aus($sofort) {
  $script:onlineOffen = $false
  $script:diktat = $false
  Diktat-Anzeige
  Log-Zeile "online-diktat aus"
  if ($sofort) { $script:onlineZu.Stop(); Eingabe-Schliessen } else { $script:onlineZu.Stop(); $script:onlineZu.Start() }
}
$BtnMikro.Add_Click({
  if ($script:onlineOffen) { Online-Aus; return }
  if ($script:diktat) { Diktat-Stopp; return }
  # Vorlesen stoppen, sonst hoert das Mikrofon die eigene Stimme mit
  if ($state.Speaking) { Stop-Sprechen }
  if ($script:diktatOnline -and (Internet-Da)) { $script:onlineZu.Stop(); Online-An; return }
  if ($script:diktatOnline) { Log-Zeile "kein internet, offline-diktat" }
  Diktat-Start
})
$BtnSpeak.Add_Click({
  if (-not $state.Speaking) { Start-Sprechen (Get-ClipText) }
})
$BtnPause.Add_Click({
  if ($state.Pausiert) { Fortsetzen }
  else { Anhalten }
})
$BtnStopp.Add_Click({ Stop-Sprechen })
$BtnZurueck.Add_Click({ Spulen -10 })
$BtnVor.Add_Click({ Spulen 10 })
# Menue unter den drei Punkten: Klick oeffnet, zweiter Klick schliesst,
# ein Klick irgendwo anders schliesst ebenfalls. Weil der Knopf nie den Fokus
# nimmt, merkt WPF den Klick daneben nicht selbst, deshalb wird die Maus hier
# im schnellen Takt abgefragt, solange das Menue offen ist.
function In-Element($el, $x, $y) {
  try {
    if (-not $el -or -not $el.IsVisible) { return $false }
    $q = [System.Windows.PresentationSource]::FromVisual($el)
    if (-not $q) { return $false }
    $f = $q.CompositionTarget.TransformToDevice.M11
    $p = $el.PointToScreen((New-Object System.Windows.Point 0, 0))
    return ($x -ge $p.X -and $y -ge $p.Y -and $x -le $p.X + $el.ActualWidth * $f -and $y -le $p.Y + $el.ActualHeight * $f)
  } catch { return $false }
}
function Offene-Menueflaechen($items) {
  $l = @()
  foreach ($mi in $items) {
    if ($mi -is [System.Windows.Controls.MenuItem] -and $mi.IsSubmenuOpen) {
      try { $pp = $mi.Template.FindName("PART_Popup", $mi); if ($pp -and $pp.Child) { $l += $pp.Child } } catch {}
      $l += Offene-Menueflaechen $mi.Items
    }
  }
  return $l
}
function Maus-Ueber-Menue($x, $y) {
  if ($null -eq $x) { $c = [System.Windows.Forms.Cursor]::Position; $x = $c.X; $y = $c.Y }
  foreach ($el in @($BtnDots, $KnopfMenue) + (Offene-Menueflaechen $KnopfMenue.Items)) {
    if (In-Element $el $x $y) { return $true }
  }
  return $false
}
# Ein Mausklick an der Stelle x,y: liegt er ausserhalb von Menue und Punkten, zu
function Menue-Klick($x, $y) {
  if (-not (Maus-Ueber-Menue $x $y)) { $KnopfMenue.IsOpen = $false }
}
$script:menueTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:menueTimer.Interval = [TimeSpan]::FromMilliseconds(40)
$script:menueTimer.Add_Tick({
  if (-not $KnopfMenue.IsOpen) { $script:menueTimer.Stop(); return }
  if ([TaskbarHelper]::MausGedrueckt()) { Menue-Klick }
})
# Menue mit kleinem Abstand unter den Punkten. Passt es unten nicht hin, legt
# WPF es darueber, dann wird der Abstand nach oben gedreht, damit es nie auf
# dem Knopf liegt.
function Menue-Vorab {
  # Vor dem Oeffnen: passt das Menue unter die Punkte? Sonst Abstand nach oben
  try {
    $KnopfMenue.VerticalOffset = 6
    $KnopfMenue.Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
    $h = $KnopfMenue.DesiredSize.Height
    if ($h -lt 50) { $h = 300 }
    $p = $BtnDots.TransformToAncestor($win).Transform((New-Object System.Windows.Point 0, 0))
    $unten = $win.Top + $p.Y + $BtnDots.ActualHeight
    $wa = Flaeche ($win.Left + 20) ($win.Top + 16)
    if ($unten + 6 + $h -gt $wa.Bottom) { $KnopfMenue.VerticalOffset = -6 }
  } catch {}
}
function Menue-Abstand {
  # Nach dem Oeffnen: liegt das Menue doch auf dem Knopf, Abstand umdrehen
  try {
    $f = [System.Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformToDevice.M11
    $m = $KnopfMenue.PointToScreen((New-Object System.Windows.Point 0, 0))
    $d = $BtnDots.PointToScreen((New-Object System.Windows.Point 0, 0))
    $mh = $KnopfMenue.ActualHeight * $f; $dh = $BtnDots.ActualHeight * $f
    if ($m.Y -lt $d.Y + $dh -and $m.Y + $mh -gt $d.Y) { $KnopfMenue.VerticalOffset = -$KnopfMenue.VerticalOffset }
  } catch {}
}
$KnopfMenue.Add_Opened({ $null = $KnopfMenue.Dispatcher.BeginInvoke([Action]{ Menue-Abstand }, [System.Windows.Threading.DispatcherPriority]::Loaded); [TaskbarHelper]::MausGedrueckt() | Out-Null; $script:menueTimer.Start() })
$KnopfMenue.Add_Closed({ $script:menueTimer.Stop() })
$BtnDots.Add_Click({
  try {
    if ($KnopfMenue.IsOpen) { $KnopfMenue.IsOpen = $false }
    else { Menue-Vorab; $KnopfMenue.IsOpen = $true }
  } catch { Log-Zeile ("menue " + $_.Exception.Message) }
})
# Rechtsklick auf die Punkte soll dasselbe Menue nicht zusaetzlich oeffnen
$BtnDots.Add_ContextMenuOpening({ param($s, $e) $e.Handled = $true })
$MiAuto.Add_Click({
  $state.Auto = [bool]$MiAuto.IsChecked
  # Beim Einschalten nur neu Kopiertes vorlesen, nicht den alten Inhalt
  if ($state.Auto) {
    $state.LastClip = Get-ClipText
    try { $script:clipNr = [TaskbarHelper]::GetClipboardSequenceNumber() } catch {}
  }
  try { $(if ($state.Auto) { "an" } else { "aus" }) | Set-Content $autoDatei -Encoding ASCII } catch {}
})
$MiStopp.Add_Click({ Stop-Sprechen })
$MiText.Add_Click({ Textfenster $MiText.IsChecked })
$BtnUebernehmen.Add_Click({
  try { [System.Windows.Forms.Clipboard]::SetDataObject($Klartext.Text, $true, 10, 100) } catch {}
  Start-Sprechen $Klartext.Text
})
$BtnLangsamer.Add_Click({ Tempo-Schritt -1 })
$BtnSchneller.Add_Click({ Tempo-Schritt 1 })
$BtnTextZu.Add_Click({ $MiText.IsChecked = $false; Textfenster $false })
$MiKatja.Add_Click({ Set-Stimme "de-DE-KatjaNeural" $MiKatja "Katja" })
$MiSeraphina.Add_Click({ Set-Stimme "de-DE-SeraphinaMultilingualNeural" $MiSeraphina "Seraphina" })
$MiConrad.Add_Click({ Set-Stimme "de-DE-ConradNeural" $MiConrad "Conrad" })
$MiFlorian.Add_Click({ Set-Stimme "de-DE-FlorianMultilingualNeural" $MiFlorian "Florian" })
$MiAnleitung.Add_Click({
  $KnopfMenue.IsOpen = $false
  $a = Join-Path $base "Anleitung.html"
  try { Start-Process $a } catch { Log-Zeile ("anleitung " + $_.Exception.Message) }
})
$MiExit.Add_Click({ Stop-Sprechen; $win.Close() })
$win.Add_Closing({ Stop-Sprechen; Worker-Ende; Hoerer-Ende; if ($script:onlineOffen) { Eingabe-Schliessen }; Save-Position })
$win.Add_LocationChanged({
  $jetzt = [DateTime]::Now.Ticks
  if ($jetzt - $script:lastSave -gt 20000000) { $script:lastSave = $jetzt; Save-Position }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
  $script:tick++
  try {
    # Immer im Vordergrund halten
    # Nicht ueber das offene Menue legen, sonst verschwindet es hinter dem Knopf
    if ($script:handle -ne [IntPtr]::Zero -and -not $KnopfMenue.IsOpen) { [TaskbarHelper]::InDenVordergrund($script:handle) }
    if (-not $win.IsVisible) { $win.Show() }
    # Nicht aus dem Bildschirmbereich verlieren
    # Waehrend die Maus gedrueckt ist (Ziehen), nicht eingreifen, sonst kommt
    # der Knopf nicht ueber die Grenze zum zweiten Bildschirm
    $lx = $win.Left; $ly = $win.Top
    $wa = Flaeche ($lx + $win.Width / 2) ($ly + $win.Height / 2)
    if (-not [TaskbarHelper]::LinksUnten() -and ($lx -lt $wa.Left -or $ly -lt $wa.Top -or $lx -gt $wa.Right - $win.Width - 4 -or $ly -gt $wa.Bottom - $win.Height - 5)) {
      $win.Left = [math]::Max($wa.Left, [math]::Min($lx, $wa.Right - $win.Width - 4))
      $win.Top = [math]::Max($wa.Top, [math]::Min($ly, $wa.Bottom - $win.Height - 5))
      if (-not $script:textOffen) { Save-Position }
    }
  } catch {}
  # Naechsten Teil abholen, sobald er fertig ist
  if ($script:diktat -and $script:tick % 4 -eq 0) { Diktat-Pruefen }
  if ($script:mp3Wartet) { Naechster-Teil }
  elseif ($script:job -and $script:engine -eq "mp3") { Vorladen }
  # Ende der Windows-Stimme erkennen, erst nach kurzer Anlaufzeit
  if ($state.Engine -eq "windows" -and $state.Speaking -and -not $state.Pausiert -and $synth.State -ne "Speaking" -and ((Get-Date) - $script:synthStart).TotalMilliseconds -gt 500) {
    if ($script:engine -eq "teilwin" -and $script:job) {
      # Ein einzelner Teil war mit der Windows-Stimme, weiter mit dem naechsten
      $script:mp3Wartet = $true
      Naechster-Teil
    } else {
      $state.Speaking = $false
      $state.Pausiert = $false
      Set-Symbol "aus"
    }
  }
  # Position regelmaessig sichern
  if ($script:tick % 130 -eq 0) { Save-Position }
  # Warten auf die Stimme sichtbar machen
  if ($script:mp3Wartet -and $script:tick % 66 -eq 0) {
    Log-Zeile ("warte auf die stimme " + [int](((Get-Date) - $script:mp3Start).TotalSeconds) + "s")
  }
  # Auto-Vorlesen: Windows zaehlt jede Aenderung der Zwischenablage mit.
  # Nur wenn sich der Zaehler aendert, wird der Text gelesen, so reagiert
  # der Knopf sofort, ohne die Oberflaeche zu bremsen.
  # Neu Kopiertes ersetzt sofort, was gerade gelesen wird.
  if ($state.Auto) {
    $nr = 0
    try { $nr = [TaskbarHelper]::GetClipboardSequenceNumber() } catch {}
    if ($nr -ne $script:clipNr) {
      $script:clipNr = $nr
      $t = Get-ClipText
      if (-not [string]::IsNullOrWhiteSpace($t) -and $t -ne $state.LastClip -and $t.Length -gt 2) {
        $state.LastClip = $t
        Start-Sprechen $t
      }
    }
  }
})
$timer.Start()
$state.LastClip = Get-ClipText
try { $script:clipNr = [TaskbarHelper]::GetClipboardSequenceNumber() } catch {}
# Sprechdienst gleich beim Start hochfahren, damit das erste Vorlesen schnell ist
Worker-Bereit | Out-Null
# Einmal pro Woche die Stimmen-Bibliothek still aktualisieren. Microsoft aendert
# den Zugang ab und zu, eine neue Fassung von edge-tts behebt das dann.
if (-not $Selbsttest -and $script:py -ne "") {
  $standDatei = Join-Path $daten "aktualisiert.txt"
  $alt = $true
  try { if (Test-Path $standDatei) { $alt = ((Get-Date) - (Get-Item $standDatei).LastWriteTime).TotalDays -gt 7 } } catch {}
  if ($alt -and (Internet-Da)) {
    try {
      $a = ""
      foreach ($v in $script:pyVor) { $a += $v + " " }
      Start-Process $script:py -ArgumentList ($a + "-m pip install --user --upgrade --quiet --disable-pip-version-check --no-warn-script-location edge-tts") -WindowStyle Hidden
      (Get-Date).ToString() | Set-Content $standDatei -Encoding ASCII
      Log-Zeile "stimmen-bibliothek wird aktualisiert"
    } catch {}
  }
}
# Hoer-Dienst einige Sekunden spaeter vorladen, damit der Rechnerstart nicht leidet
$script:hoerVorlade = New-Object System.Windows.Threading.DispatcherTimer
$script:hoerVorlade.Interval = [TimeSpan]::FromSeconds(8)
$script:hoerVorlade.Add_Tick({ $script:hoerVorlade.Stop(); if (-not $script:diktatOnline) { Hoerer-Starten | Out-Null } })
if (-not $Selbsttest) { $script:hoerVorlade.Start() }

# Mausrad im Textfenster: immer das Textfeld scrollen, egal wo die Maus steht
$win.Add_PreviewMouseWheel({
  param($s, $e)
  if (-not $script:textOffen) { return }
  try {
    $zeilen = [int]($e.Delta / 120)
    for ($i = 0; $i -lt [math]::Abs($zeilen) * 3; $i++) {
      if ($zeilen -gt 0) { $Klartext.LineUp() } else { $Klartext.LineDown() }
    }
    $e.Handled = $true
  } catch {}
})

$win.Add_SourceInitialized({
  try {
    $script:handle = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    [TaskbarHelper]::Show($script:handle)
    [TaskbarHelper]::OhneFokus($script:handle, $true)
    try {
      # Startbefehl und Symbol zeigen auf die Starter-exe, deren Logo nimmt
      # die Taskleiste, auch beim Anheften
      $exePfad = Join-Path $base "Read & Write.exe"
      [FensterApp]::Setzen($script:handle, "APirzadeh.ReadUndWrite", ("`"" + $exePfad + "`""), ($exePfad + ",0"), "Read & Write")
    } catch { Log-Zeile ("taskleiste " + $_.Exception.Message) }
    if ($script:iconGross -ne [IntPtr]::Zero) { [TaskbarHelper]::SetIcon($script:handle, $script:iconGross, $script:iconKlein) }
  } catch {}
})
# --- Selbsttest: Schritt fuer Schritt, jeder mit Bedingung und Frist ---
if ($Selbsttest) {
  foreach ($sp in $script:spieler) { $sp.Volume = 0 }
  $synth.Volume = 0
  $script:stDatei = Join-Path $env:TEMP "read-und-write-selbsttest.txt"
  Set-Content $script:stDatei ("Selbsttest Read & Write " + (Get-Date)) -Encoding UTF8
  function ST-Log($t) { Add-Content $script:stDatei $t -Encoding UTF8 }
  function ST-Klick($knopf) {
    $ev = [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent
    if ($knopf -is [System.Windows.Controls.MenuItem]) { $ev = [System.Windows.Controls.MenuItem]::ClickEvent }
    $knopf.RaiseEvent((New-Object System.Windows.RoutedEventArgs $ev))
  }
  function ST-Faktor { try { return [System.Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformToDevice.M11 } catch { return 1.0 } }
  function ST-Ecke($el) { return $el.PointToScreen((New-Object System.Windows.Point 0, 0)) }
  # Wo liegt das offene Menue: "unten" oder "oben" an den Punkten, mit
  # 2 bis 20 Punkt Abstand, nah an den Punkten und ganz im Bild; sonst ""
  function ST-Lage {
    $f = ST-Faktor; $m = ST-Ecke $KnopfMenue; $d = ST-Ecke $BtnDots
    $mh = $KnopfMenue.ActualHeight * $f; $mw = $KnopfMenue.ActualWidth * $f; $dh = $BtnDots.ActualHeight * $f
    $wa = Flaeche ($d.X / $f) ($d.Y / $f)
    $script:stMerk.menue = "Menü " + [int]$m.X + "," + [int]$m.Y + " " + [int]$mw + "x" + [int]$mh + ", Punkte " + [int]$d.X + "," + [int]$d.Y + " Höhe " + [int]$dh
    $nah = ([math]::Abs($m.X - $d.X) -le $mw)
    $imBild = ($m.Y -ge $wa.Top * $f - 1 -and $m.Y + $mh -le $wa.Bottom * $f + 1 -and $m.X -ge $wa.Left * $f - 1 -and $m.X + $mw -le $wa.Right * $f + 1)
    if (-not ($nah -and $imBild)) { return "" }
    $abUnten = $m.Y - ($d.Y + $dh)
    $abOben = $d.Y - ($m.Y + $mh)
    if ($abUnten -ge 2 * $f -and $abUnten -le 20 * $f) { return "unten" }
    if ($abOben -ge 2 * $f -and $abOben -le 20 * $f) { return "oben" }
    return ""
  }
  $script:stText = "Das ist der erste Satz für den Selbsttest. " +
    "Read und Write liest diesen Text in mehreren Teilen vor, damit das Vorlesen sofort beginnt. " +
    "Der zweite Teil folgt ohne Pause, während der erste noch klingt. " +
    "Danach wird das Tempo geändert, und es geht an derselben Stelle weiter. " +
    "Auch ein Wechsel der Stimme darf nicht von vorn beginnen. " +
    "Zum Schluss wird gestoppt, und der Knopf zeigt wieder den Lautsprecher. " +
    "Hier kommen noch einige Sätze, damit es genug Teile gibt. " +
    "Ein Satz mit Umlauten: Äpfel, Öl, Übung und Straße. " +
    "Und noch ein letzter Satz, damit auch der vierte Teil sicher entsteht. " +
    "Fertig ist der Text, und jetzt beginnt die Prüfung der übrigen Funktionen."
  $script:stTempo = $script:tempo
  $script:stClip = Get-ClipText
  $script:stMerk = @{}
  $script:stSchritte = @(
    @{ N = "Fenster da"; A = {}; B = { $script:handle -ne [IntPtr]::Zero -and $win.IsVisible -and $win.ActualWidth -gt 100 }; F = 10 },
    @{ N = "Arbeitsfläche erkannt"; A = { $script:stMerk.wa = Flaeche ($win.Left + 20) ($win.Top + 16) }; B = { $script:stMerk.wa.Width -gt 300 -and $win.Left -ge $script:stMerk.wa.Left -and $win.Left + $win.Width -le $script:stMerk.wa.Right }; F = 2; D = { "Fläche " + $script:stMerk.wa + ", Knopf " + [int]$win.Left + "," + [int]$win.Top } },
    @{ N = "Menü öffnet bei Klick auf die Punkte"; A = { ST-Klick $BtnDots }; B = { $KnopfMenue.IsOpen -and $KnopfMenue.ActualHeight -gt 50 }; F = 3 },
    @{ N = "Menü liegt mit Abstand über den Punkten (unten kein Platz) und ganz im Bild"; A = {}; B = { (ST-Lage) -eq "oben" }; F = 2; D = { $script:stMerk.menue } },
    @{ N = "Klick ins Menü lässt es offen"; A = {
        $f = ST-Faktor; $m = ST-Ecke $KnopfMenue
        Menue-Klick ($m.X + 20) ($m.Y + 20) }; B = { $KnopfMenue.IsOpen }; F = 1 },
    @{ N = "Klick auf die Punkte zählt nicht als daneben"; A = {
        $f = ST-Faktor; $d = ST-Ecke $BtnDots
        Menue-Klick ($d.X + 5) ($d.Y + 5) }; B = { $KnopfMenue.IsOpen }; F = 1 },
    @{ N = "Zweiter Klick auf die Punkte schließt"; A = { ST-Klick $BtnDots }; B = { -not $KnopfMenue.IsOpen }; F = 2 },
    @{ N = "Menü öffnet erneut"; A = { ST-Klick $BtnDots }; B = { $KnopfMenue.IsOpen }; F = 2 },
    @{ N = "Klick daneben schließt"; A = {
        $f = ST-Faktor; $d = ST-Ecke $BtnDots
        Menue-Klick ($d.X - 400 * $f) ($d.Y - 300 * $f) }; B = { -not $KnopfMenue.IsOpen }; F = 2 },
    @{ N = "Knopf nach oben geschoben"; A = { $script:stMerk.oy = $win.Top; $win.Top = (Flaeche ($win.Left + 20) ($win.Top + 16)).Top + 40 }; B = { $win.Top -lt $script:stMerk.oy - 100 }; F = 2 },
    @{ N = "Knopf oben am Bildschirm: Menü öffnet darunter"; A = { ST-Klick $BtnDots }; B = { $KnopfMenue.IsOpen -and (ST-Lage) -eq "unten" }; F = 3; D = { $script:stMerk.menue } },
    @{ N = "Menü zu, Knopf zurück"; A = { ST-Klick $BtnDots; $win.Top = $script:stMerk.oy }; B = { -not $KnopfMenue.IsOpen -and [math]::Abs($win.Top - $script:stMerk.oy) -lt 1 }; F = 2 },
    @{ N = "Vorlesen startet mit Online-Stimme"; A = { $script:stMerk.t0 = Get-Date; Start-Sprechen $script:stText }; B = { $script:engine -eq "mp3" -and $state.Speaking }; F = 25; D = { "erster Teil nach " + [int](((Get-Date) - $script:stMerk.t0).TotalMilliseconds) + " ms" } },
    @{ N = "Knopf zeigt sechs Felder"; A = {}; B = { $win.Width -eq 199 -and $BtnPause.Visibility -eq "Visible" -and $BtnStopp.Visibility -eq "Visible" }; F = 2 },
    @{ N = "Nächster Teil folgt von selbst"; A = {}; B = { $script:aktTeil -ge 2 -and $script:engine -eq "mp3" }; F = 40; D = { "Teil " + $script:aktTeil } },
    @{ N = "Pause"; A = { ST-Klick $BtnPause }; B = { $state.Pausiert }; F = 2 },
    @{ N = "Weiter nach Pause"; A = { ST-Klick $BtnPause }; B = { -not $state.Pausiert -and $state.Speaking }; F = 2 },
    @{ N = "Tempo schneller liest an der Stelle weiter"; A = { $script:stMerk.job = $script:job; Tempo-Schritt 1 }; B = {
        $neuText = ""
        try { $neuText = [System.IO.File]::ReadAllText((Join-Path $script:job "text.txt"), [System.Text.Encoding]::UTF8) } catch {}
        $script:stMerk.neu = $neuText
        $script:job -ne $script:stMerk.job -and $neuText -ne "" -and -not $neuText.StartsWith("Das ist der erste Satz") -and $script:engine -eq "mp3" }; F = 25; D = { "Tempo " + $script:tempo + ", weiter mit: " + $script:stMerk.neu.Substring(0, [math]::Min(40, $script:stMerk.neu.Length)) } },
    @{ N = "Stimmwechsel liest an der Stelle weiter"; A = { $script:stMerk.job = $script:job; Set-Stimme "de-DE-KatjaNeural" $MiKatja "Katja" }; B = { $script:job -ne $script:stMerk.job -and $script:engine -eq "mp3" -and $state.Speaking }; F = 25 },
    @{ N = "10 Sekunden vor"; A = { $script:stMerk.pos = $script:player.Position.TotalSeconds; $script:stMerk.teil = $script:aktTeil; ST-Klick $BtnVor }; B = { $script:aktTeil -gt $script:stMerk.teil -or $script:player.Position.TotalSeconds -gt $script:stMerk.pos + 5 -or $script:mp3Wartet }; F = 3 },
    @{ N = "10 Sekunden zurück"; A = { $script:stMerk.teil = $script:aktTeil; ST-Klick $BtnZurueck }; B = { $state.Speaking }; F = 3; D = { "Teil " + $script:stMerk.teil + " -> " + $script:aktTeil } },
    @{ N = "Stopp"; A = { ST-Klick $BtnStopp }; B = { -not $state.Speaking -and $win.Width -eq 133 -and $BtnSpeak.Visibility -eq "Visible" }; F = 2 },
    @{ N = "Ohne Internet: Windows-Stimme"; A = { Set-Tempo $script:stTempo; $script:testOhneNetz = $true; Start-Sprechen "Kurzer Satz ohne Internet." }; B = { $state.Engine -eq "windows" -and $state.Speaking }; F = 3 },
    @{ N = "Windows-Stimme endet von selbst"; A = {}; B = { -not $state.Speaking }; F = 20 },
    @{ N = "Auto-Vorlesen liest neu Kopiertes"; A = { $script:testOhneNetz = $false; $MiAuto.IsChecked = $true; ST-Klick $MiAuto; $script:stMerk.a = "Auto Test eins, ein neu kopierter Satz."; [System.Windows.Forms.Clipboard]::SetDataObject($script:stMerk.a, $true, 20, 100) }; B = { $state.Speaking -and $state.LastClip -eq $script:stMerk.a }; F = 5 },
    @{ N = "Neu Kopiertes ersetzt das laufende Vorlesen"; A = { $script:stMerk.b = "Auto Test zwei, das ersetzt den ersten Satz."; [System.Windows.Forms.Clipboard]::SetDataObject($script:stMerk.b, $true, 20, 100) }; B = { $state.Speaking -and $state.LastClip -eq $script:stMerk.b }; F = 5 },
    @{ N = "Auto-Vorlesen aus"; A = { Stop-Sprechen; $MiAuto.IsChecked = $false; ST-Klick $MiAuto }; B = { -not $state.Auto -and -not $state.Speaking }; F = 2 },
    @{ N = "Textfenster öffnet ganz sichtbar"; A = { $script:stMerk.kx = $win.Left; $script:stMerk.ky = $win.Top; $MiText.IsChecked = $true; Textfenster $true }; B = {
        $wa = Flaeche ($win.Left + 20) ($win.Top + 16)
        $win.Width -eq 420 -and $TextZone.Visibility -eq "Visible" -and $win.Left -ge $wa.Left -and $win.Left + 420 -le $wa.Right + 1 -and $win.Top -ge $wa.Top -and $win.Top + 340 -le $wa.Bottom + 1 }; F = 2 },
    @{ N = "Textfenster: Vorlesen"; A = { $Klartext.Text = "Text aus dem Textfenster."; ST-Klick $BtnUebernehmen }; B = { $state.Speaking -and $state.LastClip -eq "Text aus dem Textfenster." }; F = 3 },
    @{ N = "Textfenster: Tempo-Knöpfe"; A = { Stop-Sprechen; $script:stMerk.tp = $script:tempo; ST-Klick $BtnLangsamer }; B = { $script:tempo -lt $script:stMerk.tp -and $TempoText.Text -like "*$($script:tempo)*" }; F = 2 },
    @{ N = "Textfenster zu, Knopf an alter Stelle"; A = { Set-Tempo $script:stTempo; ST-Klick $BtnTextZu }; B = { $win.Width -eq 133 -and [math]::Abs($win.Left - $script:stMerk.kx) -lt 1 -and [math]::Abs($win.Top - $script:stMerk.ky) -lt 1 }; F = 2 },
    @{ N = "Diktat-Auswahl gespeichert"; A = { $script:stMerk.dw = $script:diktatOnline; Diktat-Wahl $true }; B = { $MiOnline.IsChecked -and -not $MiOffline.IsChecked -and ((Get-Content $diktatDatei -Raw).Trim() -eq "online") }; F = 2 },
    @{ N = "Offline-Diktat: Dienst lädt und ist bereit"; A = { Diktat-Wahl $false }; B = { $z = ""; try { $z = (Get-Content $script:hoerZustand -Raw -Encoding UTF8).Trim() } catch {}; $script:stMerk.z = $z; $z -eq "bereit" }; F = 240; D = { "Zustand " + $script:stMerk.z } },
    @{ N = "Offline-Diktat: Mikrofon an und wieder aus"; A = { Diktat-Start }; B = { $z = ""; try { $z = (Get-Content $script:hoerZustand -Raw -Encoding UTF8).Trim() } catch {}; $script:stMerk.z = $z; $script:diktat -and $z -eq "hoert" }; F = 10; D = { "Zustand " + $script:stMerk.z } },
    @{ N = "Offline-Diktat: Stopp"; A = { Diktat-Stopp }; B = { $z = ""; try { $z = (Get-Content $script:hoerZustand -Raw -Encoding UTF8).Trim() } catch {}; -not $script:diktat -and $z -eq "bereit" }; F = 10 }
  )
  $script:stNr = -1
  $script:stStart = Get-Date
  $script:stOk = 0
  $script:stTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:stTimer.Interval = [TimeSpan]::FromMilliseconds(100)
  $script:stTimer.Add_Tick({
    try {
      $s = $null
      if ($script:stNr -ge 0) { $s = $script:stSchritte[$script:stNr] }
      $fertig = $false; $gut = $false
      if ($s) {
        try { $gut = [bool](& $s.B) } catch { $gut = $false; $script:stMerk.fehler = $_.Exception.Message }
        $fertig = $gut -or ((Get-Date) - $script:stStart).TotalSeconds -gt $s.F
      }
      if ($script:stNr -lt 0 -or $fertig) {
        if ($s) {
          $d = ""
          if ($s.D) { try { $d = " (" + (& $s.D) + ")" } catch {} }
          if (-not $gut -and $script:stMerk.fehler) { $d += " [" + $script:stMerk.fehler + "]"; $script:stMerk.fehler = $null }
          # Ist die Zwischenablage gesperrt (etwa bei gesperrtem Bildschirm),
          # laesst sich Kopieren nicht pruefen: dann uebersprungen, kein Fehler
          $art = $(if ($gut) { "OK      " } elseif ($d -match "Clipboard|Zwischenablage") { "SPÄTER  " } else { "FEHLER  " })
          ST-Log ($art + $s.N + $d)
          if ($gut) { $script:stOk++ }
        }
        $script:stNr++
        if ($script:stNr -ge $script:stSchritte.Count) {
          $script:stTimer.Stop()
          try { Diktat-Wahl $script:stMerk.dw } catch {}
          try { if ($script:stClip -ne "") { [System.Windows.Forms.Clipboard]::SetDataObject($script:stClip, $true, 20, 100) } } catch {}
          ST-Log ("SELBSTTEST FERTIG: " + $script:stOk + " von " + $script:stSchritte.Count + " bestanden")
          $win.Close()
          return
        }
        $script:stStart = Get-Date
        try { & $script:stSchritte[$script:stNr].A } catch { $script:stMerk.fehler = $_.Exception.Message }
      }
    } catch { ST-Log ("ABBRUCH " + $_.Exception.Message) }
  })
  $win.Add_ContentRendered({ $script:stTimer.Start() })
}
$win.ShowDialog() | Out-Null
