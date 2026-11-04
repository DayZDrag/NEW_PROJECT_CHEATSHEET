<#
.SYNOPSIS
Синхронизирует обязательные инструкции главного шаблона с проектными файлами.

.DESCRIPTION
Скрипт сравнивает Git-коммит, Git-состояние и SHA-256 главной шпаргалки с
предыдущим запуском. При изменении шаблона или управляемого блока он обновляет
только блоки между маркерами, не затрагивая проектный текст вне них.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ProjectRoot = (Get-Location).Path,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$TemplateRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$beginMarker = '<!-- BEGIN MANAGED TEMPLATE INSTRUCTIONS -->'
$endMarker = '<!-- END MANAGED TEMPLATE INSTRUCTIONS -->'
$managedBlockPattern = [regex]::Escape($beginMarker) + '(?s:.*?)' + [regex]::Escape($endMarker)

function Get-ExistingDirectory {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Label не существует или не является каталогом: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Invoke-RepositoryGit {
    param(
        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $result = & git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $details = ($result | Out-String).Trim()
        throw "Git-проверка не выполнена: git -C <repo> $($Arguments -join ' '). $details"
    }

    return $result
}

function Get-StringSha256 {
    param([Parameter(Mandatory)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-PathInsideProject {
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][string]$RelativePath
    )

    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Недопустимый абсолютный путь целевого файла: $RelativePath"
    }

    $projectFullPath = [System.IO.Path]::GetFullPath($Project).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $projectFullPath $RelativePath))
    $prefix = $projectFullPath + [System.IO.Path]::DirectorySeparatorChar

    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Целевой файл находится вне корня проекта: $RelativePath"
    }

    return $candidate
}

function Write-Utf8Atomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $directory = Split-Path -Parent $Path
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [System.Guid]::NewGuid().ToString('N') + '.tmp')
    $encoding = [System.Text.UTF8Encoding]::new($false)

    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Content, $encoding)
        [System.IO.File]::Move($temporaryPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Get-ManagedBlockMatch {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Path
    )

    $matches = [regex]::Matches($Content, $managedBlockPattern)
    if ($matches.Count -gt 1) {
        throw "В файле найдено несколько управляемых блоков: $Path"
    }

    if ($matches.Count -eq 0) {
        return $null
    }

    return $matches[0]
}

function Set-ManagedBlock {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentContent,
        [Parameter(Mandatory)][string]$Header,
        [Parameter(Mandatory)][string]$ManagedBlock,
        [Parameter(Mandatory)][string]$Path
    )

    $match = Get-ManagedBlockMatch -Content $CurrentContent -Path $Path
    if ($null -ne $match) {
        return $CurrentContent.Substring(0, $match.Index) + $ManagedBlock + $CurrentContent.Substring($match.Index + $match.Length)
    }

    if ([string]::IsNullOrWhiteSpace($CurrentContent)) {
        return "$Header`n`n$ManagedBlock`n"
    }

    return $CurrentContent.TrimEnd() + "`n`n$ManagedBlock`n"
}

function Get-StateProperty {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $State) {
        return $null
    }

    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return [string]$property.Value
}

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git не найден: безопасная синхронизация инструкций невозможна.'
}

$TemplateRoot = Get-ExistingDirectory -Path $TemplateRoot -Label 'Корень главного шаблона'
$ProjectRoot = Get-ExistingDirectory -Path $ProjectRoot -Label 'Корень проекта'

if ([string]::Equals($TemplateRoot, $ProjectRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Нельзя синхронизировать главный шаблон с ним самим. Укажите корень целевого проекта.'
}

$templateFile = Join-Path $TemplateRoot 'NEW_PROJECT_CHEATSHEET.md'
if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf)) {
    throw "Не найден главный файл шаблона: $templateFile"
}

# Проверяем, что оба пути относятся к Git-репозиториям до любых записей.
$null = Invoke-RepositoryGit -Repository $TemplateRoot -Arguments @('rev-parse', '--is-inside-work-tree')
$null = Invoke-RepositoryGit -Repository $ProjectRoot -Arguments @('rev-parse', '--is-inside-work-tree')

$templateCommit = (@(Invoke-RepositoryGit -Repository $TemplateRoot -Arguments @('rev-parse', 'HEAD'))[0]).Trim()
$templateStatusLines = @((Invoke-RepositoryGit -Repository $TemplateRoot -Arguments @('status', '--porcelain=v1', '--untracked-files=all')) | ForEach-Object { [string]$_ })
$templateText = [System.IO.File]::ReadAllText($templateFile)
$templateHash = Get-StringSha256 -Text $templateText
$templateStatusHash = Get-StringSha256 -Text ($templateStatusLines -join "`n")
$templateState = if ($templateStatusLines.Count -gt 0) { 'есть локальные изменения' } else { 'рабочее дерево чисто' }

$gitStatePathOutput = @(Invoke-RepositoryGit -Repository $ProjectRoot -Arguments @('rev-parse', '--git-path', 'template-instruction-sync.json'))
$gitStatePathValue = ([string]$gitStatePathOutput[0]).Trim()
$statePath = if ([System.IO.Path]::IsPathRooted($gitStatePathValue)) {
    [System.IO.Path]::GetFullPath($gitStatePathValue)
}
else {
    [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $gitStatePathValue))
}

$previousState = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try {
        $previousState = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    }
    catch {
        throw "Служебное состояние синхронизации повреждено: $statePath. Устраните ошибку до продолжения работы."
    }
}

$managedBlock = @"
$beginMarker
## Синхронизируемые обязательные инструкции главного шаблона

Источник: `NEW_PROJECT_CHEATSHEET.md`; Git-коммит: $templateCommit; состояние источника: $templateState; SHA-256: $templateHash; отпечаток локального Git-состояния: $templateStatusHash.

Этот блок управляется скриптом `sync-template-instructions.ps1`. Не изменяйте и не удаляйте его вручную: при следующем рабочем цикле скрипт безопасно восстановит актуальную редакцию. Текст вне маркеров остаётся проектным и не перезаписывается.

$($templateText.Trim())
$endMarker
"@.Trim()

$targets = @(
    [pscustomobject]@{ RelativePath = 'AGENTS.md'; Header = '# Инструкции для агентов' },
    [pscustomobject]@{ RelativePath = 'PREFERENCES.md'; Header = '# Предпочтения разработки' },
    [pscustomobject]@{ RelativePath = '.obsidian/PROJECT_CREATION_PLAN.md'; Header = '# План создания проекта' },
    [pscustomobject]@{ RelativePath = '.obsidian/SECURITY_CHECKLIST.md'; Header = '# Контрольный список безопасности' },
    [pscustomobject]@{ RelativePath = '.obsidian/FINAL_VERIFICATION_CHECKLIST.md'; Header = '# Итоговый контрольный список' }
)

$templateChanged = ($null -eq $previousState) -or
    ((Get-StateProperty -State $previousState -Name 'templateCommit') -ne $templateCommit) -or
    ((Get-StateProperty -State $previousState -Name 'templateHash') -ne $templateHash) -or
    ((Get-StateProperty -State $previousState -Name 'templateStatusHash') -ne $templateStatusHash)

$updatedTargets = [System.Collections.Generic.List[string]]::new()
foreach ($target in $targets) {
    $targetPath = Get-PathInsideProject -Project $ProjectRoot -RelativePath $target.RelativePath
    $currentContent = if (Test-Path -LiteralPath $targetPath -PathType Leaf) {
        [System.IO.File]::ReadAllText($targetPath)
    }
    else {
        ''
    }

    $match = Get-ManagedBlockMatch -Content $currentContent -Path $targetPath
    $blockIsCurrent = ($null -ne $match) -and ($match.Value -ceq $managedBlock)
    if ($templateChanged -or -not $blockIsCurrent) {
        $newContent = Set-ManagedBlock -CurrentContent $currentContent -Header $target.Header -ManagedBlock $managedBlock -Path $targetPath
        if ($newContent -cne $currentContent) {
            Write-Utf8Atomically -Path $targetPath -Content $newContent
            $updatedTargets.Add($target.RelativePath)
        }
    }
}

$state = [ordered]@{
    schemaVersion = 1
    templateCommit = $templateCommit
    templateHash = $templateHash
    templateStatusHash = $templateStatusHash
    templateHasLocalChanges = ($templateStatusLines.Count -gt 0)
    synchronizedAtUtc = [DateTime]::UtcNow.ToString('o')
    targets = @($targets | ForEach-Object { $_.RelativePath })
}

if ($templateChanged -or $updatedTargets.Count -gt 0) {
    Write-Utf8Atomically -Path $statePath -Content (($state | ConvertTo-Json -Depth 3) + "`n")
}

if ($templateChanged) {
    Write-Output "TEMPLATE_CHANGE=DETECTED; git=$templateCommit; local_state=$templateState"
}

if ($updatedTargets.Count -gt 0) {
    Write-Output "SYNC_RESULT=UPDATED; files=$($updatedTargets -join ',')"
}
else {
    Write-Output 'SYNC_RESULT=CURRENT'
}

Write-Output 'NEXT_STEP=READ_AGENTS_AND_PREFERENCES'
