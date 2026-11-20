param([string]$GamePath = 'D:\Game\Steam\steamapps\common\Brotato')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-common.ps1')
$paths = Get-AutoBuildPaths -GamePath $GamePath
$state = $null
if (Test-Path -LiteralPath $paths.State) {
    $state = [IO.File]::ReadAllText($paths.State) | ConvertFrom-Json
}
# 递归删除只允许针对已经解析并核对过的固定模组目录。
if (Test-Path -LiteralPath $paths.Target) {
    $links = @(Get-ChildItem -LiteralPath $paths.Target -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    if ($links.Count -gt 0) { throw '模组目录内含目录联接或符号链接，停止卸载。' }
}
if (Test-Path -LiteralPath $paths.Config) {
    $text = [IO.File]::ReadAllText($paths.Config)
    $updated = Remove-AutoBuildEntry -Text $text
    if ($text -ne $updated) {
        if ($null -ne $state -and $text -eq $state.installed_text) {
            if ($state.override_existed) {
                [IO.File]::WriteAllBytes($paths.Config, [Convert]::FromBase64String($state.original_bytes))
            } else {
                Remove-Item -LiteralPath $paths.Config
            }
        } elseif ((Test-AutoBuildOnlyConfig -Text $updated) -and ($null -eq $state -or !$state.override_existed)) {
            Remove-Item -LiteralPath $paths.Config
        } else {
            [IO.File]::WriteAllText($paths.Config, $updated, [Text.UTF8Encoding]::new($false))
        }
    }
}
if (Test-Path -LiteralPath $paths.Target) {
    Remove-Item -LiteralPath $paths.Target -Recurse -Force
}
if ((Test-Path -LiteralPath $paths.Parent) -and @(Get-ChildItem -LiteralPath $paths.Parent -Force).Count -eq 0) {
    Remove-Item -LiteralPath $paths.Parent
}
Write-Output '已卸载：模组文件和自动加载入口已移除，其他游戏配置已保留。'
Write-Output '保留个人快捷键配置和历史日志，重新安装可继续使用。'
