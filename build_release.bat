@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

cd /d "%~dp0"

REM 最终发布产物目录（相对项目根目录）
set "RELEASE_DIR=build\release"
if not exist "%RELEASE_DIR%" mkdir "%RELEASE_DIR%"

echo ============================================
echo    NarrChat Release 构建脚本
echo ============================================
echo    1. Android arm64 APK
echo    2. Windows x64 (ZIP 便携包)
echo    3. 全部构建
echo    0. 退出
echo ============================================
echo    产物输出目录：%RELEASE_DIR%
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
set "APK_SRC=build\app\outputs\flutter-apk\app-release.apk"
if not exist "%APK_SRC%" (
    echo [错误] 未找到构建产物：%APK_SRC%
    exit /b 1
)
set "APK_NAME=NarrChat-Android-arm64-%APP_VERSION%-%APP_BUILD%.apk"
move /y "%APK_SRC%" "%RELEASE_DIR%\%APK_NAME%" >nul
if errorlevel 1 (
    echo [错误] 移动 APK 到发布目录失败！
    exit /b 1
)
echo [完成] APK 已生成：
echo     %RELEASE_DIR%\%APK_NAME%
exit /b 0

:build_windows
echo.
echo [Windows] 正在编译 x64 Release ...
call flutter build windows --release
if errorlevel 1 (
    echo [错误] Windows 构建失败！
    exit /b 1
)
call :get_version
set "WIN_SRC=build\windows\x64\runner\Release"
if not exist "%WIN_SRC%\narrchat.exe" (
    echo [错误] 未找到构建产物：%WIN_SRC%\narrchat.exe
    exit /b 1
)
set "ZIP_NAME=NarrChat-Windows-x64-%APP_VERSION%-%APP_BUILD%.zip"
set "ZIP_PATH=%RELEASE_DIR%\%ZIP_NAME%"
REM 压缩包内顶层目录名固定为 Narrchat（解压后即得统一程序文件夹，实现类安装包效果）
set "WIN_STAGE=%RELEASE_DIR%\Narrchat"

REM 清理旧的同名产物，避免残留（若 ZIP 被占用则明确提示，防止打包阶段再次报错）
if exist "%ZIP_PATH%" del /f /q "%ZIP_PATH%" 2>nul
if exist "%ZIP_PATH%" (
    echo [错误] 无法删除旧的 %ZIP_NAME%，文件正被其他程序占用。
    echo        请关闭正在预览或使用该 ZIP 的程序后重新构建。
    exit /b 1
)
if exist "%WIN_STAGE%" rmdir /s /q "%WIN_STAGE%"
REM 顺带清理旧命名残留的暂存目录（NarrChat / NarrChat-Windows-x64-* 等）
for /d %%d in ("%RELEASE_DIR%\NarrChat*") do if exist "%%d" rmdir /s /q "%%d"

REM 复制产物到暂存目录，使 ZIP 解压后是干净的顶层文件夹
mkdir "%WIN_STAGE%"
xcopy /e /i /q /y "%WIN_SRC%" "%WIN_STAGE%" >nul
if errorlevel 1 (
    echo [错误] 复制 Windows 产物失败！
    exit /b 1
)

echo [打包] 正在压缩为 ZIP 便携包 ...
powershell -NoProfile -Command "Compress-Archive -Path '%WIN_STAGE%' -DestinationPath '%ZIP_PATH%' -Force"
if errorlevel 1 (
    echo [错误] ZIP 打包失败！
    exit /b 1
)

REM 清理暂存目录
rmdir /s /q "%WIN_STAGE%"

echo [完成] ZIP 已生成：
echo     %ZIP_PATH%
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
