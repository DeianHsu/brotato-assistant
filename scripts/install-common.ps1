$AutoBuildEntry = 'PotatoAutoBuild="*res://mods-unpacked/Potato-AutoBuild/mod_main.gd"'
$AutoBuildEntryPattern = '(?m)^PotatoAutoBuild[ \t]*=[ \t]*"\*res://mods-unpacked/Potato-AutoBuild/mod_main\.gd"[ \t]*\r?\n?'

function Get-AutoBuildPaths {
    param([string]$GamePath)
    $gameRoot = (Resolve-Path -LiteralPath $GamePath).Path
    $executable = Join-Path $gameRoot 'Brotato.exe'
    if (!(Test-Path -LiteralPath $executable -PathType Leaf)) { throw '此目录中没有 Brotato.exe。' }
    if (Get-Process Brotato -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $executable }) {
        throw '请先退出游戏，再安装或卸载。'
    }
    $parent = Join-Path $gameRoot 'mods-unpacked'
    $target = [IO.Path]::GetFullPath((Join-Path $parent 'Potato-AutoBuild'))
    if (!$target.StartsWith($gameRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw '模组路径不在指定游戏目录内。'
    }
    $config = Join-Path $gameRoot 'override.cfg'
    foreach ($path in @($parent, $target, $config)) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "安装目标使用了目录联接或符号链接，停止操作：$path"
        }
    }
    return @{ Root = $gameRoot; Parent = $parent; Target = $target; Config = $config; State = (Join-Path $target '.install-state.json') }
}

function Remove-AutoBuildEntry {
    param([AllowEmptyString()][string]$Text)
    return [regex]::Replace($Text, $AutoBuildEntryPattern, '')
}

function Test-AutoBuildOnlyConfig {
    param([AllowEmptyString()][string]$Text)
    return $Text -match '\A\s*(?:\[autoload\]\s*)?\z'
}

function Add-AutoBuildEntry {
    param([AllowEmptyString()][string]$Text)
    $existing = [regex]::Match($Text, '(?m)^PotatoAutoBuild[ \t]*=.*$')
    if ($existing.Success) {
        if ($existing.Value.TrimEnd() -ne $AutoBuildEntry) {
            throw '已有同名自动加载项指向其他脚本，安装已取消。'
        }
        return $Text
    }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $autoload = [regex]::Match($Text, '(?m)^\[autoload\][ \t]*(?:\r?\n|$)')
    if ($autoload.Success) {
        $prefix = if ($autoload.Value.EndsWith("`n")) { '' } else { $newline }
        return $Text.Insert($autoload.Index + $autoload.Length, $prefix + $AutoBuildEntry + $newline)
    }
    $separator = if ($Text.Length -eq 0) { '' } else { $newline + $newline }
    return $Text + $separator + '[autoload]' + $newline + $AutoBuildEntry + $newline
}
