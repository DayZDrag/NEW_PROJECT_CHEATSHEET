<#
.SYNOPSIS
Проверяет синхронизацию правил и реестра на изолированных Git-репозиториях.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = Split-Path -Parent $PSScriptRoot
$syncScript = Join-Path $PSScriptRoot 'sync-template-instructions.ps1'
$testParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testName = 'new-project-template-tests-' + [Guid]::NewGuid().ToString('N')
$testRoot = Join-Path $testParent $testName
$utf8 = [System.Text.UTF8Encoding]::new($false)
$targets = @(
    'AGENTS.md', 'PREFERENCES.md', '.obsidian/PROJECT_CREATION_PLAN.md',
    '.obsidian/SECURITY_CHECKLIST.md', '.obsidian/FINAL_VERIFICATION_CHECKLIST.md'
)

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-TestGit {
    param([string]$Repository, [string[]]$GitArguments)
    $output = & git -C $Repository @GitArguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Ошибка Git в изолированном тестовом репозитории.' }
    return $output
}

function Invoke-TestSync {
    param([string]$Project, [string]$Template, [string]$ExpectedStatus)
    $output = @(& $syncScript -ProjectRoot $Project -TemplateRoot $Template)
    Assert-True ($null -ne ($output | Where-Object { $_ -like "SYNC_RESULT=$ExpectedStatus*" })) 'Неожиданный статус синхронизации.'
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $template = Join-Path $testRoot 'template'
    $project = Join-Path $testRoot 'project'
    $missingTemplate = Join-Path $testRoot 'missing-registry'
    foreach ($directory in @($template, $project, $missingTemplate)) {
        $null = New-Item -ItemType Directory -Path $directory
        $null = Invoke-TestGit $directory @('init', '--quiet')
    }
    foreach ($name in @('NEW_PROJECT_CHEATSHEET.md', 'TECHNOLOGY_REGISTRY.md')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $template $name)
    }
    $null = Invoke-TestGit $template @('add', '--', 'NEW_PROJECT_CHEATSHEET.md', 'TECHNOLOGY_REGISTRY.md')
    $null = Invoke-TestGit $template @('-c', 'user.name=Template Test', '-c', 'user.email=template-test@example.invalid', 'commit', '--quiet', '-m', 'Тестовый шаблон')

    $agentsPath = Join-Path $project 'AGENTS.md'
    $prefix = "# Проектные инструкции`n`nСохранить заметку пользователя до блока.`n"
    $suffix = "`nСохранить заметку пользователя после блока.`n"
    [System.IO.File]::WriteAllText($agentsPath, $prefix, $utf8)
    Invoke-TestSync $project $template 'UPDATED'
    foreach ($relative in $targets) {
        $content = [System.IO.File]::ReadAllText((Join-Path $project $relative))
        Assert-True ($content.Contains('# Глобальный реестр сервисов и инструментов разработки')) "Реестр не перенесён: $relative"
        Assert-True ($content.Contains('У пользователя есть опыт работы с Vercel, и он доверяет сервису.')) "Обоснование не перенесено: $relative"
    }
    Assert-True ([System.IO.File]::ReadAllText($agentsPath).StartsWith($prefix.TrimEnd())) 'Потерян проектный текст до блока.'
    [System.IO.File]::AppendAllText($agentsPath, $suffix, $utf8)
    Write-Output 'INITIAL_SYNC_AND_REGISTRY=PASS'

    $statePath = Join-Path $project '.git/template-instruction-sync.json'
    $beforeHashes = @{}
    foreach ($relative in @($targets) + @('.git/template-instruction-sync.json')) {
        $beforeHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash
    }
    Invoke-TestSync $project $template 'CURRENT'
    foreach ($relative in $beforeHashes.Keys) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash -eq $beforeHashes[$relative]) 'Повторная синхронизация изменила актуальный файл.'
    }
    Write-Output 'NO_OP_AND_STATE_STABILITY=PASS'

    $registryPath = Join-Path $template 'TECHNOLOGY_REGISTRY.md'
    [System.IO.File]::AppendAllText($registryPath, "`nТестовая запись: первая редакция.`n", $utf8)
    Invoke-TestSync $project $template 'UPDATED'
    $statusBefore = @(Invoke-TestGit $template @('status', '--porcelain=v1')) -join "`n"
    $stateBefore = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $registryText = [System.IO.File]::ReadAllText($registryPath).Replace('первая редакция', 'вторая редакция')
    [System.IO.File]::WriteAllText($registryPath, $registryText, $utf8)
    $statusAfter = @(Invoke-TestGit $template @('status', '--porcelain=v1')) -join "`n"
    Assert-True ($statusBefore -ceq $statusAfter) 'Тест не сохранил одинаковое Git-состояние.'
    Invoke-TestSync $project $template 'UPDATED'
    $stateAfter = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($stateBefore.registryHash -cne $stateAfter.registryHash) 'Изменение только содержимого реестра не обнаружено.'
    foreach ($relative in $targets) {
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $project $relative)).Contains('Тестовая запись: вторая редакция.')) "Снимок реестра устарел: $relative"
    }
    $agentsText = [System.IO.File]::ReadAllText($agentsPath)
    Assert-True ($agentsText.StartsWith($prefix.TrimEnd()) -and $agentsText.EndsWith($suffix)) 'Изменены заметки пользователя вокруг блока.'
    Write-Output 'REGISTRY_ONLY_CHANGE_AND_NOTE_PRESERVATION=PASS'

    [System.IO.File]::WriteAllText($agentsPath, $agentsText.Replace('Тестовая запись: вторая редакция.', 'Повреждённый снимок.'), $utf8)
    Invoke-TestSync $project $template 'UPDATED'
    Assert-True ([System.IO.File]::ReadAllText($agentsPath) -ceq $agentsText) 'Управляемый снимок не восстановлен.'
    Write-Output 'MANAGED_SNAPSHOT_REPAIR=PASS'

    $legacyState = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $legacyState.schemaVersion = 1
    $legacyState.PSObject.Properties.Remove('registryHash')
    [System.IO.File]::WriteAllText($statePath, ($legacyState | ConvertTo-Json -Depth 3), $utf8)
    Invoke-TestSync $project $template 'CURRENT'
    $migratedState = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($migratedState.schemaVersion -eq 2 -and $migratedState.registryHash.Length -eq 64) 'Старое служебное состояние не обновлено.'
    Write-Output 'LEGACY_STATE_MIGRATION=PASS'

    Copy-Item -LiteralPath (Join-Path $template 'NEW_PROJECT_CHEATSHEET.md') -Destination (Join-Path $missingTemplate 'NEW_PROJECT_CHEATSHEET.md')
    $protectedFiles = @($targets) + @('.git/template-instruction-sync.json')
    $protectedHashes = @{}
    foreach ($relative in $protectedFiles) {
        $protectedHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash
    }
    $rejected = $false
    try { $null = & $syncScript -ProjectRoot $project -TemplateRoot $missingTemplate }
    catch { $rejected = $_.Exception.Message -like 'Не найден глобальный реестр технологий:*' }
    Assert-True $rejected 'Отсутствующий реестр не отклонён.'
    foreach ($relative in $protectedFiles) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash -eq $protectedHashes[$relative]) 'Проект изменён при отсутствии исходного реестра.'
    }
    Write-Output 'MISSING_REGISTRY_NO_WRITES=PASS'
}
finally {
    # Удаляем только созданный этим запуском каталог с точным случайным именем.
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = (Resolve-Path -LiteralPath $testRoot).Path
        $expectedTestRoot = [System.IO.Path]::GetFullPath((Join-Path $testParent $testName))
        if ($resolvedTestRoot -cne $expectedTestRoot -or
            (Split-Path -Leaf $resolvedTestRoot) -cne $testName -or
            (Split-Path -Parent $resolvedTestRoot).TrimEnd('\') -cne $testParent.TrimEnd('\')) {
            throw 'Очистка отменена: путь тестового каталога не прошёл проверку.'
        }
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
