# 把 UTF-8 的 BatchPlot.lsp 转成 GBK/ANSI（中文版 AutoCAD 读取 .lsp 使用系统 ANSI 代码页）
# 用法: powershell -ExecutionPolicy Bypass -File .\tools\to-gbk.ps1 .\BatchPlot.lsp
param([Parameter(Mandatory=$true)][string]$Path)

$full = (Resolve-Path -LiteralPath $Path).Path
if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "文件不存在: $full" }

$bak = "$full.utf8.bak"
$text = [IO.File]::ReadAllText($full, (New-Object Text.UTF8Encoding $false))
if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force }
Copy-Item -LiteralPath $full -Destination $bak -Force

$gbk = [Text.Encoding]::GetEncoding(936)
[IO.File]::WriteAllBytes($full, $gbk.GetBytes($text))

Write-Output "已转换为 GBK: $full"
Write-Output "原 UTF-8 备份: $bak"
