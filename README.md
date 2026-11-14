<img src="bilder/logo.png" alt="Read & Write Logo" width="128" align="left">

# Read & Write

**Vorlesen und Diktieren mit einem Klick, in jedem Programm unter Windows.**

Ein kleiner schwebender Knopf am Bildschirmrand: Er liest kopierten Text mit natürlichen Stimmen vor und schreibt Gesprochenes direkt in das Textfeld, in das du geklickt hast. Ob Word, Browser, E-Mail oder Chat.

<br clear="left">

![Version](https://img.shields.io/badge/Version-5.7-black) ![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-black) ![Lizenz](https://img.shields.io/badge/Lizenz-MIT-black)

---

## Wofür?

- **Zuhören statt lesen:** lange Texte, Skripte, E-Mails oder Webseiten vorlesen lassen.
- **Sprechen statt tippen:** Berichte, Nachrichten und Notizen diktieren.
- **Hilfreich bei** Lese- oder Rechtschreibschwäche, müden Augen, beim Lernen und überall, wo es schnell gehen soll.

## So funktioniert es

| Knopf | Aufgabe |
|---|---|
| ⋮ Griff | Knopf an eine beliebige Stelle ziehen, auch auf einen zweiten Bildschirm |
| 🔊 Lautsprecher | Liest den kopierten Text vor (`Strg + C`, dann klicken) |
| 🎤 Mikrofon | In ein Textfeld klicken, aufs Mikrofon klicken, sprechen. Nochmal klicken beendet. |
| ⋯ Menü | Stimme, Tempo, Auto-Vorlesen, Diktier-Art |

Beim Vorlesen: 10 Sekunden zurück und vor, Pause, Stopp. Vier natürliche Stimmen (Katja, Seraphina, Conrad, Florian), Tempo von 70 bis 200 %. Satzzeichen beim Diktieren einfach ansagen: „Punkt“, „Komma“, „Fragezeichen“, „neue Zeile“.

## Online oder lokal?

Read & Write funktioniert mit und ohne Internet. Ist keine Verbindung da, schaltet es automatisch auf lokal um.

|  | Online | Lokal (offline) |
|---|---|---|
| **Diktieren** | Windows-Spracheingabe (wie `Windows + H`): sehr schnell und am genauesten | Läuft komplett auf deinem Rechner. Wörter erscheinen live, jeder Satz wird danach ausgebessert. Tempo und Genauigkeit hängen vom Prozessor ab. |
| **Vorlesen** | Natürliche Microsoft-Stimmen | Eingebaute Windows-Stimme, klingt einfacher |
| **Datenschutz** | Text bzw. Sprache geht an Microsoft | Nichts verlässt den Rechner |

**Empfehlung:** Für beste Ergebnisse online diktieren. Für vertrauliche Inhalte oder ohne Internet lokal.

## Installieren

1. Im Ordner [`download`](download/) die Datei **`Read & Write Setup.exe`** öffnen und rechts oben auf den Download-Pfeil klicken.
2. Doppelklicken. Fragt Windows nach: **Weitere Informationen** → **Trotzdem ausführen**.
3. **Weiter** → **Installieren**. Adminrechte sind nicht nötig.

Beim ersten Mal dauert die Installation einige Minuten, weil Python, Stimmen und Sprachmodelle geladen werden. Dafür ist Internet nötig, danach läuft das lokale Diktieren auch offline.

**Voraussetzungen:** Windows 10 oder 11, Mikrofon zum Diktieren, rund 1 GB freier Speicher.

**Entfernen:** Windows-Einstellungen → Apps → Installierte Apps → „Read & Write“ → Deinstallieren.

## Für Entwickler

| Datei | Aufgabe |
|---|---|
| `Read-und-Write.ps1` | Der schwebende Knopf (PowerShell, WPF) |
| `speak.py` | Vorlese-Dienst (edge-tts), erzeugt Teile parallel für schnellen Start |
| `hoeren.py` | Diktier-Dienst: Vosk schreibt live, Whisper bessert jeden Satz aus |
| `Installieren.ps1` / `Deinstallieren.ps1` | Installation ohne Adminrechte, richtet bei Bedarf Python 3.12 ein |
| `Setup.cs`, `Starter.cs` | Setup- und Start-Datei mit Logo |
| `Setup-bauen.ps1` | Baut `Read & Write Setup.exe` mit dem C#-Compiler, der in Windows steckt |

Verwendete Bausteine (eigene Lizenzen): [edge-tts](https://github.com/rany2/edge-tts), [faster-whisper](https://github.com/SYSTRAN/faster-whisper), [Vosk](https://github.com/alphacep/vosk-api), [sounddevice](https://github.com/spatialaudio/python-sounddevice), [NumPy](https://numpy.org).

## Über das Projekt

Entwickelt von **A.Pirzadeh** ([@Apirz-AI](https://github.com/Apirz-AI)).

Lizenz: [MIT](LICENSE). Frei nutzbar und veränderbar, auch kommerziell, mit Namensnennung. Ohne Gewähr.

---

<sub>**English:** Read & Write is a floating button for Windows that reads copied text aloud and lets you dictate into any text field. Online mode uses Windows voice typing and natural Microsoft voices for the best results; offline mode runs fully on your PC (Vosk + Whisper), with speed depending on your CPU. German interface. Install via `download/Read & Write Setup.exe`. MIT licensed.</sub>
