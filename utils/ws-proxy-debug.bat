@echo off
chcp 437 > nul
powershell -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0ws-proxy.ps1"
