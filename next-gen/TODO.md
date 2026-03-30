# Cosmos DB: The Good Parts — Remaining Work

All 28 chapters are written, reviewed, fixed, and committed. Epub is built. Here's what's left.

## 1. Write Appendices A–E

Each appendix is a quick-reference table/cheat sheet. Use the `cosmos-book-writer` agent with the relevant outline section from `next-gen/outline.md`.

- **Appendix A** — CLI and Terraform Quick Reference
- **Appendix B** — NoSQL Query Language Reference
- **Appendix C** — Consistency Level Comparison Table
- **Appendix D** — Capacity and Pricing Cheat Sheet
- **Appendix E** — Service Limits and Quotas Quick Reference

## 2. Final Cross-Reference Audit

Sweep all 28 chapters for any remaining `Chapter X` / `Ch X` references that point to the wrong number. The initial audit fixed 23 errors in Ch 1–3, but later chapters were written with correct numbering — a final pass would catch any stragglers.

## 3. Fix `build.ps1`

The PowerShell build script (`next-gen/build.ps1`) has encoding issues (likely smart quotes or BOM problems) that cause parse errors. Either fix the encoding or rewrite it. For now, running pandoc directly works:

```powershell
Set-Location C:\Users\mgarner\dev\cosmos-book\next-gen
$chapters = Get-ChildItem -Filter "chapter-*.md" | Sort-Object Name
$files = @("metadata.yaml", "preface.md") + ($chapters | ForEach-Object { $_.Name })
& "C:\Program Files\Pandoc\pandoc.exe" --from markdown --to epub3 --output "Cosmos DB - The Good Parts.epub" --toc --toc-depth=2 $files
```

## 4. Outline Updates (Optional)

Reviewers noted a few items in `outline.md` that could be updated:
- `quantizedFlat` index type (new addition to vector search)
- Spring AI integration notes (Spring Apps retired March 2025)
- LangGraph integration examples
- Change feed processor language support corrections

## Pipeline Reminder

The write→review→fix→commit pipeline for each chapter/appendix:
1. **Write** with `cosmos-book-writer` agent (provide outline section, cross-ref map, docs mirror path)
2. **Review** with `cosmos-book-reviewer` agent
3. **Fix** with `cosmos-book-writer` agent (pass the numbered issue list)
4. **Git commit**

Docs mirror is at `C:\Users\mgarner\dev\cosmos-book\mslearn-docs\content\`.
Pandoc is at `C:\Program Files\Pandoc\pandoc.exe` (not on PATH).
