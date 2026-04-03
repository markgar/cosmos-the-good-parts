#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Builds "Cosmos DB: The Good Parts" epub from markdown sources.
.DESCRIPTION
    Assembles all front matter, chapters, appendices, and back matter
    into a single epub using Pandoc. Chapters are included in order
    based on filename (chapter-01.md, chapter-02.md, etc.).
    Only includes chapter files that actually exist, so the book
    builds cleanly at any stage of writing.
.EXAMPLE
    .\build.ps1
    .\build.ps1 -Output "preview.epub"
#>
param(
    [string]$Output = "Cosmos DB - The Good Parts.epub"
)

$ErrorActionPreference = "Stop"
$rootDir = $PSScriptRoot
$bookDir = Join-Path $rootDir "manuscript"

# Ensure Pandoc is available
$pandoc = Get-Command pandoc -ErrorAction SilentlyContinue
if (-not $pandoc) {
    $programFiles = "C:\Program Files\Pandoc\pandoc.exe"
    if (Test-Path $programFiles) {
        $pandoc = $programFiles
    } else {
        Write-Error "Pandoc not found. Install from https://pandoc.org/installing.html"
        exit 1
    }
} else {
    $pandoc = $pandoc.Source
}

Write-Host "Using Pandoc: $pandoc" -ForegroundColor Cyan
& $pandoc --version | Select-Object -First 1

# Subdirectories
$frontMatterDir = Join-Path $bookDir "frontmatter"
$chaptersDir    = Join-Path $bookDir "chapters"
$appendicesDir  = Join-Path $bookDir "appendices"
$backMatterDir  = Join-Path $bookDir "backmatter"

# Assemble source files in book order
$sources = @()

# Metadata (build config, lives in project root)
$metadataPath = Join-Path $rootDir "metadata.yaml"
if (Test-Path $metadataPath) { $sources += $metadataPath }
else { Write-Warning "Metadata missing: metadata.yaml" }

# Front matter
$frontMatter = @("copyright.md", "preface.md")
foreach ($f in $frontMatter) {
    $path = Join-Path $frontMatterDir $f
    if (Test-Path $path) { $sources += $path }
    else { Write-Warning "Front matter missing: $f" }
}

# Chapters (sorted numerically by filename)
$chapters = Get-ChildItem -Path $chaptersDir -Filter "chapter-*.md" | Sort-Object Name
if ($chapters.Count -eq 0) {
    Write-Error "No chapter files found in $chaptersDir"
    exit 1
}
foreach ($ch in $chapters) {
    $sources += $ch.FullName
}
Write-Host "Including $($chapters.Count) chapters: $($chapters.Name -join ', ')" -ForegroundColor Green

# Appendices (individual files sorted by name, or single appendices.md)
$appendixFiles = Get-ChildItem -Path $appendicesDir -Filter "appendix-*.md" | Sort-Object Name
if ($appendixFiles.Count -gt 0) {
    foreach ($app in $appendixFiles) { $sources += $app.FullName }
    Write-Host "Including $($appendixFiles.Count) appendices: $($appendixFiles.Name -join ', ')" -ForegroundColor Green
} else {
    $appendices = Join-Path $appendicesDir "appendices.md"
    if (Test-Path $appendices) { $sources += $appendices }
}

# Back matter
$backMatter = @("about-author.md")
foreach ($f in $backMatter) {
    $path = Join-Path $backMatterDir $f
    if (Test-Path $path) { $sources += $path }
}

# Output directory
$buildDir = Join-Path $rootDir "build"
if (-not (Test-Path $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}

# Pandoc arguments
$pandocArgs = @(
    "--from", "markdown"
    "--to", "epub3"
    "--toc"
    "--toc-depth=2"
    "--css=$(Join-Path $rootDir 'assets' 'epub.css')"
    "-o", (Join-Path $buildDir $Output)
)

# Add cover image if it exists
$cover = Join-Path $rootDir "assets" "cover.png"
if (Test-Path $cover) {
    $pandocArgs += "--epub-cover-image=$cover"
    Write-Host "Cover image: assets/cover.png" -ForegroundColor Green
} else {
    Write-Host "No cover image found (assets/cover.png) -- building without cover" -ForegroundColor Yellow
}

# Build
Write-Host "`nBuilding epub..." -ForegroundColor Cyan
& $pandoc @sources @pandocArgs

if ($LASTEXITCODE -eq 0) {
    $epub = Get-Item (Join-Path $buildDir $Output)
    $sizeKB = [math]::Round($epub.Length / 1024)
    Write-Host "`nBuilt: $($epub.Name) ($sizeKB KB)" -ForegroundColor Green
} else {
    Write-Error "Pandoc failed with exit code $LASTEXITCODE"
    exit 1
}
