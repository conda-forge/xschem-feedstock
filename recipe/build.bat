@echo on
setlocal EnableDelayedExpansion

rem Windows (MSVC + Win32 Tk + Cairo) build script for xschem in conda-forge.
rem Upstream xschem uses scconfig (./configure + make) on Unix and a Visual Studio
rem project (XSchemWin/XSchemWin_cairo.vcxproj) on Windows. Here we invoke
rem win_bison/win_flex + cl.exe + link.exe directly against conda-forge's
rem %LIBRARY_INC% and %LIBRARY_LIB%.

set "BUILD_DIR=%SRC_DIR%\build-win"
set "OBJ_DIR=%BUILD_DIR%\obj"
mkdir "%OBJ_DIR%"
if errorlevel 1 exit /b 1

rem 1. Locate bison and flex (conda-forge winflexbison provides win_bison/win_flex).
set "BISON="
if exist "%BUILD_PREFIX%\Library\bin\win_bison.exe" (
    set "BISON=%BUILD_PREFIX%\Library\bin\win_bison.exe"
) else if exist "%BUILD_PREFIX%\Library\bin\bison.exe" (
    set "BISON=%BUILD_PREFIX%\Library\bin\bison.exe"
) else (
    for /f "delims=" %%B in ('where win_bison.exe bison.exe 2^>nul') do if "!BISON!"=="" set "BISON=%%B"
)
if "%BISON%"=="" (
    echo ERROR: Could not find win_bison.exe or bison.exe.
    exit /b 1
)

set "FLEX="
if exist "%BUILD_PREFIX%\Library\bin\win_flex.exe" (
    set "FLEX=%BUILD_PREFIX%\Library\bin\win_flex.exe"
) else if exist "%BUILD_PREFIX%\Library\bin\flex.exe" (
    set "FLEX=%BUILD_PREFIX%\Library\bin\flex.exe"
) else (
    for /f "delims=" %%F in ('where win_flex.exe flex.exe 2^>nul') do if "!FLEX!"=="" set "FLEX=%%F"
)
if "%FLEX%"=="" (
    echo ERROR: Could not find win_flex.exe or flex.exe.
    exit /b 1
)

rem 2. Generate parser/lexer sources (matching XSchemWin_cairo.vcxproj & src/Makefile.in).
pushd "%BUILD_DIR%"
if errorlevel 1 exit /b 1

"%BISON%" -d -o expandlabel.c "%SRC_DIR%\src\expandlabel.y"
if errorlevel 1 (popd & exit /b 1)

"%FLEX%" -l -o parselabel.c "%SRC_DIR%\src\parselabel.l"
if errorlevel 1 (popd & exit /b 1)

"%BISON%" -p kk -o eval_expr.c "%SRC_DIR%\src\eval_expr.y"
if errorlevel 1 (popd & exit /b 1)

rem 3. Generate Windows config.h (shared conda-forge cairo.dll, no X11/XRender).
rem    src/xschem.h includes "../XSchemWin/config.h" on Windows, while
rem    src/cairo_jpg.c includes "config.h", so write to both locations.
(
    echo #define HAS_CAIRO 1
    echo #define HAS_XRENDER 0
    echo #define HAS_POPEN 0
    echo #define USER_CONF_DIR "userConf"
    echo #define _XOPEN_SOURCE
) > "%SRC_DIR%\XSchemWin\config.h"
if errorlevel 1 (popd & exit /b 1)
copy /y "%SRC_DIR%\XSchemWin\config.h" "%BUILD_DIR%\config.h"
if errorlevel 1 (popd & exit /b 1)

rem 3b. Conda-forge's Windows tk package installs public headers (tk.h,
rem     tkDecls.h, tkPlatDecls.h, tkIntXlibDecls.h, X11/*.h) via Tk's
rem     makefile.vc, but does not ship Tk's private win/ headers (tkWin.h,
rem     tkWinInt.h). xschem only needs Tk_GetHWND (tkPlatDecls.h), Tk's Xlib
rem     emulation declarations (tkIntXlibDecls.h), and Tk's bundled X11/*.h.
if exist "%LIBRARY_INC%\tkWin.h" goto :have_tkwin
(
    echo #ifndef _TKWIN
    echo #define _TKWIN
    echo #ifndef _TK
    echo #include "tk.h"
    echo #endif
    echo #include "windows.h"
    echo #include "tkPlatDecls.h"
    echo #endif
) > "%BUILD_DIR%\tkWin.h"
if errorlevel 1 (popd & exit /b 1)
:have_tkwin

if exist "%LIBRARY_INC%\tkWinInt.h" goto :have_tkwinint
(
    echo #ifndef _TKWININT
    echo #define _TKWININT
    echo #include "io.h"
    echo #include "malloc.h"
    echo #include "tchar.h"
    echo #include "tkWin.h"
    echo #include "tkIntXlibDecls.h"
    echo #include "X11/Xlib.h"
    echo #include "X11/cursorfont.h"
    echo #include "X11/keysym.h"
    echo #include "X11/Xatom.h"
    echo #include "X11/Xutil.h"
    echo #ifndef __GNUC__
    echo #ifndef strncasecmp
    echo #define strncasecmp _strnicmp
    echo #endif
    echo #ifndef strcasecmp
    echo #define strcasecmp _stricmp
    echo #endif
    echo #endif
    echo #endif
) > "%BUILD_DIR%\tkWinInt.h"
if errorlevel 1 (popd & exit /b 1)
:have_tkwinint

rem 4. Detect Tcl/Tk import libraries shipped by conda-forge's tk package.
set "TCL_LIB="
for %%L in (tcl86t.lib tcl86.lib) do if "!TCL_LIB!"=="" if exist "%LIBRARY_LIB%\%%L" set "TCL_LIB=%%L"
set "TK_LIB="
for %%L in (tk86t.lib tk86.lib) do if "!TK_LIB!"=="" if exist "%LIBRARY_LIB%\%%L" set "TK_LIB=%%L"
if "%TCL_LIB%"=="" (echo ERROR: tcl86*.lib not found in %LIBRARY_LIB% & popd & exit /b 1)
if "%TK_LIB%"==""  (echo ERROR: tk86*.lib not found in %LIBRARY_LIB%  & popd & exit /b 1)

rem 5. Compile all C sources in parallel (/MP) with MSVC.
rem    /Gy (Function-Level Linking) matches XSchemWin_cairo.vcxproj so link.exe
rem    /OPT:REF discards unreferenced Unix-only functions (e.g. xserver_ok).
cl /nologo /c /O2 /MD /W3 /MP /Gy ^
    /DNDEBUG /D_CONSOLE /DWIN32 /DUNICODE /D_UNICODE /DYY_NO_UNISTD_H /D_CRT_SECURE_NO_WARNINGS ^
    /I"%BUILD_DIR%" ^
    /I"%SRC_DIR%\src" ^
    /I"%LIBRARY_INC%" ^
    /I"%LIBRARY_INC%\cairo" ^
    /Fo"%OBJ_DIR%\\" ^
    "%SRC_DIR%\src\actions.c" ^
    "%SRC_DIR%\src\cairo_jpg.c" ^
    "%SRC_DIR%\src\callback.c" ^
    "%SRC_DIR%\src\check.c" ^
    "%SRC_DIR%\src\clip.c" ^
    "%SRC_DIR%\src\draw.c" ^
    "%SRC_DIR%\src\editprop.c" ^
    "%SRC_DIR%\src\findnet.c" ^
    "%SRC_DIR%\src\font.c" ^
    "%SRC_DIR%\src\globals.c" ^
    "%SRC_DIR%\src\hash_iterator.c" ^
    "%SRC_DIR%\src\hilight.c" ^
    "%SRC_DIR%\src\icon.c" ^
    "%SRC_DIR%\src\in_memory_undo.c" ^
    "%SRC_DIR%\src\main.c" ^
    "%SRC_DIR%\src\move.c" ^
    "%SRC_DIR%\src\netlist.c" ^
    "%SRC_DIR%\src\node_hash.c" ^
    "%SRC_DIR%\src\options.c" ^
    "%SRC_DIR%\src\paste.c" ^
    "%SRC_DIR%\src\psprint.c" ^
    "%SRC_DIR%\src\save.c" ^
    "%SRC_DIR%\src\scheduler.c" ^
    "%SRC_DIR%\src\select.c" ^
    "%SRC_DIR%\src\spice_netlist.c" ^
    "%SRC_DIR%\src\store.c" ^
    "%SRC_DIR%\src\svgdraw.c" ^
    "%SRC_DIR%\src\tedax_netlist.c" ^
    "%SRC_DIR%\src\token.c" ^
    "%SRC_DIR%\src\verilog_netlist.c" ^
    "%SRC_DIR%\src\vhdl_netlist.c" ^
    "%SRC_DIR%\src\xinit.c" ^
    "%BUILD_DIR%\eval_expr.c" ^
    "%BUILD_DIR%\expandlabel.c" ^
    "%BUILD_DIR%\parselabel.c"
if errorlevel 1 (popd & exit /b 1)

rem 6. Link xschem.exe (and rawtovcd.exe helper tool).
link /NOLOGO /SUBSYSTEM:CONSOLE /OPT:REF /OPT:ICF ^
    /LIBPATH:"%LIBRARY_LIB%" ^
    /OUT:"%BUILD_DIR%\xschem.exe" ^
    "%OBJ_DIR%\*.obj" ^
    cairo.lib %TCL_LIB% %TK_LIB% ^
    kernel32.lib user32.lib gdi32.lib winspool.lib comdlg32.lib ^
    advapi32.lib shell32.lib ole32.lib oleaut32.lib uuid.lib
if errorlevel 1 (popd & exit /b 1)

cl /nologo /O2 /MD /DNDEBUG /D_CRT_SECURE_NO_WARNINGS ^
    "%SRC_DIR%\src\rawtovcd.c" /Fe:"%BUILD_DIR%\rawtovcd.exe"
if errorlevel 1 (popd & exit /b 1)

popd

rem 7. Install binaries and share tree matching XSchemWin/INSTALL_WIN & src/Makefile.in.
set "XSHAREDIR=%LIBRARY_PREFIX%\share\xschem"
if not exist "%LIBRARY_BIN%" mkdir "%LIBRARY_BIN%"
if not exist "%XSHAREDIR%" mkdir "%XSHAREDIR%"

copy /y "%BUILD_DIR%\xschem.exe" "%LIBRARY_BIN%\xschem.exe"
if errorlevel 1 exit /b 1
copy /y "%BUILD_DIR%\rawtovcd.exe" "%LIBRARY_BIN%\rawtovcd.exe"
if errorlevel 1 exit /b 1

for %%F in (
    keys.help xschem.help xschem.tcl break.awk convert_to_verilog2001.awk
    flatten.awk flatten_tedax.awk flatten_savenodes.awk make_sym.awk make_sym_lcc.awk
    symgen.awk order_labels.awk sort_labels.awk spice.awk tedax.awk verilog.awk
    vhdl.awk hspice_backannotate.tcl add_custom_menu.tcl create_graph.tcl
    add_custom_button.tcl change_index.tcl icon.xpm resources.tcl xschemrc
    ngspice_backannotate.tcl gschemtoxschem.awk mouse_bindings.tcl cadence_style_rc
    place_sym_pins.tcl place_pins.tcl make_sch_from_spice.awk make_sym_from_spice.awk
) do (
    copy /y "%SRC_DIR%\src\%%F" "%XSHAREDIR%\%%F"
    if errorlevel 1 exit /b 1
)

xcopy /e /i /y "%SRC_DIR%\src\systemlib" "%XSHAREDIR%\systemlib"
if errorlevel 1 exit /b 1

xcopy /e /i /y "%SRC_DIR%\xschem_library" "%XSHAREDIR%\xschem_library"
if errorlevel 1 exit /b 1
