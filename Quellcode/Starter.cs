// Starter fuer Read & Write: eine kleine exe mit dem Logo als Symbol.
// Sie startet den Knopf ohne Konsolenfenster. Weil Verknuepfungen und die
// Taskleiste auf diese exe zeigen, erscheint ueberall das Logo.
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

[assembly: AssemblyTitle("Read & Write")]
[assembly: AssemblyProduct("Read & Write")]
[assembly: AssemblyCompany("A.Pirzadeh")]
[assembly: AssemblyVersion("@VERSION@.0.0")]

static class Starter
{
    static void Main()
    {
        string ordner = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        var si = new ProcessStartInfo("powershell.exe",
            "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + Path.Combine(ordner, "Read-und-Write.ps1") + "\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = ordner
        };
        Process.Start(si);
    }
}
