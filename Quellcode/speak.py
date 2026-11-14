# Sprech-Dienst fuer Read & Write.
# Laeuft die ganze Zeit im Hintergrund, solange der Knopf offen ist. So entfallen
# Python-Start und Laden von edge-tts bei jedem Vorlesen.
#
# Befehle kommen zeilenweise ueber die Standardeingabe:
#   <auftragsordner>\t<stimme>\t<tempo>   Text aus <auftragsordner>\text.txt vorlesen,
#                                       Tempo wie "+10%" oder "-20%"
#   STOP                                laufenden Auftrag abbrechen
# Ergebnis je Teil: 001.txt mit dem Text des Teils, dann 001.mp3, sobald fertig.
# Klappt ein Teil auch nach mehreren Versuchen nicht, entsteht 001.fehlt, dann
# liest der Knopf genau diesen Teil mit der Windows-Stimme. So geht nie Text
# verloren. Zum Schluss die Datei "ende".
# Der erste Teil ist absichtlich kurz, damit das Vorlesen sofort beginnt,
# die folgenden Teile werden parallel erzeugt, waehrend schon gesprochen wird.
# Endet die Standardeingabe, weil der Knopf geschlossen wurde, endet der Dienst.
import asyncio
import os
import re
import sys
import threading

import time

import edge_tts

STANDARD_STIMME = "de-DE-FlorianMultilingualNeural"
# Teilgroessen in Zeichen: der erste Teil ist ein Satz fuer schnellen Start,
# danach wachsen die Teile langsam. Gemessen erzeugt Microsoft etwa dreimal
# schneller als gesprochen wird, so ist der naechste Teil immer rechtzeitig da.
GRENZEN = [160, 220, 320, 400]
GLEICHZEITIG = 4      # Teile, die parallel erzeugt werden
ERSTER_LANG = 110     # ab dieser Laenge wird der erste Satz am Komma geteilt
ERSTER_MIN = 40       # der erste Teil ist mindestens so lang
VORRANG_FRIST = 1.5   # so lange hat der erste Teil die Leitung fuer sich
VERSUCHE = 4
STILLE_FRIST = 5      # Sekunden ohne Daten, dann neuer Versuch
PROTOKOLL = os.path.join(os.environ.get("TEMP", "."), "auto-reading-dienst.log")


def log(text):
    try:
        with open(PROTOKOLL, "a", encoding="utf-8") as f:
            f.write(time.strftime("%H:%M:%S ") + text + "\n")
    except OSError:
        pass


def zerlege(text):
    text = re.sub(r"[ \t]+", " ", text.replace("\r", "")).strip()
    saetze = []
    for absatz in re.split(r"\n\s*\n|\n", text):
        absatz = absatz.strip()
        if not absatz:
            continue
        saetze += [s.strip() for s in re.split(r"(?<=[.!?…:;])\s+", absatz) if s.strip()]

    # Ueberlange Saetze an Komma oder Leerzeichen kuerzen
    def kuerze(s, grenze):
        teile = []
        while len(s) > grenze:
            schnitt = max(s.rfind(", ", 0, grenze), s.rfind(" ", 0, grenze))
            if schnitt < grenze // 3:
                schnitt = grenze
            teile.append(s[:schnitt + 1].strip())
            s = s[schnitt + 1:].strip()
        if s:
            teile.append(s)
        return teile

    def grenze():
        return GRENZEN[min(len(teile), len(GRENZEN) - 1)]

    # Ist der erste Satz lang, wird er am Komma geteilt: der erste Teil ist
    # dann schneller erzeugt und das Vorlesen beginnt frueher.
    if saetze and len(saetze[0]) > ERSTER_LANG:
        schnitt = saetze[0].rfind(", ", ERSTER_MIN, ERSTER_LANG)
        if schnitt > 0:
            saetze[0:1] = [saetze[0][:schnitt + 1], saetze[0][schnitt + 2:].strip()]

    teile, akt = [], ""
    for s in saetze:
        for stueck in kuerze(s, 200):
            if akt and len(akt) + 1 + len(stueck) > grenze():
                teile.append(akt)
                akt = stueck
            else:
                akt = (akt + " " + stueck).strip()
            # Den ersten Teil sofort abschliessen, sobald ein Satz drin ist
            if not teile and len(akt) >= 30:
                teile.append(akt)
                akt = ""
    if akt:
        teile.append(akt)
    return teile


def netzfehler(e):
    # Keine Verbindung zum Server (kein Internet, Name nicht aufloesbar)
    return isinstance(e, OSError) and not isinstance(e, FileNotFoundError)


async def erzeuge(text, stimme, tempo, ziel, lage, beim_ton=None):
    teil = ziel + ".teil"
    for versuch in range(VERSUCHE):
        # Ohne Internet nicht jeden Teil lange probieren: dann sofort die
        # Windows-Stimme, damit das Vorlesen nicht stockt
        if lage["netz_weg"] and not lage["ok"]:
            return False
        try:
            # Nur abbrechen, wenn die Verbindung wirklich steht: kommt einige
            # Sekunden lang gar nichts, neu versuchen. Langsame, aber laufende
            # Uebertragungen werden nicht abgewuergt.
            strom = edge_tts.Communicate(text, stimme, rate=tempo, pitch="-2Hz").stream().__aiter__()
            with open(teil, "wb") as f:
                while True:
                    try:
                        stueck = await asyncio.wait_for(strom.__anext__(), STILLE_FRIST)
                    except StopAsyncIteration:
                        break
                    if stueck["type"] == "audio":
                        f.write(stueck["data"])
                        if beim_ton:
                            beim_ton()
                            beim_ton = None
            if os.path.getsize(teil) < 200:
                raise RuntimeError("leere Tonspur")
            os.replace(teil, ziel)
            lage["ok"] += 1
            return True
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log("teil %s versuch %d: %r" % (os.path.basename(ziel), versuch + 1, e))
            if netzfehler(e) and versuch >= 1:
                lage["netz_weg"] = True
            await asyncio.sleep(0.3 * (versuch + 1))
    return False


async def auftrag(ordner, stimme, tempo):
    try:
        with open(os.path.join(ordner, "text.txt"), encoding="utf-8") as f:
            text = f.read()
        teile = zerlege(text)
        # Erst alle Teiltexte ablegen, dann weiss der Knopf, wie viele kommen
        for i, t in enumerate(teile):
            with open(os.path.join(ordner, "%03d.txt" % (i + 1)), "w", encoding="utf-8") as f:
                f.write(t)
        with open(os.path.join(ordner, "anzahl"), "w") as f:
            f.write(str(len(teile)))
        sperre = asyncio.Semaphore(GLEICHZEITIG)
        lage = {"netz_weg": False, "ok": 0}

        # Der erste Teil bekommt Vorrang: die uebrigen starten erst, wenn sein
        # Ton fliesst (oder nach kurzer Frist). So beginnt das Vorlesen und
        # auch ein Stimm- oder Tempowechsel spuerbar schneller.
        erster_laeuft = asyncio.Event()

        async def eins(i, t):
            if i > 0:
                try:
                    await asyncio.wait_for(erster_laeuft.wait(), VORRANG_FRIST)
                except asyncio.TimeoutError:
                    pass
            async with sperre:
                name = os.path.join(ordner, "%03d" % (i + 1))
                try:
                    ok = await erzeuge(t, stimme, tempo, name + ".mp3", lage,
                                       erster_laeuft.set if i == 0 else None)
                finally:
                    if i == 0:
                        erster_laeuft.set()
                if not ok:
                    open(name + ".fehlt", "w").close()

        # Alle Teile starten sofort, die Sperre laesst sie in Lesereihenfolge
        # durch. Ein Fehler in einem Teil bricht die anderen nicht ab.
        await asyncio.gather(*(eins(i, t) for i, t in enumerate(teile)), return_exceptions=True)
    except asyncio.CancelledError:
        return
    except Exception as e:
        log("auftrag %s: %r" % (ordner, e))
    try:
        open(os.path.join(ordner, "ende"), "w").close()
    except OSError:
        pass


async def main():
    loop = asyncio.get_running_loop()
    zeilen = asyncio.Queue()

    def lesen():
        for zeile in sys.stdin:
            loop.call_soon_threadsafe(zeilen.put_nowait, zeile.rstrip("\r\n"))
        loop.call_soon_threadsafe(zeilen.put_nowait, None)

    threading.Thread(target=lesen, daemon=True).start()
    print("bereit", flush=True)
    laufend = None
    while True:
        zeile = await zeilen.get()
        if laufend and not laufend.done():
            laufend.cancel()
        if zeile is None:
            return
        if not zeile or zeile == "STOP":
            continue
        teile = zeile.split("\t")
        stimme = teile[1].strip() if len(teile) > 1 and teile[1].strip() else STANDARD_STIMME
        tempo = teile[2].strip() if len(teile) > 2 and teile[2].strip() else "-5%"
        laufend = asyncio.create_task(auftrag(teile[0], stimme, tempo))


if __name__ == "__main__":
    asyncio.run(main())
