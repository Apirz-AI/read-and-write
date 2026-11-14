# Hoer-Dienst fuer Read & Write: Diktieren ohne Windows-Diktierfenster.
# Nimmt das Standard-Mikrofon selbst auf und schreibt offline mit, live waehrend
# man spricht. Zwei Erkenner arbeiten zusammen:
# - Vosk erkennt Wort fuer Wort in Echtzeit und tippt sofort einen Entwurf.
#   Vosk erfindet nichts: hoert es keine Woerter, wird auch nichts geschrieben.
# - Whisper "small" hoert jeden fertigen Satz genau nach und korrigiert den
#   Entwurf per Ruecktaste, mit Grossschreibung und Satzzeichen.
#   Erfindet Whisper Saetze wie "Vielen Dank", die Vosk nicht gehoert hat,
#   gilt der Vosk-Text.
# - Satzzeichen setzt Whisper selbst. Sagt man sie an, gilt das Angesagte:
#   Punkt, Komma, Fragezeichen, Ausrufezeichen, Doppelpunkt, Semikolon,
#   Bindestrich, neue Zeile, neuer Absatz.
#
# Steuerung zeilenweise ueber die Standardeingabe:
#   START   zuhoeren
#   STOP    aufhoeren, angefangener Satz wird noch fertig geschrieben
# Endet die Standardeingabe, weil der Knopf geschlossen wurde, endet der Dienst.
# Zustand fuer den Knopf in %TEMP%\auto-reading-hoeren.txt:
#   laedt | bereit | hoert | schreibt | fehler <text>
import ctypes
import datetime
import difflib
import os
import queue
import re
import sys
import threading
import time
from ctypes import wintypes

import numpy as np

TEMP = os.environ.get("TEMP", ".")
ZUSTAND = os.path.join(TEMP, "auto-reading-hoeren.txt")
PROTOKOLL = os.path.join(TEMP, "auto-reading-hoeren.log")
TEST = os.environ.get("HOEREN_TEST") == "1"   # nur protokollieren, nicht tippen
MODELL = os.environ.get("HOEREN_MODELL", "small")       # bessert fertige Saetze aus, genauer als "base"
DATEI = os.environ.get("HOEREN_DATEI", "")              # Selbsttest: Tondatei statt Mikrofon
VOSK_SPRACHE = "de"                                     # kleines deutsches Vosk-Modell

RATE = 16000
BLOCK = 480                 # 30 ms
VORLAUF = 10                # Bloecke vor dem Sprechbeginn mitnehmen (300 ms)
PAUSE_ENDE = 0.5           # Sekunden Stille beenden einen Satz
MAX_SATZ = 8.0              # Sekunden, dann wird der Satz abgeschlossen
MIN_SPRACHE = 0.3           # kuerzere Geraeusche ignorieren
ENTWURF_TAKT = 0.25         # Sekunden zwischen zwei Live-Entwuerfen
# Whisper rechnet sonst immer ein 30-Sekunden-Fenster durch, auch fuer ein
# einzelnes Wort. Ein Satz ist hier hoechstens MAX_SATZ lang, ein Fenster von
# 12 Sekunden reicht also. Gemessen bessert das jeden Satz mehr als doppelt so
# schnell aus, bei gleichem Text. 0 oder 30 schaltet das kurze Fenster ab.
FENSTER = int(os.environ.get("HOEREN_FENSTER", "12"))
STRAHL = int(os.environ.get("HOEREN_STRAHL", "5"))     # Suchbreite, genauer als 1
KONTEXT_LAENGE = 200        # so viele Zeichen des bisher Diktierten kennt Whisper
# Satzzeichen: Whisper setzt hinter fast jedes Stueck einen Punkt und hinter
# einzelne Woerter gern ein Fragezeichen, auch wenn man nur kurz Luft holt.
# Deshalb entscheidet hier die Pause: erst nach SATZ_PAUSE Sekunden Stille
# (oder beim Beenden) gilt ein Satz als zu Ende. Whispers eigenes Schlusszeichen
# zaehlt nur bei Stuecken mit genug Woertern.
SATZ_PAUSE = 1.2            # Sekunden Stille, nach denen ein Satz sicher zu Ende ist
KURZ_WOERTER = 2            # bis zu so vielen Woertern ist ein Stueck nur ein Bruchstueck
PUNKT_AB = 4                # ab so vielen Woertern gilt Whispers Punkt
# Woerter, die mitten im Satz klein bleiben, auch wenn Whisper sie gross
# schreibt, weil es jedes Stueck wie einen Satzanfang behandelt
KLEIN = set("""der die das den dem des ein eine einen einem einer eines und oder aber denn sondern
doch weil dass ob wenn als wie wo was wer wen wem ich du er es wir mich dich sich uns euch mir dir
ihm ihn mein meine dein deine sein seine unser unsere in im an am auf aus bei mit nach von vom vor
zu zum zur über unter um durch für gegen ohne bis seit per pro ist sind war waren bin bist hat habe
haben hatte hatten wird werden wurde wurden kann können konnte muss müssen musste soll sollen sollte
will wollen wollte darf dürfen nicht kein keine auch noch schon nur sehr dann da hier dort so also
jetzt nun mal eben gerade vielleicht immer wieder dieser diese dieses man""".split())
SATZENDE = ".!?…"

# Typische Phantomsaetze von Whisper bei Stille oder Rauschen
PHANTOM = re.compile(r"untertitel|amara\.org|vielen dank (fürs|für's|fuers) zu(sehen|schauen)|"
                     r"copyright|swr|zdf|bis zum nächsten mal|danke fürs zuhören", re.I)

# Angesagte Satzzeichen. Was Whisper selbst daneben gesetzt hat, faellt weg.
ANSAGEN = [
    (r"neuer absatz", "\n\n"),
    (r"neue zeile|zeilenumbruch|nächste zeile", "\n"),
    (r"fragezeichen", "?"),
    (r"ausrufezeichen|ausrufungszeichen", "!"),
    (r"doppelpunkt", ":"),
    (r"semikolon|strichpunkt", ";"),
    (r"bindestrich", "-"),
    (r"komma", ","),
    (r"punkt", "."),
]
ANSAGE_RE = [(re.compile(r"[.,!?;:]*\s*\b(?:%s)\b[.,!?;:]*" % muster, re.I), zeichen) for muster, zeichen in ANSAGEN]


def log(text):
    try:
        with open(PROTOKOLL, "a", encoding="utf-8") as f:
            f.write(datetime.datetime.now().strftime("%H:%M:%S ") + text + "\n")
    except OSError:
        pass


def zustand(text):
    try:
        with open(ZUSTAND, "w", encoding="utf-8") as f:
            f.write(text)
    except OSError:
        pass


# --- Tippen per SendInput: Unicode fuer Text, echte Tasten fuer Enter und Ruecktaste ---
class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.c_size_t)]


class _U(ctypes.Union):
    _fields_ = [("ki", KEYBDINPUT), ("mi", MOUSEINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _U)]


def _taste(vk=0, code=0, flags=0):
    e = INPUT()
    e.type = 1
    e.u.ki = KEYBDINPUT(vk, code, flags, 0, 0)
    return e


def senden(loeschen, text):
    """Erst loeschen Zeichen per Ruecktaste entfernen, dann text tippen."""
    if TEST:
        log("tasten: %d zurueck, tippe %r" % (loeschen, text))
        return
    folge = []
    for _ in range(loeschen):
        folge += [_taste(0x08), _taste(0x08, flags=0x0002)]
    for z in text:
        if z == "\n":
            folge += [_taste(0x0D), _taste(0x0D, flags=0x0002)]
            continue
        roh = z.encode("utf-16-le")
        for i in range(0, len(roh), 2):
            code = int.from_bytes(roh[i:i + 2], "little")
            folge += [_taste(code=code, flags=0x0004), _taste(code=code, flags=0x0006)]
    if folge:
        feld = (INPUT * len(folge))(*folge)
        ctypes.windll.user32.SendInput(len(folge), feld, ctypes.sizeof(INPUT))


# --- Text aufbereiten ---
def ansagen(text):
    t = " " + text + " "
    for muster, zeichen in ANSAGE_RE:
        t = muster.sub(zeichen + (" " if zeichen not in "\n-" else ""), t)
    # Leerzeichen vor Satzzeichen und um Zeilenumbrueche weg
    t = re.sub(r"\s+([.,!?;:])", r"\1", t)
    t = re.sub(r"[ \t]*\n[ \t]*", "\n", t)
    t = re.sub(r"[ \t]{2,}", " ", t)
    return t.strip(" \t")


def satzschluss(text):
    """Trennt das Schlusszeichen ab, das Whisper gesetzt hat: (text, zeichen)."""
    t = text.rstrip()
    m = re.search(r"[.!?…]+$", t)
    if not m:
        return t, ""
    z = t[m.start():]
    return t[:m.start()].rstrip(" ,;:"), ("?" if "?" in z else "!" if "!" in z else ".")


def schluss_gilt(kern, zeichen):
    """Welches Schlusszeichen von Whisper uebernommen wird."""
    n = len(re.findall(r"\w+", kern))
    if n <= KURZ_WOERTER:
        return ""                   # Bruchstueck: kein Punkt, kein Fragezeichen
    if zeichen in ("?", "!"):
        return zeichen
    if zeichen == "." and n >= PUNKT_AB:
        return "."
    return ""


def gross_nach_satzende(t, neuer_anfang):
    zeichen = list(t)
    gross = neuer_anfang
    for i, z in enumerate(zeichen):
        if gross and z.isalpha():
            zeichen[i] = z.upper()
            gross = False
        elif z in SATZENDE or z == "\n":
            gross = True
        elif not z.isspace() and z not in "\"'„“»«(":
            gross = False
    return "".join(zeichen)


class Schreiber:
    """Fest geschriebener Text plus offene Saetze am Ende.

    Jeder offene Satz hat einen Entwurf oder schon das endgueltige Ergebnis.
    Angezeigt wird immer die Kette aller offenen Saetze. Aendert sich etwas,
    wird nur der abweichende Rest per Ruecktaste ersetzt. Ist der vorderste
    Satz endgueltig und steht fest, ob danach ein Satzende kommt, wandert er
    in den festen Text.
    """

    def __init__(self):
        self.sperre = threading.Lock()
        self.neu()

    def neu(self):
        self.letztes = ""
        self.offen = {}       # nr -> [roh, endgueltig, schlusszeichen von Whisper]
        self.pause = {}       # nr -> True: danach lange Pause (Satzende), False: es ging gleich weiter
        self.gezeigt = ""
        self.fertig = -1      # hoechste fest geschriebene Satznummer

    @staticmethod
    def form(roh, endgueltig, vorher, schluss="", pause=None):
        t = ansagen(" ".join(roh.split()) if "\n" not in roh else roh)
        if not t:
            return ""
        anfang = vorher == "" or vorher in SATZENDE + "\n"
        if endgueltig and not anfang:
            # Mitten im Satz: Fuellwoerter klein, Hauptwoerter bleiben wie erkannt
            m = re.match(r"\w+", t)
            if m and m.group(0).lower() in KLEIN:
                t = t[0].lower() + t[1:]
        t = gross_nach_satzende(t, anfang)
        if endgueltig and t[-1] not in SATZENDE + ",;:-\n":
            if schluss in ("?", "!"):
                t += schluss
            elif schluss == "." or pause:
                t += "."
        if vorher not in ("", "\n") and t[0] not in ".,!?;:\n":
            t = " " + t
        return t

    def setze(self, nr, roh, endgueltig, schluss=""):
        with self.sperre:
            if nr <= self.fertig:
                return
            alt = self.offen.get(nr)
            if alt and alt[1] and not endgueltig:
                return            # ein Entwurf ueberschreibt nie das Ergebnis
            self.offen[nr] = [roh, endgueltig, schluss]
            self._zeige()

    def pause_entschieden(self, nr, satzende):
        """Nach Satz nr kam eine lange Pause (Satzende) oder es ging gleich weiter."""
        with self.sperre:
            if nr <= self.fertig:
                return
            self.pause[nr] = bool(satzende)
            if nr in self.offen:
                self._zeige()

    def _zeige(self):
        teile, vorher = [], self.letztes
        for k in sorted(self.offen):
            roh, endgueltig, schluss = self.offen[k]
            t = self.form(roh, endgueltig, vorher, schluss, self.pause.get(k))
            teile.append((k, t))
            if t:
                vorher = t[-1]
        neu = "".join(t for _, t in teile)
        alt = self.gezeigt
        p = 0
        while p < len(alt) and p < len(neu) and alt[p] == neu[p]:
            p += 1
        if len(alt) - p or neu[p:]:
            senden(len(alt) - p, neu[p:])
        self.gezeigt = neu
        # Vorne fertige Saetze festschreiben. Steht noch nicht fest, ob nach
        # dem Satz ein Punkt kommt, bleibt er offen, bis die Pause entschieden ist.
        for k, t in teile:
            if not self.offen[k][1]:
                break
            if t and t[-1] not in SATZENDE + "\n" and k not in self.pause:
                break
            del self.offen[k]
            self.pause.pop(k, None)
            self.gezeigt = self.gezeigt[len(t):]
            if t:
                self.letztes = t[-1]
            self.fertig = k


def woerter(t):
    return set(re.findall(r"\w+", t.lower()))


def aehnlich(a, b):
    """Aehnlichkeit zweier Texte ohne Leerzeichen und Satzzeichen, 0 bis 1."""
    a = "".join(re.findall(r"\w+", a.lower()))
    b = "".join(re.findall(r"\w+", b.lower()))
    return difflib.SequenceMatcher(None, a, b).ratio() if a and b else 0.0


def pruefe(whisper, vosk, kontext=""):
    """Whisper-Text gegen den Vosk-Text pruefen und das Bessere waehlen."""
    if not vosk:
        return ""                      # Vosk hat keine Woerter gehoert: Stille oder Rauschen
    if not whisper or PHANTOM.search(whisper):
        return vosk
    w, v = woerter(whisper), woerter(vosk)
    # Erfundene Floskeln, die Vosk nicht gehoert hat, entfernen
    for schluessel, muster in (("dank", r"(vielen )?dank(e)?( schön| fürs zuhören| fürs zuschauen)?"),
                               ("tschüss", r"tschüss"), ("bis dann", r"bis dann")):
        if schluessel not in vosk.lower():
            whisper = re.sub(r"\s*\b" + muster + r"\b[.!]?", "", whisper, flags=re.I).strip()
    if not whisper:
        return vosk
    if v and len(w & v) == 0:
        # Kein gemeinsames Wort. Vosk trennt aber oft ein Wort in zwei
        # ("per formen" statt "performen"): klingt beides gleich, gilt Whisper.
        if aehnlich(whisper, vosk) >= 0.7:
            return whisper
        # Whisper weicht voellig ab: lieber den Vosk-Text nehmen
        if len(v) >= 3:
            return vosk
        # Whisper wiederholt nur, was vorher schon diktiert wurde
        if kontext and w and w <= woerter(kontext):
            return vosk
    return whisper


class DateiStrom:
    """Spielt eine Tondatei in Echtzeit wie ein Mikrofon ein, fuer den Selbsttest."""

    def __init__(self, pfad, rueckruf, an, ende):
        import av
        stille = np.full(int(RATE * 1.5), 0.0005, dtype="float32")
        teile = [stille]
        for einzeln in pfad.split(";"):
            c = av.open(einzeln)
            r = av.AudioResampler(format="flt", layout="mono", rate=RATE)
            for f in c.decode(c.streams.audio[0]):
                for g in r.resample(f):
                    teile.append(g.to_ndarray().flatten())
            teile.append(stille)
        self.audio = np.concatenate(teile).astype("float32")
        self.rueckruf, self.an, self.ende = rueckruf, an, ende

    def start(self):
        def lauf():
            t0 = time.time()
            for i in range(0, len(self.audio) - BLOCK, BLOCK):
                self.rueckruf(self.audio[i:i + BLOCK].reshape(-1, 1), BLOCK, None, None)
                warte = t0 + (i + BLOCK) / RATE - time.time()
                if warte > 0:
                    time.sleep(warte)
            log("datei zu ende")
        threading.Thread(target=lauf, daemon=True).start()

    def stop(self):
        pass

    def close(self):
        pass


def fenster_setzen(sekunden):
    """Kurzes Rechenfenster fuer Whisper einschalten. Gibt eine Funktion zum
    Zuruecksetzen zurueck, oder None, wenn es mit dieser Fassung nicht geht."""
    try:
        import faster_whisper.transcribe as ft
        original = ft.pad_or_trim
        n = int(sekunden * 100)

        def kurz(feld, length=n, *, axis=-1):
            return original(feld, n, axis=axis)

        ft.pad_or_trim = kurz

        def zurueck():
            ft.pad_or_trim = original
        return zurueck
    except Exception as e:
        log("kurzes fenster nicht moeglich: %r" % e)
        return None


def faeden(kerne):
    """Rechenfaeden fuer Whisper: echte Kerne sind schneller als alle logischen."""
    return max(2, kerne // 2) if kerne >= 6 else max(2, kerne - 1)


def main():
    zustand("laedt")
    log("start, modell %s und vosk" % MODELL)
    try:
        import json
        import sounddevice as sd
        import vosk
        from faster_whisper import WhisperModel
    except Exception as e:
        zustand("fehler Sprachpakete fehlen, bitte neu installieren")
        log("import %r" % e)
        return
    try:
        t0 = time.time()
        vosk.SetLogLevel(-1)
        vmodell = vosk.Model(lang=VOSK_SPRACHE)
        kerne = os.cpu_count() or 4
        modell = WhisperModel(MODELL, device="cpu", compute_type="int8", cpu_threads=faeden(kerne))
        modelle = {MODELL: modell}
        # Kurzes Fenster einschalten und einmal pruefen. Klappt es mit dieser
        # Fassung der Bibliothek nicht, laeuft alles wie bisher mit 30 Sekunden.
        kurz = {"sek": 0, "zurueck": None}
        if 0 < FENSTER < 30:
            kurz["zurueck"] = fenster_setzen(FENSTER)
            if kurz["zurueck"]:
                try:
                    probe = (np.random.default_rng(0).standard_normal(RATE) * 0.001).astype("float32")
                    list(modell.transcribe(probe, language="de", beam_size=1, chunk_length=FENSTER,
                                           without_timestamps=True)[0])
                    kurz["sek"] = FENSTER
                except Exception as e:
                    log("kurzes fenster abgeschaltet: %r" % e)
                    kurz["zurueck"]()
        log("modelle geladen in %.1fs, fenster %ds, %d faeden" % (time.time() - t0, kurz["sek"] or 30, faeden(kerne)))
    except Exception as e:
        zustand("fehler Sprachmodell konnte nicht geladen werden, beim ersten Start wird Internet gebraucht")
        log("modell %r" % e)
        return

    an = threading.Event()
    stopp = threading.Event()
    ende = threading.Event()
    bloecke = queue.Queue()
    fertige = queue.Queue()          # (nr, audio, vosk_text), alle werden geschrieben
    vosk_auftraege = queue.Queue()   # Auftraege an den Vosk-Faden
    schreiber = Schreiber()

    def befehle():
        for zeile in sys.stdin:
            z = zeile.strip().upper()
            if z == "START":
                # Nur neu anfangen, wenn nichts mehr in Arbeit ist
                if not schreiber.offen:
                    schreiber.neu()
                    kontext["text"] = ""
                an.set()
                zustand("hoert")
                log("start")
            elif z == "STOP":
                an.clear()
                stopp.set()
                zustand("bereit")
                log("stop")
        ende.set()
        an.clear()

    def aufnahme(daten, frames, zeit, status):
        if an.is_set() or stopp.is_set():
            bloecke.put(daten[:, 0].copy())

    # Schafft der Rechner das genaue Modell nicht schnell genug, wird auf
    # das schnellere "base" gewechselt, damit das Ausbessern nie hinterherhinkt
    tempo = {"modell": MODELL}
    kontext = {"text": ""}           # das zuletzt Diktierte, fuer Whisper

    def erkenne(audio, kontext=""):
        m = modelle.get(tempo["modell"])
        if m is None:
            m = WhisperModel(tempo["modell"], device="cpu", compute_type="int8", cpu_threads=faeden(kerne))
            modelle[tempo["modell"]] = m
            log("modell %s nachgeladen" % tempo["modell"])
        spitze = float(np.max(np.abs(audio))) if len(audio) else 0.0
        if 0 < spitze < 0.5:
            audio = (audio * (0.5 / spitze)).astype("float32")
        # Das bisher Diktierte als Kontext: so werden auch einzelne Woerter
        # und Fachbegriffe richtig erkannt, die vorher schon vorkamen.
        def lauf():
            extra = {"chunk_length": kurz["sek"]} if kurz["sek"] else {}
            segs, _ = m.transcribe(
                audio, language="de", beam_size=STRAHL, vad_filter=True,
                condition_on_previous_text=False, without_timestamps=True,
                initial_prompt=kontext or None, **extra)
            return [x.text.strip() for x in segs if x.no_speech_prob < 0.6 and x.avg_logprob > -1.2]

        try:
            teile = lauf()
        except Exception as e:
            if not kurz["sek"]:
                raise
            # Mit kurzem Fenster ging es nicht: abschalten und normal wiederholen
            log("kurzes fenster abgeschaltet: %r" % e)
            kurz["zurueck"]()
            kurz["sek"] = 0
            teile = lauf()
        return " ".join(teile).strip()

    # Faden 1: Vosk, Wort fuer Wort in Echtzeit, tippt Live-Entwuerfe
    def vosk_faden():
        rec = vosk.KaldiRecognizer(vmodell, RATE)
        aktuell, letzter = -1, 0.0
        while not ende.is_set():
            try:
                art, nr, daten = vosk_auftraege.get(timeout=0.3)
            except queue.Empty:
                continue
            try:
                if art == "start":
                    rec.Reset()
                    aktuell = nr
                    for b in daten:
                        rec.AcceptWaveform((np.clip(b, -1, 1) * 32767).astype(np.int16).tobytes())
                elif art == "block" and nr == aktuell:
                    rec.AcceptWaveform((np.clip(daten, -1, 1) * 32767).astype(np.int16).tobytes())
                    if time.time() - letzter >= ENTWURF_TAKT:
                        teil = json.loads(rec.PartialResult()).get("partial", "")
                        if teil:
                            schreiber.setze(nr, teil, False)
                        letzter = time.time()
                elif art == "ende":
                    text = json.loads(rec.FinalResult()).get("text", "").strip()
                    log("vosk %d: %r" % (nr, text))
                    if text:
                        schreiber.setze(nr, text, False)
                    fertige.put((nr, daten, text))
                    aktuell = -1
            except Exception as e:
                log("vosk %r" % e)
                if art == "ende":
                    fertige.put((nr, daten, ""))

    # Faden 2: fertige Saetze mit Whisper genau nachhoeren, der Reihe nach
    def saetze_faden():
        while not ende.is_set():
            try:
                nr, audio, vtext = fertige.get(timeout=0.3)
            except queue.Empty:
                continue
            try:
                if not vtext:
                    schreiber.setze(nr, "", True)     # nichts gehoert, nichts erfinden
                    continue
                # Staut es sich, den Vosk-Text direkt nehmen, damit nichts haengen bleibt
                if fertige.qsize() >= 2:
                    log("satz %d: stau, vosk-text direkt" % nr)
                    schreiber.setze(nr, vtext, True)
                    continue
                zustand("schreibt")
                t0 = time.time()
                wtext = erkenne(audio, kontext["text"])
                dauer = time.time() - t0
                text = pruefe(wtext, vtext, kontext["text"])
                if text:
                    kontext["text"] = (kontext["text"] + " " + text).strip()[-KONTEXT_LAENGE:]
                kern, zeichen = satzschluss(text)
                schluss = schluss_gilt(kern, zeichen)
                log("satz %d in %.1fs mit %s: whisper %r -> %r" % (nr, dauer, tempo["modell"], wtext, kern + schluss))
                schreiber.setze(nr, kern, True, schluss)
                # Der erste Satz zaehlt nicht, da waermt sich das Modell noch auf
                laenge = len(audio) / RATE
                tempo["saetze"] = tempo.get("saetze", 0) + 1
                if tempo["modell"] != "base" and tempo["saetze"] > 1 and laenge > 0 and dauer > max(4.0, laenge * 1.5):
                    tempo["modell"] = "base"
                    log("zu langsam, ab jetzt base")
            except Exception as e:
                log("erkennen %r" % e)
                schreiber.setze(nr, vtext, True)
            if not ende.is_set():
                zustand("hoert" if an.is_set() else "bereit")

    threading.Thread(target=befehle, daemon=True).start()
    threading.Thread(target=vosk_faden, daemon=True).start()
    threading.Thread(target=saetze_faden, daemon=True).start()

    # Das Mikrofon ist nur offen, solange diktiert wird. So leuchtet das
    # Mikrofon-Zeichen von Windows nicht dauernd, und ein neu angestecktes
    # Headset wird beim naechsten Start gleich benutzt.
    def oeffne():
        try:
            sd._terminate()
            sd._initialize()
        except Exception:
            pass
        try:
            s = sd.InputStream(samplerate=RATE, channels=1, dtype="float32", blocksize=BLOCK, callback=aufnahme)
        except Exception as e:
            # Manche Mikrofone kennen nur 44,1 oder 48 kHz: dann umrechnen
            log("16 kHz geht nicht: %r" % e)
            sr = int(sd.query_devices(kind="input")["default_samplerate"])
            n = int(round(BLOCK * sr / RATE))
            x_alt = np.arange(n)
            x_neu = np.linspace(0, n - 1, BLOCK)

            def umrechnen(daten, frames, zeit, status):
                if an.is_set() or stopp.is_set():
                    bloecke.put(np.interp(x_neu, x_alt, daten[:, 0]).astype("float32"))
            s = sd.InputStream(samplerate=sr, channels=1, dtype="float32", blocksize=n, callback=umrechnen)
        s.start()
        log("mikrofon: %s" % sd.query_devices(kind="input")["name"])
        return s

    def schliesse(s):
        try:
            s.stop()
            s.close()
        except Exception:
            pass

    strom = None
    if DATEI:
        strom = DateiStrom(DATEI, aufnahme, an, ende)
        an.set()
        zustand("hoert")
        strom.start()
        log("datei: %s" % DATEI)
    else:
        zustand("bereit")

    # Satzerkennung ueber den Pegel: Grundrauschen laufend nachfuehren,
    # Sprache beginnt deutlich darueber, ein Satz endet nach einer kurzen Pause
    rauschen = 0.002
    vorlauf, satz = [], []
    still = sprache = 0
    nr = 0
    wartend = None            # (Satznummer, Zeit): Satz zu Ende, Pause noch nicht entschieden

    def entscheide(satzende):
        nonlocal wartend
        if wartend is not None:
            schreiber.pause_entschieden(wartend[0], satzende)
            wartend = None

    def abschliessen():
        nonlocal satz, vorlauf, still, sprache, nr, wartend
        if satz:
            entscheide(False)
            wartend = (nr, time.time())
            if sprache * BLOCK / RATE >= MIN_SPRACHE:
                vosk_auftraege.put(("ende", nr, np.concatenate(satz)))
            else:
                vosk_auftraege.put(("ende", nr, np.zeros(0, dtype="float32")))
            nr += 1
        satz, vorlauf, still, sprache = [], [], 0, 0

    while not ende.is_set():
        if not DATEI and an.is_set() and strom is None:
            try:
                strom = oeffne()
            except Exception as e:
                log("mikrofon %r" % e)
                an.clear()
                zustand("fehler Kein Mikrofon gefunden. Bitte ein Mikrofon anschließen oder in Windows erlauben (Einstellungen, Datenschutz, Mikrofon).")
                continue
        try:
            b = bloecke.get(timeout=0.3)
        except queue.Empty:
            b = None
        if stopp.is_set() and (b is None or bloecke.empty()):
            if b is not None and satz:
                satz.append(b)
                vosk_auftraege.put(("block", nr, b))
            abschliessen()
            entscheide(True)          # Diktat beendet: der letzte Satz ist zu Ende
            stopp.clear()
            if not an.is_set() and strom is not None and not DATEI:
                schliesse(strom)
                strom = None
            continue
        # Bleibt es nach einem Satz laenger still, ist er wirklich zu Ende
        if wartend is not None and not satz and time.time() - wartend[1] >= SATZ_PAUSE - PAUSE_ENDE:
            entscheide(True)
        if b is None:
            continue
        pegel = float(np.sqrt(np.mean(b * b)))
        # Leise Laptop-Mikrofone: Schwelle knapp ueber dem Grundrauschen
        laut = pegel > max(0.003, rauschen * 2.5)
        if not satz:
            if laut:
                entscheide(False)     # es geht gleich weiter: derselbe Satz
                satz = vorlauf + [b]
                sprache, still = 1, 0
                vosk_auftraege.put(("start", nr, list(satz)))
            else:
                rauschen = rauschen * 0.97 + pegel * 0.03
                vorlauf = (vorlauf + [b])[-VORLAUF:]
            continue
        satz.append(b)
        vosk_auftraege.put(("block", nr, b))
        if laut:
            sprache += 1
            still = 0
        else:
            still += 1
        dauer = len(satz) * BLOCK / RATE
        if still * BLOCK / RATE >= PAUSE_ENDE or dauer >= MAX_SATZ:
            abschliessen()

    if strom is not None:
        schliesse(strom)
    log("ende")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        zustand("fehler " + repr(e))
        log("absturz %r" % e)
