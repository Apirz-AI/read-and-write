# Baut die eine Weitergabe-Datei "Read & Write Setup.exe" eine Ebene hoeher.
# Alle Programmdateien kommen als paket.zip in die exe, dazu das Logo.
# Uebersetzt wird Setup.cs mit dem C#-Compiler, der in jedem Windows steckt.
$quellen = Split-Path -Parent $MyInvocation.MyCommand.Path
$ausgabe = Join-Path (Split-Path -Parent $quellen) "Read & Write Setup.exe"
$dateien = @("Read-und-Write.ps1", "speak.py", "hoeren.py", "read-und-write.ico",
             "Installieren.ps1", "Deinstallieren.ps1", "Anleitung.html",
             "stimme-katja.mp3", "stimme-seraphina.mp3", "stimme-conrad.mp3", "stimme-florian.mp3")
$version = ([regex]::Match((Get-Content (Join-Path $quellen "Installieren.ps1") -Raw), '\$version = "([^"]+)"')).Groups[1].Value

$tmp = Join-Path $env:TEMP "read-und-write-bauen"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $tmp "paket") | Out-Null
foreach ($f in $dateien) { Copy-Item (Join-Path $quellen $f) (Join-Path $tmp "paket") -Force }
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
$fw = Split-Path $csc
# Starter-exe mit Logo, sie kommt mit ins Paket
(Get-Content (Join-Path $quellen "Starter.cs") -Raw -Encoding UTF8).Replace("@VERSION@", $version) | Set-Content (Join-Path $tmp "Starter.cs") -Encoding UTF8
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$(Join-Path $tmp 'paket\Read & Write.exe')" "/win32icon:$(Join-Path $quellen 'read-und-write.ico')" (Join-Path $tmp "Starter.cs")
if (-not (Test-Path (Join-Path $tmp "paket\Read & Write.exe"))) { "FEHLER: Starter wurde nicht gebaut"; exit 1 }
$zip = Join-Path $tmp "paket.zip"
Compress-Archive -Path (Join-Path $tmp "paket\*") -DestinationPath $zip -Force
Copy-Item (Join-Path $quellen "read-und-write.ico") (Join-Path $tmp "logo.ico")
(Get-Content (Join-Path $quellen "Setup.cs") -Raw -Encoding UTF8).Replace("@VERSION@", $version) | Set-Content (Join-Path $tmp "Setup.cs") -Encoding UTF8

if (Test-Path $ausgabe) { Remove-Item $ausgabe -Force }
& $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$ausgabe" "/win32icon:$(Join-Path $tmp 'logo.ico')" `
  "/resource:$zip,paket.zip" "/resource:$(Join-Path $tmp 'logo.ico'),logo.ico" `
  /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `
  "/r:$fw\System.IO.Compression.dll" "/r:$fw\System.IO.Compression.FileSystem.dll" `
  (Join-Path $tmp "Setup.cs")
Remove-Item $tmp -Recurse -Force
if (-not (Test-Path $ausgabe)) { "FEHLER: Setup wurde nicht gebaut"; exit 1 }
"Setup: $ausgabe"
"Version: $version"
"Groesse: " + [math]::Round((Get-Item $ausgabe).Length / 1KB) + " KB"
