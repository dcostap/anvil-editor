@echo off
rem A stand-in for "cargo watch", for screenshots.
echo [Running 'cargo run --release -- scenes/cornell.toml']
echo    Compiling raytracer v0.9.0
echo     Finished `release` profile [optimized] target(s) in 3.84s
echo      Running `target\release\raytracer.exe scenes/cornell.toml`
echo rendering 1920x1080, 256 spp, 12 threads
echo [##########################--------------] 64%%  eta 41s
powershell.exe -NoLogo -NoProfile -Command "Start-Sleep -Seconds 86400"
