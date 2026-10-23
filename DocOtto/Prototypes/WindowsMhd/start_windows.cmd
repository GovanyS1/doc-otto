@echo off
setlocal
cd /d "%~dp0"
where py >nul 2>&1
if errorlevel 1 goto try_python
py -3 -c "import sys; assert sys.version_info >= (3, 10); import tkinter" >nul 2>&1
if errorlevel 1 goto try_python
py -3 doc_otto.py
goto done
:try_python
where python >nul 2>&1
if errorlevel 1 goto missing
python -c "import sys; assert sys.version_info >= (3, 10); import tkinter" >nul 2>&1
if errorlevel 1 goto missing
python doc_otto.py
goto done
:missing
echo Install Python 3.10 or newer from https://www.python.org/downloads/windows/
echo Include Tcl/Tk and the Python launcher during installation, then reopen this file.
pause
exit /b 1
:done
if errorlevel 1 pause
