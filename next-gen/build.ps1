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
$bookDir = $PSScriptRoot

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

# Assemble source files in book order
$sources = @()

# Front matter
$frontMatter = @("metadata.yaml", "copyright.md", "preface.md")
foreach ($f in $frontMatter) {
    $path = Join-Path $bookDir $f
    if (Test-Path $path) { $sources += $path }
    else { Write-Warning "Front matter missing: $f" }
}

# Chapters (sorted numerically by filename)
$chapters = Get-ChildItem -Path $bookDir -Filter "chapter-*.md" | Sort-Object Name
if ($chapters.Count -eq 0) {
    Write-Error "No chapter files found in $bookDir"
    exit 1
}
foreach ($ch in $chapters) {
    $sources += $ch.FullName
}
Write-Host "Including $($chapters.Count) chapters: $($chapters.Name -join ', ')" -ForegroundColor Green

# Appendices
$appendices = Join-Path $bookDir "appendices.md"
if (Test-Path $appendices) { $sources += $appendices }

# Back matter
$backMatter = @("about-author.md")
foreach ($f in $backMatter) {
    $path = Join-Path $bookDir $f
    if (Test-Path $path) { $sources += $path }
}

# Pandoc arguments
$pandocArgs = @(
    "--toc"
    "--css=epub.css"
    "-o", (Join-Path $bookDir $Output)
)

# Add cover image if it exists
$cover = Join-Path $bookDir "cover.png"
if (Test-Path $cover) {
    $pandocArgs += "--epub-cover-image=$cover"
    Write-Host "Cover image: cover.png" -ForegroundColor Green
} else {
    Write-Host "No cover image found (cover.png) — building without cover" -ForegroundColor Yellow
}

# Build
Write-Host "`nBuilding epub..." -ForegroundColor Cyan
& $pandoc @sources @pandocArgs

if ($LASTEXITCODE -eq 0) {
    $epub = Get-Item (Join-Path $bookDir $Output)
    Write-Host "`n✅ Built: $($epub.Name) ($([math]::Round($epub.Length / 1KB)) KB)" -ForegroundColor Green
} else {
    Write-Error "Pandoc failed with exit code $LASTEXITCODE"
    exit 1
}
