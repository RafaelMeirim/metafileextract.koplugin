@echo off
setlocal enabledelayedexpansion
echo --- KOReader Batch Renamer ---
set /p pattern="Main Title: "
set /p author="Author name: "
set /p keyword="Keyword (press Enter to skip): "
set /p series_name="Series name: "
set /p include_num="Include number in filename (y/n)? "

for %%f in (*.cbz *.epub *.pdf *.cbr) do (
    set "filename=%%f"
    
    :: Extrai apenas o ultimo numero antes da extensao usando Regex
    for /f %%n in ('powershell -command "$f = '%%f'; if ($f -match '(\d+)\.[^.]+$') { [int]$matches[1] } else { 0 }"') do set "num=%%n"
    
    set "new_name=!pattern!"
    if /i "!include_num!"=="y" set "new_name=!new_name! #!num!"
    set "new_name=!new_name! - !author!"
    if not "!keyword!"=="" set "new_name=!new_name! - !keyword!"
    set "new_name=!new_name! - !series_name! #!num!%%~xf"
    
    echo Renaming: "!filename!" to "!new_name!"
    ren "!filename!" "!new_name!"
)
pause
