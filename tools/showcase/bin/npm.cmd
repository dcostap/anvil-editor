@echo off
rem A stand-in for "npm run dev", for screenshots.
echo.
echo ^> orbit-api@2.4.0 dev
echo ^> vite --port 5173
echo.
echo   VITE v6.3.1  ready in 412 ms
echo.
echo   -^> Local:   http://localhost:5173/
echo   -^> Network: use --host to expose
echo.
echo   [api] listening on :8080
echo   [api] GET /v1/invoices 200 4.1ms
echo   [api] POST /v1/invoices/preview 200 11.8ms
powershell.exe -NoLogo -NoProfile -Command "Start-Sleep -Seconds 86400"
