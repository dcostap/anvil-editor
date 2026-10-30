param([Parameter(Mandatory=$true)][string]$WidthFile)

# Read the shell's console size while PSReadLine waits for input.
Add-Type @'
using System;
using System.IO;
using System.Threading;

public static class AnvilResizeReport {
  public static void Start(string path) {
    var thread = new Thread(() => {
      int previous = -1;
      while (true) {
        try {
          int width = Console.WindowWidth;
          if (width != previous) {
            File.WriteAllText(path, width.ToString());
            Console.Write("\u001b]2;ANVIL_WIDTH_" + width + "\u0007");
            previous = width;
          }
        } catch (IOException) {
          // A concurrent reader can briefly hold the report file.
        }
        Thread.Sleep(10);
      }
    });
    thread.IsBackground = true;
    thread.Start();
  }
}
'@
[AnvilResizeReport]::Start($WidthFile)
function global:prompt { 'PS resize> ' }
