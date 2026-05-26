$p=Get-Process anvil -ErrorAction SilentlyContinue
$p | Select Id,MainWindowTitle,MainWindowHandle,Responding
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
 public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@
foreach($x in $p){
  $r=New-Object W+RECT
  [W]::GetWindowRect($x.MainWindowHandle,[ref]$r) | Out-Null
  "rect=$($r.Left),$($r.Top),$($r.Right),$($r.Bottom) iconic=$([W]::IsIconic($x.MainWindowHandle)) visible=$([W]::IsWindowVisible($x.MainWindowHandle))"
}
