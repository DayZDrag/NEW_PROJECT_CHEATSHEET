<#
.SYNOPSIS
Проверяет синхронизацию правил, реестра и рекомендаций на изолированных Git-репозиториях.
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

function Get-TestFileSha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    $template = Join-Path $testRoot 'template'
    $project = Join-Path $testRoot 'project'
    $missingRegistryTemplate = Join-Path $testRoot 'missing-registry'
    $missingRecommendationsTemplate = Join-Path $testRoot 'missing-recommendations'
    foreach ($directory in @($template, $project, $missingRegistryTemplate, $missingRecommendationsTemplate)) {
        $null = New-Item -ItemType Directory -Path $directory
        $null = Invoke-TestGit $directory @('init', '--quiet')
    }
    foreach ($name in @('NEW_PROJECT_CHEATSHEET.md', 'TECHNOLOGY_REGISTRY.md', 'COORDINATION_RECOMMENDATIONS.md')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination (Join-Path $template $name)
    }
    $null = Invoke-TestGit $template @('add', '--', 'NEW_PROJECT_CHEATSHEET.md', 'TECHNOLOGY_REGISTRY.md', 'COORDINATION_RECOMMENDATIONS.md')
    $null = Invoke-TestGit $template @('-c', 'user.name=Template Test', '-c', 'user.email=template-test@example.invalid', 'commit', '--quiet', '-m', 'Тестовый шаблон')

    $agentsPath = Join-Path $project 'AGENTS.md'
    $historyPath = Join-Path $template 'COORDINATION_HISTORY.md'
    $prefix = "# Проектные инструкции`n`nСохранить заметку пользователя до блока.`n"
    $suffix = "`nСохранить заметку пользователя после блока.`n"
    [System.IO.File]::WriteAllText($agentsPath, $prefix, $utf8)
    Assert-True (-not (Test-Path -LiteralPath $historyPath -PathType Leaf)) 'История не должна быть обязательным источником начальной синхронизации.'
    $recommendationsPath = Join-Path $template 'COORDINATION_RECOMMENDATIONS.md'
    $recommendationsHashBeforeInitialSync = Get-TestFileSha256 -Path $recommendationsPath
    $recommendationsSnapshotText = [System.IO.File]::ReadAllText($recommendationsPath).Trim()
    Invoke-TestSync $project $template 'UPDATED'
    Assert-True ((Get-TestFileSha256 -Path $recommendationsPath) -ceq $recommendationsHashBeforeInitialSync) 'Синхронизация изменила источник рекомендаций.'
    foreach ($relative in $targets) {
        $content = [System.IO.File]::ReadAllText((Join-Path $project $relative))
        Assert-True ($content.Contains('# Глобальный реестр сервисов и инструментов разработки')) "Реестр не перенесён: $relative"
        Assert-True ($content.Contains('У пользователя есть опыт работы с Vercel, и он доверяет сервису.')) "Обоснование не перенесено: $relative"
        Assert-True ($content.Contains('## Снимок рекомендаций по координации')) "Заголовок снимка рекомендаций не перенесён: $relative"
        Assert-True ($content.Contains('Источник: COORDINATION_RECOMMENDATIONS.md')) "Источник снимка рекомендаций не указан: $relative"
        Assert-True ($content.Contains("SHA-256: $recommendationsHashBeforeInitialSync")) "Хеш снимка рекомендаций не указан: $relative"
        Assert-True ($content.Contains($recommendationsSnapshotText)) "Рекомендации не перенесены: $relative"
    }
    Assert-True ([System.IO.File]::ReadAllText($agentsPath).StartsWith($prefix.TrimEnd())) 'Потерян проектный текст до блока.'
    [System.IO.File]::AppendAllText($agentsPath, $suffix, $utf8)
    $initialState = [System.IO.File]::ReadAllText((Join-Path $project '.git/template-instruction-sync.json')) | ConvertFrom-Json
    Assert-True ($initialState.schemaVersion -eq 3 -and $initialState.coordinationRecommendationsHash.Length -eq 64) 'Состояние рекомендаций не записано.'
    Write-Output 'INITIAL_SYNC_REGISTRY_AND_RECOMMENDATIONS_WITHOUT_HISTORY=PASS'

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

    $recommendationsFirstRevision = 'Тестовые рекомендации: первая редакция.'
    $recommendationsSecondRevision = 'Тестовые рекомендации: вторая редакция.'
    [System.IO.File]::AppendAllText($recommendationsPath, "`n$recommendationsFirstRevision`n", $utf8)
    Invoke-TestSync $project $template 'UPDATED'
    $statusBefore = @(Invoke-TestGit $template @('status', '--porcelain=v1')) -join "`n"
    $stateBefore = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $recommendationsText = [System.IO.File]::ReadAllText($recommendationsPath).Replace($recommendationsFirstRevision, $recommendationsSecondRevision)
    [System.IO.File]::WriteAllText($recommendationsPath, $recommendationsText, $utf8)
    $statusAfter = @(Invoke-TestGit $template @('status', '--porcelain=v1')) -join "`n"
    Assert-True ($statusBefore -ceq $statusAfter) 'Тест не сохранил одинаковое Git-состояние.'
    $recommendationsHashBeforeSecondSync = Get-TestFileSha256 -Path $recommendationsPath
    Invoke-TestSync $project $template 'UPDATED'
    Assert-True ((Get-TestFileSha256 -Path $recommendationsPath) -ceq $recommendationsHashBeforeSecondSync) 'Синхронизация изменила обновлённый источник рекомендаций.'
    $stateAfter = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($stateBefore.coordinationRecommendationsHash -cne $stateAfter.coordinationRecommendationsHash) 'Изменение только содержимого рекомендаций не обнаружено.'
    foreach ($relative in $targets) {
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $project $relative)).Contains($recommendationsSecondRevision)) "Снимок рекомендаций устарел: $relative"
    }
    $agentsText = [System.IO.File]::ReadAllText($agentsPath)
    Assert-True ($agentsText.StartsWith($prefix.TrimEnd()) -and $agentsText.EndsWith($suffix)) 'Изменены заметки пользователя вокруг блока.'
    Write-Output 'RECOMMENDATIONS_ONLY_CHANGE_AND_NOTE_PRESERVATION=PASS'

    $registryPath = Join-Path $template 'TECHNOLOGY_REGISTRY.md'
    $registryFirstRevision = 'Тестовая запись реестра: первая редакция.'
    $registrySecondRevision = 'Тестовая запись реестра: вторая редакция.'
    [System.IO.File]::AppendAllText($registryPath, "`n$registryFirstRevision`n", $utf8)
    Invoke-TestSync $project $template 'UPDATED'
    $registryStatusBefore = @(Invoke-TestGit $template @('status', '--porcelain=v1')) -join "`n"
    $registryStateBefore = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $registryText = [System.IO.File]::ReadAllText($registryPath).Replace($registryFirstRevision, $registrySecondRevision)
    [System.IO.File]::WriteAllText($registryPath, $registryText, $utf8)
    $registryStatusAfter = @(Invoke-TestGit $template @('status', '--porcelain=v1')) -join "`n"
    Assert-True ($registryStatusBefore -ceq $registryStatusAfter) 'Тест реестра не сохранил одинаковое Git-состояние.'
    Invoke-TestSync $project $template 'UPDATED'
    $registryStateAfter = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($registryStateBefore.registryHash -cne $registryStateAfter.registryHash) 'Изменение только содержимого реестра не обнаружено.'
    foreach ($relative in $targets) {
        Assert-True ([System.IO.File]::ReadAllText((Join-Path $project $relative)).Contains($registrySecondRevision)) "Снимок реестра устарел: $relative"
    }
    $agentsText = [System.IO.File]::ReadAllText($agentsPath)
    Assert-True ($agentsText.StartsWith($prefix.TrimEnd()) -and $agentsText.EndsWith($suffix)) 'Тест реестра изменил заметки пользователя вокруг блока.'
    Write-Output 'REGISTRY_ONLY_CHANGE_AND_NOTE_PRESERVATION=PASS'

    [System.IO.File]::WriteAllText($agentsPath, $agentsText.Replace($recommendationsSecondRevision, 'Повреждённый снимок.'), $utf8)
    Invoke-TestSync $project $template 'UPDATED'
    Assert-True ([System.IO.File]::ReadAllText($agentsPath) -ceq $agentsText) 'Управляемый снимок не восстановлен.'
    Write-Output 'MANAGED_SNAPSHOT_REPAIR=PASS'

    $legacyState = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    $legacyState.schemaVersion = 2
    $legacyState.PSObject.Properties.Remove('coordinationRecommendationsHash')
    [System.IO.File]::WriteAllText($statePath, ($legacyState | ConvertTo-Json -Depth 3), $utf8)
    Invoke-TestSync $project $template 'CURRENT'
    $migratedState = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($migratedState.schemaVersion -eq 3 -and $migratedState.coordinationRecommendationsHash.Length -eq 64) 'Состояние schema 2 не обновлено.'
    $migratedState.schemaVersion = 1
    $migratedState.PSObject.Properties.Remove('registryHash')
    $migratedState.PSObject.Properties.Remove('coordinationRecommendationsHash')
    [System.IO.File]::WriteAllText($statePath, ($migratedState | ConvertTo-Json -Depth 3), $utf8)
    Invoke-TestSync $project $template 'CURRENT'
    $migratedState = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($migratedState.schemaVersion -eq 3 -and $migratedState.registryHash.Length -eq 64 -and $migratedState.coordinationRecommendationsHash.Length -eq 64) 'Состояние schema 1 не обновлено.'
    Write-Output 'LEGACY_STATE_SCHEMA_1_AND_2_MIGRATION=PASS'

    $historyCommittedRevision = '[тестовая история] исходная редакция.'
    $historyFirstRevision = '[тестовая история] первая локальная редакция.'
    $historySecondRevision = '[тестовая история] вторая локальная редакция.'
    [System.IO.File]::WriteAllText($historyPath, "$historyCommittedRevision`n", $utf8)
    $null = Invoke-TestGit $template @('add', '--', 'TECHNOLOGY_REGISTRY.md', 'COORDINATION_RECOMMENDATIONS.md', 'COORDINATION_HISTORY.md')
    $null = Invoke-TestGit $template @('-c', 'user.name=Template Test', '-c', 'user.email=template-test@example.invalid', 'commit', '--quiet', '-m', 'Добавить историю для теста')
    Invoke-TestSync $project $template 'UPDATED'
    foreach ($relative in $targets) {
        Assert-True (-not [System.IO.File]::ReadAllText((Join-Path $project $relative)).Contains($historyCommittedRevision)) "История попала в управляемый блок: $relative"
    }

    [System.IO.File]::WriteAllText($historyPath, "$historyFirstRevision`n", $utf8)
    Invoke-TestSync $project $template 'UPDATED'
    $historyStatusBefore = @(Invoke-TestGit $template @('status', '--porcelain=v1')) -join "`n"
    $historyStableHashes = @{}
    foreach ($relative in @($targets) + @('.git/template-instruction-sync.json')) {
        $historyStableHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash
    }
    [System.IO.File]::WriteAllText($historyPath, "$historySecondRevision`n", $utf8)
    $historyStatusAfter = @(Invoke-TestGit $template @('status', '--porcelain=v1')) -join "`n"
    Assert-True ($historyStatusBefore -ceq $historyStatusAfter) 'Изменение содержимого истории изменило Git-статус.'
    Invoke-TestSync $project $template 'CURRENT'
    foreach ($relative in $historyStableHashes.Keys) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash -eq $historyStableHashes[$relative]) 'Содержимое истории вызвало перезапись синхронизации.'
    }
    foreach ($relative in $targets) {
        $content = [System.IO.File]::ReadAllText((Join-Path $project $relative))
        Assert-True (-not $content.Contains($historyFirstRevision) -and -not $content.Contains($historySecondRevision)) "Содержимое истории попало в управляемый блок: $relative"
    }
    $historyState = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json
    Assert-True ($null -eq $historyState.PSObject.Properties['coordinationHistoryHash']) 'История ошибочно добавлена в служебное состояние.'
    Write-Output 'HISTORY_IGNORED_AND_STABLE_WITH_SAME_GIT_STATUS=PASS'

    $protectedFiles = @($targets) + @('.git/template-instruction-sync.json')
    $protectedHashes = @{}
    foreach ($relative in $protectedFiles) {
        $protectedHashes[$relative] = (Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash
    }

    Copy-Item -LiteralPath (Join-Path $template 'NEW_PROJECT_CHEATSHEET.md') -Destination (Join-Path $missingRegistryTemplate 'NEW_PROJECT_CHEATSHEET.md')
    Copy-Item -LiteralPath (Join-Path $template 'COORDINATION_RECOMMENDATIONS.md') -Destination (Join-Path $missingRegistryTemplate 'COORDINATION_RECOMMENDATIONS.md')
    $rejected = $false
    try { $null = & $syncScript -ProjectRoot $project -TemplateRoot $missingRegistryTemplate }
    catch { $rejected = $_.Exception.Message -like 'Не найден глобальный реестр технологий:*' }
    Assert-True $rejected 'Отсутствующий источник реестра не отклонён.'
    foreach ($relative in $protectedFiles) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash -eq $protectedHashes[$relative]) 'Проект изменён при отсутствии исходного реестра.'
    }
    Write-Output 'MISSING_REGISTRY_NO_WRITES=PASS'

    Copy-Item -LiteralPath (Join-Path $template 'NEW_PROJECT_CHEATSHEET.md') -Destination (Join-Path $missingRecommendationsTemplate 'NEW_PROJECT_CHEATSHEET.md')
    Copy-Item -LiteralPath (Join-Path $template 'TECHNOLOGY_REGISTRY.md') -Destination (Join-Path $missingRecommendationsTemplate 'TECHNOLOGY_REGISTRY.md')
    $rejected = $false
    try { $null = & $syncScript -ProjectRoot $project -TemplateRoot $missingRecommendationsTemplate }
    catch { $rejected = $_.Exception.Message -like 'Не найден файл рекомендаций по координации:*' }
    Assert-True $rejected 'Отсутствующий источник рекомендаций не отклонён.'
    foreach ($relative in $protectedFiles) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $project $relative)).Hash -eq $protectedHashes[$relative]) 'Проект изменён при отсутствии источника рекомендаций.'
    }
    Write-Output 'MISSING_RECOMMENDATIONS_NO_WRITES=PASS'
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
