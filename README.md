# Luxor: Thebes hotel booking and operations

**Luxor is a hotel's own booking site and back office, running as a smart contract on the Thebes
substrate.** Every state the hotel holds is a fold over an append-only, hash-chained log of commands:
a booking, a payment, a night audit or a credit note exists because a command that made it was
accepted, and replaying the log rebuilds every table byte for byte. It covers direct booking and
rates, the front desk and housekeeping, the guest's bill, invoices and credit notes, deposits and a
card kept on file, group blocks, negotiated rates and promotions, the night audit and its figures,
and the emails a hotel owes its guests, with a web front end in English and Arabic. Written in
Motoko. Apache 2.0.

- **A guest is held at the price they were shown.** A quote is one pure function the search and the
  fold both call (`src/Quote.mo`): exact integers, one declared rounding (half-even, once per stored
  figure), per-night lines and each tax's share allocated by largest remainder so the parts sum to
  their totals. A hold carries the quote's hash; the fold recomputes the quote at the block and refuses
  a hold whose price moved.
- **No night is sold twice.** A stay's nights are one contiguous range of the night grid's index
  (`src/Rows.mo`), read once; a hold or a booking checks every night's allotment, rooms in service and
  restrictions (minimum and maximum stay, closed to arrival, closed to departure, stop sell) and writes
  only after the last check passes, in a step with no await between the check and the write
  (`src/Contract.mo`). A refused command appends nothing to the log.
- **Rates as data.** Room types, rooms, rate plans (a best available rate or a discount off it, in basis
  points) and taxes (a percentage, per room night or per stay, on the room or compounded on earlier
  taxes, in rank order) are rows (`src/Setup.mo`); the rates calendar edits a range of nights as one
  command that lands whole or not at all (`setNights`, `setNightsMany`).
- **Who a rate is sold to.** A plan closed to one company is sold only to that company's bookings; a
  promotion's code opens a closed plan within its booking window, its stay window and its number of
  uses (`src/Access.mo`, `src/RateProducts.mo`). The access a closed rate was sold under is kept beside
  the hold and the booking, so a later change to the booking is checked under it too.
- **Cancellation terms the guest agreed to.** Each plan states whether it is refundable, the days
  before arrival a cancellation is free, the penalty in nights and the guarantee: the first night
  authorised, a deposit (a whole percentage, captured at confirmation) or prepaid in full. A change of
  dates is re-quoted and re-checked like a new stay; a cancellation or a no-show charges what the terms
  say and refunds the rest in the same step.
- **Packages.** A plan can include extras (breakfast for every guest every night, a spa visit on the
  arrival night), priced into the rate and posted as their own lines on the bill (`setPlanInclusions`).
- **The guest's own keys.** A hold belongs to the browser key that made it; a guest without an account
  manages their booking through a P-256 manage key made in their browser, whose private half stays in
  their link; every act is signed over the contract, the booking, the act, a hash of its arguments and
  a nonce that moves with every act, so no signature works twice (`src/ManageKey.mo`). An account
  holder signs in with a passkey and sees every stay and waitlist place on one page.
- **A waitlist that offers rooms when they free up.** A guest waits for a stay that is sold out; a room
  freed by a cancellation is offered to the first guest it fits, and nobody waits for a stay that could
  be offered now (law I9).
- **The front desk.** Today's arrivals and guests in house; check-in gives a free room of the booked
  type; a room can be moved; check-out shows what is left to pay. Bookings taken by phone, walk-ins and
  group pickups are recorded with their channel (law I12: every booking came from a hold it confirmed,
  or was taken by staff, never both). The room plan draws every room across the nights ahead.
- **Housekeeping with two people.** A departure makes its rooms dirty; one member of housekeeping marks
  a room clean and a different one inspects it, compared by principal (`src/Housekeeping.mo`). A room
  taken out of order with dates leaves its type's count only for those nights, and only when the type
  still has the rooms each night offers.
- **The bill, split by who pays.** Extras (restaurant, minibar, spa, parking, breakfast) are folio lines
  with their taxes, under the booking's money identity: charged = paid + credited + outstanding
  (`src/Bill.mo`, law I4). Lines can be routed to other payers on the same stay, each settling its own
  share (`src/Windows.mo`). A posted charge is never edited: it is voided by a credit of the same
  amount, proposed by one member of staff and approved by another.
- **Invoices and credit notes in unbroken runs.** An invoiced bill is closed to new lines; it is
  amended only by a credit note, numbered in a run of its own, naming the invoice and the lines it takes
  back, never beyond a line's amount, under four eyes (`src/CreditNote.mo`). A credit note is also
  written as the Egyptian Tax Authority's e-invoicing document (type C, version 1.0) with its canonical
  serialisation and digest, built to the text of the authority's SDK specification (`src/Eta.mo`).
- **Refunds that go back where the money came from.** A refund to a guest is split across the guest's
  own cards, newest first, each drawn no further than it captured, a card that refused a refund passed
  over; only what no card can take is paid at the desk, as a refund under four eyes with its reference
  (`src/Reservations.mo`, law I5).
- **A card kept on file, with the guest's agreement.** When the owner turns the card rule on, a rate
  guaranteed by the first night or a deposit keeps the guest's card on file as the gateway's token,
  with the agreement shown in English and Arabic at payment. A booking taken by phone gets a card link
  for the guest to open (`/card/<ref>`). At a no-show the guarantee is captured as far as it goes and
  the rest charged once to the card; a declined charge stays outstanding and is shown to the desk,
  never retried; the token is forgotten at the gateway once the booking is settled (law I16).
- **Payments through a gateway contract, signed.** Luxor draws its P-256 merchant key once from the
  substrate's randomness and signs every capture, refund and void (`src/Sign.mo`, RFC 6979 nonces,
  checked against the RFC 6979 and RFC 4231 vectors). The gateway in this repository is a test gateway
  (`gateway-test/`): it never receives a card number, answers the published test cards' scenarios, is
  idempotent on the merchant's request key, and keeps a public ledger (`ledgerView`) against which the
  hotel's cash can be checked.
- **Group blocks.** A block takes rooms of one type out of sale on each of its nights; the desk picks
  them up from the group's rooming list as bookings; at the cut-off day's night audit, or when revenue
  releases it, every room still held goes back on sale (`src/Blocks.mo`, law I15).
- **Staff authority as a table.** Six roles (owner, revenue, front desk, auditor, housekeeping, mailer);
  every staff command has a row in the permission catalogue, checked total in both directions against
  the command list (`src/Staff.mo`). A cancellation with a refund, a waived fee, a refund outside the
  terms, complimentary nights, a price override, a change to a guest's name, a void, a credit note and a
  desk refund are proposed by one person and approved by a different one, over the act's canonical
  bytes and their hash.
- **Identity documents sealed and erased on schedule.** The desk's browser encrypts a guest's document
  (AES-GCM), seals the key to the hotel's guest-data key and uploads only ciphertext; the night audit
  erases what is due by destroying the sealed key, leaving the record that a document existed
  (`src/IdDocs.mo`).
- **The night audit, in bounded steps.** A run for a business day is planned from recorded counts:
  expired holds released, no-shows marked, identity documents erased, the day's figures written; acts
  dated in the day wait while it runs; the oracle walks every table, and the day closes only when the
  plan completed, nothing failed and the walk found nothing (`src/Audit.mo`). The owner can let the
  contract run it by itself at a local time in the hotel's time zone (`src/HotelClock.mo`).
- **The hotel's figures.** Each closed day records rooms sold, out of order, arrivals and guests in
  house, room nights and room revenue by room type and rate plan, and pickup since the day before
  (law I13); the reports screen reads them back with what is on the books ahead.
- **Eighteen laws, checked where anyone can read them.** The oracle recomputes the hotel's laws from the
  raw rows, one bounded page at a time, over 31 sections (`src/Oracle.mo`): capacity, counters, nights,
  money, cash, restrictions, indexes, rooms, waitlist, housekeeping, the bill, booking origin, figures,
  rates sold under their access, blocks, cards on file, the outbox and packages. The guest's pages show
  the result (`LuxorSeal`).
- **Emails the hotel owes, through the hotel's own account.** A confirmation at once, a note two days
  before arrival, the receipt at check-out and a cancellation notice are outbox rows written in the
  block of the act that owes them; the address is sealed in the guest's browser, so the contract holds
  only ciphertext (`src/Mail.mo`, law I17). The relay (`mailrelay/`) pulls due messages with its own
  key and sends them through the hotel's own provider: SMTP, Google or Microsoft (sign-in with PKCE),
  SendGrid, Postmark, Resend, Mailgun, Brevo or Amazon SES; it checks the domain's SPF and DKIM records
  before the first message, sends each message at most once and records the outcome on the chain. The
  contract makes no outbound request.
- **A booking's history from the log.** Every act on a booking is a block; the history is the log read
  backwards a bounded stretch at a time (`src/History.mo`). A booking's reference (`LX-XXXXXX-C`) spreads
  its id over Crockford base-32 with a check character (`src/Ref.mo`).
- **Rules that change without rewriting the past.** The log records which rules each block was folded
  under; an owner's `#adoptRules` moves the hotel to the next epoch, and every rule that changed is read
  as a function of the epoch, so a new build rebuilds an old log exactly (`src/Rules.mo`).
- **A web front end for guests and staff.** Search, room, details, payment, confirmation, manage, my
  stays and the card link for guests; today, bookings, new booking, the room plan, rates, rate products,
  groups, extras, the bill, settlement, invoices, credit notes, refunds, approvals, housekeeping, the
  audit, reports, guest email, setup and staff for the hotel. English and Arabic (right to left),
  light and dark, at phone and desktop widths, with a demo data source that runs the same rules in the
  browser (`frontend/`).

| | |
|---|---|
| Log and fold | 70 command families in a frozen canonical encoding; one fold, the only writer; a fingerprint over every table, counter and string |
| Selling | quotes with one declared rounding, the night grid and its restrictions, plans and taxes as data, companies, promotions, packages, group blocks, the waitlist |
| Operations | the front desk, the room plan, housekeeping with inspection, identity documents sealed and erased, the night audit in bounded steps, the automatic audit at local time |
| Money | the bill by payer, extras, invoices and credit notes in unbroken runs, refunds across the guest's cards, deposits, a card on file for no-shows, signed gateway requests |
| Controls | six roles from a permission catalogue, four eyes over canonical bytes, typed refusals that name what to fix, eighteen laws over 31 sections |
| Guests | browser-held hold and manage keys, passkey accounts, sealed contact details, emails through the hotel's own provider |
| Verification | the Motoko batteries (4 suites, 2,567 checks, every refusal compared on the state it left untouched), the independent reader (16 laws recomputed from the exported rows; 148 of 148 injected faults caught), the front end's unit tests (35), the relay's tests (40; 12 of 12 injected faults caught), the browser walk (116 screens; 5 of 5 injected faults caught), the time-surface, outcall-and-secret and contrast checks with their controls |

Luxor is written in Motoko for the Thebes substrate. Its command log, fold, row store and permission
catalogue are the Thebes Domain Kernel's; its credit note follows the Egyptian Tax Authority's
e-invoicing specification; its rates, restrictions and night audit follow the conventions of hotel
property management systems, each stated where it is used.

**Type-safe, memory-safe, no silent errors.** Motoko is a strongly and statically typed language of
the ML family. It has option types in place of nulls, arbitrary-precision and overflow-checked
arithmetic that traps rather than wraps, garbage-collected memory with no pointers to corrupt, and
atomic message execution: a trap rolls the whole message back. Luxor is written to that discipline.
Every refusal is a typed value with its reason and the figures it was decided on (`src/Refusal.mo`):
a guest told a stay is sold out is told which night, an owner told an allotment is too low is told
how many rooms are already sold there. A byte nobody assigned is a decode failure, never a default
value; money is in minor units everywhere, never a float.

## Why it runs on Thebes

A hotel's books are the record of who stays, who pays and what is owed. Running them as a smart
contract on the Thebes substrate changes what that record is:

- **Redundant by construction.** The contract does not run on a server; it runs on every validator of
  the network, and its state is what a Byzantine fault-tolerant quorum of them agrees on. There is no
  primary to fail over from and no replica to fall behind: every validator holds the same log and the
  same bookings, and a validator that is lost is replaced by the others without a restore.
- **Tamper-proof execution.** A booking, a payment or a closed day exists only if the validators
  executed the same command on the same state and reached the same result. No administrator, no
  one with access to a single machine and no validator on its own can change a rate after it was sold,
  back-date a cancellation or remove a block: the log is append-only and hash-chained, and the fold
  that rebuilds the state from it is the only writer.
- **Verification without the hotel's word.** The log, block by block (`blockBytes`), its tip hash
  (`tipHash`), the fingerprint of the whole state (`fingerprintView`), the cash law (`sealView`) and
  every page of the oracle (`invariantPageView`) are public queries. A guest, an owner, an auditor or a
  tax inspector reads the same answer the hotel reads, and the gateway's own ledger (`ledgerView`) is a
  record of the money the hotel did not write.
- **A consortium, not a vendor.** The validators of a Thebes network can be run by the parties to a
  hotel's books: an owner and its management company, a franchisor and its hotels, or the hotels of one
  destination, as a consortium subnet. Each of them holds the record and can prove it to itself, rather
  than trusting a system one of them operates.
- **Upgrades that keep the record.** The contract is upgraded in place, its stable memory carried
  across. A build that changes a rule does not reinterpret old blocks: the log says which rules each
  block was folded under (`src/Rules.mo`), so the state stays a function of the log alone.

What this means for a hotel in particular:

- **The hotel's own booking site and back office in one deployment.** Direct bookings, the rates
  calendar, the front desk, the bill and the night audit are one contract; the page is served from the
  chain and the guests and staff sign in with passkeys through the chain's identity service. There is no
  separately hosted database, sign-in service, web host or backup job to buy and operate. The one
  service off the chain is the mail relay, which holds the hotel's email credential and only pulls.
- **Folios, invoices, refunds and deposits the guest and the hotel can both check.** The guest's manage
  page reads the booking from the contract with their own key; the laws that govern the money
  (charged = paid + credited + outstanding, refunds back to the cards that paid, invoices and credit
  notes in unbroken runs) are checked by the contract's oracle and shown on the guest's pages.
- **Guest data the chain does not reveal.** A guest's email address and identity documents are sealed in
  the browser before they reach the chain (to the hotel's own key, and the address also to the mail
  relay's key), so the validators and every reader of the log hold only ciphertext; an identity document
  is erased on schedule by destroying its key, and nobody, the hotel included, can open it again.

## What is here

| Module | What it does |
|---|---|
| `src/Luxor.mo` | The contract: the edge that establishes who (browser key, manage key, passkey session, gateway authorisation), the accept path, the views, the timer for the automatic audit |
| `src/Contract.mo`, `src/State.mo`, `src/Log.mo` | The accept path (clock read once, bind, fold, append, no await), the fold's single entry point, the block log |
| `src/Command.mo`, `src/Encoding.mo`, `src/Enums.mo` | Every act as one flat variant of 70 families, their canonical bytes (version 1, frozen), the closed vocabularies as bytes |
| `src/Rows.mo`, `src/Widths.mo`, `src/Store.mo`, `src/TextArena.mo` | Fixed-width rows in stable memory with declared and partial indexes, every width declared once and summed, the fingerprint over all state, text in an append-only arena |
| `src/Quote.mo`, `src/Setup.mo`, `src/Access.mo`, `src/RateProducts.mo` | The price of a stay; the property, room types, rooms, plans, taxes and the night grid; who a rate is sold to; companies and promotions |
| `src/Reservations.mo` | Holds, bookings, changes, cancellations, the waitlist, the front desk and the money each moves |
| `src/Bill.mo`, `src/Windows.mo`, `src/CreditNote.mo`, `src/Eta.mo` | Extras, the bill by payer, invoices, credit notes, desk refunds, the tax authority's document |
| `src/Blocks.mo`, `src/Housekeeping.mo`, `src/IdDocs.mo` | Group blocks and pickups, room states and out of order with dates, identity documents |
| `src/Audit.mo`, `src/HotelClock.mo`, `src/ClockWiring.mo` | The night audit, the hotel's time zone and automatic audit, the one place that answers a question about time |
| `src/Staff.mo`, `src/Sign.mo`, `src/ManageKey.mo`, `src/Ref.mo` | Roles, the permission catalogue and four eyes; P-256 signing for the gateway; the guest's manage key; booking references |
| `src/Mail.mo`, `src/History.mo`, `src/Rules.mo`, `src/Refusal.mo`, `src/Oracle.mo` | The outbox; a booking's history; the rules by epoch; typed refusals; the eighteen laws |
| `src/vendor/MemphisAuth.mo` | Passkey session verification, copied unchanged from thebes-lib at `deps/THEBES_LIB_PIN` |
| `gateway-test/` | The test payment gateway: authorisations, signed capture, refund and void, cards on file, a public ledger |
| `mailrelay/` | The mail relay: the outbox pull, nine providers, OAuth with PKCE, the DNS check, the sealed address and credential |
| `frontend/` | The guest site and the hotel's console (Preact with its React compatibility, Radix, Tailwind), English and Arabic, the chain and demo data sources |

## Layout

```
src/            the contract and its domain modules
gateway-test/   the test payment gateway contract
test/           the Motoko batteries (Hotel, Gateway, Crypto, Rules); test/run.sh runs them under WASI
tools/          the gate (gate.sh), the independent reader (oracle_twin.py), the time-surface and
                outcall-and-secret checkers with their controls, contrast, the browser walk, the
                package flags (packages.sh), the NOTICE writer, the chain client the relay tests use
mailrelay/      the mail relay and its tests (capture servers for HTTP, SMTP with TLS, OAuth and DNS)
frontend/       the web front end
deps/           the pinned commits of the kernel and thebes-lib
vendor/         the kernel's README, naming the dependency and its commit
thebes.toml     the deployment manifest, as a template
```

## Building and testing

Requirements: `moc` 1.4.1 and `mops` (`mops install` fetches `core`, `base`, `sha2` and
`libsecp256k1`), `wasmtime` for the batteries, Node.js 22 or later for the front end, Python 3 with
`cryptography` and `dnspython` for the independent reader and the relay, and Playwright with Chromium
for the walk.

The Thebes Domain Kernel is a dependency at the commit in `deps/KERNEL_PIN`, checked out beside this
repository as `thebes-kernel` (or placed in `vendor/thebes-kernel`, or named by `KERNEL`);
`tools/packages.sh` refuses a kernel checkout at any other commit. thebes-lib's `MemphisAuth.mo` is vendored under `src/vendor/` at the commit in
`deps/THEBES_LIB_PIN`, and the Thebes SDK is a git dependency of the front end at the commit in
`frontend/package.json`:

```
thebes-kernel/             the kernel, checked out at the commit in Luxor/deps/KERNEL_PIN
Luxor/
  deps/KERNEL_PIN          the kernel's commit
  deps/THEBES_LIB_PIN      the thebes-lib commit src/vendor/MemphisAuth.mo was copied from
  frontend/package.json    "@thebes/sdk": "github:Mercatura-Forum/thebes-sdk#<commit>"
```

None of the following needs a chain:

```
mops install
TEST_OUT=/tmp/luxor-battery ./test/run.sh                  # the batteries, with no zero counts
python3 tools/oracle_twin.py /tmp/luxor-battery/Hotel.log  # the laws recomputed from the exported rows
python3 tools/oracle_twin.py /tmp/luxor-battery/Hotel.log --control
./tools/no_direct_clock.sh && ./tools/no_direct_clock_control.sh
./tools/outcall_and_secrets.sh && ./tools/outcall_and_secrets_control.sh
node tools/contrast.mjs
python3 mailrelay/tests/run.py && python3 mailrelay/tests/control.py
(cd frontend && npm ci && npx tsc -b && npx vitest run && npm run build)
tools/gate.sh                                               # all of the above and the browser walk, on HEAD
```

The contracts are built with legacy persistence, so an in-place upgrade keeps their state:

```
moc --legacy-persistence $(./tools/packages.sh) -o build/luxor.wasm src/Luxor.mo
moc --legacy-persistence $(./tools/packages.sh) -o build/gateway.wasm gateway-test/main.mo
```

`thebes.toml` is the deployment manifest for `thebes-deploy`, with every network value a placeholder;
its header states the order of the install (the gateway, Luxor, Luxor's merchant key, the gateway's
upgrade with that key).

## Known limitations and open items

- The kernel's public repository is not yet published; until it is, the batteries and the contract
  build only where the kernel at `deps/KERNEL_PIN` is available. The front end, the relay and the
  checkers run without it.
- Payments run through the test gateway in this repository. A connection to a card acquirer is not
  part of this tree.
- A guest's name and note are stored in the log in clear text, and the log is readable through the
  public queries; the email address, the email credential and identity documents are sealed.
- Luxor does not publish its log under a root certified by the network: a query is answered by the
  validator it reaches, and a reader who needs more compares the answers of more than one.
- The batteries that drive a contract on a chain (the deployed pair's integration, the timer-driven
  landings, upgrade rehearsals) are not in this repository; what is here runs without a chain.
- The mail relay is one service per network, off the chain; it holds the master key from which
  each hotel's mail keys are derived, and each hotel's email credential under the digest the owner
  authorised.

## Contributing

This repository is the clean cut of a product built through iteration, test batteries, an
independent reader of its laws and review; each release states what the system guarantees. Open an
issue for a question or a report, with the file and line; open a pull request against `main` with the
gate green. Contributions are attributed to the team.

## Licence

Apache License 2.0 (see `LICENSE`). Third-party material the page ships (fonts, the photographs of the
demo properties, the SDK's Ed25519 fallback) is listed in `NOTICE`.

The Thebes family: [Mentat](https://github.com/Mercatura-Forum/Mentat) (enterprise and ledger),
[Hippocrates](https://github.com/Mercatura-Forum/Hippocrates) (hospital),
[Manticore](https://github.com/Mercatura-Forum/Manticore) (core banking and payments),
[Solari](https://github.com/Mercatura-Forum/Solari) (audit),
[Lazarus](https://github.com/Mercatura-Forum/Lazarus) (insurance),
[thebes-lib](https://github.com/Mercatura-Forum/thebes-lib) and
[thebes-sdk](https://github.com/Mercatura-Forum/thebes-sdk).

Attribution: Thebes Core Team.
