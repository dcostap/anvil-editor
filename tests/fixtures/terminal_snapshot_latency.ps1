Add-Type -TypeDefinition @'
using System;
using System.Text;
public static class SnapshotLatency {
    public static void Run() {
        var random = new Random(42);
        var batch = new StringBuilder();
        for (int row = 0; row < 6000; row++) {
            for (int group = 0; group < 30; group++) {
                batch.Append("\x1b[38;2;").Append(random.Next(256)).Append(';')
                    .Append(random.Next(256)).Append(';').Append(random.Next(256)).Append('m');
                for (int cell = 0; cell < 8; cell++) batch.Append((char)random.Next(33, 127));
            }
            batch.Append("\x1b[0m\r\n");
            if (row % 100 == 99) { Console.Write(batch.ToString()); batch.Clear(); }
        }
        Console.WriteLine("SNAPSHOT_LATENCY_READY");
        string input;
        while ((input = Console.ReadLine()) != null) Console.WriteLine("REPLY_" + input);
    }
}
'@
[SnapshotLatency]::Run()
