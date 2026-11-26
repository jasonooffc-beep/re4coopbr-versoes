@echo off
title RE4 Co-op BR - Ponte de rede
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ponte.ps1"
echo.
echo A ponte foi encerrada.
pause
