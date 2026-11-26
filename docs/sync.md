# Sync

Your spaces, tabs, folders, bookmarks and settings on every Mac (and later
the iPhone), end-to-end encrypted: the sync server keeps only boxes it
can't open, under names it can't read. The plan and its decisions are in
`PLAN-sync.md`; this page is how it works.

## Pieces

- `Sources/SyncKit` (no AppKit, shared with the iPhone app):
  - `Clock.swift`: hybrid logical clocks (`Stamp`), the order every device
    agrees on.
  - `Record.swift`: a record is fields, each with the stamp of its last
    change, and a removal stamp. `Kind` says how a collection merges:
    `last` (newest wins), `most` (largest number), `perDevice`, groups of
    fields that move as one (`parent` + `order`), and whether a removal beats
    everything (`removalWins`, tabs and pairs).
  - `Order.swift`: fractional keys in base 62; `assign` keeps the keys of
    the longest run that didn't move.
  - `Tree.swift`: orphans and loops put right after a merge.
  - `Journal.swift`: `sync.sqlite`, this device's copy of every record, its
    dirty flag, the server's version of it and the cursor.
  - `Seal.swift`: the account key and everything derived from it.
  - `SyncClient.swift`: the connection to the server.
  - `Collections.swift`: every collection's name and merge rules
    (`SyncCollection.register()`), one list for the Mac and the iPhone.
  - `Shapes.swift` and `ChatShapes.swift`: what each collection's records
    say, as plain values (`SyncSpace`, `SyncTab`, `SyncFolder`, `SyncPair`,
    `SyncBookmark`, `SyncVisit`, `SyncSetting`, `SyncIcon`, `SyncChat`,
    `SyncChatItem`, `SyncSend`, `SyncPresence`) with their `fields`, and
    `RecordShapes`, whole collections from lists. Both devices write and
    read records through these, so their fields can't drift apart;
    `Tests/FastTests/SyncWireTests.swift` holds the Mac's records to the
    bytes it wrote before they moved here.
  - `StepWords.swift`: a chat step in words and its mark's name (`StepArt`),
    the one table the Mac's chat and dock and the iPhone's chats read.
- `Sources/Fast/SyncShapes.swift`: Yab's files as records and back: its own
  types turned into SyncKit's values.
- `Sources/Fast/SyncCenter.swift`: the mirrors, the key, Settings › Sync.
- `Sources/Fast/SyncWallet.swift`: passwords, two-factor keys, cards and
  addresses, between the keychain and the journal.
- `Sources/Fast/SyncAddons.swift`: extensions and plugins as records and
  back; `Sources/Fast/SyncMirror.swift` runs those between the journal and
  the lists here; `Sources/Fast/SyncInstalls.swift` fetches and puts in
  what another Mac has and this one hasn't.
- `sync-server/`: the Cloudflare Worker and its Durable Objects.

## The key and the account

One random 32-byte key `K` per account, made on the first device. It never
reaches the server. From it (HKDF-SHA256, info strings in `Seal.swift`):

| Derived | Info | Use |
|---|---|---|
| record key | `yab sync records v1` | AES-GCM over each record, the record's server name as associated data |
| name key | `yab sync names v1` | HMAC-SHA256 of `collection \0 id`, base64url: the record's name on the server |
| account id | `yab sync account v1`, 16 bytes | base64url, the account's address on the server |
| auth secret | `yab sync auth v1` | proves to the server that a device holds `K`; the server keeps only its SHA-256 |

### Turning on

Turn On Sync makes no account by itself. iCloud Keychain can be seconds or
minutes behind, and a key made in that gap is a second account for the same
person. So it looks for the shared key for six seconds; if none comes it
asks Is This Your First Device?, and only Start Syncing makes a new account.
Without a line (`v1/health` unanswered) it says so and makes nothing.

### Two accounts

A Mac that syncs compares its key with iCloud Keychain's when it goes live
and when Settings › Sync opens. A different key is another account on the
same Apple ID (a key that came too late, or a Mac from before Turning on):
Sync's page says so at its top, a corner notice says so once. Join needs no
digits, the Apple ID has said both are the person's. Keep Separate leaves a
row under Add a Device.

A Mac on another Apple ID joins from Add a Device with the other Mac's code,
no need to turn sync off: nobody waits under such a code, so the Mac waits
under it (`askToJoin(invite:)`), both show the four digits, and both say
yes, in either order. Half a minute without Let In adds a line under the
digits; the server can't tell a slow person from a mistyped code.

Either way one Mac holds both keys (`AccountMove`). The account with more
devices stays, this Mac's when even. The device list comes from signing in
for a moment under a throwaway id (`peek`), which leaves the Mac itself out
of that account. The other account gets one `accountmove` record with the
key of the one that stays, so every device there, a phone that was off
included, goes on by itself and nobody stays behind. Accounts left are
noted in `sync.leftAccounts`: two Macs merging opposite ways at once can't
send each other round.

There is no other account: no email, no password. Whoever holds `K` is the
account. A new device gets `K`:

1. from iCloud Keychain, a synchronizable item (`SyncKey.swift`), when the
   build is signed to use it and the same Apple ID is signed in: nothing to
   do;
2. by a code: the new device shows eight characters, you type them on a
   device already in the account, which seals `K` to the new device's
   one-time X25519 key through the server's pairing box. Or the other way
   round (`JoinInvite`): Settings › Sync › Add a Device opens a page,
   using the same grouped code field as connecting an assistant. The QR,
   a code from another Mac, matching digits and the result stay on that
   page. Going back or closing Settings cancels its invitation; reopening
   makes a fresh code. A Mac's Add a Device shows a code of its own, as
   text and as a QR of `yab://join/ABCD-EFGH` (nothing but the code), and
   an iPhone scans it (Join Your Mac › Scan QR, VisionKit's data scanner,
   or the Camera, which opens Yab on the link) or types it. The iPhone
   posts its one-time key under that code in the same box; both screens
   show four digits worked out from the key and the code
   (`JoinInvite.check`, SHA-256 of "yab sync check v1", the code and the
   key), and the Mac seals `K` only once the person says in its "Let In
   This Device?" that they match. Whoever saw the code over a shared
   screen and posted first gets nothing without that yes, and the person's
   own iPhone, finding the box taken, says the code was used already.
   A new Mac takes that code too: under Already syncing on another device?
   it shows its own code and a field for the one the other Mac shows, and
   typed there it waits under it with the four digits, as an iPhone does
   (register 1628; before, a syncing Mac's code worked only for an iPhone,
   and two Macs each typing the other's displayed code both failed). A wait
   under a code rides out a moment without network or the server's 429,
   says why it ended (taken, ran out) and is cancelled when its page goes
   (`Pairing.wait`, `Pairing.Asking`): waits left polling could add up to
   the pairing door's 100 a minute for the house's address;
3. from the Recovery Key, `K` in base32, shown once when sync is turned on,
   with Copy and Download… (Yab Recovery Key.pdf, one page drawn on the Mac);
   an iPhone in sync shows it in Settings › Sync › Recovery Key after Face ID
   (or the passcode), with Copy to this iPhone's pasteboard only, for two
   minutes.

An iPhone leaves with Settings › Sync › Turn Off Sync on This iPhone (asked
first): the account removes it (it revokes itself, as Remove does from a
Mac), and it forgets `K`, its token, its id and the journal; its tabs and
chats stay. A Mac's key in iCloud Keychain doesn't bring it back by itself
afterwards (`settings.syncTurnedOff`); a code or the Recovery Key does.
The iPhone keeps which of its spaces, tabs and folders are which records
(`browser-ids.json`, per account, with the device ids it had), so joining
the same account again, after Turn Off or Join Again, maps its own spaces
back instead of adding them a second time. It waits for the whole line
first, then takes the account's rows with its own tabs put back: one made
while out goes up, one of today's still under an old device id becomes this
iPhone's again (same record), and an old id's tab of today it closed while
out closes everywhere (row 385). Settings › Sync lists the account's devices,
this iPhone first, a Mac's or an
iPhone's glyph, and in the Mac's words "Syncing now" (heard from in the
last two minutes) or "Last synced …".

Removing a device revokes its token at once. It still knows `K`, so
**Remove and Change Key** makes a new `K`, a new account, re-sends
everything and moves every other device over with a sealed note under the
old account (`rekeyed`).

## Protocol v1

Catch-up is paged by record sequence, not by space. A space renamed after
its tabs can arrive in a later page than those tabs, their folders and
pairs. Until that parent space arrives, their absence from this Mac's
rows is not a deletion. When the space arrives, its row is rebuilt from
the journal even if that page contains no tab records. A known space's
removal still removes its rows. `SyncSpaceDeliveryTests` covers both a
fresh join and a reconnect, including the next save back to the other Mac;
`evals/golden/sync_space_delivery.sh` runs the focused checks.

Folders the same way: a folder opened, renamed or moved since its tabs
were written comes pages after them, and a folder can come before or after
the folder it is in. A row draws a folder only from its record, so until it
comes the row shows those tabs loose, and the Mac's save of its rows
meanwhile is no move out of it (`SyncCenter.reconcileRows`): a tab's or a
folder's `folder` naming a folder the journal has never held stays as it
was (`SyncShapes.keepingLinks`), a folder no record here names yet was
never drawn here and isn't removed for missing, nor a pair whose other tab
hasn't come. A folder known and removed still lets its tabs go, and a
folder emptied here still goes. Through 0.46.24 a fresh Mac's first sync
took every tab whose folder came late out of it, and those folders away,
on every device (`SyncFolderDeliveryTests`, row 1895).

Base URL: `YAB_SYNC_URL`, then `Info.plist` `YabSync`, then
`https://yab-sync.21st.workers.dev` (the owner's Cloudflare account,
Worker `yab-sync`, deployed with `npx wrangler
deploy` from `sync-server/`). JSON everywhere; blobs are
base64 (standard alphabet) of `Seal.seal` output.

### HTTP

- `POST /v1/accounts/{account}/devices`
  body `{"secret": A, "device": {"id", "name", "model"}}` →
  `{"token"}`. Creates the account if it does not exist (storing
  `sha256(A)`); 403 `{"error": "secret"}` if it exists and the secret
  differs, 403 `{"error": "revoked"}` for a device id that was removed.
  Re-registering any other device id replaces its token.
- `GET /v1/accounts/{account}/devices` → `{"devices": [{"id", "name",
  "model", "lastSeen", "revoked"}]}`.
- `DELETE /v1/accounts/{account}/devices/{id}` → 204. The device's sockets
  close with code 4003.
- `DELETE /v1/accounts/{account}` → 204, everything gone.
- `GET /v1/census` with `Authorization: Bearer <CENSUS_TOKEN>` (a Worker
  secret; 404 without it) → sums for the site's /admin: accounts heard
  from in 7 days, how many have 1, 2, 3, 4+ devices, Macs, iPhones, those
  on 2+ Macs. Each account object tells one `Counts` object
  (`src/census.ts`) its own id (a hash of the account name), its Macs and
  iPhones seen in 30 days and when, on a device added or removed and at
  most hourly otherwise; nothing else leaves the account.
- `PUT /v1/accounts/{account}/devices/{id}/push` body `{"token": hex,
  "env": "sandbox"|"production", "topic": bundle id}` → 204, by that device
  only (403 `not-yours` for another's); `DELETE` the same path → 204. While
  that device has no socket open, a change accepted from another device
  sends it a silent APNs push (`content-available`, priority 5, collapsed),
  at most one a minute; a token APNs calls gone is forgotten. It needs the
  team's APNs key in the Worker's secrets (`APNS_KEY`, the .p8's text,
  `APNS_KEY_ID`, `APNS_TEAM`); without them nothing is sent. An iPhone
  in the back catches up on it (sync-ios.md, R2).
- `POST /v1/pair` body `{"code": box, "pub": b64(key ‖ tag)}` → 204. The
  server never sees the code (v2, `Stretch` in `Seal.swift`): the code is
  stretched by PBKDF2-SHA256 (300,000 rounds, salt "yab sync pairing v2"),
  and HKDF of that gives the box name (hex), the key that tags the posted
  X25519 key (HMAC-SHA256 over "yab sync pub v2" and the key) and the salt
  of the envelope's key ("yab sync join v2"). A device already in seals
  only to a key whose tag checks (`Joining.verified`), so a server that
  swaps in its own key, or tries every code within the ten minutes, gets
  nothing. v1 (a plain SHA-256 of the code, a bare key) is refused: both
  devices need a Yab from 2026-10-09 on.
  `GET /v1/pair/{code}` → `{"pub", "envelope"?}`; `PUT /v1/pair/{code}`
  body `{"envelope": b64}` → 204. Entries live ten minutes; once answered,
  the envelope can be read at most 20 times (reads of `pub` alone are free).

All but `POST …/devices` and `/v1/pair` need `Authorization: Bearer
<token>`; 401 for an unknown or revoked token.

### Socket

`GET /v1/accounts/{account}/socket` (WebSocket, bearer token).

Client → server:

- `{"t": "hello", "cursor": N, "v": 1}`: send everything after seq `N`.
- `{"t": "push", "id": "r1", "changes": [{"name", "base", "blob"}]}`:
  `base` is the version this device last had (0: none). Each change is
  taken when `base` equals the server's version, else returned as a
  conflict.
- `{"t": "presence", "blob"}`: relayed to the account's other sockets,
  and kept, the last one per device: a socket that says `hello` gets the
  others' right after its catch-up (a phone that just connected knows the
  Mac's tab and whether it sleeps). A removed device's goes with it.

Server → client:

- `{"t": "changes", "items": [{"name", "version", "seq", "blob"}],
  "cursor": N, "more": bool}`: after `hello`, in batches of at most 500
  (`more` until caught up), then one per accepted push from another
  device, live.
- `{"t": "pushed", "id", "accepted": [{"name", "version", "seq"}],
  "conflicts": [{"name", "version", "blob"}]}`. A conflict is merged on
  the device and pushed again on top of the version given.
- `{"t": "presence", "device", "blob"}`.
- `{"t": "error", "code", "message"}`; codes `too-big` (a blob over 96 KB
  of base64), `full` (an account over 250 MB), `bad`.

The server keeps the latest blob of each name, not a log: an account's
size is bounded by its records, not its history. Removals are records too
(their blob says so), kept for good.

## Collections

Every record is `{collection, id, fields, stamps, deleted, schema}`
(`Record.swift`), JSON, sealed whole. Fields below are the record's
`fields`; times are seconds since 1970; `order` is a fractional key
(`Order.swift`: base 62, `0-9A-Za-z`, sort as plain strings, ties by id).
A record merges field by field, newest stamp winning, unless said
otherwise. A device that writes a record stamps each field it changes with
its own hybrid clock (`Clock.swift`) and sends the whole record.

| Collection | id | Fields | Merge |
|---|---|---|---|
| `space` | space UUID (the first is `00000000-0000-0000-0000-000000000001`) | `name`, `icon` (an emoji, or an SF Symbol's name from the Icon tab, which an iPhone shows as its emoji and writes back as the symbol until another is picked there: `SpaceSymbols.wire`, feedback #354), optional `iconChoice` (the exact icon deliberately picked) and `iconChoiceID` (a fresh UUID for each manual pick, even the same icon), stamped with `icon`; an unmarked matching emoji echoed by an older device cannot replace a local symbol, `ownSignIns`, `paint` (`{swatch, color, grain}`), `origin`, `order` | `parent`+`order`, and `icon`+`iconChoice`+`iconChoiceID`, move as one |
| `tab` | tab UUID | `parent` (space UUID), `order`, `url`, `title`, `pin` (a letter, or absent), `name`, `seen`, `kept` (true or absent), `folder` (folder id), `live`, `customMark`, `depth` (how far down the page was read, 0 to 1 by hundredths), `home` and `homeTitle` (a pin's or a kept tab's address where it was pinned or kept, and that page's title; absent: the address it is at, PinnedHome.swift), `device` (a tab of today's: the device it is open on; absent on pins, kept tabs and today's tabs from before, below) | a removal wins over everything; `seen` is the largest |
| `folder` | folder UUID | `parent` (space), `order`, `name`, `open`, `search`, `today`, `ordinaryToday` (an ordinary folder moved among today's: it keeps its name and nesting; absent otherwise), `live`, `customMark`, `folder` (the folder it is in, absent at the top of the kept) | `parent`, `order` and `folder` move as one |
| `pair` | `<tab id>\|<tab id>` | `parent` (space), `share` (0.25 to 0.75) | a removal wins; a pair of two pins is a pair pinned as one (PinPairs.swift), and with the pins in every space it goes with them in the first space's row (`SharedPins.folded`) |
| `bookmark` | UUID | `parent` (folder id or `root`), `order`, `title`, `url` (absent for a folder), `folder` (true for one), `added` | |
| `setting` | the key (`SyncShapes.settingKeys`) | `value` (data as `{"$data": base64}`, dates as `{"$date": seconds}`) | |
| `file` | path under the app's folder (`SyncShapes.files`) | `json` | whole file |
| `answer` | `FormAnswers.Said.id` (a hash of site and question) | `question`, `answer`, `site`, `at`, `fresh` | one a question on a site, so two Macs' answers add up |
| `login` | `<host>\u0001<user>` | `host`, `user`, `used`, `clear` (kept from plain http), `space` (the UUID of the Space it was saved in, none for shared; a Mac without Spaces in logins ignores it), `secret` (the password, sealed) | `used` is the largest |
| `code` | its login's id | `secret` (the two-factor setup key or otpauth link, sealed) | |
| `card` | the card's keychain id | `facts` (brand, last four, name, expiry, nickname, issuer, `used`…), `secret` (sealed `{number, csc}`) | also written by an iPhone that keeps a card for a payment's yes (`AssistantWallet`, id a UUID); a Mac takes it into Wallet as another Mac's |
| `address` | the address's keychain id | `secret` (the address, sealed) | the same, `AssistantWallet.address` |
| `icon` | file name in `custom-icons/` | `data` (base64) | |
| `routine` | routine id | the `Routine` fields but how its runs went, and `runsOn` (device id); not a plugin's (`boost:`) | only `runsOn` runs it |
| `memory` | page path, or `episodic/<day>.md#<hash>` for a diary entry | `text`; a diary entry also `day` | |
| `visit` | the page's key (`Address.pretty`, lowercased) | `url`, `title`, `last`, `typed` | `last` is the largest; history only ever adds |
| `chat` | `a:<chat id>` | `kind` (`agent`), `device`, `title`, `state`, `answer`, `cli`, `model`, `started`, `updated`, `pinned`, `archived`, `unread`, `effort` (how hard its agent thinks now, absent for the agent's own; `model` is the one it is on now), `choices` (while it is going: what its agent waits for you to pick from, its question the last `message` named `question`; null once picked), `project` (the `project` record it is in, absent for a chat on its own; a phone writes it to move the chat, stamped as Pin is) | Metadata set on another device is taken by the owning Mac. A phone draws `choices` as the Mac's column does, numbered over its field; a tap, or words typed there, goes as an ordinary `send` and the Mac answers the pick with it (`Agents.choose`), never as a follow-up |
| `chatitem` | `<chat record id>/<item id>` | `chat`, `n` (its place in the chat), `kind` (`asked`, `message`, `thinking`, `tool`, `command`, `edit`, `plan`, `subagent`, `chose`), `name`, `detail`, `text`, `state`, `began`, `ended` | the last 80 of each chat; `text` of a command its last 1,500 characters, of a thought or a tool its first 2,000, else 8,000 (an account holds 250 MB) |
| `project` | `prj-` and eight letters | `name`, `emoji`, `tint` (blue, green, orange, purple, pink, yellow, teal or gray), `instructions` (up to 8,000 characters), `memoryOn`, `pinned`, `archived`, `order` (among the pinned), `created`, `updated` | a project of chats (`SyncProject`, docs/chat-projects.md); its memory and files stay on the Macs; a removal sends its chats back to Chats on every Mac |
| `send` | a new UUID per message | see below | |
| `sendpart` | `<send id>/<file index>/<n>` | `send` (its send's id), `data` (up to 48,000 bytes of a file attached to the send, base64) | a removal wins; written by the iPhone before its send and removed by it once the send is done, never written or removed by a Mac |
| `commandcap` | the device's id | what that device takes from the others: a Mac's from the iPhone, an iPhone's (`kind` `iphone`) from a Mac, below | written only by its own device, every field stamped by it |
| `taskcommand` | a new UUID per task | `body`: a task from the iPhone (`TaskRecords.Request`), below | a removal wins |
| `task` | the `taskcommand`'s id | `body`: what the Mac says of it (`TaskRecords.Observation`) | a removal wins |
| `extension` | its Chrome Web Store id | `name`, `version` (the newer of the Macs'), `enabled`, `pinned`, `permissions` (what it was allowed, which only grows) | a removal wins over a change made as it happened; installing again brings it back |
| `plugin` | the plugin's package id | `name`, `sites`, `rung`, `enabled`, `author`, `digest` (BoostShare.digest of its files), `runsOn` (device id), `state` (its own storage, while the record fits), and `store` + `revision` for a Store release kept as it came, or `parts` (ids, in order) for one of your own | as `extension`; only `runsOn` ticks its service |
| `pluginpart` | `<digest>/<n>` | `data` (up to 48,000 bytes, base64 in its URL-safe letters) | named by what it holds; removed, data and all, once no plugin names it |
| `now` | Now's row id on the Mac (`mail.<thread>`) | `title`, `detail` (Now's own words), `who`, `host`, `web` (the thread in Gmail on the web), `message` (its newest Message-ID), `order`, `device` | a Mac's Now rows about mail, at most three (SyncNow); each Mac writes and removes only its own. The iPhone keeps them in the App Group for the Now widget (NowShelf) and opens a row in the mail app it has: Gmail's app by the web link, else Mail by `message://`, else Gmail on the web in Peek |
| `assistantapproval` | the question's UUID | `body`: an agent's question for a yes on another device (`AssistantApprovalRecords.Request`, docs/approvals.md); `seen` set when opened on the Mac or written while the person is at it (quiet: shown, answerable, not rung), taken off only to ring it once they are away | a removal wins; written and removed only by the asking Mac |
| `assistantanswer` | the question's id | `body`: the yes or no (`Answer`), a payment's picked `card`, `place` and the `added` ids of version 3 | a removal wins; written by the answering device |
| `assistantdetail` | the question's id | `body`: what it is about, whole (`Detail`: mails, files, a payment's cards and addresses, words, verb), at most 60,000 bytes | a removal wins; written, rewritten and removed only by the asking Mac, with its question |
| `assistantpreview` | `<question id>.<file id>.<page>` | `body`: one JPEG of a file's page, 50 KB at most, base64 | a removal wins; the asking Mac's, gone with its question |
| `assistantresult` | the question's id | `body`: what came of a yes given elsewhere: `paying`, `paid` (with `order`), `declined`, `done`, `failed` | a removal wins; the asking Mac's, kept until settled and read, then gone with its question |

Pins every space shares (Pins: In Every Space, `docs/shared-pins.md`) have
no collection of their own: a Mac that shares them sends them as the first
space's pins, at the head of its row, under their own ids, and takes the
first space's pins that come in as the shared ones. A phone, or a Mac at
In Each Space, sees and changes them as the first space's pins.

The current Space (`space.current` and `window.<id>.space`) stays on each
Mac. The window's color defaults (`SyncShapes.localSpaceKeys`) stay there
too: switching Spaces writes the selected Space's paint into them. Only
the Space's own `paint` record carries its colors, grain and other Look
choices between devices. An edit to that paint still reaches a Mac showing
the same Space; switching to another Space never selects it or lends its
color to the other Mac. Legacy color settings, including removals, are
ignored when received and left untouched when reconciling settings, so an
updated Mac does not reset an older Mac's defaults.

One Personal per account. A new iPhone profile starts with a Personal
(`local.personal`) of its own. Joining an account that has spaces, it
never becomes another space: untouched, it goes; used before joining (and
still called Personal), its tabs go into the first space, kept ones kept,
the rest today's (`SyncBridge.rebuild`), and a pin the first space has at
that address isn't added twice. It waits for the whole catch-up: a
catch-up page can bring Work before the first space. Before that wait, a
join could put the starting Personal up as a second Personal under an id
of its own. The device that made it repairs it on each launch once its
line is caught up (`SyncBridge+JoinRepair.swift`: `joinDuplicate`, `repairJoinDuplicate`,
beside the prune below). Only that device acts: its own
`browser-ids.json` maps `local.personal` to the copy, and two devices
moving and deleting at once could lose a tab (a tab's removal wins). All
must hold: the copy isn't the first space, the first space is in, the
copy is still Personal with 🏠, has no sign-ins or folders of its own,
and holds no page of another device's today (pins, kept tabs and this
device's today's only). Its tabs go into the first space the way a used
starting space's do, the moves are written, and once the journal holds
nothing of it but blank tabs, it is deleted on every device. After the
delete its tombstone makes the rule false, so a second run writes
nothing; a launch cut short between the moves and the delete finishes on
the next. Its colors are not kept. Earlier builds added one
empty Personal per install; once its line is caught up, an iPhone deletes
those on every device: not the first space, not one with a page, a folder,
its own sign-ins or a private tab, and one Personal always stays
(`SyncBridge.emptyPersonals`). `scripts/runs/one_personal_check.sh` checks
it in the simulator: join, reinstall, reinstall untouched.

A device is gone (`SyncBridge.goneDevices`, from the account's whole device
list, read first) when it was removed, when it is an id this iPhone had
before (`browser-ids.json`'s `former`), or when it is another iPhone or
iPad the server hasn't heard from in 30 days (a reinstall comes back as a
new device). A gone device's tabs of today count as nothing: nobody will
see them again, so a Personal holding only those is empty (row 386).

Before row 385's fix, joining again (Turn Off, Join Again) forgot
`browser-ids.json`, so the iPhone's renamed starting space came back as a
new space each time, its pages with it. Once an account (`IDs.swept`, the
sweep's number `SyncBridge.sweep`), with the line caught up and the device
list read, an iPhone deletes those copies on every device
(`SyncBridge.duplicateSpaces`): a space with the same name and icon as
another, whose record a gone device made (the device of its earliest
stamp), beside a copy a living device made or the first space. Only when
nothing in it is its own: not the first space, no sign-ins or folders of its
own, every page in it (pins, kept, today's, a living device's today's) at an
address a living copy has, and on this iPhone no private tab and no page
the living copies lack. The server can't tell any of this (names and
records are sealed); only a device in the account can.

Keyboard shortcuts chosen in Settings › Shortcuts go one `setting` record
an action, `shortcut.<action>` (value: the key as `Hotkey.stored`, or empty
for none), so a key changed on one Mac and another on a second both stay;
a key set back to its own removes its record. The whole `shortcuts`
dictionary still goes up for a Yab from before and is taken only until
this Mac has split its keys. Splitting is once per joining
(`sync.shortcuts.split`, this Mac's only): that flush adds this Mac's keys
and removes none, then the Mac takes every key the account has. Another
Mac's keys apply at once (`Keymap.adoptStored`), menus and rows too. Keys
given in System Settings › Keyboard › App Shortcuts are macOS's and never
sync.

### Passwords and cards

`login`, `code`, `card` and `address` mirror the keychain (Vault, OneTime,
Wallet), on a queue of their own, read again whenever Yab's count of its
own keychain writes moves (checked every 2 s). A sealed field is
`Seal.hide`: AES-GCM under a key derived from the account's ("yab sync
secrets v1"), its record's key as associated data, base64. So the
journal on disk, which keeps records as they are, holds no password,
number or address that opens without the account key, and that key is
in the keychain. A phone opens them with `Seal.reveal`.

Which side wins: the keychain's modification date against the record's
latest stamp. An item changed here after the record goes up, a record
changed elsewhere after the item comes into the keychain
(`SyncWallet.recordIsNewer`). An item whose record this Mac changed last
goes up whatever the dates say: it is read again only once it changed,
and the keychain keeps whole seconds, so a password changed in the second
its record was written would read as older than the record and be put
back. An item sync wrote in from a record, and nothing here changed since
(`Vault.synced`), is as old as that record, and only a record stamped
after it is newer (`SyncWallet.keychainIsNewer`): its date is when this
Mac got round to writing it, and a busy Mac that wrote one change in a
second after the next was made elsewhere read its late write as the newer,
passed the next record over and sent the older password back. Yab marks
its own keychain writes once they are in, never before, so a read that
takes the mark finds the write. An item gone
from the keychain is a removal only if the mirror saw it there before;
otherwise it is a record not written in yet, and is written. A Mac that
joins reads its keychain only after it has caught up, so a login on both
sides is settled by those dates rather than by who joined last. A
two-factor key is a record of its own, so a device that never had one
never takes it from the others. Settings › Sync, Passwords, cards and
addresses (on by default) stops this Mac sending and taking them; what
the account has stays.

### Extensions and plugins

`extension` and `plugin` mirror Settings › Extensions and the plugins you
keep (`Extensions.installed`, the boost library), read whenever either
changes, and a plugin's own state whenever it is saved (BoostStorage).
`SyncMirror` runs one read both ways, from a flush or from records that came
in, through the pure passes in `SyncAddons` (`passExtensions`,
`passPlugins`); the lists are behind two small protocols, so
`SyncAddonsTests` runs this very code against real journals.

What goes: an extension from the Chrome Web Store, by its id, with whether
it is on and pinned and what it was allowed. A plugin with whether it is
on, the Mac that ticks it and its state, while the record with it still
fits what the server takes (its JSON measured, not the state's length); a
Store release kept as it came goes as the release (the files' payload named
for the listing hashes to its revision), anything else as its files: the
BoostShare payload, cut into `pluginpart` records of 48,000 bytes, each
named by the files' digest and its place, so a plugin sent again unchanged
sends nothing new and two Macs holding the same files write the same parts.

What doesn't: an extension loaded from a folder (there is nothing to fetch
it from on another Mac), what an extension keeps itself (a password
manager's sign-in, its options, `chrome.storage.sync`, which is local in
WebKit), its optional permissions chosen on this Mac, a plugin's daily AI
allowance and use of your plan, which each Mac asks for itself, and the
routines a plugin adds: each Mac makes those from the plugins it has, so a
Mac without the plugin never takes them off the others. `boost:` routine
records an older Yab still writes are left as they are. An extension's own
settings (`extensions.access.`, `.settings.`, `.keys.`) go as settings,
with the switch.

**Which side wins.** Each Mac keeps what it and the account last agreed on,
per extension and plugin (`SyncAddons.Ledger`: on, pinned, a plugin's
digest and its state's hash), in sync's own file `sync-addons.json`,
removed when sync is turned off here; not in Yab's lists, which an older
Yab rewrites. A value changed here since goes up; one unchanged here takes
the account's, and so does one never agreed on: a Mac joining takes the
account's on, off, pins, files and state for what both have. So a Mac back
from away, or from the switch off, sends only what it changed, and a change
made here and not yet sent isn't undone by one coming in. Who ticks a
plugin is always the account's, but for a plugin with no record yet, or a
new life after a removal.

**Removals.** An item in the ledger is one this Mac had at its last read:
one gone here since goes as a removal, though Yab quit right after, and
isn't put back from the account meanwhile; one the account removed comes
out here, whether the word came live or while the switch was off. An
extension or plugin this Mac had before it joined, whose record was
removed long ago, goes up again instead. A list that couldn't be read
(installed.json or the boost index there and unreadable, a later Yab's)
takes nothing away, puts nothing in and changes nothing. A removal empties
the record (Journal `reconcile(…, blank:)`): the server keeps removals for
good, and a part kept with its data would be 85 KB a version toward the
account's 250 MB.

**Parts.** A Mac takes back only parts it gave itself at its last read and
gives no more, that no plugin of the account names, and only once the line
is live: a Mac still taking in its first pages may have a plugin's parts
before its record. When one of its parts is removed elsewhere, it writes it
again; at launch it writes its own once. A part's record, sealed and in
base64, stays under the server's 96 KB. One push carries at most 768 KB of
records (`SyncClient.pushBytes`), so the server's handing it on to the other
Macs stays under a socket's megabyte, and a socket here takes messages up
to 16 MB (`WebTransport.largestMessage`), past the server's 4 MB catch-up
pages.

**Putting in.** Another Mac's extension or plugin that this one hasn't is
put in by `SyncInstalls`, one after another (WebKit fails extension workers
started together), without a question or a card: it was asked for and
kept on your own Mac. Checking, unpacking and reading run off the main
thread, and whether it is still wanted (the switch on, not removed here or
elsewhere meanwhile) is asked again right before it goes in. An extension
is fetched from the Web Store and checked as any install is (Crx), comes in
on or off and pinned as it is there, and loads only if on; a version here
that asks for more than it was allowed there (`permissions`) comes in off,
its row says "New version asks for more", turning it on asks as an update
that wants more does, and the daily update leaves it alone until then. A
Store release is downloaded by its revision; code (by the record's rung, or
the listing's) only while a catalog read from yetanotherbrowser.com in the
last six hours lists it reviewed at that very revision, checked before and
again after the download, as a release on trial must be: any other
revision the site still serves is not the reviewed one. An older catalog
is asked for again, and the release waits until one lists it, tried again
when the next catalog comes. It is kept as the listing's
(`store.origins`). A plugin of your own comes when all its parts have: put
together, hashed, and kept only if that is the digest the record says. A
Look boost comes in on or off as it is on the other Mac. Code (Page and
higher, your own or a Store release) that this Mac never said yes to comes
in off and waits for the person's yes here (`SyncAddons.arrival`,
`BoostRecord.waits`), as an extension that asks for more does: one new
here, one still waiting, or a version that asks for more than the one kept
here could (`BoostPackage.widens`, a Look boost turning into code
included). While it waits, the sync pass leaves the account's on or off as
it is (off here is not the person turning it off, so it goes to no other
Mac), the account's on doesn't turn it on here, and it ticks nothing. The
mark clears only when the person turns it on here in Settings
(`Boosts.setEnabled`); from then on it follows the account as any plugin
does, and a later version that asks for no more comes in on or off as it
is there. Nothing reloads a page for one that came, and its code doesn't go into pages already open: it runs from
their next load. While it waits, its row in Settings › Extensions or Site
Controls says so: "Downloading…", "Couldn't download, trying again" (the
network or a server, the Store's 5xx and 429 too: again after a minute,
five, fifteen, then every hour, and when the network comes back),
"Couldn't install" (files that aren't the other Mac's, a package that won't
open, or a release the catalog doesn't vouch for yet) or "Needs a newer
Yab" (a rung, payload format or record schema this Yab doesn't read). Only
a change to what putting it in depends on (its digest, release, parts,
rung, version) tries one again at once; its state or Mac moving doesn't. A
release waiting for the catalog is also tried when a fresh catalog comes,
even with unchanged listings, and with the same backoff if fetching it
failed. A package or account changed during a download keeps its new
request in the queue after the old attempt finishes. A
test run fetches nothing from the network for this: it reads `<id>.crx` and
`<revision>.boost` from the folder YAB_SYNC_STANDINS names.

**Who ticks a plugin** (`runsOn`): the Mac that kept it first, or that sends
it first if it was kept before sync. A Mac not syncing plugins (sync off,
or the switch) ticks every plugin it keeps. A Mac joining again waits for
the complete account before reconciling its plugins and extensions: the
owner another Mac took while it was away stays, and removals made meanwhile
are applied to what it still keeps. Earlier clients' callbacks cannot
change the new account's records, device list or connection state.
Turning the switch off, Turn
Off on This Mac and Undo Joining give up the plugins this Mac ticks first:
their `runsOn` goes, nothing else is read or sent meanwhile, and the line
stays open until the server has taken that (five seconds at most). A Mac
away for two days (`lastSeen`), or gone from the account, gives its
plugins up by that. The live device list is refreshed every five minutes,
so this does not depend on reconnecting. Either way the first other Mac
present to see it that
keeps the plugin and has it on writes itself; if two do, the later write
wins and the other stops.

Settings › Sync, Extensions and plugins (on by default) stops this Mac
sending and taking them; what the account has stays. On again, it takes
what changed elsewhere meanwhile, removals too, and sends what changed
here.

Undo Joining takes out what sync put in since joining, once sync is off
here, as well as putting back spaces, tabs and bookmarks.

What the encryption doesn't cover: a server that keeps old sealed records
could serve one again, say a plugin record from before its removal and its
parts, and a Mac joining fresh, with nothing newer to weigh it against,
would put it in, its code on. Sync's records carry no version a server
can't forge back; that limit, which covers everything sync carries, now
covers code too.

The iPhone takes none of them: its mirror (Phone/Sources/Sync) reads the
collections it shows and passes over the rest, and their kinds are plain,
so its journal merges them as a Mac's does.

### How far down a page

A tab's `depth` is written with the row (`Tab.depth`, from the page's
scroll reports) and sent with the tab. A Mac that hears a new depth for a
tab not on its screen takes the page there once: when it next loads, or
at once if it is loaded and out of sight. The tab you are looking at is
never moved under you. The same depth brings a page back to its place
after a relaunch.

Per-site settings (zoom, camera, microphone, location, notifications,
paused blocking) are settings by prefix (`SyncShapes.settingPrefixes`).
The iPhone reads the ad blocker's two, `shield` (the switch) and
`shield.paused` (the sites it is off for), as what its own switch and
sites follow until told otherwise there, and writes neither
(Phone/Sources/Page/Shield+App.swift).
The field's Favorites are one setting, `field.favorites`, the whole list
in its order (docs/field-favorites.md).
The iPhone reads Settings › Field's `field.firstRow` (Return takes the
top row, so a question or a task is not guessed) and `field.under` (the
rows under the words; it looks only for `ask` and `task`) as the default
of its Settings › Search, Guess from Your Words and Under Your Words,
until the person chooses there, and writes neither.

What each Mac sends: everything of the main window's spaces (not other
windows', not private tabs or an agent's), the last 14 days of history
(Settings › Sync, History of the last two weeks, on by default), its
chats updated in the last 14 days or pinned. A space's kept tabs and pins
are every window's (docs/kept-tabs.md, "In every window"): a change made
in another window is followed by the main window, whose row then goes up,
and a row that comes in is followed by the other windows. A kept tab is
sent under its key, which is the main window's tab id unless that tab was
made for an entry another window had first (`Tab.keptKey`); a row coming
in is matched by that key.

Yab for iPhone sends its own visits as `visit` records in the Mac's shape
and key (`SyncVisit`, `PhoneSync.visited`): each page an ordinary tab
opens, and the last 14 days again when sync starts writing or its switch
(Settings › Sync, History, on by default) is turned back on; never a
private tab's, a sign-in step's (`History.signInStep`) or an address with
a password. The Mac takes them into History as another Mac's. The iPhone's
History shows the Mac's places beside its own, by the device stamped on
`last`; a place taken out there stays out on the iPhone until visited
again, since history in sync only adds (Phone/Sources/History).

Nothing of Gmail's goes, sealed or not (docs/casa.md, Sync): a chat mail
went into (`Chat.withMail`), memory mail wrote or a task that read mail
kept (`Memory.fromMail`), mail's splits, lists and snippets, what a
routine on mail has done, and a sign-in's steps in history stay on their
Mac. A task the phone starts runs without mail tools, so its chat can
come back to the phone.

### Today is each device's own

Pins, kept tabs, folders, spaces, history and chats are every device's.
Today's tabs are the device's they are open on: a tab of today's carries
`device`, the id of the device that opened it (`SyncTab.device`), and each
device's rows show only its own (`SyncTab.shown`, `SyncRow(device:mac:)`).
The alpha group asked for it on 2026-10-12: a phone shouldn't get the Mac's
whole desk, nor the Mac what the phone opened on the way.

- A tab of today's with no `device` was written before this: it counts as a
  Mac's. Every Mac shows it, an iPhone doesn't, so nothing closes on the
  day both update.
- A Mac writes its new tabs of today with its own id and keeps the owner a
  tab already had (`SyncShapes.owners`); it reads only what it shows
  (`SyncShapes.row(device:)`) and never removes another device's tab of
  today for missing from its rows (`SyncShapes.elsewhere`, `reconcile`'s
  `within`). Clear on a Mac clears that Mac's.
  Nor its folders of today's tabs or its pairs side by side: a folder a tab
  of another device's is in, and a pair with such a tab, stay too (row 965).
- The iPhone writes its tabs of today with its id (`PhoneSync.openTab`),
  keeps the Macs' apart in its mirror (`SyncMirror.elsewhere`) so comparing
  the app's rows with sync never closes them, and has them in each row's
  `elsewhere` to look into. Closing one from there removes its record: it
  closes on its Mac, as any close does. Clear on the iPhone clears its own.
  Settings › Today › Your Mac's Tabs shows them under each space's own Today
  (docs/iphone-mac-tabs.md); it reads only what sync already keeps.
- Kept, a tab loses `device` and is every device's; put back among today's,
  it is the device's that did it. Keep is the one way a tab of today's
  reaches the other device's rows; Send to iPhone and Continue from iPhone
  hand a page over on purpose.
- The first launch of an iPhone with this keeps the page that was in front:
  if it was a shared tab of today's, the iPhone opens a copy of its own at
  the top of its Today and the app's tab stands for the copy
  (`PhoneSync.keepFrontAsOwn`, `IDs.alias`, once per sync folder).
- An older copy on either side doesn't know `device`. An older iPhone
  writes its new tabs of today without it: a Mac takes a tab of today's
  that comes in new to its journal, without `device`, opened by another
  device (the device on its `url` stamp), as that device's and leaves it
  out (`SyncShapes.mark`, `sync.todayOwners` in this Mac's settings, never
  synced); tabs it already held stay. An older iPhone still shows every tab
  of today's, the Macs' too, until it updates. An older Mac shows the
  iPhone's too.

### Folders in folders

A folder of yours can be in another, five deep at most (docs/kept-tabs.md,
"Folders in folders"). A tab's `folder` is the folder it is right in; a
folder record's `folder` is the folder that one is in, absent at the top of
the kept. Every folder in the tree has a record, also one no tab is right
in (a folder holding only folders), standing where the first tab under it
stands (`order`). The Mac writes them from each kept tab's `folderPath`
(`SyncShapes.rows`) and reads the path back by walking `folder` up
(`SyncShapes.row`), stopping at a loop or at five. Search folders and
folders made of today's tabs never have a `folder`.

A device draws the tree by `folder`: a folder's row, then what is right in
it in `order`, its tabs and its folders, each folder's tabs and folders
under it, stepped in a level. A device that doesn't know the field shows
folders flat, every tab under the folder it is right in. Careful with two
Macs on different versions: a Yab from before folders in folders rebuilds
whole folder records when it writes its row, so it clears `folder` and drops
the records of folders no tab is right in, and the other Mac then reads
those folders flat. Both Macs need a version with folders in folders.

A folder moved to another space (Move to Space, docs/kept-tabs.md) is
written as its tabs' move: each tab's `parent` and the folder records'
`parent` become the other space, the moved folder's `folder` absent (it is
at the top of the other's kept), the same ids throughout.

The iPhone creates folder records with stable UUIDs, including empty folders,
and writes their immediate parent in `folder`. Renaming writes only `name`;
folding remains local, and unknown Mac metadata is preserved. Moving a tab
into a folder sets the tab's `folder` to that folder, whatever depth. Deleting
a folder promotes its immediate tabs and child folders to its parent (or the
space root), then removes only that folder record. A deliberate tab title is
`name` on both devices; resetting clears `name` and reveals the page's `title`.

### Chats and words from the iPhone

There are no chats of sync's own. A chat is a conversation with Claude
Code or Codex that runs on one Mac (`device`), and its history is its
`chatitem` records. Another device says something in it by writing a
`send` record:

| Field | Set by | Means |
|---|---|---|
| `device` | the phone | the Mac to say it on: the chat's `device`, or for a new chat a Mac that is online |
| `chat` | the phone | the chat record id (`a:…`); absent for a new chat |
| `text` | the phone | the words; may be absent when `files` are there |
| `files` | the phone | photos and files with the words, at most 10 (`SyncSendFile`): each `{name, type, size, digest, parts}`, `digest` the SHA-256 of its bytes in hex, `parts` its `sendpart` ids in order; a file 10 MB at most, 20 MB a send |
| `agentText`, `cli` | the phone | instead of `text`, for a new chat with the agent chosen there (`claude` or `codex`): the Mac starts that one or fails, never its default |
| `choice` | an older phone | a bare number, bound to no question: refused |
| `kind` | the phone | `agent` for a new browser chat; `open` for Open on Mac, with `url` and `space` |
| `project` | the phone | for a new chat, the project to start it in (`prj-…`): the Mac fails the send when it hasn't that project, "That project isn't on this Mac any more."; never with `chat` |
| `model`, `effort` | the phone | the model and effort picked there (`ModelPick`): a new chat starts on them, a chat switches to them before it hears the words |
| `clientDevice`, `clientChat` | the phone | which phone, and its own id for the chat until the Mac names one |
| `at` | the phone | when it was written |
| `state` | the Mac | `processing` while it runs, then `taken`, `failed` (with `reason`) or `expired` (more than 12 hours late) |
| `took` | the Mac | when |
| `chat` | the Mac | for a new chat, the one it started |

The Mac whose id is in `device` says the words in the chat the moment it
hears the record (live, or on its next hello if it was asleep), exactly
as if they were typed there: into the turn going on, or a turn of their
own (`Agents.followUp`). Its agent's answer then comes
back as the chat's new items. A phone shows the send as waiting until
`state` is set.

Each send is done once (`ChatCommand.consume`, `OpenOnMac.consume`): its
receipt goes into the journal's own table before anything runs, so a
replay, a rewrite of the record or a relaunch never runs it twice; one left
`processing` by a relaunch is said `failed`, "interrupted", and not run
again. An unknown `kind` fails instead of becoming an agent task.

**Files with the words** (`files`): the phone writes each file's
`sendpart` records first, then the send. A Mac leaves a send whose parts
haven't all come waiting, untouched, and tries again as more parts come
(still `expired` 12 hours late). With every part there it puts each file
together, checks its size and `digest` (a mismatch, or `files` it can't
read, fail the send: "A file didn't arrive whole"), writes it to a folder
of the send's own, `agent/inbox/<send id>/<name>` under Yab's folder
(`name 2.jpg` when two share a name), and says the words with those files
attached as its own field attaches one: named to the agent with their
paths, shown as file chips over your words, into an existing chat or a new
one. Words may be empty when there are files. The phone removes the parts
once the send is `taken`, `failed` or `expired`.

**What a Mac takes** is said in its `commandcap` record (SyncChats.capability),
written with its chats, and a phone offers a command only to a Mac that
names its version there: `open` (Open on Mac), `chatAgent` (a chat with
the chosen agent), `chatMetadata` (Pin, Unread, Archive and Rename taken, R4), `chatProjects` (a new chat in a project, `send.project`, and a chat moved by its head's `project`; an older Mac fails the one and ignores the other),
`taskRecords`, `taskReadOnly` and this run's `taskReadOnlyEpoch` (tasks,
below), `attachments` (files with the words, `SyncSendFile.supports`), `modelPick` with
`models` (the model picker, below), and `atLogin` when Yab opens at login there (Settings › General,
Open at Login; docs/headless.md).

**Model and effort** (`modelPick`): a Mac lists in `models` the models its
own picker shows for a chat (Claude Code's and Codex's, those left out of
the lists left out), each `{cli, model, name, about, efforts}`, efforts
least first (`SyncMacModel`, `ModelPick.models`); a phone groups them by
`cli` as Claude and ChatGPT. A send's `model` and `effort` start a new chat
on that model (a model picks its agent when no `cli` was named) or switch
an existing chat to them before its words, as picking in its column does;
a chat keeps its agent. A model the Mac doesn't have is ignored, the chat
staying on its own, and an effort the model lacks becomes the most it
takes short of it: a pick never fails a send. The chat's head says the
model and effort it is on.

**Open on Mac** (`kind: open`): the Mac shows the page in front in its
main window, the tab already showing it if there is one, in the space the
page was in on the phone (`space`) when it has it, else where Link Routes
send the site; then `taken`, and the phone says "Opened on <Mac>".

### Pages for the iPhone

Send to iPhone is Open on Mac the other way round (`OpenOnPhone`). An
iPhone says it takes pages in a `commandcap` record of its own, id its
device id: `device`, `kind` `iphone`, `open` 1, written as its line comes
up; a Mac believes it only with `open` and `device` stamped by that iPhone
(a record another device wrote for it offers nothing). For each iPhone of
the device list that says so, a tab's menu and Site Controls' ⋯ offer
"Send to <iPhone>", for any page Handoff would offer (ContinuePage: a web
address, not Yab's own, Mail's, an agent's, or one only this Mac reaches).
It goes as a `send` record of kind `open` addressed to the iPhone, with
`url`, `clientDevice` (the Mac), `at`, the `space` it is in and the page's
`title` (one line, 200 characters at most), and the corner says "Sent to
<iPhone>".

The iPhone takes it once, as a Mac takes Open on Mac (`OpenOnMac.consume`:
the receipt first, then the page, then `taken`; more than 12 hours late
`expired` and never opened; one left `opening` by a relaunch `failed`). The
page is the tab already showing it in the space it was in on the Mac (the
iPhone's own space in front when it hasn't that one), else a new tab at the
top of that space's Today. While Yab is in front, nothing is being typed
(no keyboard, no field, Settings or chat up) and it was sent in the last
ten minutes, it comes in front and the corner says "From <Mac>"; otherwise
it waits in Today and the Now line's calm chip says "From <Mac>: <title>"
with Open (✕ or a swipe puts the chip away, the tab stays).

There is no APNs key yet, so nothing wakes an iPhone in the back: a page
comes in as the line opens, when Yab comes to the front (the journal keeps
what came while it was closed, taken on the next launch too). Once the
Worker has the key, the silent push (R2) brings it in the back the same way,
and it waits in Today with its chip.

### Continue from your iPhone

An iPhone's presence (as a Mac's, every 55 seconds while its line is up)
has `kind` `iphone`, `name`, `at` and its tab in front, never a private
one's: `url`, `title`, `tab`, and for a Mac's From iPhone the `space` it is
in and `changed`, when that page came in front on the iPhone or was last
left there (Yab to the back). It says it as the page or its title changes
(400 ms after, for a loading page's title) and as Yab goes to the back,
ahead of the line closing. A Mac (`PhoneFront`, SyncPhone) offers that page
under its empty field (Noticing, beside a link just copied, and over a page
with ⌘L) as the page's title with "From <iPhone>" in gray, for a minute
after `changed`, unless the Mac has that very tab or page in front. Taken,
it is the tab already showing it, in its space, as Open on Mac; Don't Show
Things Like This turns off Pages from Your iPhone.

**Pin, Unread, Archive, Rename** made on another device are this Mac's
chat's from then on: `SyncCenter.adopt` reads the fields another device
stamped on a head of this Mac's (SyncChats.Metadata) into Chats, with
their stamps, so the next flush writes the same values back and nothing
new goes up. A read is bound to the answer it read: the next answer is new
again.

### Tasks from the iPhone

A task the phone sends a Mac is a `taskcommand`
record whose `body` is the request: the phone, the Mac, the public space
and tab it was sent from, the words, and the `readOnlyEpoch` the Mac said.
It is taken only from an iPhone or iPad in the account's device list; a
phone that joined since the Mac last read the list has it read again (at
most every ten seconds), and the list coming back takes the task.
The Mac (SyncTasks) reserves it once in the journal (`TaskLaunch`: a
relaunch or a replay never runs it again) and runs it with the Tasks
agent (Settings › Agents), browser only, under its read-only MCP server
(`yab mcp --phone-read-only`): open, navigate, snapshot, text, wait, tabs,
close and name, in pages of its own behind the tabs, in that space's
website store (RemoteReadPage: GET only, no popups, downloads, dialogs or
sign-ins). Every call of it goes to SyncTaskRead and nowhere else; any
other verb is refused and said on the task ("needs the person on their
Mac"), and nothing local widens it: no Mac access, permits, subagents,
steering or follow-ups, and no memory turn. What the session does goes back
as the `task` record (`TaskObservation.checkpoint`): running, needs you,
done with its answer, failed or stopped, each a revision past the last, a
finished one never rewritten. A task for an earlier run of Yab, more than
12 hours late, or for a space this Mac hasn't is told failed with why; one
whose session went with a relaunch, failed, "quit before it finished". Its
chat stays on the Mac and isn't sent as a chat. Approvals signed with Face
ID on the phone (`TaskApproval`) are not taken yet: a task from the iPhone
that would pay, post or cancel stops and says so. A task started on the Mac
asks its yes on the iPhone through the sealed approval records instead
([approvals.md](approvals.md)).

Which Mac is online: a Mac with its socket open sends `presence` every 55
seconds (and once when it comes up), which also refreshes its `lastSeen`
in `GET …/devices` (milliseconds). A Mac seen in the last two minutes is
online. A presence blob is a sealed record of collection `presence`, id
the device id (so its server name is `Seal.name(presence/<device>)`),
fields `name` (the Mac's), `at`, and the tab in front: `url`, `title`,
`tab` (its id, the same as its `tab` record's), `scroll` (how far down its
page is, 0 to 1, read as the person leaves the Mac: a phone opening that
tab starts there, once), `asleep` (true as the Mac goes to sleep or Yab
quits). Besides the beat, a Mac says it when its front tab changes, when
Yab goes to the back or the screen locks, as it sleeps and when it wakes.

A tab opened, closed, moved or kept on a Mac is written to its session at
once (titles and the like wait out the usual second) and flushed 20 ms
later, so another device has it in a few hundred milliseconds with the
network (sync-ios.md, R8).

## Merging on the device

`Journal.receive` merges what came with what is here, field by field; a
record still dirty here stays dirty and goes back up. Mirrors then write
the merged state into Yab's own files and live windows (`SyncCenter`), and
the next save of those files finds nothing new to send.

### Only what the files changed is an edit

Tabs, folders and pairs are told to the journal three-way
(`Journal.reconcile(…, shown: true)`): a local change carries only what the
person did, never a difference from the merged state.
The journal keeps each record as this Mac's files last said it (the
`shown` table): a field goes up only when the files changed it since, and a
record missing from them is removed only when they held it (or its space
was removed). A row's order keys are the journal's when the row stands in
the journal's order, otherwise the keys its files were last written with
(`SyncCenter.previousOrders`), so an old row gives back its old keys
rather than new ones over the other Mac's.

Before, any difference between the files and the journal went up stamped
now, and the files lag the journal whenever they haven't drawn what came
yet: a catch-up page whose rows aren't drawn, and above all a relaunch
between a page's merge and its rows (an idle Mac restarting for the update
it just downloaded while it catches up on two weeks). The relaunch took
every pin of the other Mac's that page brought for one closed here, and a
tab's removal wins for good, so they went on every device; the old row's
order and fields beat what the other Mac did meanwhile (register 2589,
feedback #2032; `SyncStaleReturnTests`). After a delivery the rows as drawn
are read back at once, so a tab that just came and is closed goes; at
launch, records the journal has and the rows never drew
(`Journal.unshown`) are drawn (`SyncCenter.drawUnshown`), since the line
brings them again unchanged. A journal from before this has no `shown`
yet: its first save measures from the journal, as before, and sets it.

## Testing

- `swift test --filter 'Sync'`: merging (300 random runs of three
  devices), shapes, the client against an in-memory server.
- `sync-server`: `npm test` (vitest in the Workers runtime).
- Two real Yabs against one server: `evals/sync/check.py` (open in one, close in the other, five rounds, timings; an extension, a Look boost, a plugin with code in parts, a Store release and the switch, with stand-ins it downloads first; what A takes from the iPhone: its commandcap, Open on Mac, a chat with the chosen agent, a pin and a name kept; with `--iphone`, the same from Yab for iPhone in the simulator and a read-only task answered by A's agent, then Send to iPhone (opened at once, kept in Today with its chip while something is typed, taken as the iPhone comes back to the front), From iPhone on A's field, the iPhone's devices, Turn Off and joining again by scanning A's Add a Device code, `Phone/tools/sync-e2e/macs.sh`; the wallet's races: a password changed again in the very second A wrote its record, timed inside A, and a change B writes in late, its keychain's queue held, after A changed it again; `evals/sync/local.sh RUNS` runs it that many times on a local server without the iPhone, on a Mac with node); `evals/sync/shots.py` pictures Settings › Sync, its pages further in (What Syncs, Turn Off Sync) and the Recovery Key's PDF; run it as a display farm job, it captures the window from the screen.
- Over the web: `YAB_SYNC_LIVE=1 swift test --filter SyncLiveTests`.

### Agent question withdrawals

`SyncClient.kick(alerting:withdraw: true)` puts `alert` (the accepted sealed
record name), `alertID` (the question UUID) and `withdraw: true` on a push.
The Worker only wakes devices for an accepted change. A withdrawal uses
priority 5, `content-available` and the question UUID as `apns-collapse-id`;
it bypasses the ordinary one-minute silent limit and sends at most once per
question and recipient, with a durable two-day deduplication window. Both
closing an `assistantapproval` and marking it `seen` use this path. The
record stays sealed, and the APNs key is unchanged. APNs delivery is still
a hint; foreground catch-up and every background wake reconcile all of the
iPhone's delivered approval notifications. See [approvals.md](approvals.md).
