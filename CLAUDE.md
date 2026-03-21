# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A KOReader Lua plugin (`kocharacters.koplugin`) that extracts book character profiles using the Google Gemini AI API. It runs on a Kindle device running KOReader.

## Deployment

There is no build step. Deploy by copying files directly to the Kindle over SFTP:

```bash
pscp -pw root -P 2222 -batch -hostkey "f6:62:ef:7b:99:9b:b2:51:3c:55:9b:4d:72:cd:af:9b" \
  kocharacters.koplugin/main.lua kocharacters.koplugin/gemini_client.lua \
  kocharacters.koplugin/character_db.lua kocharacters.koplugin/_meta.lua \
  root@192.168.10.155:/mnt/us/koreader/plugins/kocharacters.koplugin/
```

Restart KOReader after deploying:
```bash
curl -s "http://192.168.10.155:8080/koreader/event/Restart"
```

The Kindle is at `192.168.10.155` (static IP), SSH port `2222`, credentials `root`/`root`.

## Architecture

The plugin has four modules:

**`main.lua`** — The plugin entry point. Registers the menu, owns all UI logic (InfoMessage, TextViewer, Menu, ConfirmBox, InputDialog), handles page text extraction, and orchestrates calls to the other modules. All KOReader widget interaction lives here.

**`gemini_client.lua`** — Stateless API client. Builds prompts, makes HTTPS requests via `ssl.https`/`ltn12`, and parses JSON response envelopes. Model is `gemini-3.1-flash-lite-preview`. Free tier limits: 15 RPM, 500 RPD, 250K TPM. Exposes: `extractCharacters`, `reanalyzeCharacter`, `cleanCharacter`, `cleanCharacters`, `buildRelationshipMap`, `fetchModelInfo`.

**`character_db.lua`** — Persistence layer. Reads/writes per-book JSON files at `<koreader_data>/kocharacters/<book_id>.json`. Exports go to `<koreader_data>/kocharacters/`. Exposes merge, update, delete, enrich, cleanup, scanned-page tracking, and pending-cleanup flag operations.

**`_meta.lua`** — Plugin metadata (name, version) read by KOReader.

## Key design decisions

**Text extraction** — KOReader's document APIs (`getTextBoxesFromPositions`, `getDocumentFileContent`) are unreliable on this build. The working path is: `getPageXPointer` → fragment index → read OPF from epub via `unzip -p` → find spine item → read chapter HTML → strip tags → slice ~2500 chars around the current page position.

**Book ID** — Derived from the file path: `<sanitized_filename>_<byte-sum hash>`. Not MD5. The `character_db` parameter is named `book_md5` but actually receives this path-based ID.

**Character update flow** — Before each Gemini call, the plugin scans the page text for names of already-known characters. Known characters found in the text are passed to Gemini as full profiles to update; known characters not found are passed as a skip list. `character_db:merge` updates existing entries in-place rather than skipping duplicates.

**Duplicate detection** — Three local functions in `main.lua`:
- `findDuplicatePairs(chars)` — checks within the existing DB; used by `checkAndWarnDuplicates`.
- `findIncomingConflicts(existing, incoming)` — checks new chars from Gemini against the existing DB, returns conflict pairs.
- `deduplicateIncoming(chars)` — collapses near-duplicates within a single incoming batch before DB insertion.
All use Levenshtein distance (≤1 for names ≤6 chars, ≤2 for longer) plus substring matching.

**Spoiler protection** — Characters have an `unlocked` field. Locked characters show as `[SPOILER]` in the browser; tapping unlocks them.

**Pending cleanup** — After auto-enrichment, a `pending_cleanup` flag is set per book. The user can run "Clean up all characters" to batch-deduplicate text fields via Gemini. The flag is shown in the menu title.

**Auto-extract** — A debounced `onPageUpdate` handler auto-extracts on page turn if enabled. Tracks scanned pages in a sidecar JSON to avoid re-processing.

**Rate limiting** — Chapter scan processes pages in batches of 4, sleeping 3 seconds between API calls (`os.execute("sleep 3")`). Combined with ~1-2s API latency this stays under 15 RPM.

## Release process

**Always bump the version in `kocharacters.koplugin/_meta.lua` before committing and pushing.** Use patch increments (e.g. 1.3.23 → 1.3.24). Include the version bump in the same commit as the change.

## KOReader Lua constraints

- Use `Menu` (not `TouchMenu`) for flat item lists — `TouchMenu` expects a tabbed `tab_item_table` structure.
- Long operations must be synchronous; update progress by closing and re-showing `InfoMessage` with `UIManager:forceRePaint()`.
- `pcall` every document API call — many methods vary by KOReader build/version.
- Settings are stored via `G_reader_settings:saveSetting` / `readSetting`.
- Data directory via `require("datastorage"):getDataDir()`.
