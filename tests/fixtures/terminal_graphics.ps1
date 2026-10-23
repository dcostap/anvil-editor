$e = [char]27
function Send-Image($payload) {
  [Console]::Write($e + '[2;3H' + $e + '_Ga=T,f=32,s=1,v=1,i=42,p=1,c=4,r=2,C=1,q=2;' + $payload + $e + '\')
}
[Console]::Write($e + '[2J' + $e + '[H')
Send-Image '/wAA/w=='
[Console]::Write($e + '[5;1HGRAPHICS_READY')
while ($null -ne ($line = [Console]::ReadLine())) {
  switch ($line) {
    'crop' {
      [Console]::Write($e + '[2;3H' + $e + '_Ga=T,f=32,s=2,v=1,i=42,p=1,c=4,r=2,x=1,w=1,h=1,C=1,q=2;/wAA/wAA//8=' + $e + '\')
      [Console]::Write($e + '[5;1HGRAPHICS_CROP')
    }
    'png' {
      [Console]::Write($e + '[2;3H' + $e + '_Ga=T,f=100,i=42,p=1,c=4,r=2,C=1,q=2;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==' + $e + '\')
      [Console]::Write($e + '[5;1HGRAPHICS_PNG')
    }
    'replace' { Send-Image 'AAD//w=='; [Console]::Write($e + '[5;1HGRAPHICS_BLUE') }
    'delete' { [Console]::Write($e + '_Ga=d,d=I,i=42,q=2' + $e + '\' + $e + '[5;1HGRAPHICS_DELETED') }
    'scroll' { [Console]::Write($e + '[1S' + $e + '[5;1HGRAPHICS_SCROLLED') }
  }
}
