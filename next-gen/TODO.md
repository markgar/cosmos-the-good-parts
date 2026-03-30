# Cosmos DB: The Good Parts — Remaining Work

All 28 chapters + 5 appendices are written, reviewed/fact-checked, and committed. Epub is built (494 KB).

## Completed

- [x] **28 chapters** — written, reviewed, fixed, committed
- [x] **Appendices A–E** — written and fact-checked against docs mirror
- [x] **Cross-reference audit** — 346 references checked, zero errors
- [x] **build.ps1 fixed** — encoding issues resolved, appendices now included
- [x] **Preface chapter ranges** — corrected to match outline

## Remaining (Optional)

### Outline Updates
Reviewers noted a few items in `outline.md` that could be updated:
- `quantizedFlat` index type (new addition to vector search)
- Spring AI integration notes (Spring Apps retired March 2025)
- LangGraph integration examples
- Change feed processor language support corrections

## Build

Run from `next-gen/`:
```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Pandoc is at `C:\Program Files\Pandoc\pandoc.exe` (not on PATH).
Docs mirror is at `C:\Users\mgarner\dev\cosmos-book\mslearn-docs\content\`.
