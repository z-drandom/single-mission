@echo off
rem ============================================================
rem  One-click folder scanner. Double-click to scan the folder
rem  this .bat sits in, or drag a folder onto it to scan that.
rem  Result: a .txt on your Desktop + copied to the clipboard.
rem ============================================================
setlocal
set "SELF=%~f0"
set "SCAN_DIR=%~1"
if not defined SCAN_DIR set "SCAN_DIR=%~dp0"

rem --- ask for admin rights (needed to read C:\Windows etc.) ---
net session >nul 2>&1 && goto run
if "%~2"=="elevated" goto run
powershell -NoProfile -Command "try { Start-Process -FilePath $env:SELF -ArgumentList ('\"'+$env:SCAN_DIR+'\" elevated') -Verb RunAs -ErrorAction Stop; exit 0 } catch { exit 1 }"
if not errorlevel 1 exit /b

:run
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:SELF,[Text.Encoding]::UTF8); iex $s.Substring($s.IndexOf('#'+'PS_BEGIN'))"
echo.
pause
exit /b

#PS_BEGIN
# ---------------- PowerShell part (works on Windows PowerShell 5.1+) ----------------
$ErrorActionPreference = 'SilentlyContinue'
$maxDepth = 4          # folder tree depth to report
$treeMin  = 300MB      # sub-folders smaller than this are hidden (level 2+)
$bigMin   = 100MB      # files >= this go into the "largest files" list
$bigTop   = 60         # how many largest files to list

$root = $env:SCAN_DIR.Trim().Trim('"')
if ($root -match '^[A-Za-z]:\\?$') { $root = $root.Substring(0, 2) + '\' }
$root = [IO.Path]::GetFullPath($root)
if ($root.Length -gt 3) { $root = $root.TrimEnd('\') }

function Fmt([int64]$b) {
    if ($b -ge 1GB) { return '{0:N2} GB' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1} MB' -f ($b / 1MB) }
    return '{0:N0} KB' -f ($b / 1KB)
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "正在扫描: $root"
Write-Host "管理员权限: $isAdmin"
Write-Host "C 盘全盘扫描通常需要 1~10 分钟，请耐心等待..."

$sizes        = @{}   # tracked folder (depth 1..maxDepth) -> total bytes
$children     = @{}   # folder -> list of tracked sub-folders
$deniedSet    = @{}   # tracked folders we could not read
$big          = New-Object 'System.Collections.Generic.List[object]'
$rootFiles    = New-Object 'System.Collections.Generic.List[object]'
$total        = [int64]0
$fileCount    = 0
$dirCount     = 0
$denied       = 0
$sw           = [Diagnostics.Stopwatch]::StartNew()

$stack = New-Object 'System.Collections.Generic.Stack[object]'
$stack.Push(@($root, 0, @()))
while ($stack.Count -gt 0) {
    $e = $stack.Pop(); $d = $e[0]; $depth = $e[1]; $anc = $e[2]
    $dirCount++
    if ($dirCount % 3000 -eq 0) { Write-Host ("  已扫描 {0:N0} 个文件夹, {1:N0} 个文件, {2}" -f $dirCount, $fileCount, (Fmt $total)) }
    try { $items = (New-Object IO.DirectoryInfo $d).GetFileSystemInfos() }
    catch { $denied++; if ($sizes.ContainsKey($d)) { $deniedSet[$d] = 1 }; continue }

    if ($depth -ge 1 -and $depth -le $maxDepth) { $chain = $anc + @($d) } else { $chain = $anc }
    $local = [int64]0
    foreach ($it in $items) {
        if ($it -is [IO.DirectoryInfo]) {
            # skip junctions / symlinks so nothing is counted twice
            if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $stack.Push(@($it.FullName, ($depth + 1), $chain))
            if ($depth + 1 -le $maxDepth) {
                $sizes[$it.FullName] = [int64]0
                if (-not $children.ContainsKey($d)) { $children[$d] = New-Object 'System.Collections.Generic.List[string]' }
                $children[$d].Add($it.FullName)
            }
        } else {
            $len = $it.Length
            $local += $len
            $fileCount++
            if ($len -ge $bigMin) { $big.Add($it) }
            if ($depth -eq 0) { $rootFiles.Add($it) }
        }
    }
    $total += $local
    foreach ($k in $chain) { $sizes[$k] += $local }
}
$sw.Stop()

# ---------------- build report ----------------
$lines = New-Object 'System.Collections.Generic.List[string]'
$lines.Add("扫描目录: $root")
$lines.Add("扫描时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm')   耗时: $([int]$sw.Elapsed.TotalSeconds) 秒   管理员: $isAdmin")
try {
    $drv = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($root))
    $lines.Add("所在磁盘: $($drv.Name)  总容量 $(Fmt $drv.TotalSize)  已用 $(Fmt ($drv.TotalSize - $drv.AvailableFreeSpace))  剩余 $(Fmt $drv.AvailableFreeSpace)")
} catch {}
$lines.Add("本目录合计: $(Fmt $total)   文件 $('{0:N0}' -f $fileCount) 个   文件夹 $('{0:N0}' -f $dirCount) 个   无权限读取 $denied 个")
$lines.Add('')

function Add-Tree([string]$path, [int]$level) {
    if (-not $children.ContainsKey($path)) { return }
    $sorted = $children[$path] | Sort-Object { $sizes[$_] } -Descending
    foreach ($k in $sorted) {
        $s = $sizes[$k]
        if ($level -gt 1 -and $s -lt $treeMin) { continue }
        $mark = ''
        if ($deniedSet.ContainsKey($k)) { $mark = '   [无权限读取]' }
        $lines.Add(('{0}{1,11}   {2}{3}' -f ('      ' * ($level - 1)), (Fmt $s), (Split-Path $k -Leaf), $mark))
        Add-Tree $k ($level + 1)
    }
}

$lines.Add("==== 一、文件夹大小（第 1 层全部列出，更深层只列 >= $(Fmt $treeMin) 的，最多 $maxDepth 层）====")
Add-Tree $root 1
$lines.Add('')

$lines.Add('==== 二、本目录下直接存放的文件（含隐藏/系统文件）====')
foreach ($f in ($rootFiles | Sort-Object Length -Descending)) {
    $lines.Add(('{0,11}   {1}' -f (Fmt $f.Length), $f.Name))
}
$lines.Add('')

$lines.Add("==== 三、最大的文件 Top $bigTop（>= $(Fmt $bigMin)，含完整路径和修改日期）====")
foreach ($f in ($big | Sort-Object Length -Descending | Select-Object -First $bigTop)) {
    $lines.Add(('{0,11}   {1}   {2}' -f (Fmt $f.Length), $f.LastWriteTime.ToString('yyyy-MM-dd'), $f.FullName))
}
$lines.Add('')
$lines.Add('注: 大小按文件逻辑大小统计; C:\Windows\WinSxS 内大量硬链接会被重复计算, 实际占用比显示的小。')

# ---------------- save + clipboard ----------------
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop -or -not (Test-Path $desktop)) { $desktop = $env:TEMP }
$tag = ($root -replace '[:\\/]+', '_').Trim('_')
$out = Join-Path $desktop ("文件清单_{0}_{1}.txt" -f $tag, (Get-Date -Format 'yyyyMMdd_HHmm'))
[IO.File]::WriteAllLines($out, $lines, (New-Object Text.UTF8Encoding $true))

$copied = $false
if (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
    try { Set-Clipboard -Value ($lines -join "`r`n") -ErrorAction Stop; $copied = $true } catch {}
}

Write-Host ''
Write-Host "完成！结果已保存到: $out"
if ($copied) { Write-Host '结果已复制到剪贴板，可以直接粘贴发给 Claude。' }
if (-not $isAdmin) { Write-Host '提示: 未以管理员身份运行，部分系统文件夹读不到，大小会偏小。' }
Start-Process notepad.exe -ArgumentList "`"$out`""
