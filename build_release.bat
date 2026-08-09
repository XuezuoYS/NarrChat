@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

cd /d "%~dp0"

echo ============================================
echo    NarrChat Release 构建脚本
echo ============================================
echo    1. Android arm64 APK
echo    2. Windows x64
echo    3. 全部构建
echo    0. 退出
echo ============================================

set /p choice=请选择 (0/1/2/3): 

if "%choice%"=="0" exit /b 0
if "%choice%"=="1" goto android
if "%choice%"=="2" goto windows
if "%choice%"=="3" goto all

echo 无效输入，脚本退出。
exit /b 1

:android
call :build_android
goto end

:windows
call :build_windows
goto end

:all
call :build_android
if errorlevel 1 goto end
call :build_windows
goto end

:build_android
echo.
echo [Android] 正在编译 arm64 Release APK ...
call :get_version
call flutter build apk --release --target-platform android-arm64 --build-name=%APP_VERSION% --build-number=%APP_BUILD%
if errorlevel 1 (
    echo [错误] Android 构建失败！
    exit /b 1
)
set "APK_NAME=NarrChat-v%APP_VERSION%.apk"
copy /y "build\app\outputs\flutter-apk\app-release.apk" "build\app\outputs\flutter-apk\%APK_NAME%" >nul
echo [完成] APK 已生成：
echo     build\app\outputs\flutter-apk\%APK_NAME%
exit /b 0

:build_windows
echo.
echo [Windows] 正在编译 x64 Release ...
call flutter build windows --release
if errorlevel 1 (
    echo [错误] Windows 构建失败！
    exit /b 1
)
echo [完成] Windows 程序已生成：
echo     build\windows\x64\runner\Release\
exit /b 0

REM 从 release.yaml 读取版本号（build 用作 Android versionCode）
:get_version
set "APP_VERSION="
set "APP_BUILD="
for /f "tokens=2" %%v in ('findstr /b "version:" release.yaml') do set "APP_VERSION=%%v"
for /f "tokens=2" %%b in ('findstr /b "build:" release.yaml') do set "APP_BUILD=%%b"
if "%APP_VERSION%"=="" (
    echo [警告] 未能从 release.yaml 读取版本号，使用默认值 1.0.0
    set "APP_VERSION=1.0.0"
)
if "%APP_BUILD%"=="" set "APP_BUILD=1"
exit /b 0

:end
echo.
echo 全部构建完成！
pause
exit /b 0
