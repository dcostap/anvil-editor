@echo off
rem A stand-in for the Gradle wrapper, for screenshots.
echo ^> Task :composeApp:compileKotlinDesktop UP-TO-DATE
echo ^> Task :composeApp:desktopProcessResources UP-TO-DATE
echo ^> Task :composeApp:runAppDesktop
echo Hot reload enabled. Watching 214 files.
echo [main] INFO  Shop - Catalog loaded: 1,284 products
powershell.exe -NoLogo -NoProfile -Command "Start-Sleep -Seconds 86400"
