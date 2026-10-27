@ECHO OFF
:: PixelOS factory image installer for the Pixel 5 (redfin).
:: Flashes PixelOS, installs the PixelOS verified boot key and wipes the
:: device. The phone must already run the latest stock Android 14 firmware
:: (UP1A.231105.001.B2); the bootloader refuses single firmware partitions.
:: Needs Android platform-tools 35 or newer.
SETLOCAL ENABLEDELAYEDEXPANSION
CD /D "%~dp0"

SET TAG=@TAG@
SET IMAGE=image-redfin-%TAG%.zip

WHERE fastboot >NUL 2>&1 || (ECHO Error: fastboot not found. Install Android platform-tools and add them to PATH. & GOTO :fail)
SET FBVER=0
FOR /F "tokens=3 delims=. " %%v IN ('fastboot --version ^| FINDSTR /B "fastboot version"') DO SET FBVER=%%v
IF !FBVER! LSS 35 (ECHO Error: fastboot is too old ^(!FBVER!^). Update Android platform-tools to 35 or newer. & GOTO :fail)
FOR %%f IN (%IMAGE% avb_pkmd.bin) DO IF NOT EXIST "%%f" (ECHO Error: missing %%f. Extract the whole factory zip first. & GOTO :fail)

ECHO PixelOS %TAG% for Pixel 5 (redfin)
ECHO.
ECHO Put the phone in bootloader mode (power off, hold Power + Volume Down) and connect it.
ECHO Waiting for the device...
CALL :wait

SET PRODUCT=
FOR /F "tokens=2" %%p IN ('fastboot getvar product 2^>^&1 ^| FINDSTR /B "product:"') DO SET PRODUCT=%%p
IF NOT "!PRODUCT!"=="redfin" (ECHO Error: this is '!PRODUCT!', not a Pixel 5 ^(redfin^). Nothing was flashed. & GOTO :fail)
SET UNLOCKED=
FOR /F "tokens=2" %%u IN ('fastboot getvar unlocked 2^>^&1 ^| FINDSTR /B "unlocked:"') DO SET UNLOCKED=%%u
IF NOT "!UNLOCKED!"=="yes" (ECHO Error: the bootloader is locked. Enable OEM unlocking in Developer options, then run: fastboot flashing unlock & GOTO :fail)

SET BLVER=
FOR /F "tokens=2" %%b IN ('fastboot getvar version-bootloader 2^>^&1 ^| FINDSTR /B "version-bootloader:"') DO SET BLVER=%%b
SET BBVER=
FOR /F "tokens=2" %%b IN ('fastboot getvar version-baseband 2^>^&1 ^| FINDSTR /B "version-baseband:"') DO SET BBVER=%%b
ECHO.
ECHO Bootloader: !BLVER!   Modem: !BBVER!
ECHO The phone must have been updated to the latest stock Android 14 (UP1A.231105.001.B2)
ECHO before installing PixelOS. If unsure, flash it first from https://flash.android.com
ECHO.
ECHO WARNING: this erases ALL data on the phone and installs PixelOS %TAG%.
SET /P ANSWER="Continue? [y/N] "
IF /I NOT "!ANSWER!"=="y" (ECHO Cancelled. Nothing was flashed. & GOTO :end)

ECHO.
ECHO ^>^> Installing the PixelOS verified boot key
fastboot erase avb_custom_key || GOTO :fail
fastboot flash avb_custom_key avb_pkmd.bin || GOTO :fail

ECHO ^>^> Flashing PixelOS and wiping data
fastboot -w --skip-reboot update %IMAGE% || GOTO :fail
fastboot reboot-bootloader || GOTO :fail
CALL :wait

ECHO.
ECHO PixelOS is installed.
ECHO.
ECHO You can now relock the bootloader. A locked bootloader verifies PixelOS on every
ECHO boot and blocks tampering. The phone will show a yellow 'different operating
ECHO system' notice at boot; that is expected. Locking wipes the phone again, so do it now.
SET /P ANSWER="Lock the bootloader now? Confirm on the phone with Volume keys + Power. [y/N] "
IF /I "!ANSWER!"=="y" (
    fastboot flashing lock
    ECHO Locked. Choose Start on the phone to boot PixelOS.
    ECHO Keep OEM unlocking enabled until you have checked that PixelOS boots.
) ELSE (
    fastboot reboot
    ECHO Booting PixelOS. To lock later: reboot to bootloader and run: fastboot flashing lock
)
GOTO :end

:wait
TIMEOUT /T 5 /NOBREAK >NUL
:waitloop
fastboot devices 2>NUL | FINDSTR /R "fastboot$" >NUL && EXIT /B 0
TIMEOUT /T 1 /NOBREAK >NUL
GOTO :waitloop

:fail
ECHO.
ECHO Flashing stopped. Fix the error above and run this script again.
PAUSE
EXIT /B 1

:end
PAUSE
EXIT /B 0
