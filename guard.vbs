' napcat-guard launcher
' 2026-11-11
'
' 计划任务直接挂 powershell.exe 会每隔两分钟闪一下黑窗。
' wscript 起就不建控制台，一个窗口都没有。
' 注意：这个文件必须是 UTF-8 无 BOM，带 BOM 时 wscript 会报「无效字符」。

Dim sh, fso, here, ps1
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = here & "\guard.ps1"

If Not fso.FileExists(ps1) Then
    sh.LogEvent 1, "napcat-guard: guard.ps1 not found next to launcher"
    WScript.Quit 1
End If

sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & ps1 & """", 0, False
