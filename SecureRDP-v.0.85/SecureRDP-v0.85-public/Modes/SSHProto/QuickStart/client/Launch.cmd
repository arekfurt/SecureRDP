@echo off
:: SecureRDP - Client Launcher
:: Double-click this file to connect.
:: Calls Connect-SecureRDP.ps1 directly -- no encrypted package required.
:: This file bypasses the PowerShell execution policy for this session only.
:: No changes are made to your system's execution policy settings.
powershell.exe -ExecutionPolicy Bypass -STA -File "%~dp0Connect-SecureRDP.ps1"
