@echo off
start "zapret: ws-proxy" /min powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ws-proxy.ps1"
