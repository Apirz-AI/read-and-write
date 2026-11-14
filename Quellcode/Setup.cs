// Setup-Assistent fuer Read & Write.
// Wird von Setup-bauen.ps1 mit dem csc von Windows uebersetzt. Das Programmpaket
// steckt als Ressource "paket.zip" in der exe. Der Assistent entpackt es in den
// Temp-Ordner und fuehrt Installieren.ps1 aus, die Meldungen laufen live mit.
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Read & Write Setup")]
[assembly: AssemblyProduct("Read & Write")]
[assembly: AssemblyCompany("A.Pirzadeh")]
[assembly: AssemblyVersion("@VERSION@.0.0")]

public class Setup : Form
{
    const string VERSION = "@VERSION@";
    static readonly Color Dunkel = Color.FromArgb(32, 32, 32);
    static readonly Color Flaeche = Color.FromArgb(43, 43, 43);
    static readonly Color Schrift = Color.FromArgb(240, 240, 240);
    static readonly Color Grau = Color.FromArgb(170, 170, 170);
    static readonly Color Akzent = Color.FromArgb(232, 232, 232);   // heller Hauptknopf, ohne Blau

    Panel seite;
    Button weiter, zurueck, abbrechen;
    int schritt = 0;
    CheckBox desktop, autostart, starten;
    ProgressBar balken;
    Label status;
    TextBox protokoll;
    string ordner;
    bool fertig, fehler;
    int zeilen;

    [STAThread]
    static int Main(string[] argumente)
    {
        // Ohne Fenster fuer Tests und Verteilung: Setup.exe /still
        foreach (var a in argumente)
            if (a.Equals("/still", StringComparison.OrdinalIgnoreCase)) return Still();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new Setup());
        return 0;
    }

    static string Entpacken()
    {
        string ziel = Path.Combine(Path.GetTempPath(), "read-und-write-setup");
        if (Directory.Exists(ziel)) Directory.Delete(ziel, true);
        Directory.CreateDirectory(ziel);
        using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("paket.zip"))
        using (var z = new ZipArchive(s, ZipArchiveMode.Read))
            z.ExtractToDirectory(ziel);
        return ziel;
    }

    static int Still()
    {
        try
        {
            string ordner = Entpacken();
            var p = Process.Start(new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(ordner, "Installieren.ps1") + "\"")
                { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = ordner });
            p.WaitForExit();
            try { Directory.Delete(ordner, true); } catch { }
            return p.ExitCode;
        }
        catch { return 1; }
    }

    public Setup()
    {
        Text = "Read & Write " + VERSION + " installieren";
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(560, 380);
        BackColor = Dunkel;
        ForeColor = Schrift;
        Font = new Font("Segoe UI", 10f);

        seite = new Panel { Location = new Point(0, 0), Size = new Size(560, 316), BackColor = Dunkel };
        Controls.Add(seite);
        var leiste = new Panel { Location = new Point(0, 316), Size = new Size(560, 64), BackColor = Flaeche };
        Controls.Add(leiste);
        abbrechen = Knopf("Abbrechen", 444, false);
        weiter = Knopf("Weiter", 332, true);
        zurueck = Knopf("Zurück", 220, false);
        leiste.Controls.AddRange(new Control[] { zurueck, weiter, abbrechen });
        weiter.Click += (s, e) => Weiter();
        zurueck.Click += (s, e) => { schritt = 0; Zeige(); };
        abbrechen.Click += (s, e) => Close();
        FormClosing += (s, e) =>
        {
            if (schritt == 2 && !fertig) { e.Cancel = true; return; }
        };

        desktop = Haken("Symbol auf dem Desktop anlegen", true);
        autostart = Haken("Beim Einschalten des Rechners automatisch starten", true);
        starten = Haken("Read & Write jetzt starten", true);
        Zeige();
    }

    Button Knopf(string text, int x, bool haupt)
    {
        var b = new Button
        {
            Text = text, Location = new Point(x, 14), Size = new Size(100, 36),
            FlatStyle = FlatStyle.Flat, BackColor = haupt ? Akzent : Color.FromArgb(60, 60, 60),
            ForeColor = haupt ? Dunkel : Color.White, Cursor = Cursors.Hand
        };
        b.FlatAppearance.BorderSize = 0;
        return b;
    }

    CheckBox Haken(string text, bool an)
    {
        return new CheckBox { Text = text, Checked = an, AutoSize = true, ForeColor = Schrift, BackColor = Dunkel };
    }

    Label Titel(string text, int y)
    {
        return new Label { Text = text, Location = new Point(156, y), AutoSize = true, Font = new Font("Segoe UI Semibold", 16f), ForeColor = Schrift };
    }

    Label Absatz(string text, int y, int hoehe)
    {
        return new Label { Text = text, Location = new Point(156, y), Size = new Size(380, hoehe), ForeColor = Grau };
    }

    Bitmap logoBild;
    PictureBox Logo()
    {
        if (logoBild == null)
        {
            try
            {
                using (var st = Assembly.GetExecutingAssembly().GetManifestResourceStream("logo.ico"))
                    logoBild = new Icon(st, new Size(256, 256)).ToBitmap();
            }
            catch { logoBild = Icon.ToBitmap(); }
        }
        return new PictureBox { Image = logoBild, SizeMode = PictureBoxSizeMode.Zoom, Location = new Point(28, 36), Size = new Size(104, 104), BackColor = Dunkel };
    }

    void Zeige()
    {
        seite.Controls.Clear();
        seite.Controls.Add(Logo());
        zurueck.Visible = schritt == 1;
        abbrechen.Enabled = schritt != 2;
        weiter.Enabled = true;
        if (schritt == 0)
        {
            seite.Controls.Add(Titel("Willkommen", 36));
            seite.Controls.Add(Absatz(
                "Dieser Assistent installiert Read & Write " + VERSION + ".\n\n" +
                "Read & Write ist ein kleiner schwebender Knopf: Er liest kopierten Text " +
                "mit natürlichen Stimmen vor und schreibt Gesprochenes direkt in jedes Textfeld.\n\n" +
                "Adminrechte sind nicht nötig. Beim ersten Mal dauert die Installation " +
                "einige Minuten, weil Stimmen und Sprachmodell geladen werden.", 84, 220));
            weiter.Text = "Weiter";
        }
        else if (schritt == 1)
        {
            seite.Controls.Add(Titel("Einstellungen", 36));
            seite.Controls.Add(Absatz("Installiert wird für diesen Benutzer in\n" +
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs\\Read und Write"), 84, 50));
            desktop.Location = new Point(156, 150);
            autostart.Location = new Point(156, 182);
            seite.Controls.Add(desktop);
            seite.Controls.Add(autostart);
            seite.Controls.Add(Absatz("Eine frühere Fassung wird automatisch ersetzt, Einstellungen bleiben erhalten.", 226, 50));
            weiter.Text = "Installieren";
        }
        else if (schritt == 2)
        {
            seite.Controls.Add(Titel("Installation läuft", 36));
            status = Absatz("Wird vorbereitet ...", 76, 40);
            status.ForeColor = Schrift;
            seite.Controls.Add(status);
            balken = new ProgressBar { Location = new Point(156, 122), Size = new Size(376, 12), Style = ProgressBarStyle.Continuous, Maximum = 100 };
            seite.Controls.Add(balken);
            protokoll = new TextBox
            {
                Location = new Point(156, 146), Size = new Size(376, 150), Multiline = true, ReadOnly = true,
                ScrollBars = ScrollBars.Vertical, BackColor = Flaeche, ForeColor = Grau, BorderStyle = BorderStyle.None,
                Font = new Font("Consolas", 9f)
            };
            seite.Controls.Add(protokoll);
            weiter.Enabled = false;
            weiter.Text = "Weiter";
            Installieren();
        }
        else
        {
            seite.Controls.Add(Titel(fehler ? "Nicht ganz fertig" : "Fertig", 36));
            seite.Controls.Add(Absatz(fehler
                ? "Die Installation hat gemeldet, dass etwas fehlt. Read & Write läuft trotzdem, " +
                  "Details stehen im Protokoll im Temp-Ordner unter read-und-write-installation.txt."
                : "Read & Write ist installiert. Der Knopf erscheint unten rechts auf dem Bildschirm, " +
                  "im Startmenü steht \"Read & Write\".\n\nDeinstallieren geht jederzeit über " +
                  "Einstellungen, Apps, installierte Apps.", 84, 130));
            starten.Location = new Point(156, 230);
            seite.Controls.Add(starten);
            if (!fehler)
            {
                var anleitung = new LinkLabel
                {
                    Text = "Anleitung öffnen", Location = new Point(156, 266), AutoSize = true,
                    LinkColor = Schrift, ActiveLinkColor = Grau, VisitedLinkColor = Schrift, BackColor = Dunkel
                };
                anleitung.LinkClicked += (s, e) =>
                {
                    try
                    {
                        string ziel = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs\\Read und Write\\Anleitung.html");
                        Process.Start(new ProcessStartInfo(ziel) { UseShellExecute = true });
                    }
                    catch { }
                };
                seite.Controls.Add(anleitung);
            }
            weiter.Text = "Fertigstellen";
            abbrechen.Visible = false;
        }
    }

    void Weiter()
    {
        if (schritt == 3) { if (starten.Checked) Starten(); Close(); return; }
        schritt++;
        Zeige();
    }

    void Starten()
    {
        try
        {
            string ziel = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs\\Read und Write");
            Process.Start(new ProcessStartInfo(Path.Combine(ziel, "Read & Write.exe")) { WorkingDirectory = ziel, UseShellExecute = false });
        }
        catch { }
    }

    void Installieren()
    {
        try
        {
            ordner = Entpacken();
        }
        catch (Exception ex)
        {
            Zeile("FEHLER beim Entpacken: " + ex.Message);
            fehler = true;
            Abschluss();
            return;
        }

        string args = "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(ordner, "Installieren.ps1") + "\" -NichtStarten";
        if (!desktop.Checked) args += " -KeinDesktop";
        if (!autostart.Checked) args += " -KeinAutostart";
        var p = new Process
        {
            StartInfo = new ProcessStartInfo("powershell.exe", args)
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = ordner,
                StandardOutputEncoding = System.Text.Encoding.UTF8
            },
            EnableRaisingEvents = true
        };
        p.OutputDataReceived += (s, e) => { if (e.Data != null) BeginInvoke((Action)(() => Zeile(e.Data))); };
        p.ErrorDataReceived += (s, e) => { };
        p.Exited += (s, e) => BeginInvoke((Action)(() =>
        {
            if (p.ExitCode != 0) fehler = true;
            try { Directory.Delete(ordner, true); } catch { }
            Abschluss();
        }));
        try
        {
            p.Start();
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
        }
        catch (Exception ex)
        {
            Zeile("FEHLER: " + ex.Message);
            fehler = true;
            Abschluss();
        }
    }

    void Zeile(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        protokoll.AppendText(text + Environment.NewLine);
        if (text.StartsWith("HINWEIS") || text.StartsWith("FEHLER")) fehler = true;
        else status.Text = text;
        zeilen++;
        balken.Value = Math.Min(95, zeilen * 8);
    }

    void Abschluss()
    {
        fertig = true;
        balken.Value = 100;
        weiter.Enabled = true;
        schritt = 3;
        Zeige();
    }
}
