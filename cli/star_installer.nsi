; NSIS installer script for the `star` CLI tool.
;
; Called by release_windows.sh after staging the binary and DLLs in PKG_DIR.
; Required /D defines (all passed on the makensis command line):
;   STAR_VERSION — e.g. 1.2.3
;   ARCH         — e.g. x64
;   PKG_DIR      — Windows path to the staging dir (contains star.exe + *.dll)
;   OUTPUT_FILE  — Windows path for the generated setup .exe

!define APP_NAME      "Star CLI"
!define APP_KEY       "StarCLI"
!define APP_PUBLISHER "Brian Martin"
!define REG_UNINSTALL "Software\Microsoft\Windows\CurrentVersion\Uninstall\${APP_KEY}"

Name    "${APP_NAME} ${STAR_VERSION}"
OutFile "${OUTPUT_FILE}"
InstallDir "$PROGRAMFILES64\Star"
InstallDirRegKey HKLM "${REG_UNINSTALL}" "InstallLocation"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
Unicode true

!include "LogicLib.nsh"
!include "MUI2.nsh"

!define MUI_ABORTWARNING
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"

; ── Install ───────────────────────────────────────────────────────────────────
Section "Install"
    SetOutPath "$INSTDIR"
    File "${PKG_DIR}\star.exe"
    File "${PKG_DIR}\*.dll"

    WriteUninstaller "$INSTDIR\uninstall.exe"

    ; Add $INSTDIR to the system PATH idempotently via PowerShell.
    ; NSIS expands $INSTDIR to the chosen install directory before writing.
    FileOpen  $0 "$TEMP\star_add_path.ps1" w
    FileWrite $0 "$$d = '$INSTDIR'$\n"
    FileWrite $0 "$$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'$\n"
    FileWrite $0 "$$p = (Get-ItemProperty $$k Path).Path$\n"
    FileWrite $0 "if (($$p -split ';') -notcontains $$d) { Set-ItemProperty $$k Path ($$p + ';' + $$d) }$\n"
    FileClose $0
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TEMP\star_add_path.ps1"'
    Delete "$TEMP\star_add_path.ps1"
    SendMessage ${HWND_BROADCAST} ${WM_WININICHANGE} 0 "STR:Environment" /TIMEOUT=5000

    WriteRegStr   HKLM "${REG_UNINSTALL}" "DisplayName"     "${APP_NAME} ${STAR_VERSION} (${ARCH})"
    WriteRegStr   HKLM "${REG_UNINSTALL}" "DisplayVersion"  "${STAR_VERSION}"
    WriteRegStr   HKLM "${REG_UNINSTALL}" "Publisher"       "${APP_PUBLISHER}"
    WriteRegStr   HKLM "${REG_UNINSTALL}" "InstallLocation" "$INSTDIR"
    WriteRegStr   HKLM "${REG_UNINSTALL}" "UninstallString" '"$INSTDIR\uninstall.exe"'
    WriteRegStr   HKLM "${REG_UNINSTALL}" "DisplayIcon"     "$INSTDIR\star.exe,0"
    WriteRegDWORD HKLM "${REG_UNINSTALL}" "NoModify"        1
    WriteRegDWORD HKLM "${REG_UNINSTALL}" "NoRepair"        1
SectionEnd

; ── Uninstall ─────────────────────────────────────────────────────────────────
Section "Uninstall"
    ; Remove $INSTDIR from the system PATH via PowerShell.
    ; NSIS expands $INSTDIR before writing to the temp file.
    FileOpen  $0 "$TEMP\star_remove_path.ps1" w
    FileWrite $0 "$$d = '$INSTDIR'$\n"
    FileWrite $0 "$$k = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'$\n"
    FileWrite $0 "$$p = (Get-ItemProperty $$k Path).Path$\n"
    FileWrite $0 "$$n = ($$p -split ';' | Where-Object { $$_ -ne $$d }) -join ';'$\n"
    FileWrite $0 "Set-ItemProperty $$k Path $$n$\n"
    FileClose $0
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$TEMP\star_remove_path.ps1"'
    Delete "$TEMP\star_remove_path.ps1"
    SendMessage ${HWND_BROADCAST} ${WM_WININICHANGE} 0 "STR:Environment" /TIMEOUT=5000

    Delete "$INSTDIR\star.exe"
    Delete "$INSTDIR\*.dll"
    Delete "$INSTDIR\uninstall.exe"
    RMDir  "$INSTDIR"
    DeleteRegKey HKLM "${REG_UNINSTALL}"
SectionEnd
