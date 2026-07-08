@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\cc-remote.ps1" %*
