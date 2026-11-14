# Entfernt Read und Write vollstaendig: Programm, Symbole, Autostart,
# Eintrag unter Apps und die gespeicherten Einstellungen.
param([switch]$Still)
$ziel = Join-Path $env:LOCALAPPDATA "Programs\Read und Write"
$startmenue = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"

if (-not $Still) {
  Add-Type -AssemblyName PresentationFramework
  $a = [System.Windows.MessageBox]::Show("Read & Write wirklich vollständig entfernen?", "Read & Write deinstallieren", "YesNo", "Question")
  if ($a -ne "Yes") { exit 0 }
}

# Laufenden Knopf und seine Dienste beenden
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match "Read-und-Write\.ps1|Auto-Reading\.ps1" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "Programs\\(Auto Reading|Read und Write)\\(speak|hoeren)\.py" } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force } catch {} }
Start-Sleep -Milliseconds 500

foreach ($n in @("Read & Write.lnk", "Auto Reading.lnk")) {
  foreach ($o in @([Environment]::GetFolderPath("Desktop"), $startmenue, (Join-Path $startmenue "Startup"))) {
    $f = Join-Path $o $n
    if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
  }
}
# Angeheftetes Taskleisten-Symbol zeigt sonst ins Leere
Remove-Item (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Read & Write.lnk") -Force -ErrorAction SilentlyContinue
# Heruntergeladene Sprachmodelle von Read & Write (etwa 700 MB)
foreach ($m in @("models--Systran--faster-whisper-small", "models--Systran--faster-whisper-base")) {
  Remove-Item (Join-Path $env:USERPROFILE ".cache\huggingface\hub\$m") -Recurse -Force -ErrorAction SilentlyContinue
}
Get-ChildItem (Join-Path $env:USERPROFILE ".cache\vosk") -Filter "vosk-model-small-de*" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
Remove-Item "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ReadUndWrite" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $env:APPDATA "Read und Write") -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem $env:TEMP -Filter "auto-reading*" -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item $_.FullName -Force -Recurse -ErrorAction SilentlyContinue }

# Der Programmordner wird zuletzt geloescht, dieses Skript liegt selbst darin.
# Deshalb wird es kurz nach Ende von einem kleinen Hilfsprozess entfernt.
if (Test-Path $ziel) {
  $cmd = "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$ziel`""
  Start-Process "$env:WINDIR\System32\cmd.exe" -ArgumentList $cmd -WindowStyle Hidden -WorkingDirectory $env:TEMP
}
if (-not $Still) {
  [System.Windows.MessageBox]::Show("Read & Write wurde entfernt.", "Read & Write", "OK", "Information") | Out-Null
}
exit 0
