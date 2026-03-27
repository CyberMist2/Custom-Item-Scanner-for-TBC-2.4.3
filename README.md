# Custom Item Scanner

Addon for **World of Warcraft: The Burning Crusade (2.4.3)** clients. It scans a range of **item IDs**, records any item the client can resolve with `GetItemInfo`, and shows the results in a sortable list with search and quality filters.

**Interface:** `20400` (see `CustomItemScanner.toc`)

---

## Installation

1. Copy the `CustomItemScanner` folder into:
   - `World of Warcraft\Interface\AddOns\`
2. Enable **Out of date AddOns** if your client build differs slightly.
3. Restart the client or `/reload`.

---

## Opening the window

- Click the **minimap button** (drag to reposition; position is saved).
- Or type: `/cis show`  
- Toggle: `/cis toggle`  
- Hide: `/cis hide`

---

## Scanning

1. Set **Start ID** and **End ID** (numeric item entry IDs).
2. Click **Start Scan**. The addon walks every ID in order; it does **not** skip IDs in the range.
3. Use **Stop** or `/cis stop` to cancel.

### Chunking (large ranges)

Long ranges are split into **chunks** (default **10,000** IDs per chunk). Between chunks the scanner **pauses** (default **3 seconds**) to reduce stress on the client. Chat messages show chunk progress (e.g. `Chunk 5/20`).

### Server vs cache mode

- **Server mode** (`scanner.useServerRequests`, default **on**): may request item data via a hidden tooltip hyperlink before `GetItemInfo`. This can help with uncached items but is heavier on the client.
- **Cache-only**: `/cis server off` — only uses `GetItemInfo` without those extra requests (often safer for huge scans).

Toggle: `/cis server on` | `/cis server off`

---

## Results list

- Columns: **ID**, **Item** (link when available), **Type**, **iLvl**.
- **Search**: filters by item **name** (substring, case-insensitive).
- **Quality**: dropdown filters by rarity (Poor through Legendary, plus Artifact).
- **Refresh**: rebuilds the list from saved data.
- **Clear**: wipes the saved item list (see Saved data below).

Click a row to print the link (or name) to chat. Hover a row with a valid link to show the game tooltip.

---

## Slash commands

| Command | Description |
|--------|-------------|
| `/cis show` | Show the main window |
| `/cis hide` | Hide the window |
| `/cis toggle` | Toggle the window |
| `/cis start [from] [to]` | Start scan (defaults if omitted) |
| `/cis stop` | Stop scan |
| `/cis refresh` | Refresh the list |
| `/cis clear` | Clear saved found items |
| `/cis count` | Print how many items are stored |
| `/cis server on` | Enable server-request assist |
| `/cis server off` | Cache-only scanning |

---

## Saved data

The addon uses **`SavedVariables: CustomItemScannerDB`**.

- Found items are stored in **`CustomItemScannerDB.items`** (persists across sessions).
- Minimap button angle is stored in **`CustomItemScannerDB.minimapAngle`**.

WoW writes this to your account’s SavedVariables (typically under the client’s `WTF` folder). This is **not** the same as the in-memory item cache; it is normal addon saved data on disk.

---

## Performance and stability

Very large scans, especially with **server mode on**, can stress old clients. If you see instability or crashes:

- Use `/cis server off` for long runs.
- Reduce scan aggressiveness in `CustomItemScanner.lua` (see tunables below).
- Prefer smaller ID ranges or rely on chunking + cooldowns (already enabled).

---

## Tunables (advanced)

Edit **`CustomItemScanner.lua`** at the top of the `scanner` table:

| Variable | Role |
|---------|------|
| `batchSize` | How many IDs processed per tick |
| `delay` | Minimum seconds between ticks |
| `useServerRequests` | Default server-request assist on/off |
| `maxServerRequestsPerTick` | Cap on hyperlink requests per tick |
| `chunkSize` | IDs per chunk before cooldown |
| `chunkCooldown` | Seconds to wait between chunks |

---

## Limitations

- The client only “knows” an item if `GetItemInfo` returns data (and optionally after server/cache resolution). IDs that never resolve will not appear in results; that does not necessarily mean the ID is invalid on the server.
- Custom/private items must exist in the client data the same way as normal items for results to show correctly.

---

## Files

| File | Purpose |
|------|---------|
| `CustomItemScanner.toc` | Addon metadata and load order |
| `CustomItemScanner.lua` | All UI and scan logic |

---

## License

Not specified in the addon; treat as the author’s preference or your project default.
