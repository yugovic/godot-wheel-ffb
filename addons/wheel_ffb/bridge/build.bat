@echo off
rem Build WheelBridge.exe with MSVC (C++ build tools + Windows SDK; no extra downloads).
rem Output: ..\bin\WheelBridge.exe (the file the addon launches)
setlocal enabledelayedexpansion
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
set "FOUND="
for /f "usebackq delims=" %%I in (`"%VSWHERE%" -all -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
  if not defined FOUND (
    if exist "%%I\VC\Auxiliary\Build\vcvars64.bat" (
      call "%%I\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
      where cl >nul 2>&1
      if not errorlevel 1 set "FOUND=%%I"
    )
  )
)
if not defined FOUND (
  echo MSVC C++ build tools not found. Install "Desktop development with C++" or Build Tools for Visual Studio.
  exit /b 1
)
echo using %FOUND%
cd /d "%~dp0"
if not exist obj mkdir obj
cl /nologo /O2 /EHsc /std:c++17 /utf-8 /W3 /Fe:..\bin\WheelBridge.exe /Fo:obj\ wheel_bridge.cpp
if errorlevel 1 exit /b 1
rmdir /s /q obj
echo built %~dp0..\bin\WheelBridge.exe