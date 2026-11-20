param([string]$GamePath = 'D:\Game\Steam\steamapps\common\Brotato')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'install-common.ps1')
$projectRoot = Split-Path -Parent $PSScriptRoot
$paths = Get-AutoBuildPaths -GamePath $GamePath
$source = Join-Path $projectRoot 'mods-unpacked\Potato-AutoBuild'
if (!(Test-Path -LiteralPath (Join-Path $source 'mod_main.gd'))) { throw '安装包缺少模组源码。' }
$text = ''
$configExisted = Test-Path -LiteralPath $paths.Config
$originalBytes = ''
if ($configExisted) {
    $text = [IO.File]::ReadAllText($paths.Config)
    $originalBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($paths.Config))
}
$installedText = Add-AutoBuildEntry -Text $text
$state = $null
if (Test-Path -LiteralPath $paths.State) {
    $state = [IO.File]::ReadAllText($paths.State) | ConvertFrom-Json
    if ($text -eq $state.installed_text) {
        $configExisted = $state.override_existed
        $originalBytes = $state.original_bytes
    }
}
# 兼容之前未记录安装信息的版本，也保留安装期间新增的其他配置。
if ($text -match $AutoBuildEntryPattern -and ($null -eq $state -or $text -ne $state.installed_text)) {
    $baseline = Remove-AutoBuildEntry -Text $text
    if (Test-AutoBuildOnlyConfig -Text $baseline) {
        $configExisted = $false
        $originalBytes = ''
    } else {
        $configExisted = $true
        $originalBytes = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($baseline))
    }
}
New-Item -ItemType Directory -Force -Path $paths.Target | Out-Null
Get-ChildItem -LiteralPath $source -File | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $paths.Target $_.Name) -Force
}
$installState = @{ override_existed = [bool]$configExisted; original_bytes = $originalBytes; installed_text = $installedText }
[IO.File]::WriteAllText($paths.State, ($installState | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($paths.Config, $installedText, [Text.UTF8Encoding]::new($false))
Write-Output "已安装到 $($paths.Target)"
Write-Output '从 Steam 正常启动。商店、属性升级和战后宝箱：Alt+1 执行，Alt+2 预览，Alt+3 日志。'
Write-Output 'Xbox 手柄按住右摇杆 RS：十字键右执行、上预览、下切换日志。'
Write-Output '卸载时双击安装包中的“卸载.cmd”。'
