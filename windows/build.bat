@echo off
rem Compile le widget avec le compilateur C# inclus dans Windows. Rien a installer.
cd /d "%~dp0"
set FW=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319
"%FW%\csc.exe" /nologo /codepage:65001 /target:winexe /platform:x64 /optimize+ /out:ClaudeUsage.exe ^
  /r:System.dll /r:System.Core.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll /r:System.Web.Extensions.dll ^
  /r:Microsoft.Web.WebView2.Core.dll /r:Microsoft.Web.WebView2.WinForms.dll ^
  ClaudeUsage.cs
if errorlevel 1 (
  echo Echec de la compilation.
  exit /b 1
)
echo OK : ClaudeUsage.exe
