#!/usr/bin/env python3
"""The independent reader: Luxor's laws recomputed from the raw rows, by code that shares nothing with
the contract.

The battery ends by printing every row of the tables the laws read, as the bytes the store holds
(`export: row <table> <id> <hex>`), the business day, the fold's cash counters and the contract
oracle's own verdict. This reader decodes those bytes from the row layouts the contract declares
(src/Rows.mo, src/Widths.mo): fixed-width big-endian numbers, one-byte flags and enums, a principal as
a length byte and 29 bytes. It recomputes the laws and must reach the contract's verdict. A reader
that agrees with a checker it copied proves nothing; this one is written from the layouts and the laws
as stated, not from the checker's code.

The rules the books are kept under are read first, from the rules row (none is epoch 0): the twin holds its
own table of the audit walk's span by epoch, as the rules define it (5 sections, then all 31), and the walk the battery
exports must stand within the span its row gives it (done exactly at its end, or still short of it), at an
epoch the table has. The laws added inside the first five sections after the first released build are
recomputed from epoch 1 only, as the contract checks them.

Fifteen of the seventeen laws are properties of the rows and are recomputed here:
  I1 capacity (rooms counted night by night: a room out of order with dates counts from its first
  night back), I2 counters, I3 nights, I4 money, I5 cash (from the payments themselves, not the
  fold's counters; and a refund to a guest split across the guest's own cards as those cards stood when it
  was written: newest card first, a card that has refused a refund passed over, each drawn no further than
  it can give back and to nothing before an older one is drawn, only the rest paid at the desk, as a refund
  the gateway would not make; no card ever giving back more than it captured), I6 restrictions, I8 rooms, I10 housekeeping, I11 bill (an extra's line is its quantity
  times its price, its taxes follow it on its bill, a void credits exactly the charge and its taxes; lines and
  payments moved to a bill are on that payer's booking; invoices numbered without a gap, their figures still
  their bill's less the credit notes against them; a credit note numbered in a run of its own without a
  gap, against an invoice of its booking's bill, totalling its lines, which are credits on that bill each
  recorded against a line of that booking it may take back, no line taken back beyond its amount, proposed
  by one person and approved by another under its own permission; a refund paid at the desk is a refund
  the gateway would not make, with a reference, approved the same way; no bill of a split booking paid for
  more than it owes), I12 origin, and I13 figures (a day's rooms sold and out of order within its rooms, its
  arrivals among its guests in house, its revenue rows by type and plan summing to its night, its pickup an
  unbroken run of bookings that exist, and, on a closed day, everything planned counted; and one law the
  contract's oracle does not hold: the pickup's room nights and room revenue recomputed from the bookings
  and their folio lines), and I14 rates (a booking or hold on a plan whose access was set before it carries
  the company the plan is closed to, or, on a plan closed to everyone but codes, a promotion naming the plan;
  a kept access is never the public sale, names a company or a promotion that exists and never both, and a
  booking's was kept in the block that made it; a booking from a hold keeps the hold's access; a hold counts
  no use of a promotion; a promotion's uses are its bookings' uses, each from 1 to its count, held by one
  booking only, with no gap below it, and the last use counted held; no promotion past its limit; a company's
  or a promotion's code is capitals, digits and dashes, no earlier one of its kind has it, and a company's is
  no promotion's; each has a name; a plan named for a company is closed, and the plan and company exist; a
  promotion's plan exists and its windows begin before they end), and I15 blocks (each night of a group
  block has its row on the block's room type; its rooms picked up are the rooms of the bookings on its rooming
  list that hold that night, never more than the block's rooms; what it still holds is its rooms less those
  while it is open and nothing once released; a hotel night's rooms held by blocks are the sum of its block
  nights, and I1 counts them with the sold and held; a pickup is the block's room type and plan within its
  dates, taken by staff from the group's list, and every booking taken from a group's list is a pickup; the
  block's room type, plan and company exist and its cut-off is on or before its arrival), I16 card on file (a
  card on file is the gateway's token on a payment the guest made, agreed before anything was charged to it;
  charged once, for a no-show alone, never past the penalty less what the guarantee captured, a decline
  shown only on a charge that failed; every charge on file is the one its card names; a card let go only
  once nothing is owed on it, and let go once its booking is settled; a card the desk still waits for
  belongs to a booking still to arrive; a deposit plan has its share, a whole percentage from 1% to 99%;
  a charge on file counts as money in wherever a capture does, in I4 and I5), I17 mail (a message owed
  belongs to a booking that gave an address, and is the one that address names for its kind; it is tried at
  most three times, failed only on the third and with a reason, sent with none, still due only with fewer
  than three; a receipt is owed only for a stay checked out, a cancellation notice only for a booking
  cancelled, a note before arrival still due only for a booking still to arrive and dated before it; every
  address is sealed, never an address in the clear, has its confirmation, and a cancelled booking's its
  notice and a checked-out stay's its receipt; guest email is on only with a relay connected and the account
  the relay tested, and the relay's key holds an active mailer grant), and I18 packages
  (a package line is an extra of its booking posted by the package, not by staff, its charge the inclusion
  sold, untaxed when its extra is; while its booking holds its nights, each inclusion's live lines are on
  nights of the stay, an arrival-night one on the arrival alone, an every-night one an unbroken run, no
  night twice; a held package line is its quantity times its price with its taxes after it on its hold; a
  plan's inclusion sits under its own plan and slot, and, while on, names a plan and an extra that exist
  and gives 1 to 9 of it).
Two are not, and say so rather than pass silently:
  I7 is about the index structures beside the rows, which the export does not carry;
  I9 asks whether a stay could be priced and offered now, which is the reservation engine itself, and a
  second copy of that engine written here would be a twin of the code, not of the law.

  python3 tools/oracle_twin.py <battery log>              the verdicts must agree
  python3 tools/oracle_twin.py <battery log> --control    each law broken on purpose in the bytes, and caught

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import collections, sys

# the row layouts: (field, width in bytes), in the order the contract writes them
LAYOUT = {
    "roomType": [("code", 16), ("nameEn", 8), ("nameAr", 8), ("descEn", 8), ("descAr", 8), ("sizeSqm", 2), ("maxAdults", 1), ("maxChildren", 1),
                 ("maxOccupancy", 1), ("bedKind", 1), ("bedCount", 1), ("amenities", 4), ("photos", 8), ("rank", 1), ("active", 1), ("lastBlock", 6)],
    "room": [("roomTypeId", 6), ("number", 8), ("status", 1), ("occupiedBy", 6), ("lastBlock", 6)],
    "night": [("allotment", 2), ("sold", 2), ("held", 2), ("bar", 8), ("minStay", 1), ("maxStay", 1), ("closedToArrival", 1),
              ("closedToDeparture", 1), ("stopSell", 1), ("lastBlock", 6)],
    "hold": [("roomTypeId", 6), ("planId", 6), ("arrival", 3), ("nights", 1), ("rooms", 1), ("adults", 1), ("children", 1), ("owner", 30),
             ("expiresAt", 6), ("state", 1), ("quotedTotal", 8), ("quoteHash", 32), ("fromWaitlist", 6), ("key", 33), ("lastBlock", 6)],
    "booking": [("roomTypeId", 6), ("planId", 6), ("arrival", 3), ("departure", 3), ("rooms", 1), ("adults", 1), ("children", 1), ("status", 1),
                ("account", 30), ("manageKey", 33), ("manageNonce", 4), ("guestName", 8), ("guestEmail", 8), ("note", 8), ("charged", 8),
                ("credited", 8), ("paid", 8), ("outstanding", 8), ("cancelDeadline", 3), ("penalty", 8), ("checkedMinStay", 1),
                ("checkedMaxStay", 1), ("holdId", 6), ("assignedRoom", 6), ("createdBlock", 6), ("lastBlock", 6)],
    "folio": [("bookingId", 6), ("kind", 1), ("code", 1), ("night", 3), ("amount", 8), ("block", 6)],
    "payment": [("bookingId", 6), ("gatewayAuth", 6), ("kind", 1), ("amount", 8), ("state", 1), ("attempts", 1), ("block", 6)],
    "housekeeping": [("cleaning", 1), ("cleanedBy", 30), ("inspectedBy", 30), ("outReason", 8), ("outFrom", 3), ("outUntil", 3),
                     ("changedDay", 3), ("lastBlock", 6)],
    "charge": [("bookingId", 6), ("extraId", 6), ("quantity", 2), ("unitAmount", 8), ("taxLines", 1), ("postedBy", 30), ("voidLine", 6), ("lastBlock", 6)],
    "payer": [("bookingId", 6), ("name", 8), ("lastBlock", 6)],
    "lineRoute": [("payerId", 6), ("lastBlock", 6)],
    "paymentRoute": [("payerId", 6), ("lastBlock", 6)],
    "invoice": [("bookingId", 6), ("payerId", 6), ("issuedDay", 3), ("charges", 8), ("credits", 8), ("taxes", 8), ("paid", 8), ("issuedBy", 30),
                ("lastBlock", 6)],
    "creditNote": [("invoice", 6), ("bookingId", 6), ("payerId", 6), ("issuedDay", 3), ("net", 8), ("taxes", 8), ("total", 8), ("firstLine", 6),
                   ("lines", 1), ("proposal", 6), ("lastBlock", 6)],
    "creditLine": [("note", 6), ("source", 6), ("lastBlock", 6)],
    "deskRefund": [("bookingId", 6), ("method", 1), ("reference", 8), ("day", 3), ("proposal", 6), ("lastBlock", 6)],
    "staffBooking": [("channel", 1), ("madeBy", 30), ("day", 3), ("lastBlock", 6)],
    "dayFigures": [("roomsTotal", 4), ("roomsSeen", 4), ("roomsOut", 4), ("roomsSold", 4), ("roomRevenue", 8), ("inHouse", 4), ("houseSeen", 4),
                   ("arrivals", 4), ("noShows", 4), ("pickupFrom", 6), ("pickupCount", 4), ("pickupBookings", 4), ("pickupNights", 4),
                   ("pickupRevenue", 8), ("cursorDay", 3), ("cursorId", 6), ("lastBlock", 6)],
    "dayRevenue": [("day", 3), ("roomTypeId", 6), ("planId", 6), ("roomNights", 4), ("revenue", 8), ("lastBlock", 6)],
    "refundSlice": [("firstSlice", 6), ("excess", 8), ("written", 6)],
    "company": [("code", 16), ("nameOffset", 6), ("nameLength", 2), ("active", 1), ("lastBlock", 6)],
    "planAccess": [("companyId", 6), ("closed", 1), ("lastBlock", 6)],
    "holdRate": [("companyId", 6), ("promoId", 6), ("use", 4), ("lastBlock", 6)],
    "bookingRate": [("companyId", 6), ("promoId", 6), ("use", 4), ("lastBlock", 6)],
    "promo": [("code", 16), ("nameOffset", 6), ("nameLength", 2), ("planId", 6), ("bookFrom", 3), ("bookUntil", 3), ("stayFrom", 3), ("stayUntil", 3),
              ("maxUses", 4), ("used", 4), ("active", 1), ("lastBlock", 6)],
    "block": [("nameOffset", 6), ("nameLength", 2), ("companyId", 6), ("roomTypeId", 6), ("planId", 6), ("arrival", 3), ("departure", 3), ("rooms", 2),
              ("cutoff", 3), ("open", 1), ("lastBlock", 6)],
    "blockNight": [("night", 5), ("picked", 2), ("open", 2), ("lastBlock", 6)],
    "nightBlock": [("open", 2), ("lastBlock", 6)],
    "holdLine": [("bookingId", 6), ("kind", 1), ("code", 1), ("night", 3), ("amount", 8), ("block", 6)],
    "extra": [("code", 16), ("nameEn", 8), ("nameAr", 8), ("category", 1), ("price", 8), ("taxed", 1), ("active", 1), ("lastBlock", 6)],
    "planInclusion": [("planId", 6), ("extraId", 6), ("quantity", 2), ("rhythm", 1), ("per", 1), ("on", 1), ("lastBlock", 6)],
    "packageLine": [("slot", 1), ("extraId", 6), ("quantity", 2), ("unitAmount", 8), ("rhythm", 1), ("taxed", 1), ("taxLines", 1), ("lastBlock", 6)],
    "holdPackage": [("slot", 1), ("extraId", 6), ("quantity", 2), ("unitAmount", 8), ("rhythm", 1), ("taxed", 1), ("taxLines", 1), ("lastBlock", 6)],
    "bookingBlock": [("blockId", 6), ("lastBlock", 6)],
    "cardOnFile": [("token", 6), ("firstAuth", 6), ("agreedBlock", 6), ("deadline", 3), ("state", 1), ("chargeId", 6), ("attempts", 1),
                   ("declinedDay", 3), ("lastBlock", 6)],
    "planDeposit": [("depositBps", 2), ("lastBlock", 6)],
    "cardPolicy": [("fromBlock", 6), ("lastBlock", 6)],
    "outbox": [("bookingId", 6), ("kind", 1), ("notBefore", 3), ("state", 1), ("attempts", 1), ("failure", 1), ("queuedBlock", 6), ("lastBlock", 6)],
    "mailAddress": [("sealedOffset", 6), ("sealedLength", 2), ("lang", 1), ("attachedBlock", 6), ("confirmation", 6), ("preArrival", 6), ("receipt", 6),
                    ("cancellation", 6), ("lastBlock", 6)],
    "mailSetup": [("mailKey", 65), ("mailerGrant", 6), ("authorised", 32), ("tested", 32), ("on", 1), ("lastBlock", 6)],
    "rules": [("epoch", 1), ("walkSections", 1), ("lastBlock", 6)],
    "grant": [("subject", 30), ("role", 1), ("active", 1), ("lastBlock", 6)],
    "ratePlan": [("code", 16), ("nameEn", 8), ("nameAr", 8), ("kind", 1), ("discountBps", 2), ("refundable", 1), ("freeCancelDaysBefore", 1),
                 ("penaltyNights", 1), ("guarantee", 1), ("modifiable", 1), ("active", 1), ("lastBlock", 6)],
    "proposal": [("maker", 30), ("permission", 1), ("proposedBlock", 6), ("expiresAt", 6), ("status", 1), ("checker", 30), ("resolvedBlock", 6),
                 ("commandHash", 32), ("act", 8)],
}
WIDTH = {t: sum(w for _, w in f) for t, f in LAYOUT.items()}
# the row widths the contract declares (src/Widths.mo); a layout that disagrees is a reader that would misread
DECLARED = {"roomType": 75, "room": 27, "night": 25, "hold": 141, "booking": 182, "folio": 25, "payment": 29, "housekeeping": 84,
            "charge": 65, "payer": 20, "lineRoute": 12, "paymentRoute": 12, "invoice": 83, "creditNote": 64, "creditLine": 18, "deskRefund": 30,
            "staffBooking": 40, "dayFigures": 81, "dayRevenue": 33, "refundSlice": 20, "proposal": 120,
            "company": 31, "planAccess": 13, "holdRate": 22, "bookingRate": 22, "promo": 57,
            "block": 44, "blockNight": 15, "nightBlock": 8, "bookingBlock": 12,
            "holdLine": 25, "extra": 49, "planInclusion": 23, "packageLine": 26, "holdPackage": 26,
            "cardOnFile": 38, "planDeposit": 8, "cardPolicy": 12, "ratePlan": 47,
            "outbox": 25, "mailAddress": 45, "mailSetup": 142, "grant": 38, "rules": 8}
IDS_ONLY = set()            # tables a law reads only the ids of: which rows exist
# THE RULES BY EPOCH, as the rules are stated, not as the contract's code says: the audit's
# walk spans 5 sections under the rules of the first released build and every one of the 31 from epoch 1; the
# laws added inside the first five sections (I1 counting rooms out of order by their dates and the rooms
# blocks hold; I11 a split bill's windows, I12 a booking's origin, I14 its rate's access and I16 a charge
# on file, read from the booking) hold from epoch 1.
SECTIONS_AT = [5, 31]
LAWS_FROM = 1
BYTES = {"code", "number", "owner", "account", "manageKey", "quoteHash", "key", "cleanedBy", "inspectedBy", "postedBy", "issuedBy",
         "maker", "checker", "commandHash", "madeBy", "subject", "mailKey", "authorised", "tested"}   # kept as bytes, not numbers

HOLDS_NIGHTS = {1, 2, 3}    # booking status: confirmed, checked in, checked out
CHECKED_IN, CHECKED_OUT = 2, 3
LIVE, CONFIRMED = 1, 2       # hold state
WALK_IN, GROUP = 2, 3       # a staff booking's channel
ACTIVE, OUT_OF_ORDER = 1, 2 # room status
DIRTY, CLEAN, INSPECTED = 1, 2, 3   # housekeeping cleaning
CREDIT, TAX, EXTRA, EXTRA_TAX = 4, 2, 6, 7   # folio kind
AUTHORISED, CAPTURED, REFUNDED, CHARGED_ON_FILE = 1, 2, 3, 5   # payment kind
MONEY_IN = (CAPTURED, CHARGED_ON_FILE)   # the kinds that take the guest's money: a capture, and a charge to the card on file
DUE, DONE, FAILED = 1, 2, 3  # payment state
EXECUTED = 2                # proposal status
ROOM_NIGHT, PENALTY = 1, 3  # folio kind: with EXTRA, what a credit note may take back
NOTE_CODE = 2               # a credit note's credit lines
MAX_REFERENCE = 64          # bytes of a desk refund's reference
DAY_SPAN = 1 << 24          # a night's id is room type × 2^24 + day; a block night's, block × 2^24 + day
COVERED = ["I1 capacity", "I2 counters", "I3 nights", "I4 money", "I5 cash", "I6 restrictions", "I8 rooms", "I10 housekeeping", "I11 bill", "I12 origin",
           "I13 figures", "I14 rates", "I15 blocks", "I16 card on file", "I17 mail", "I18 packages"]
CONFIRMATION, PRE_ARRIVAL, RECEIPT, CANCELLATION = 1, 2, 3, 4   # a message's kind
MAIL_DUE, MAIL_SENT, MAIL_FAILED, MAIL_SKIPPED = 1, 2, 3, 4      # a message's state
MAILER = 6                  # the relay's role
SEALED_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
CONFIRMED_B, CHECKED_OUT_B, CANCELLED, NO_SHOW = 1, 3, 4, 5   # booking status
WANTED, KEPT, CLOSED_CARD = 1, 2, 6   # a card on file's state
DEPOSIT = 3                 # a plan's guarantee
EVERY_NIGHT, ARRIVAL_NIGHT = 1, 2   # an inclusion's rhythm
BOOKED, IN_HOUSE = 1, 2      # booking status: the two whose package lines must sit on the stay
MAX_INCLUSIONS, MAX_INCLUSION_QUANTITY = 8, 9
# who posts a package's lines: the anonymous principal (its one byte 0x04), as a 30-byte principal field
PACKAGE_POSTER = bytes([1, 4]) + bytes(28)


def decode(table, raw):
    if table in IDS_ONLY:
        return {}
    if len(raw) != WIDTH[table]:
        raise ValueError(f"{table} row of {len(raw)} bytes, layout says {WIDTH[table]}")
    out, o = {}, 0
    for name, w in LAYOUT[table]:
        chunk = raw[o:o + w]
        out[name] = bytes(chunk) if name in BYTES else int.from_bytes(chunk, "big")
        o += w
    return out


# what each permission guards, by its place in the catalogue, as the battery exported it
PERMISSIONS = {}


def parse(lines):
    rows, counters, day, contract, done = collections.defaultdict(dict), {}, None, [], None
    PERMISSIONS.clear()
    for line in lines:
        if not line.startswith("export: "):
            continue
        parts = line[len("export: "):].rstrip("\n").split(" ")
        if parts[0] == "row":
            rows[parts[1]][int(parts[2])] = bytearray.fromhex(parts[3])
        elif parts[0] == "day":
            day = int(parts[1])
        elif parts[0] == "sealed":
            # an address's sealed text: kept beside the rows, under a name no table has
            rows["_sealed"][int(parts[1])] = bytearray(" ".join(parts[2:]).encode())
        elif parts[0] == "walk":
            # the audit's walk: the section it is at, and whether it is done
            rows["_walk"][0] = bytearray(" ".join(parts[1:3]).encode())
        elif parts[0] == "permission":
            PERMISSIONS[int(parts[1])] = parts[2] if len(parts) > 2 else ""
        elif parts[0] == "counter":
            counters[parts[1]] = int(parts[2])
        elif parts[0] == "oracle" and parts[1] == "done":
            done = int(parts[2])
        elif parts[0] == "oracle":
            contract.append(" ".join(parts[1:]).split(" | ")[0])
    return rows, counters, day, contract, done


def laws(raw_rows, counters, today):
    t = {name: {i: decode(name, b) for i, b in rows.items()} for name, rows in raw_rows.items() if not name.startswith("_")}
    sealed_text = {i: bytes(b).decode("utf-8", "replace") for i, b in raw_rows.get("_sealed", {}).items()}
    types, rooms, nights = t.get("roomType", {}), t.get("room", {}), t.get("night", {})
    holds, bookings, folio, payments = t.get("hold", {}), t.get("booking", {}), t.get("folio", {}), t.get("payment", {})
    hk = t.get("housekeeping", {})
    out = []
    # the rules the books are kept under: no row is epoch 0, whose walk spans SECTIONS_AT[0]
    rules = t.get("rules", {})
    epoch = rules[1]["epoch"] if 1 in rules else 0
    span = rules[1]["walkSections"] if 1 in rules else SECTIONS_AT[0]
    newer = epoch >= LAWS_FROM
    if any(rid != 1 for rid in rules) or (1 in rules and epoch == 0):
        out.append(("rules", f"rows {sorted(rules)} at epoch {epoch}: the rules are one row, written by the first adoption"))
    if epoch >= len(SECTIONS_AT):
        out.append(("rules", f"epoch {epoch} is past the rules defined ({len(SECTIONS_AT) - 1})"))
    elif span not in SECTIONS_AT[:epoch + 1]:
        out.append(("rules", f"the walk's span of {span} sections is no epoch's up to {epoch}"))
    walk = raw_rows.get("_walk", {}).get(0)
    if walk is not None:
        section, done = (int(x) for x in bytes(walk).decode().split())
        if (done and section != span) or (not done and section >= span):
            out.append(("rules", f"the walk is at section {section}, {'done' if done else 'under way'}, and spans {span}"))
    active = collections.Counter(r["roomTypeId"] for r in rooms.values() if r["status"] == ACTIVE)
    # a room out of order with dates is back in its type's count from the night `outUntil`
    back = collections.defaultdict(list)
    for rid, r in rooms.items():
        if r["status"] == OUT_OF_ORDER and rid in hk and hk[rid]["outUntil"] > 0:
            back[r["roomTypeId"]].append(hk[rid]["outUntil"])

    def rooms_on(rt, d):
        # epoch 0 counts the rooms active today, as the first released build did
        return active[rt] + sum(1 for u in back[rt] if u <= d) if newer else active[rt]
    sold, held = collections.Counter(), collections.Counter()
    for b in bookings.values():
        if b["status"] in HOLDS_NIGHTS:
            for d in range(b["arrival"], b["departure"]):
                sold[(b["roomTypeId"], d)] += b["rooms"]
    for h in holds.values():
        if h["state"] == LIVE:
            for d in range(h["arrival"], h["arrival"] + h["nights"]):
                held[(h["roomTypeId"], d)] += h["rooms"]
    night_block = t.get("nightBlock", {})
    for nid, n in nights.items():
        rt, d = divmod(nid, DAY_SPAN)
        blocked = night_block.get(nid, {"open": 0})["open"] if newer else 0
        if n["sold"] + n["held"] + blocked > n["allotment"]:
            out.append(("I1 capacity", f"type {rt} day {d}: sold + held + held by blocks over the allotment"))
        if n["allotment"] > rooms_on(rt, d) and d >= today:
            out.append(("I1 capacity", f"type {rt} day {d}: allotment over the rooms in service that night"))
        if n["sold"] != sold[(rt, d)]:
            out.append(("I2 counters", f"type {rt} day {d}: sold {n['sold']}, bookings {sold[(rt, d)]}"))
        if n["held"] != held[(rt, d)]:
            out.append(("I2 counters", f"type {rt} day {d}: held {n['held']}, live holds {held[(rt, d)]}"))
    lines_of, pays_of = collections.defaultdict(list), collections.defaultdict(list)
    lines_ids_of, pays_ids_of = collections.defaultdict(list), collections.defaultdict(list)
    for lid, l in folio.items():
        lines_of[l["bookingId"]].append(l); lines_ids_of[l["bookingId"]].append(lid)
    for pid, p in payments.items():
        pays_of[p["bookingId"]].append(p); pays_ids_of[p["bookingId"]].append((pid, p))
    paid_sum = 0
    for bid, b in bookings.items():
        if b["status"] in HOLDS_NIGHTS:
            for d in range(b["arrival"], b["departure"]):
                if b["roomTypeId"] * DAY_SPAN + d not in nights:
                    out.append(("I3 nights", f"booking {bid} holds day {d}, which has no row"))
        charged = sum(l["amount"] for l in lines_of[bid] if l["kind"] != CREDIT)
        credited = sum(l["amount"] for l in lines_of[bid] if l["kind"] == CREDIT)
        paid = sum(p["amount"] for p in pays_of[bid] if p["kind"] in MONEY_IN and p["state"] == DONE) \
            - sum(p["amount"] for p in pays_of[bid] if p["kind"] == REFUNDED)   # a refund is committed when it is written
        if charged != b["charged"] or credited != b["credited"] or paid != b["paid"]:
            out.append(("I4 money", f"booking {bid}: lines {charged}/{credited} and payments {paid} against {b['charged']}/{b['credited']}/{b['paid']}"))
        if b["charged"] != b["paid"] + b["credited"] + b["outstanding"]:
            out.append(("I4 money", f"booking {bid}: charged is not paid + credited + outstanding"))
        stay = b["departure"] - b["arrival"]
        if b["status"] != CHECKED_OUT and ((b["checkedMinStay"] and stay < b["checkedMinStay"]) or (b["checkedMaxStay"] and stay > b["checkedMaxStay"])):
            out.append(("I6 restrictions", f"booking {bid}: {stay} nights outside {b['checkedMinStay']}..{b['checkedMaxStay']}"))
        if b["status"] == CHECKED_IN:
            occupied = sum(1 for r in rooms.values() if r["occupiedBy"] == bid and r["roomTypeId"] == b["roomTypeId"])
            if occupied != b["rooms"]:
                out.append(("I8 rooms", f"booking {bid} occupies {occupied} rooms and booked {b['rooms']}"))
        paid_sum += b["paid"]
    for rid, r in rooms.items():
        if r["occupiedBy"]:
            b = bookings.get(r["occupiedBy"])
            if b is None or b["status"] != CHECKED_IN or b["roomTypeId"] != r["roomTypeId"]:
                out.append(("I8 rooms", f"room {rid} is held by booking {r['occupiedBy']}, not checked in to its type"))
    # I10: who vouches for a room, and dates that belong to a room out of order
    for rid, h in hk.items():
        cleaner, inspector = h["cleanedBy"], h["inspectedBy"]
        nobody = lambda p: p[0] == 0   # a principal field's length byte
        if rid not in rooms:
            out.append(("I10 housekeeping", f"room {rid} has a record and does not exist"))
        if h["cleaning"] == DIRTY and not (nobody(cleaner) and nobody(inspector)):
            out.append(("I10 housekeeping", f"room {rid} is dirty and names someone"))
        if h["cleaning"] == CLEAN and (nobody(cleaner) or not nobody(inspector)):
            out.append(("I10 housekeeping", f"room {rid} is clean without its cleaner or with an inspector"))
        if h["cleaning"] == INSPECTED and (nobody(cleaner) or nobody(inspector) or cleaner == inspector):
            out.append(("I10 housekeeping", f"room {rid} is inspected without two different people"))
        if h["outUntil"] > 0:
            if rid in rooms and rooms[rid]["status"] != OUT_OF_ORDER:
                out.append(("I10 housekeeping", f"room {rid} has dates out of order and is in service"))
            if h["outFrom"] >= h["outUntil"] or h["outReason"] & 0xFFFF == 0:
                out.append(("I10 housekeeping", f"room {rid} is out of order with dates or a reason that do not hold"))
    # I11: the bill. A line's or a payment's bill is its route, or the guest's (0).
    charges, payers = t.get("charge", {}), t.get("payer", {})
    lroute, proute, invoices = t.get("lineRoute", {}), t.get("paymentRoute", {}), t.get("invoice", {})
    lwin = lambda i: lroute[i]["payerId"] if i in lroute else 0
    pwin = lambda i: proute[i]["payerId"] if i in proute else 0
    on_booking = lambda bid, p: p == 0 or (p in payers and payers[p]["bookingId"] == bid)
    for lid, ch in charges.items():
        l = folio.get(lid)
        if l is None or l["kind"] != EXTRA or l["bookingId"] != ch["bookingId"] or l["amount"] != ch["quantity"] * ch["unitAmount"]:
            out.append(("I11 bill", f"charge {lid} is not its quantity times its price on its booking")); continue
        total = l["amount"]
        for tid in range(lid + 1, lid + ch["taxLines"] + 1):
            tl = folio.get(tid)
            if tl is None or tl["kind"] != EXTRA_TAX or tl["bookingId"] != ch["bookingId"] or tl["night"] != l["night"] or lwin(tid) != lwin(lid):
                out.append(("I11 bill", f"charge {lid}: line {tid} is not its tax on its bill"))
            else:
                total += tl["amount"]
        if ch["voidLine"]:
            v = folio.get(ch["voidLine"])
            if v is None or v["kind"] != CREDIT or v["bookingId"] != ch["bookingId"] or v["amount"] != total or lwin(ch["voidLine"]) != lwin(lid):
                out.append(("I11 bill", f"charge {lid} is voided by a line that is not a credit of {total} on its bill"))
    for lid, r in lroute.items():
        if lid not in folio or not on_booking(folio[lid]["bookingId"], r["payerId"]):
            out.append(("I11 bill", f"line {lid} is on a bill that is not its booking's"))
    for pid, r in proute.items():
        if pid not in payments or not on_booking(payments[pid]["bookingId"], r["payerId"]):
            out.append(("I11 bill", f"payment {pid} is on a bill that is not its booking's"))
    def window(bid, w):
        ch = cr = tx = 0
        for lid in lines_ids_of[bid]:
            if lwin(lid) == w:
                l = folio[lid]
                if l["kind"] == CREDIT: cr += l["amount"]
                else: ch += l["amount"]
                if l["kind"] in (TAX, EXTRA_TAX): tx += l["amount"]
        paid = sum(p["amount"] for pid, p in pays_ids_of[bid] if pwin(pid) == w and p["kind"] in MONEY_IN and p["state"] == DONE) \
            - sum(p["amount"] for pid, p in pays_ids_of[bid] if pwin(pid) == w and p["kind"] == REFUNDED)
        return ch, cr, tx, paid
    notes, clines, desks, proposals = t.get("creditNote", {}), t.get("creditLine", {}), t.get("deskRefund", {}), t.get("proposal", {})
    noted = collections.Counter()
    for cn in notes.values():
        noted[cn["invoice"]] += cn["total"]
    for n, inv in invoices.items():
        if n < 1 or n > len(invoices) or not on_booking(inv["bookingId"], inv["payerId"]):
            out.append(("I11 bill", f"invoice {n} is out of its run or for a payer not on its booking")); continue
        ch, cr, tx, _ = window(inv["bookingId"], inv["payerId"])
        if (ch, cr, tx) != (inv["charges"], inv["credits"] + noted[n], inv["taxes"]):
            out.append(("I11 bill", f"invoice {n} says {inv['charges']}/{inv['credits']}/{inv['taxes']} and its notes {noted[n]}, its bill is {ch}/{cr}/{tx}"))

    def approved(pid, guard):
        """Proposed by one person, executed on the word of another, under the permission that guards the act."""
        p = proposals.get(pid)
        if p is None or p["status"] != EXECUTED or p["checker"][0] == 0:
            return False
        return p["checker"] != p["maker"] and PERMISSIONS.get(p["permission"]) == guard

    taken = collections.Counter()
    for lid, c in clines.items():
        if lid in folio:
            taken[c["source"]] += folio[lid]["amount"]
    for src, amount in taken.items():
        if src in folio and amount > folio[src]["amount"]:
            out.append(("I11 bill", f"line {src} is {folio[src]['amount']} and credit notes took back {amount}"))
    for n, cn in notes.items():
        if n < 1 or n > len(notes):
            out.append(("I11 bill", f"credit note {n} is outside the run 1..{len(notes)}"))
        inv = invoices.get(cn["invoice"])
        if inv is None or (inv["bookingId"], inv["payerId"]) != (cn["bookingId"], cn["payerId"]):
            out.append(("I11 bill", f"credit note {n} is not against an invoice of its bill"))
        if cn["total"] != cn["net"] + cn["taxes"]:
            out.append(("I11 bill", f"credit note {n}: net and taxes do not make its total"))
        if not approved(cn["proposal"], "propose:issueCreditNote"):
            out.append(("I11 bill", f"credit note {n} lacks a second person's approval"))
        total = taxes = 0
        for lid in range(cn["firstLine"], cn["firstLine"] + cn["lines"]):
            l, c = folio.get(lid), clines.get(lid)
            if l is None or c is None or l["kind"] != CREDIT or l["code"] != bytes([NOTE_CODE]) or l["bookingId"] != cn["bookingId"] \
                    or lwin(lid) != cn["payerId"] or c["note"] != n:
                out.append(("I11 bill", f"credit note {n}: line {lid} is not a credit of this note on its bill")); continue
            total += l["amount"]
            src = folio.get(c["source"])
            if src is None or src["bookingId"] != cn["bookingId"] or src["kind"] not in (ROOM_NIGHT, PENALTY, EXTRA, TAX, EXTRA_TAX):
                out.append(("I11 bill", f"credit note {n}: line {lid} takes back something that is not a charge of its booking"))
            elif src["kind"] in (TAX, EXTRA_TAX):
                taxes += l["amount"]
        if cn["lines"] == 0 or (total, taxes) != (cn["total"], cn["taxes"]):
            out.append(("I11 bill", f"credit note {n}: its lines come to {total} with {taxes} of tax"))
    for pid, d in desks.items():
        p = payments.get(pid)
        if p is None or p["bookingId"] != d["bookingId"] or p["kind"] != REFUNDED or p["state"] != FAILED:
            out.append(("I11 bill", f"desk refund {pid} is not a failed refund of its booking"))
        if not 1 <= d["reference"] & 0xFFFF <= MAX_REFERENCE:
            out.append(("I11 bill", f"desk refund {pid} has no reference within {MAX_REFERENCE} bytes"))
        if not approved(d["proposal"], "propose:refundAtDesk"):
            out.append(("I11 bill", f"desk refund {pid} lacks a second person's approval"))
    for bid in ({p["bookingId"] for p in payers.values()} if newer else ()):
        for w in [0] + [pid for pid, p in payers.items() if p["bookingId"] == bid]:
            ch, cr, _, paid = window(bid, w)
            if paid > ch - cr:
                out.append(("I11 bill", f"booking {bid}: the bill of payer {w} is paid {paid} and owes {ch - cr}"))
    # I12: every booking came one way, from a hold it confirmed or taken by staff
    staff = t.get("staffBooking", {})
    for bid, b in (bookings.items() if newer else ()):
        if b["holdId"] == 0:
            if bid not in staff:
                out.append(("I12 origin", f"booking {bid} came from no hold and no member of staff"))
        elif bid in staff:
            out.append(("I12 origin", f"booking {bid} came from hold {b['holdId']} and from staff"))
        elif holds.get(b["holdId"], {}).get("state") != CONFIRMED:
            out.append(("I12 origin", f"booking {bid} came from hold {b['holdId']}, which is not confirmed"))
    for bid, x in staff.items():
        b = bookings.get(bid)
        if b is None or b["holdId"] != 0:
            out.append(("I12 origin", f"staff booking {bid} is not of a booking staff took"))
        elif x["channel"] == WALK_IN and b["arrival"] != x["day"]:
            out.append(("I12 origin", f"staff booking {bid} is a walk-in that arrived on another day"))
        if x["day"] > today:
            out.append(("I12 origin", f"staff booking {bid} was taken after today"))
    # I13: the night audit's figures
    figs, revs = t.get("dayFigures", {}), t.get("dayRevenue", {})
    per_day, seen_keys = collections.defaultdict(lambda: [0, 0]), {}
    for rid, r in sorted(revs.items()):
        at = f"revenue row {rid} (day {r['day']})"
        if r["day"] not in figs:
            out.append(("I13 figures", f"{at} is under a day with no figures"))
        if r["roomNights"] == 0:
            out.append(("I13 figures", f"{at} sells no room nights"))
        k = (r["day"], r["roomTypeId"], r["planId"])
        if k in seen_keys:
            out.append(("I13 figures", f"{at} repeats row {seen_keys[k]}"))
        seen_keys.setdefault(k, rid)
        per_day[r["day"]][0] += r["roomNights"]; per_day[r["day"]][1] += r["revenue"]
    last_booking = max(bookings) if bookings else 0
    for d, f in sorted(figs.items()):
        at = f"the figures of day {d}"
        if f["roomsSold"] + f["roomsOut"] > f["roomsTotal"]:
            out.append(("I13 figures", f"{at} sell {f['roomsSold']} rooms with {f['roomsOut']} out of order, of {f['roomsTotal']}"))
        if f["roomsTotal"] > len(rooms):
            out.append(("I13 figures", f"{at} count {f['roomsTotal']} rooms; the hotel has {len(rooms)}"))
        if f["arrivals"] > f["houseSeen"]:
            out.append(("I13 figures", f"{at} have more arrivals than guests in house"))
        if d > today:
            out.append(("I13 figures", f"{at} are for a day after today"))
        nights, revenue = per_day.get(d, [0, 0])
        if (nights, revenue) != (f["roomsSold"], f["roomRevenue"]):
            out.append(("I13 figures", f"{at} sell {f['roomsSold']} for {f['roomRevenue']}; the rows by type and plan say {nights} for {revenue}"))
        prev = figs.get(d - 1)
        if prev is not None and f["pickupFrom"] != prev["pickupFrom"] + prev["pickupCount"]:
            out.append(("I13 figures", f"{at} count pickup from booking {f['pickupFrom']}; the day before ended at {prev['pickupFrom'] + prev['pickupCount']}"))
        made = range(f["pickupFrom"], f["pickupFrom"] + f["pickupCount"])
        if f["pickupCount"] and made[-1] > last_booking:
            out.append(("I13 figures", f"{at} count pickup to booking {made[-1]}, which does not exist"))
        if d < today:
            for planned, seen, what in (("roomsTotal", "roomsSeen", "rooms"), ("inHouse", "houseSeen", "guests in house"), ("pickupCount", "pickupBookings", "bookings made")):
                if f[planned] != f[seen]:
                    out.append(("I13 figures", f"{at} looked at {f[seen]} of {f[planned]} {what}"))
            # recomputed from the bookings and their lines: the contract's oracle does not hold this one
            got_nights = sum(bookings[b]["rooms"] * (bookings[b]["departure"] - bookings[b]["arrival"]) for b in made if b in bookings)
            got_revenue = sum(l["amount"] for l in folio.values() if l["kind"] == ROOM_NIGHT and l["bookingId"] in made)
            if (got_nights, got_revenue) != (f["pickupNights"], f["pickupRevenue"]):
                out.append(("I13 figures", f"{at} book {f['pickupNights']} room nights for {f['pickupRevenue']}; its bookings hold {got_nights} for {got_revenue}"))
    # I14: who a rate is sold to
    access, companies = t.get("planAccess", {}), t.get("company", {})
    hold_rate, booking_rate, plans = t.get("holdRate", {}), t.get("bookingRate", {}), t.get("ratePlan", {})
    promos = t.get("promo", {})

    def grant(r):
        return (r["companyId"], r["promoId"]) if r else (0, 0)

    def admitted(a, g, plan_id):
        # a plan closed to a company admits that company; closed to everyone but codes, a promotion naming it
        if not a["closed"]:
            return True
        if a["companyId"]:
            return g[0] == a["companyId"]
        return g[1] != 0 and g[1] in promos and promos[g[1]]["planId"] == plan_id

    def under(g):
        return f"under company {g[0]}" if g[0] else (f"under promotion {g[1]}" if g[1] else "on public sale")
    for bid, b in (bookings.items() if newer else ()):
        g = grant(booking_rate.get(bid))
        a = access.get(b["planId"])
        if a and a["lastBlock"] < b["createdBlock"] and not admitted(a, g, b["planId"]):
            out.append(("I14 rates", f"booking {bid} is on plan {b['planId']}, closed before it was made, and was sold {under(g)}"))
        if b["holdId"] and grant(hold_rate.get(b["holdId"])) != g:
            out.append(("I14 rates", f"booking {bid} was sold {under(g)}; its hold {b['holdId']} was placed {under(grant(hold_rate.get(b['holdId'])))}"))
    for name, kept, rows_of in (("booking", booking_rate, bookings), ("hold", hold_rate, holds)):
        for i, r in sorted(kept.items()):
            at = f"the access of {name} {i}"
            if r["companyId"] == 0 and r["promoId"] == 0:
                out.append(("I14 rates", f"{at} keeps the public sale"))
            if r["companyId"] and r["companyId"] not in companies:
                out.append(("I14 rates", f"{at} names company {r['companyId']}, which does not exist"))
            if r["promoId"] and r["promoId"] not in promos:
                out.append(("I14 rates", f"{at} names promotion {r['promoId']}, which does not exist"))
            if r["companyId"] and r["promoId"]:
                out.append(("I14 rates", f"{at} names both a company and a promotion"))
            if name == "hold" and r["use"]:
                out.append(("I14 rates", f"{at} counts a use; a hold counts none"))
            row = rows_of.get(i)
            if row is None:
                out.append(("I14 rates", f"{at}: the {name} does not exist"))
            elif name == "booking" and r["lastBlock"] != row["createdBlock"]:
                out.append(("I14 rates", f"{at} was kept at block {r['lastBlock']}; the booking was made at {row['createdBlock']}"))
            elif name == "hold":
                if r["lastBlock"] > row["lastBlock"]:
                    out.append(("I14 rates", f"{at} was kept after the hold last changed"))
                a = access.get(row["planId"])
                if a and a["lastBlock"] < r["lastBlock"] and not admitted(a, grant(r), row["planId"]):
                    out.append(("I14 rates", f"{at} is on plan {row['planId']}, closed before it was placed, and was placed {under(grant(r))}"))
    # a promotion's uses, recomputed from every booking that names it: each use from 1 to the count, held by
    # one booking, with no gap below it; the count's own use held
    held = collections.defaultdict(list)
    for bid, r in sorted(booking_rate.items()):
        at = f"the access of booking {bid}"
        if not r["promoId"]:
            if r["use"]:
                out.append(("I14 rates", f"{at} counts use {r['use']} of no promotion"))
            continue
        held[(r["promoId"], r["use"])].append(bid)
        used = promos[r["promoId"]]["used"] if r["promoId"] in promos else 0
        if r["use"] == 0 or r["use"] > used:
            out.append(("I14 rates", f"{at} counts use {r['use']} of promotion {r['promoId']}, which has counted {used}"))
    for (prid, use), bids in sorted(held.items()):
        if len(bids) > 1:
            out.append(("I14 rates", f"use {use} of promotion {prid} is held by bookings {bids}"))
        if use > 1 and (prid, use - 1) not in held:
            out.append(("I14 rates", f"promotion {prid}'s use {use} is held with no use {use - 1}"))
    promo_first = {}
    company_codes = {bytes(co["code"]).rstrip(b"\0") for co in companies.values()}
    for prid, pr in sorted(promos.items()):
        at = f"promotion {prid}"
        code = bytes(pr["code"]).rstrip(b"\0")
        promo_first.setdefault(code, prid)
        if not code or any(not (0x41 <= x <= 0x5A or 0x30 <= x <= 0x39 or x == 0x2D) for x in code):
            out.append(("I14 rates", f"{at}'s code {code!r} is not capitals, digits and dashes"))
        if promo_first[code] != prid:
            out.append(("I14 rates", f"{at}'s code is promotion {promo_first[code]}'s"))
        if code in company_codes:
            out.append(("I14 rates", f"{at}'s code is a company's"))
        if pr["nameLength"] == 0:
            out.append(("I14 rates", f"{at} has no name"))
        if pr["planId"] not in plans:
            out.append(("I14 rates", f"{at} opens plan {pr['planId']}, which does not exist"))
        if pr["bookFrom"] > pr["bookUntil"] or pr["stayFrom"] > pr["stayUntil"]:
            out.append(("I14 rates", f"{at} has a window that ends before it begins"))
        if pr["maxUses"] and pr["used"] > pr["maxUses"]:
            out.append(("I14 rates", f"{at} was used {pr['used']} times, past its limit of {pr['maxUses']}"))
        if pr["used"] and (prid, pr["used"]) not in held:
            out.append(("I14 rates", f"{at} counts {pr['used']} uses; its last use is no booking's"))
    first_with = {}
    for cid, co in sorted(companies.items()):
        code = bytes(co["code"]).rstrip(b"\0")
        first_with.setdefault(code, cid)
        if not code or any(not (0x41 <= x <= 0x5A or 0x30 <= x <= 0x39 or x == 0x2D) for x in code):
            out.append(("I14 rates", f"company {cid}'s code {code!r} is not capitals, digits and dashes"))
        if first_with[code] != cid:
            out.append(("I14 rates", f"company {cid}'s code is company {first_with[code]}'s"))
        if co["nameLength"] == 0:
            out.append(("I14 rates", f"company {cid} has no name"))
    for pid, a in sorted(access.items()):
        at = f"the access of plan {pid}"
        if pid not in plans:
            out.append(("I14 rates", f"{at}: the plan does not exist"))
        if a["companyId"]:
            if not a["closed"]:
                out.append(("I14 rates", f"{at} names company {a['companyId']} and is open to everyone"))
            if a["companyId"] not in companies:
                out.append(("I14 rates", f"{at} names company {a['companyId']}, which does not exist"))
    # I15: group blocks. What each block night holds is recomputed from the block and the bookings on
    # its rooming list; what each hotel night holds for blocks, from the block nights on it.
    blocks, block_nights, pickups = t.get("block", {}), t.get("blockNight", {}), t.get("bookingBlock", {})
    picked = collections.Counter()
    for bid, p in pickups.items():
        b = bookings.get(bid)
        k = blocks.get(p["blockId"])
        at = f"the pickup of booking {bid}"
        if b is None:
            out.append(("I15 blocks", f"{at}: the booking does not exist")); continue
        if k is None:
            out.append(("I15 blocks", f"{at}: block {p['blockId']} does not exist")); continue
        if b["roomTypeId"] != k["roomTypeId"] or b["planId"] != k["planId"]:
            out.append(("I15 blocks", f"{at} is not block {p['blockId']}'s room type and plan"))
        if b["arrival"] < k["arrival"] or b["departure"] > k["departure"]:
            out.append(("I15 blocks", f"{at} runs outside block {p['blockId']}'s dates"))
        x = staff.get(bid)
        if x is None:
            out.append(("I15 blocks", f"{at} was not taken by staff"))
        elif x["channel"] != GROUP:
            out.append(("I15 blocks", f"{at} was taken on channel {x['channel']}, not from the group's list"))
        if b["status"] in HOLDS_NIGHTS:
            for d in range(b["arrival"], b["departure"]):
                picked[(p["blockId"], d)] += b["rooms"]
    for bid, x in staff.items():
        if x["channel"] == GROUP and bid not in pickups:
            out.append(("I15 blocks", f"booking {bid} was taken from a group's list and picked up from no block"))
    held_by = collections.Counter()
    for kid, k in sorted(blocks.items()):
        at = f"block {kid}"
        if k["roomTypeId"] not in types:
            out.append(("I15 blocks", f"{at} is of room type {k['roomTypeId']}, which does not exist"))
        if k["planId"] not in plans:
            out.append(("I15 blocks", f"{at} is sold at plan {k['planId']}, which does not exist"))
        if k["companyId"] and k["companyId"] not in companies:
            out.append(("I15 blocks", f"{at} names company {k['companyId']}, which does not exist"))
        if k["departure"] <= k["arrival"] or k["rooms"] == 0:
            out.append(("I15 blocks", f"{at} holds no room night"))
        if k["cutoff"] > k["arrival"]:
            out.append(("I15 blocks", f"{at}'s cut-off is after its arrival"))
        for d in range(k["arrival"], k["departure"]):
            bn = block_nights.get(kid * DAY_SPAN + d)
            on = f"{at}, day {d}"
            if bn is None:
                out.append(("I15 blocks", f"{on} has no row")); continue
            if bn["night"] != k["roomTypeId"] * DAY_SPAN + d:
                out.append(("I15 blocks", f"{on} is on another hotel night"))
            if bn["picked"] != picked[(kid, d)]:
                out.append(("I15 blocks", f"{on}: picked up says {bn['picked']}, its bookings hold {picked[(kid, d)]}"))
            if bn["picked"] > k["rooms"]:
                out.append(("I15 blocks", f"{on}: {bn['picked']} rooms picked up of {k['rooms']}"))
            want = k["rooms"] - bn["picked"] if k["open"] and k["rooms"] >= bn["picked"] else 0
            if bn["open"] != want:
                out.append(("I15 blocks", f"{on} still holds {bn['open']} rooms; it should hold {want}"))
    for bnid, bn in block_nights.items():
        held_by[bn["night"]] += bn["open"]
    for nid in set(night_block) | set(held_by):
        if night_block.get(nid, {"open": 0})["open"] != held_by[nid]:
            rt, d = divmod(nid, DAY_SPAN)
            out.append(("I15 blocks", f"type {rt} day {d}: held by blocks says {night_block.get(nid, {'open': 0})['open']}, its blocks hold {held_by[nid]}"))
    # I18: packages. Each package line is checked against its folio line and its charge; then the live
    # lines of each booking that holds its nights are laid out as the nights each inclusion is on, and
    # every inclusion's nights must be one unbroken run (every night) or the arrival alone (arrival night),
    # inside the stay, with no night twice.
    charges, plines = t.get("charge", {}), t.get("packageLine", {})
    live_nights = collections.defaultdict(list)   # (booking, slot) -> the nights its live lines are on
    for lid, pk in sorted(plines.items()):
        at = f"package line {lid}"
        l, ch = folio.get(lid), charges.get(lid)
        if l is None or ch is None:
            out.append(("I18 packages", f"{at}: its line or its charge does not exist")); continue
        if l["kind"] != EXTRA or ch["bookingId"] != l["bookingId"]:
            out.append(("I18 packages", f"{at} is not an extra of its booking"))
        if ch["postedBy"] != PACKAGE_POSTER:
            out.append(("I18 packages", f"{at} was posted by a member of staff"))
        if [ch[k] for k in ("extraId", "quantity", "unitAmount", "taxLines")] != [pk[k] for k in ("extraId", "quantity", "unitAmount", "taxLines")]:
            out.append(("I18 packages", f"{at}: its charge is not the inclusion sold"))
        if not pk["taxed"] and pk["taxLines"]:
            out.append(("I18 packages", f"{at} is taxed, and its extra was not"))
        if ch["voidLine"] == 0:
            if l["bookingId"] not in bookings:
                out.append(("I18 packages", f"{at}: booking {l['bookingId']} does not exist"))
            else:
                live_nights[(l["bookingId"], pk["slot"])].append((l["night"], lid, pk["rhythm"], l["kind"] == EXTRA))
    for (bid, slot), on in sorted(live_nights.items()):
        b = bookings[bid]
        if b["status"] not in (BOOKED, IN_HOUSE):
            continue
        # the run an inclusion makes is read from its extra lines alone: a line of another kind is named
        # by the clauses above, and is not a night of the package
        count = collections.Counter(n for n, _, _, extra in on if extra)
        for night, lid, rhythm, _ in on:
            at = f"package line {lid}"
            if not b["arrival"] <= night < b["departure"]:
                out.append(("I18 packages", f"{at} is on night {night}, outside booking {bid}'s stay"))
            if rhythm == ARRIVAL_NIGHT and night != b["arrival"]:
                out.append(("I18 packages", f"{at} is an arrival-night inclusion on night {night}"))
            if count[night] > 1:
                out.append(("I18 packages", f"{at}: inclusion {slot} is on night {night} twice"))
            if rhythm == EVERY_NIGHT:
                if night > b["arrival"] and count[night - 1] == 0:
                    out.append(("I18 packages", f"{at}: inclusion {slot} is on night {night} and not the night before"))
                if night + 1 < b["departure"] and count[night + 1] == 0:
                    out.append(("I18 packages", f"{at}: inclusion {slot} is on night {night} and not the night after"))
    hold_lines = t.get("holdLine", {})
    for hid, pk in sorted(t.get("holdPackage", {}).items()):
        at = f"hold package line {hid}"
        l = hold_lines.get(hid)
        if l is None:
            out.append(("I18 packages", f"{at}: the hold line does not exist")); continue
        if l["kind"] != EXTRA or l["bookingId"] not in holds:
            out.append(("I18 packages", f"{at} is not an extra of a hold"))
        if l["amount"] != pk["quantity"] * pk["unitAmount"]:
            out.append(("I18 packages", f"{at} is {l['amount']}, and {pk['quantity']} × {pk['unitAmount']} is {pk['quantity'] * pk['unitAmount']}"))
        if not pk["taxed"] and pk["taxLines"]:
            out.append(("I18 packages", f"{at} is taxed, and its extra was not"))
        for tid in range(hid + 1, hid + pk["taxLines"] + 1):
            tl = hold_lines.get(tid)
            if tl is None:
                out.append(("I18 packages", f"{at}: its tax line {tid} does not exist"))
            elif tl["kind"] != EXTRA_TAX or tl["bookingId"] != l["bookingId"] or tl["night"] != l["night"]:
                out.append(("I18 packages", f"{at}: line {tid} is not its tax"))
    extras, plan_ids = t.get("extra", {}), set(t.get("ratePlan", {}))
    for iid, inc in sorted(t.get("planInclusion", {}).items()):
        plan, slot = divmod(iid, 16)
        at = f"inclusion {slot} of plan {plan}"
        if inc["planId"] != plan or not 1 <= slot <= MAX_INCLUSIONS:
            out.append(("I18 packages", f"{at} is under the wrong plan or slot"))
        if inc["on"]:
            if inc["planId"] not in plan_ids:
                out.append(("I18 packages", f"{at}: the plan does not exist"))
            if inc["extraId"] not in extras:
                out.append(("I18 packages", f"{at}: extra {inc['extraId']} does not exist"))
            if not 1 <= inc["quantity"] <= MAX_INCLUSION_QUANTITY:
                out.append(("I18 packages", f"{at} gives {inc['quantity']} of its extra"))
    # I16: the card on file. A card the guest put on file is the gateway's token on a payment the guest
    # made, agreed before anything was charged to it; it is charged once, for a no-show alone, never past
    # the penalty less what the guarantee captured; a charge is the card's own; a card is let go once its
    # booking is settled. A card the desk is still waiting for belongs to a booking still to arrive. A
    # deposit plan has its share, a whole percentage from 1% to 99%.
    cards = t.get("cardOnFile", {})
    for bid, ps in (pays_ids_of.items() if newer else ()):
        for pid, p in ps:
            if p["kind"] == CHARGED_ON_FILE:
                k = cards.get(bid)
                if k is None:
                    out.append(("I16 card on file", f"booking {bid}: charge on file {pid} has no card behind it"))
                elif k["chargeId"] != pid:
                    out.append(("I16 card on file", f"booking {bid}: charge on file {pid} is not the one its card names ({k['chargeId']})"))
    for bid, k in sorted(cards.items()):
        at = f"booking {bid}'s card"
        b = bookings.get(bid)
        if b is None:
            out.append(("I16 card on file", f"{at}: no such booking")); continue
        ch = payments.get(k["chargeId"]) if k["chargeId"] else None
        owing = ch is not None and ch["state"] == DUE
        if k["state"] in (WANTED, CLOSED_CARD):
            if k["token"] or k["chargeId"]:
                out.append(("I16 card on file", f"{at} was never put on file, and holds token {k['token']} or charge {k['chargeId']}"))
            if k["state"] == WANTED and b["status"] != CONFIRMED_B:
                out.append(("I16 card on file", f"{at} is awaited, and the booking's status is {b['status']}"))
        else:
            if not k["token"] or not k["agreedBlock"]:
                out.append(("I16 card on file", f"{at} is on file without a token or without the guest's agreement"))
            if not any(p["kind"] == AUTHORISED and k["firstAuth"] and p["gatewayAuth"] == k["firstAuth"] for _, p in pays_ids_of[bid]):
                out.append(("I16 card on file", f"{at}: authorisation {k['firstAuth']} is no payment the guest made on this booking"))
            settled = b["status"] in (CHECKED_OUT_B, CANCELLED) or (b["status"] == NO_SHOW and not owing)
            if k["state"] == KEPT and settled:
                out.append(("I16 card on file", f"{at} is still on file after its booking settled"))
            if k["state"] != KEPT and owing:
                out.append(("I16 card on file", f"{at} was let go while its charge is owed"))
        if ch is not None:
            if ch["kind"] != CHARGED_ON_FILE or ch["bookingId"] != bid:
                out.append(("I16 card on file", f"{at}: payment {k['chargeId']} is no charge on file of this booking"))
            if b["status"] != NO_SHOW:
                out.append(("I16 card on file", f"{at} was charged, and its guest is no no-show"))
            if ch["block"] <= k["agreedBlock"]:
                out.append(("I16 card on file", f"{at} was charged in block {ch['block']}, before or as the guest agreed ({k['agreedBlock']})"))
            on_guarantee = sum(p["amount"] for _, p in pays_ids_of[bid] if p["kind"] == CAPTURED and p["state"] != FAILED)
            if ch["amount"] + on_guarantee > b["penalty"]:
                out.append(("I16 card on file", f"{at} took {ch['amount']} and the guarantee {on_guarantee}: more than the penalty {b['penalty']}"))
            if k["declinedDay"] and ch["state"] != FAILED:
                out.append(("I16 card on file", f"{at} is shown as declined, and its charge's state is {ch['state']}"))
        else:
            if k["chargeId"]:
                out.append(("I16 card on file", f"{at} names charge {k['chargeId']}, and there is none"))
            if k["declinedDay"]:
                out.append(("I16 card on file", f"{at} is shown as declined, and was never charged"))
    deposits = t.get("planDeposit", {})
    for pid, plan in sorted(t.get("ratePlan", {}).items()):
        if plan["guarantee"] == DEPOSIT and not deposits.get(pid, {"depositBps": 0})["depositBps"]:
            out.append(("I16 card on file", f"plan {pid} is guaranteed by a deposit of no share"))
    for pid, d in sorted(deposits.items()):
        if pid not in t.get("ratePlan", {}):
            out.append(("I16 card on file", f"the deposit of plan {pid}: no such plan"))
        bps = d["depositBps"]
        if bps and not (100 <= bps <= 9_900 and bps % 100 == 0):
            out.append(("I16 card on file", f"the deposit of plan {pid} is {bps} basis points, not 1% to 99% in whole percents"))
    # I17: the mail. Every message owed is read against its booking and the address that owes it; every
    # address against its messages; guest email's one setup row against its relay's grant.
    outbox, addresses = t.get("outbox", {}), t.get("mailAddress", {})
    slot_of = {CONFIRMATION: "confirmation", PRE_ARRIVAL: "preArrival", RECEIPT: "receipt", CANCELLATION: "cancellation"}
    for oid, o in sorted(outbox.items()):
        at = f"message {oid} to booking {o['bookingId']}"
        b, a = bookings.get(o["bookingId"]), addresses.get(o["bookingId"])
        if b is None:
            out.append(("I17 mail", f"{at}: no such booking"))
        elif a is None:
            out.append(("I17 mail", f"{at}: the booking has no address to send it to"))
        else:
            if a[slot_of[o["kind"]]] != oid:
                out.append(("I17 mail", f"{at}: the address owes message {a[slot_of[o['kind']]]} of that kind, not this one"))
            if o["kind"] == RECEIPT and b["status"] != CHECKED_OUT_B:
                out.append(("I17 mail", f"{at} is a receipt for a booking whose status is {b['status']}"))
            if o["kind"] == CANCELLATION and b["status"] != CANCELLED:
                out.append(("I17 mail", f"{at} is a cancellation notice for a booking whose status is {b['status']}"))
            if o["kind"] == PRE_ARRIVAL:
                if o["state"] == MAIL_DUE and b["status"] != CONFIRMED_B:
                    out.append(("I17 mail", f"{at} waits to go before an arrival, and the booking's status is {b['status']}"))
                if not 0 < o["notBefore"] < b["arrival"]:
                    out.append(("I17 mail", f"{at} goes on day {o['notBefore']}, not before the arrival on day {b['arrival']}"))
        if o["kind"] != PRE_ARRIVAL and o["notBefore"]:
            out.append(("I17 mail", f"{at} waits for day {o['notBefore']}, and only the note before arrival waits"))
        if o["attempts"] > 3:
            out.append(("I17 mail", f"{at} was tried {o['attempts']} times"))
        if o["state"] == MAIL_SENT and (o["attempts"] == 0 or o["failure"]):
            out.append(("I17 mail", f"{at} is sent after {o['attempts']} tries with failure code {o['failure']}"))
        if o["state"] == MAIL_FAILED and (o["attempts"] != 3 or not o["failure"]):
            out.append(("I17 mail", f"{at} is given up after {o['attempts']} tries with failure code {o['failure']}"))
        if o["state"] == MAIL_DUE and o["attempts"] >= 3:
            out.append(("I17 mail", f"{at} is still to send after {o['attempts']} tries"))
        if o["state"] == MAIL_DUE and (o["attempts"] == 0) != (o["failure"] == 0):
            out.append(("I17 mail", f"{at} is to send after {o['attempts']} tries with failure code {o['failure']}"))
        if not 0 < o["queuedBlock"] <= o["lastBlock"]:
            out.append(("I17 mail", f"{at} was owed in block {o['queuedBlock']} and last written in block {o['lastBlock']}"))
    for bid, a in sorted(addresses.items()):
        at = f"booking {bid}'s address"
        text = sealed_text.get(bid, "")
        body = text[len("lxe1."):]
        if not (text.startswith("lxe1.") and 133 <= len(text.encode()) <= 512 and set(body) <= SEALED_CHARS):
            out.append(("I17 mail", f"{at} is not a sealed address"))
        for kind, slot in slot_of.items():
            mid = a[slot]
            if mid == 0:
                continue
            o = outbox.get(mid)
            if o is None:
                out.append(("I17 mail", f"{at} owes message {mid}, and there is none"))
            elif o["bookingId"] != bid or o["kind"] != kind:
                out.append(("I17 mail", f"{at} owes message {mid} as its {slot}, and that message is not one"))
        if a["confirmation"] == 0:
            out.append(("I17 mail", f"{at} was never owed a confirmation"))
        b = bookings.get(bid)
        if b is None:
            out.append(("I17 mail", f"{at}: no such booking"))
        else:
            if b["status"] == CANCELLED and a["cancellation"] == 0:
                out.append(("I17 mail", f"{at}: the booking is cancelled and owed no notice of it"))
            if b["status"] == CHECKED_OUT_B and a["receipt"] == 0:
                out.append(("I17 mail", f"{at}: the stay is checked out and owed no receipt"))
    for _, m in sorted(t.get("mailSetup", {}).items()):
        connected = any(m["mailKey"])
        none = bytes(32)
        if connected and m["mailKey"][0] != 4:
            out.append(("I17 mail", "the relay's mail key is no uncompressed P-256 point"))
        if m["on"] and not connected:
            out.append(("I17 mail", "guest email is on, and no relay is connected"))
        if m["on"] and (m["authorised"] == none or m["tested"] != m["authorised"]):
            out.append(("I17 mail", "guest email is on, and the relay never tested the account authorised"))
        if m["tested"] != none and m["tested"] != m["authorised"]:
            out.append(("I17 mail", "the relay tested an account the owner did not authorise"))
        if connected:
            g = t.get("grant", {}).get(m["mailerGrant"])
            if g is None:
                out.append(("I17 mail", f"the relay's grant {m['mailerGrant']} is not on the roster"))
            elif not g["active"] or g["role"] != MAILER:
                out.append(("I17 mail", f"the relay's grant {m['mailerGrant']} is not an active mailer's"))
    # I5, a refund to a guest across the guest's own cards. The split is recomputed here from the
    # payments as they stood at the block that wrote it, and compared with the slices written.
    routes = t.get("paymentRoute", {})
    groups = collections.defaultdict(list)
    for sid, r in t.get("refundSlice", {}).items():
        groups[r["firstSlice"]].append((sid, r))
    for first, members in sorted(groups.items()):
        members.sort()
        at = f"the refund written from payment {first}"
        written, excess = members[0][1]["written"], members[0][1]["excess"]
        if any(r["written"] != written or r["excess"] != excess for _, r in members):
            out.append(("I5 cash", f"{at}: its slices disagree on the settle that wrote them"))
        slices = [(sid, payments.get(sid)) for sid, _ in members]
        if any(p is None or p["kind"] != REFUNDED for _, p in slices):
            out.append(("I5 cash", f"{at}: a slice is not a refund")); continue
        if sum(p["amount"] for _, p in slices) != excess:
            out.append(("I5 cash", f"{at}: its slices come to {sum(p['amount'] for _, p in slices)}, not the {excess} it gave back"))
        bid = slices[0][1]["bookingId"]
        captured, given, newest, refused = collections.Counter(), collections.Counter(), {}, set()
        for pid, p in pays_ids_of[bid]:
            if p["gatewayAuth"] == 0 or routes.get(pid, {"payerId": 0})["payerId"] != 0:
                continue
            a = p["gatewayAuth"]
            if p["kind"] in MONEY_IN and p["state"] == DONE and p["block"] <= written:
                captured[a] += p["amount"]; newest[a] = max(newest.get(a, 0), pid)
            elif p["kind"] == REFUNDED and pid < first:
                if p["state"] == FAILED and p["block"] <= written:
                    refused.add(a)
                else:
                    given[a] += p["amount"]
        expected, rest = [], excess
        for a in sorted((a for a in captured if a not in refused and captured[a] > given[a]), key=lambda a: -newest[a]):
            if rest:
                take = min(rest, captured[a] - given[a]); expected.append((a, take)); rest -= take
        if rest:
            expected.append((0, rest))
        actual = [(p["gatewayAuth"], p["amount"]) for _, p in slices]
        if actual != expected:
            out.append(("I5 cash", f"{at} went {actual}; the guest's cards as they stood call for {expected}"))
        for sid, p in slices:
            if p["gatewayAuth"] == 0 and p["state"] != FAILED:
                out.append(("I5 cash", f"{at}: payment {sid} is paid at the desk and still with the gateway"))
    # and no card, at any time, has given back more than it captured
    by_card_cap, by_card_back = collections.Counter(), collections.Counter()
    for p in payments.values():
        if p["gatewayAuth"]:
            k = (p["bookingId"], p["gatewayAuth"])
            if p["kind"] in MONEY_IN and p["state"] == DONE:
                by_card_cap[k] += p["amount"]
            elif p["kind"] == REFUNDED and p["state"] != FAILED:
                by_card_back[k] += p["amount"]
    for k, back in sorted(by_card_back.items()):
        if back > by_card_cap[k]:
            out.append(("I5 cash", f"card {k[1]} of booking {k[0]} gave back {back} of the {by_card_cap[k]} it captured"))
    # I5 from the payments themselves: what bookings hold as paid is what was captured less what was refunded
    captured = sum(p["amount"] for p in payments.values() if p["kind"] in MONEY_IN and p["state"] == DONE)
    refunded = sum(p["amount"] for p in payments.values() if p["kind"] == REFUNDED)
    if paid_sum != captured - refunded:
        out.append(("I5 cash", f"bookings hold {paid_sum} as paid; the payments say {captured} - {refunded}"))
    if counters and (counters["paidTotal"] != paid_sum or counters["capturedDone"] != captured or counters["refundsCommitted"] != refunded):
        out.append(("I5 cash", f"the fold's counters {counters} disagree with the payments ({paid_sum}, {captured}, {refunded})"))
    return out, {k: len(v) for k, v in t.items()}


def verdict(path):
    rows, counters, day, contract, done = parse(open(path))
    fail = 0
    for table, w in WIDTH.items():
        if w != DECLARED[table]:
            print(f"LAYOUT WRONG: {table} adds up to {w} bytes, the contract declares {DECLARED[table]}"); fail += 1
    if not rows or day is None or done is None:
        print("NOTHING TO READ: the log has no export (rows, day and the contract's verdict are all required)"); return 1
    found, counts = laws(rows, counters, day)
    for table, n in sorted(counts.items()):
        print(f"count: {table} rows decoded = {n}")
    r = {i: decode("rules", b) for i, b in rows.get("rules", {}).items()}
    walk = bytes(rows.get("_walk", {}).get(0, b"")).decode() or "not exported"
    print(f"rules: epoch {r[1]['epoch'] if 1 in r else 0}, the walk spans {r[1]['walkSections'] if 1 in r else SECTIONS_AT[0]} sections; the walk (section, done) {walk}")
    if 0 not in rows.get("_walk", {}):
        print("FAILED: the export has no walk to hold against its span"); fail += 1
    mine = collections.Counter(r for r, _ in found)
    theirs = collections.Counter(r for r in contract if r in COVERED)
    print(f"count: laws recomputed = {len(COVERED)}")
    print(f"count: violations found by the twin = {sum(mine.values())}")
    print(f"count: violations found by the contract (laws the twin covers) = {sum(theirs.values())}")
    print("not recomputed: I7 indexes (index structures are not in the export), I9 waitlist (it is the reservation engine)")
    if sum(counts.values()) == 0:
        print("FAILED: no rows were decoded"); fail += 1
    if mine != theirs:
        print(f"DISAGREE: twin {dict(mine)}, contract {dict(theirs)}"); fail += 1
        for r, d in found[:10]:
            print(f"  twin: {r}: {d}")
    if fail:
        print("TWIN FAILED"); return 1
    print("TWIN GREEN")
    return 0


def poke(rows, table, field, delta, pick=lambda rid, row: True):
    """Add `delta` to one field of the first row of `table` that `pick` accepts, in the bytes."""
    o = 0
    for name, w in LAYOUT[table]:
        if name == field:
            break
        o += w
    for rid, raw in sorted(rows[table].items()):
        if pick(rid, decode(table, raw)):
            v = int.from_bytes(raw[o:o + w], "big") + delta
            raw[o:o + w] = v.to_bytes(w, "big")
            return True
    return False


def stretched(rows):
    """A booking made to hold nights again and stretched 400 days past any night row: the battery ends
    with every booking cancelled or a no-show, so the status is set as well as the departure."""
    for rid, raw in sorted(rows["booking"].items()):
        b = decode("booking", raw)
        return poke(rows, "booking", "status", 1 - b["status"], lambda i, x: i == rid) and \
            poke(rows, "booking", "departure", 400, lambda i, x: i == rid)
    return False


def field_at(table, field):
    o = 0
    for name, w in LAYOUT[table]:
        if name == field:
            return o, w
        o += w
    raise KeyError(field)


def self_inspected(rows):
    """An inspected room whose inspector is made its cleaner, in the bytes."""
    c, w = field_at("housekeeping", "cleanedBy")
    i, _ = field_at("housekeeping", "inspectedBy")
    for rid, raw in sorted(rows.get("housekeeping", {}).items()):
        if decode("housekeeping", raw)["cleaning"] == INSPECTED:
            raw[i:i + w] = raw[c:c + w]
            return True
    return False


def dated(rows):
    return {rid for rid, raw in rows.get("housekeeping", {}).items() if decode("housekeeping", raw)["outUntil"] > 0}


def dates_dropped(rows):
    """A room out of order with dates loses them, so it is out with no end."""
    d = dated(rows)
    return bool(d) and poke(rows, "housekeeping", "outUntil", -decode("housekeeping", rows["housekeeping"][min(d)])["outUntil"], lambda i, x: i == min(d))


def record_moved(rows):
    """A housekeeping record moved to a room id nobody has."""
    hk = rows.get("housekeeping", {})
    if not hk:
        return False
    rid = min(hk)
    hk[max(rows["room"]) + 1000] = hk.pop(rid)
    return True


def payment_moved_to_guest(rows):
    """A payer's captured payment routed back to the guest's bill (0), which is then paid twice."""
    for pid, raw in sorted(rows.get("paymentRoute", {}).items()):
        r = decode("paymentRoute", raw)
        p = rows["payment"].get(pid)
        if r["payerId"] and p is not None and decode("payment", p)["kind"] == CAPTURED and decode("payment", p)["state"] == DONE:
            return poke(rows, "paymentRoute", "payerId", -r["payerId"], lambda i, x: i == pid)
    return False


def noted_invoices(rows):
    return {decode("creditNote", b)["invoice"] for b in rows.get("creditNote", {}).values()}


def shrunk_source(rows):
    """A room night a credit note took back whole made one unit smaller than what was taken back."""
    for lid, raw in sorted(rows.get("creditLine", {}).items()):
        src = decode("creditLine", raw)["source"]
        if src in rows["folio"] and decode("folio", rows["folio"][src])["kind"] == ROOM_NIGHT:
            return poke(rows, "folio", "amount", -1, lambda i, x: i == src)
    return False


def self_approved(rows, table):
    """The proposal behind the first row of `table` approved by its own maker, in the bytes."""
    if not rows.get(table):
        return False
    pid = decode(table, rows[table][min(rows[table])])["proposal"]
    raw = rows["proposal"].get(pid)
    if raw is None:
        return False
    m, w = field_at("proposal", "maker")
    c, _ = field_at("proposal", "checker")
    raw[c:c + w] = raw[m:m + w]
    return True


def reference_dropped(rows):
    """The first desk refund's reference cut to no bytes (a reference is an offset and, in its low two
    bytes, a length)."""
    desks = rows.get("deskRefund", {})
    if not desks:
        return False
    rid = min(desks)
    return poke(rows, "deskRefund", "reference", -(decode("deskRefund", desks[rid])["reference"] & 0xFFFF), lambda i, x: i == rid)


def note_renumbered(rows):
    """The last credit note moved to a number past the run, leaving a gap below it."""
    notes = rows.get("creditNote", {})
    if not notes:
        return False
    notes[max(notes) + 2] = notes.pop(max(notes))
    return True


def from_nowhere(rows):
    """The first booking that came from a hold, with its hold taken away."""
    first = next((decode("booking", r)["holdId"] for _, r in sorted(rows["booking"].items()) if decode("booking", r)["holdId"] != 0), None)
    return first is not None and poke(rows, "booking", "holdId", -first, lambda i, b: b["holdId"] == first)


def staffed_twice(rows):
    """A staff booking's row copied onto a booking that came from a hold."""
    staff = rows.get("staffBooking", {})
    hold_booking = next((i for i, r in sorted(rows["booking"].items()) if decode("booking", r)["holdId"] != 0), None)
    if not staff or hold_booking is None:
        return False
    staff[hold_booking] = bytearray(next(iter(staff.values())))
    return True


def unconfirmed_hold(rows):
    """The hold a booking came from, put back to live."""
    used = {decode("booking", r)["holdId"] for r in rows["booking"].values()} - {0}
    return poke(rows, "hold", "state", LIVE - CONFIRMED, lambda i, h: i in used and h["state"] == CONFIRMED)


def slice_moved(rows):
    """A refund's first slice put on the card its second slice was drawn from: the order the cards
    stood in is not the order they were drawn."""
    groups = collections.defaultdict(list)
    for sid, r in sorted(decode_rows(rows, "refundSlice").items()):
        groups[r["firstSlice"]].append(sid)
    two = next((g for g in groups.values() if len(g) >= 2), None)
    if two is None:
        return False
    a, b = decode("payment", rows["payment"][two[0]])["gatewayAuth"], decode("payment", rows["payment"][two[1]])["gatewayAuth"]
    return poke(rows, "payment", "gatewayAuth", b - a, lambda i, p: i == two[0])


def desk_slice_held(rows):
    """A card slice still due, moved to the desk."""
    due = [i for i in rows.get("refundSlice", {}) if decode("payment", rows["payment"][i])["state"] != FAILED]
    if not due:
        return False
    auth = decode("payment", rows["payment"][due[0]])["gatewayAuth"]
    return poke(rows, "payment", "gatewayAuth", -auth, lambda i, p: i == due[0])


def closed_plan(rows):
    return next((i for i, a in sorted(decode_rows(rows, "planAccess").items()) if a["closed"] and a["companyId"]), None)


def public_on_closed(rows):
    """A booking sold on public sale, made after a plan was closed to a company, moved onto that plan."""
    p = closed_plan(rows)
    if p is None:
        return False
    closed_at = decode("planAccess", rows["planAccess"][p])["lastBlock"]
    kept = rows.get("bookingRate", {})
    return any(
        poke(rows, "booking", "planId", p - b["planId"], lambda j, x, i=i: j == i)
        for i, b in sorted(decode_rows(rows, "booking").items()) if i not in kept and b["createdBlock"] > closed_at and b["planId"] != p)


def from_hold_regranted(rows):
    """The access of a hold a booking came from, moved to the next company."""
    used = {decode("booking", r)["holdId"] for r in rows["booking"].values()} - {0}
    return poke(rows, "holdRate", "companyId", 1, lambda i, r: i in used)


def code_lowered(rows):
    """A company's code put in small letters."""
    for _, raw in sorted(rows.get("company", {}).items()):
        if 0x41 <= raw[0] <= 0x5A:
            raw[0] += 0x20
            return True
    return False


def code_shared(rows):
    """A company added under the first company's code."""
    cos = rows.get("company", {})
    if not cos:
        return False
    cos[max(cos) + 1] = bytearray(cos[min(cos)])
    return True


def access_for_nothing(rows):
    """An access row for a plan that does not exist."""
    acc = rows.get("planAccess", {})
    if not acc:
        return False
    acc[999_999] = bytearray(next(iter(acc.values())))
    return True


def promo_code_lowered(rows):
    """A promotion's code put in small letters."""
    for _, raw in sorted(rows.get("promo", {}).items()):
        if 0x41 <= raw[0] <= 0x5A:
            raw[0] += 0x20
            return True
    return False


def promo_code_shared(rows):
    """A promotion added under the first promotion's code."""
    prs = rows.get("promo", {})
    if not prs:
        return False
    prs[max(prs) + 1] = bytearray(prs[min(prs)])
    return True


def promo_code_of_company(rows):
    """A promotion's code made the first company's."""
    prs, cos = rows.get("promo", {}), rows.get("company", {})
    if not prs or not cos:
        return False
    raw = prs[min(prs)]
    raw[0:16] = cos[min(cos)][0:16]
    return True


def last_use_dropped(rows):
    """The booking holding a promotion's last use moved one use up: the count's own use is held by nobody."""
    prs = decode_rows(rows, "promo")
    return poke(rows, "bookingRate", "use", 1, lambda i, r: r["promoId"] in prs and r["use"] == prs[r["promoId"]]["used"] and r["use"] > 0)


def over_picked(rows):
    """A block's rooms set one below the most picked up on any of its nights."""
    nights = decode_rows(rows, "blockNight")
    for kid, k in sorted(decode_rows(rows, "block").items()):
        most = max((bn["picked"] for i, bn in nights.items() if i // DAY_SPAN == kid), default=0)
        if most >= 1:
            return poke(rows, "block", "rooms", most - 1 - k["rooms"], lambda i, x: i == kid)
    return False


def pickup_of(rows, table, field, delta, at_arrival=False):
    """Poke the row of `table` under a pickup's booking, or (at_arrival) the block of a pickup arriving on its first night."""
    blocks, bookings = decode_rows(rows, "block"), decode_rows(rows, "booking")
    for bid, p in sorted(decode_rows(rows, "bookingBlock").items()):
        if at_arrival:
            if bookings[bid]["arrival"] == blocks[p["blockId"]]["arrival"]:
                return poke(rows, "block", field, delta, lambda i, x: i == p["blockId"])
        else:
            return poke(rows, table, field, delta, lambda i, x: i == bid)
    return False


def live_package(rows):
    """The live package lines of the bookings that hold their nights: (line id, package row, folio line, booking)."""
    plines, folio, charges, bookings = (decode_rows(rows, k) for k in ("packageLine", "folio", "charge", "booking"))
    out = []
    for lid, pk in sorted(plines.items()):
        l, ch = folio.get(lid), charges.get(lid)
        if l and ch and ch["voidLine"] == 0 and l["bookingId"] in bookings and bookings[l["bookingId"]]["status"] in (BOOKED, IN_HOUSE):
            out.append((lid, pk, l, bookings[l["bookingId"]]))
    return out


def package_twice(rows):
    """An arrival-night inclusion moved to the slot of an every-night one given on the same arrival night."""
    live = live_package(rows)
    for lid, pk, l, b in live:
        if pk["rhythm"] == ARRIVAL_NIGHT:
            for _, pk2, l2, _ in live:
                if pk2["rhythm"] == EVERY_NIGHT and l2["bookingId"] == l["bookingId"] and l2["night"] == l["night"]:
                    return poke(rows, "packageLine", "slot", pk2["slot"] - pk["slot"], lambda i, x: i == lid)
    return False


def staff_posted_package(rows):
    """A live package line's charge made out as posted by the member of staff who posted another charge."""
    o, w = field_at("charge", "postedBy")
    live = {lid for lid, _, _, _ in live_package(rows)}
    staff = next((raw[o:o + w] for raw in rows["charge"].values() if bytes(raw[o:o + w]) != PACKAGE_POSTER), None)
    for lid in sorted(live):
        if staff is not None:
            rows["charge"][lid][o:o + w] = staff
            return True
    return False


def beside(rows, table, new_id):
    """A copy of the first row of `table` put at an id nothing else has: a row added beside the fold."""
    if not rows.get(table):
        return False
    rows[table][new_id] = bytearray(rows[table][min(rows[table])])
    return True


def set_setup(rows, field, value):
    """Overwrite one bytes field of guest email's setup row."""
    if not rows.get("mailSetup"):
        return False
    o, _ = field_at("mailSetup", field)
    raw = rows["mailSetup"][min(rows["mailSetup"])]
    raw[o:o + len(value)] = value
    return True


def clear_address(rows):
    """An address put on the chain in the clear, in place of its sealed text."""
    if not rows.get("_sealed"):
        return False
    rows["_sealed"][min(rows["_sealed"])] = bytearray(b"basma.adel@example.com")
    return True


def message_to_addressless(rows):
    """The first message moved to a booking that gave no address."""
    if not rows.get("outbox"):
        return False
    bare = [b for b in sorted(rows.get("booking", {})) if b not in rows.get("mailAddress", {})]
    if not bare:
        return False
    o, w = field_at("outbox", "bookingId")
    rows["outbox"][min(rows["outbox"])][o:o + w] = bare[0].to_bytes(w, "big")
    return True


def decode_rows(rows, table):
    return {i: decode(table, b) for i, b in rows.get(table, {}).items()}


def walk_short(rows):
    """The walk marked done one section short of where it stands."""
    section, _ = (int(x) for x in bytes(rows["_walk"][0]).decode().split())
    if section == 0:
        return False
    rows["_walk"][0] = bytearray(f"{section - 1} 1".encode())
    return True


def control(path):
    base, counters, day, _, _ = parse(open(path))
    clean, _ = laws(base, counters, day)
    if clean:
        print(f"CONTROL BROKEN: the export is not clean to begin with: {clean[:3]}"); return 1
    cases = [
        ("a night sold once more than its bookings", "I2 counters", lambda r: poke(r, "night", "sold", 1, lambda i, n: n["sold"] + n["held"] < n["allotment"])),
        ("a night over its allotment", "I1 capacity", lambda r: poke(r, "night", "held", 40)),
        ("a booking paid one unit more than its payments", "I4 money", lambda r: poke(r, "booking", "paid", 1)),
        ("a capture one unit larger than the money held", "I5 cash", lambda r: poke(r, "payment", "amount", 1, lambda i, p: p["kind"] == CAPTURED and p["state"] == DONE)),
        ("a booking stretched past its night rows", "I3 nights", stretched),
        ("a stay under the minimum it was accepted under", "I6 restrictions", lambda r: poke(r, "booking", "checkedMinStay", 40, lambda i, b: b["status"] != CHECKED_OUT)),
        ("a room held by a booking that is not checked in", "I8 rooms", lambda r: poke(r, "room", "occupiedBy", 1, lambda i, x: x["occupiedBy"] == 0)),
        ("a room inspected by the person who cleaned it", "I10 housekeeping", self_inspected),
        ("dates out of order on a room in service", "I10 housekeeping", lambda r: bool(dated(r)) and poke(r, "room", "status", ACTIVE - OUT_OF_ORDER, lambda i, x: i in dated(r))),
        ("a housekeeping record for a room that does not exist", "I10 housekeeping", record_moved),
        ("a room out of order with its dates dropped, below the nights that offer it", "I1 capacity", dates_dropped),
        ("an extra that is not its quantity times its price", "I11 bill", lambda r: poke(r, "charge", "unitAmount", 1)),
        ("an invoice whose figures are not its bill's", "I11 bill", lambda r: poke(r, "invoice", "charges", 1)),
        ("a payer's payment moved onto the guest's bill", "I11 bill", payment_moved_to_guest),
        ("a line on the bill of a payer who is not on its booking", "I11 bill", lambda r: poke(r, "lineRoute", "payerId", 1000)),
        ("a credit note whose net and taxes do not make its total", ("I11 bill", "do not make its total"), lambda r: poke(r, "creditNote", "total", 1)),
        ("a credit note whose figures are not its lines'", ("I11 bill", "its lines come to"),
         lambda r: poke(r, "creditNote", "net", 1) and poke(r, "creditNote", "total", 1)),
        ("an invoice's credits moved beside its notes", ("I11 bill", "and its notes"), lambda r: poke(r, "invoice", "credits", 1, lambda i, x: i in noted_invoices(r))),
        ("a credit line recorded against another note", ("I11 bill", "is not a credit of this note"), lambda r: poke(r, "creditLine", "note", 1)),
        ("a room night taken back beyond its amount", ("I11 bill", "credit notes took back"), shrunk_source),
        ("a credit note approved by its own maker", ("I11 bill", "lacks a second person's approval"), lambda r: self_approved(r, "creditNote")),
        ("a desk refund approved under another permission", ("I11 bill", "lacks a second person's approval"),
         lambda r: poke(r, "proposal", "permission", 1, lambda i, x: i in {decode("deskRefund", b)["proposal"] for b in r.get("deskRefund", {}).values()})),
        ("a desk refund of a refund the gateway made", ("I11 bill", "is not a failed refund"),
         lambda r: poke(r, "payment", "state", DONE - FAILED, lambda i, x: i in r.get("deskRefund", {}))),
        ("a desk refund with no reference", ("I11 bill", "has no reference"),
reference_dropped),
        ("a gap in the credit notes' run", ("I11 bill", "is outside the run"), note_renumbered),
        ("a booking from no hold that no member of staff took", ("I12 origin", "came from no hold and no member of staff"), from_nowhere),
        ("a booking from a hold also recorded as taken by staff", ("I12 origin", "and from staff"), staffed_twice),
        ("a booking from a hold that was never confirmed", ("I12 origin", "which is not confirmed"), unconfirmed_hold),
        ("a walk-in recorded on a day it did not arrive", ("I12 origin", "arrived on another day"),
         lambda r: poke(r, "staffBooking", "day", -1, lambda i, x: x["channel"] == WALK_IN)),
        ("a night's revenue row moved beside its figures", ("I13 figures", "the rows by type and plan say"), lambda r: poke(r, "dayRevenue", "revenue", 1)),
        ("a day selling more rooms than it had in service", ("I13 figures", "out of order, of"),
         lambda r: poke(r, "dayFigures", "roomsOut", 10_000)),
        ("a closed day whose job skipped a guest in house", ("I13 figures", "guests in house"),
         lambda r: poke(r, "dayFigures", "inHouse", 1, lambda i, f: f["houseSeen"] > 0)),
        ("a pickup that skipped a booking", ("I13 figures", "the day before ended at"),
         lambda r: poke(r, "dayFigures", "pickupFrom", 1, lambda i, f: decode_rows(r, "dayFigures").get(i - 1) is not None)),
        ("a pickup run past the last booking", ("I13 figures", "which does not exist"), lambda r: poke(r, "dayFigures", "pickupCount", 100_000)),
        ("a day's room nights booked that its bookings do not hold", ("I13 figures", "its bookings hold"),
         lambda r: poke(r, "dayFigures", "pickupNights", 1, lambda i, f: f["pickupCount"] > 0)),
        ("a revenue row under a night with no figures", ("I13 figures", "under a day with no figures"), lambda r: poke(r, "dayRevenue", "day", 400)),
        ("a booking on a company's plan kept under another company", ("I14 rates", "closed before it was made, and was sold under company"),
         lambda r: poke(r, "bookingRate", "companyId", 1, lambda i, x: decode("booking", r["booking"][i])["planId"] == closed_plan(r))),
        ("a kept access that is the public sale", ("I14 rates", "keeps the public sale"),
         lambda r: any(poke(r, "bookingRate", "companyId", -x["companyId"], lambda j, y, i=i: j == i) for i, x in sorted(decode_rows(r, "bookingRate").items()))),
        ("an access kept in another block than its booking", ("I14 rates", "the booking was made at"), lambda r: poke(r, "bookingRate", "lastBlock", 1)),
        ("an access naming a company that does not exist", ("I14 rates", "which does not exist"), lambda r: poke(r, "bookingRate", "companyId", 1000)),
        ("an access naming a promotion that does not exist", ("I14 rates", "names promotion 5, which does not exist"),
         lambda r: poke(r, "bookingRate", "promoId", 5, lambda i, x: x["promoId"] == 0)),
        ("an access naming a company and a promotion", ("I14 rates", "names both a company and a promotion"),
         lambda r: poke(r, "bookingRate", "companyId", 1, lambda i, x: x["promoId"] != 0)),
        ("a hold counting a use", ("I14 rates", "a hold counts none"), lambda r: poke(r, "holdRate", "use", 1)),
        ("a use counted under no promotion", ("I14 rates", "of no promotion"), lambda r: poke(r, "bookingRate", "use", 1, lambda i, x: x["promoId"] == 0)),
        ("a use past the promotion's count", ("I14 rates", "which has counted"), lambda r: poke(r, "bookingRate", "use", 100, lambda i, x: x["promoId"] != 0)),
        ("a use held by two bookings", ("I14 rates", "is held by bookings"), lambda r: poke(r, "bookingRate", "use", -1, lambda i, x: x["promoId"] != 0 and x["use"] == 2)),
        ("a use with the one below it held by nobody", ("I14 rates", "with no use"), lambda r: poke(r, "bookingRate", "use", -1, lambda i, x: x["promoId"] != 0 and x["use"] == 1)),
        ("a promotion's last use held by nobody", ("I14 rates", "its last use is no booking's"), last_use_dropped),
        ("a promotion past its limit", ("I14 rates", "past its limit"), lambda r: poke(r, "promo", "maxUses", 1, lambda i, x: x["used"] > 1 and x["maxUses"] == 0)),
        ("a promotion whose window ends before it begins", ("I14 rates", "ends before it begins"), lambda r: poke(r, "promo", "stayFrom", 10_000)),
        ("a promotion of a plan that does not exist", ("I14 rates", "which does not exist"), lambda r: poke(r, "promo", "planId", 100_000)),
        ("a booking on a plan closed to codes under a promotion naming another plan", ("I14 rates", "and was sold under promotion"),
         lambda r: poke(r, "promo", "planId", 100_000)),
        ("a promotion code in small letters", ("I14 rates", "is not capitals"), promo_code_lowered),
        ("two promotions under one code", ("I14 rates", "'s code is promotion"), promo_code_shared),
        ("a promotion under a company's code", ("I14 rates", "'s code is a company's"), promo_code_of_company),
        ("a promotion with no name", ("I14 rates", "has no name"), lambda r:
         any(poke(r, "promo", "nameLength", -c["nameLength"], lambda j, y, i=i: j == i) for i, c in sorted(decode_rows(r, "promo").items()) if c["nameLength"])),
        ("a booking whose hold was placed under another access", ("I14 rates", "its hold"), from_hold_regranted),
        ("a hold's access kept after the hold last changed", ("I14 rates", "after the hold last changed"), lambda r: poke(r, "holdRate", "lastBlock", 10**9)),
        ("a public booking on a company's plan", ("I14 rates", "and was sold on public sale"), public_on_closed),
        ("a company code in small letters", ("I14 rates", "is not capitals"), code_lowered),
        ("two companies under one code", ("I14 rates", "'s code is company"), code_shared),
        ("a company with no name", ("I14 rates", "has no name"), lambda r:
         any(poke(r, "company", "nameLength", -c["nameLength"], lambda j, y, i=i: j == i) for i, c in sorted(decode_rows(r, "company").items()) if c["nameLength"])),
        ("a plan named for a company and open to everyone", ("I14 rates", "is open to everyone"), lambda r: poke(r, "planAccess", "closed", -1, lambda i, a: a["closed"] and a["companyId"])),
        ("a plan closed to a company that does not exist", ("I14 rates", "which does not exist"), lambda r: poke(r, "planAccess", "companyId", 1000, lambda i, a: a["companyId"])),
        ("an access for a plan that does not exist", ("I14 rates", "the plan does not exist"), access_for_nothing),
        ("a block night counting a pickup no booking holds", ("I15 blocks", "its bookings hold"), lambda r: poke(r, "blockNight", "picked", 1)),
        ("a block night holding a room it should not", ("I15 blocks", "still holds"), lambda r: poke(r, "blockNight", "open", 1)),
        ("a block night on another hotel night", ("I15 blocks", "is on another hotel night"), lambda r: poke(r, "blockNight", "night", 1)),
        ("a block with more rooms picked up than it holds", ("I15 blocks", "rooms picked up of"), over_picked),
        ("a released block reopened under its nights", ("I15 blocks", "still holds"), lambda r: poke(r, "block", "open", 1, lambda i, x: not x["open"])),
        ("a block whose cut-off is after its arrival", ("I15 blocks", "cut-off is after its arrival"), lambda r: poke(r, "block", "cutoff", 100)),
        ("a block on a plan that does not exist", ("I15 blocks", "is sold at plan"), lambda r: poke(r, "block", "planId", 100_000)),
        ("a block of a room type that does not exist", ("I15 blocks", "is of room type"), lambda r: poke(r, "block", "roomTypeId", 100_000)),
        ("a block for a company that does not exist", ("I15 blocks", "names company"), lambda r: poke(r, "block", "companyId", 100_000)),
        ("a pickup before its block's arrival", ("I15 blocks", "runs outside block"), lambda r: pickup_of(r, "block", "arrival", 1, at_arrival=True)),
        ("a hotel night held by blocks beside its block nights", ("I15 blocks", "held by blocks says"), lambda r: poke(r, "nightBlock", "open", 1)),
        ("a hotel night held by blocks past its allotment", ("I1 capacity", "held by blocks over the allotment"), lambda r: poke(r, "nightBlock", "open", 1000)),
        ("a pickup from a block that does not exist", ("I15 blocks", "does not exist"), lambda r: poke(r, "bookingBlock", "blockId", 100_000)),
        ("a pickup taken by phone", ("I15 blocks", "not from the group's list"), lambda r: pickup_of(r, "staffBooking", "channel", -2)),
        ("a booking from a group's list picked up from no block", ("I15 blocks", "picked up from no block"),
         lambda r: poke(r, "staffBooking", "channel", GROUP - 1, lambda i, x: x["channel"] == 1)),
        ("a pickup on another plan than its block's", ("I15 blocks", "room type and plan"), lambda r: pickup_of(r, "booking", "planId", 1)),
        ("a package line whose charge is not the inclusion sold", ("I18 packages", "is not the inclusion sold"), lambda r: poke(r, "packageLine", "quantity", 1)),
        ("a package line taxed when its extra was not", ("I18 packages", "is taxed, and its extra was not"),
         lambda r: poke(r, "packageLine", "taxed", -1, lambda i, x: x["taxed"] and x["taxLines"])),
        ("an every-night inclusion made an arrival-night one away from the arrival", ("I18 packages", "arrival-night inclusion on night"),
         lambda r: poke(r, "packageLine", "rhythm", ARRIVAL_NIGHT - EVERY_NIGHT,
                        lambda i, x: i in {lid for lid, pk, l, b in live_package(r) if pk["rhythm"] == EVERY_NIGHT and l["night"] != b["arrival"]})),
        ("a night missing from an every-night inclusion", ("I18 packages", "and not the night"),
         lambda r: poke(r, "packageLine", "slot", 7, lambda i, x: i in {lid for lid, pk, l, b in live_package(r)
                                                                          if pk["rhythm"] == EVERY_NIGHT and b["arrival"] < l["night"] < b["departure"] - 1})),
        ("an inclusion twice on one night", ("I18 packages", "twice"), package_twice),
        ("a package line posted by a member of staff", ("I18 packages", "posted by a member of staff"), staff_posted_package),
        ("a package line moved outside its stay", ("I18 packages", "outside booking"),
         lambda r: poke(r, "folio", "night", 30, lambda i, x: i in {lid for lid, _, _, _ in live_package(r)})),
        ("a package line charged to another booking", ("I18 packages", "is not an extra of its booking"),
         lambda r: poke(r, "charge", "bookingId", 1, lambda i, x: i in r["packageLine"])),
        ("a package line of a booking that does not exist", ("I18 packages", "does not exist"),
         lambda r: poke(r, "folio", "bookingId", 100_000, lambda i, x: i in {lid for lid, _, _, _ in live_package(r)})),
        ("a package row beside no line", ("I18 packages", "its line or its charge does not exist"), lambda r: beside(r, "packageLine", 10**12)),
        ("a held package line not its quantity times its price", ("I18 packages", " × "), lambda r: poke(r, "holdPackage", "unitAmount", 1)),
        ("a held package line taxed when its extra was not", ("I18 packages", "is taxed, and its extra was not"),
         lambda r: poke(r, "holdPackage", "taxed", -1, lambda i, x: x["taxed"] and x["taxLines"])),
        ("a held package line naming a line that is not its tax", ("I18 packages", "its tax"), lambda r: poke(r, "holdPackage", "taxLines", 1, lambda i, x: x["taxLines"])),
        ("a held package row beside no hold line", ("I18 packages", "the hold line does not exist"), lambda r: beside(r, "holdPackage", 10**12)),
        ("a held package line of no hold", ("I18 packages", "is not an extra of a hold"), lambda r: poke(r, "holdLine", "bookingId", 100_000, lambda i, x: i in r["holdPackage"])),
        ("an inclusion of none of its extra", ("I18 packages", "gives 0 of its extra"), lambda r:
         any(poke(r, "planInclusion", "quantity", -x["quantity"], lambda j, y, i=i: j == i) for i, x in sorted(decode_rows(r, "planInclusion").items()) if x["on"])),
        ("an inclusion of an extra that does not exist", ("I18 packages", "does not exist"), lambda r: poke(r, "planInclusion", "extraId", 100_000, lambda i, x: x["on"])),
        ("an inclusion under another plan's id", ("I18 packages", "wrong plan or slot"), lambda r: poke(r, "planInclusion", "planId", 1)),
        ("an inclusion of a plan that does not exist", ("I18 packages", "the plan does not exist"),
         lambda r: beside(r, "planInclusion", 999_999 * 16 + 1) and poke(r, "planInclusion", "planId", 999_999 - decode_rows(r, "planInclusion")[999_999 * 16 + 1]["planId"],
                                                                          lambda i, x: i == 999_999 * 16 + 1)),
        ("a card kept after its booking was cancelled", ("I16 card on file", "still on file after its booking settled"),
         lambda r: poke(r, "cardOnFile", "state", KEPT - 4, lambda i, k: k["state"] == 4 and decode("booking", r["booking"][i])["status"] == CANCELLED)),
        ("a card still awaited for a no-show", ("I16 card on file", "is awaited"),
         lambda r: poke(r, "cardOnFile", "state", WANTED - CLOSED_CARD, lambda i, k: k["state"] == CLOSED_CARD and decode("booking", r["booking"][i])["status"] == NO_SHOW)),
        ("a card never put on file that holds a token", ("I16 card on file", "was never put on file"),
         lambda r: poke(r, "cardOnFile", "token", 9, lambda i, k: k["state"] == CLOSED_CARD)),
        ("a card on file with no token", ("I16 card on file", "without a token"),
         lambda r: any(poke(r, "cardOnFile", "token", -k["token"], lambda j, y, i=i: j == i) for i, k in sorted(decode_rows(r, "cardOnFile").items()) if k["token"])),
        ("a card on file on no payment of the guest's", ("I16 card on file", "is no payment the guest made"), lambda r: poke(r, "cardOnFile", "firstAuth", 10**6, lambda i, k: k["firstAuth"])),
        ("a charge made before the guest agreed", ("I16 card on file", "before or as the guest agreed"), lambda r: poke(r, "cardOnFile", "agreedBlock", 10**6, lambda i, k: k["chargeId"])),
        ("a charge made and shown as declined", ("I16 card on file", "is shown as declined, and its charge"),
         lambda r: poke(r, "cardOnFile", "declinedDay", 1, lambda i, k: k["chargeId"] and decode("payment", r["payment"][k["chargeId"]])["state"] == DONE)),
        ("a card shown as declined with no charge", ("I16 card on file", "was never charged"), lambda r: poke(r, "cardOnFile", "declinedDay", 1, lambda i, k: not k["chargeId"])),
        ("a charge on file its card does not name", ("I16 card on file", "is not the one its card names"),
         lambda r: any(poke(r, "cardOnFile", "chargeId", -k["chargeId"], lambda j, y, i=i: j == i) for i, k in sorted(decode_rows(r, "cardOnFile").items()) if k["chargeId"])),
        ("a charge on file past the penalty", ("I16 card on file", "more than the penalty"),
         lambda r: poke(r, "booking", "penalty", -1, lambda i, b: i in {j for j, k in decode_rows(r, "cardOnFile").items() if k["chargeId"]})),
        ("a booking charged on file that is no no-show", ("I16 card on file", "is no no-show"),
         lambda r: poke(r, "booking", "status", CANCELLED - NO_SHOW, lambda i, b: i in {j for j, k in decode_rows(r, "cardOnFile").items() if k["chargeId"]})),
        ("a card let go while its charge is owed", ("I16 card on file", "let go while its charge is owed"),
         lambda r: poke(r, "payment", "state", DUE - FAILED, lambda i, p: p["kind"] == CHARGED_ON_FILE and p["state"] == FAILED)),
        ("a card for a booking that does not exist", ("I16 card on file", "no such booking"), lambda r: beside(r, "cardOnFile", 10**12)),
        ("a deposit share of 25.5%", ("I16 card on file", "whole percents"), lambda r: poke(r, "planDeposit", "depositBps", 50, lambda i, d: d["depositBps"])),
        ("a deposit plan with no share", ("I16 card on file", "a deposit of no share"),
         lambda r: any(poke(r, "planDeposit", "depositBps", -d["depositBps"], lambda j, y, i=i: j == i) for i, d in sorted(decode_rows(r, "planDeposit").items())
                       if d["depositBps"] and decode("ratePlan", r["ratePlan"][i])["guarantee"] == DEPOSIT)),
        ("a deposit for a plan that does not exist", ("I16 card on file", "no such plan"), lambda r: beside(r, "planDeposit", 999_999)),
        ("a message to a booking with no address", ("I17 mail", "has no address"), message_to_addressless),
        ("a message its address does not owe", ("I17 mail", "not this one"), lambda r: poke(r, "mailAddress", "confirmation", 1, lambda i, a: a["confirmation"])),
        ("a receipt for a stay not checked out", ("I17 mail", "is a receipt"),
         lambda r: poke(r, "outbox", "kind", RECEIPT - CONFIRMATION, lambda i, o: o["kind"] == CONFIRMATION and decode("booking", r["booking"][o["bookingId"]])["status"] == CONFIRMED_B)),
        ("a cancellation notice for a booking not cancelled", ("I17 mail", "is a cancellation notice"),
         lambda r: poke(r, "outbox", "kind", CANCELLATION - CONFIRMATION, lambda i, o: o["kind"] == CONFIRMATION and decode("booking", r["booking"][o["bookingId"]])["status"] == CONFIRMED_B)),
        ("a note before arrival still due for a no-show", ("I17 mail", "waits to go before an arrival"),
         lambda r: poke(r, "outbox", "state", MAIL_DUE - MAIL_SKIPPED, lambda i, o: o["kind"] == PRE_ARRIVAL and o["state"] == MAIL_SKIPPED
                        and decode("booking", r["booking"][o["bookingId"]])["status"] == NO_SHOW)),
        ("a note before arrival dated on the arrival", ("I17 mail", "not before the arrival"),
         lambda r: poke(r, "outbox", "notBefore", 100, lambda i, o: o["kind"] == PRE_ARRIVAL)),
        ("a confirmation that waits for a day", ("I17 mail", "only the note before arrival waits"), lambda r: poke(r, "outbox", "notBefore", 5, lambda i, o: o["kind"] == CONFIRMATION)),
        ("a message tried four times", ("I17 mail", "was tried 4 times"), lambda r: poke(r, "outbox", "attempts", 3, lambda i, o: o["state"] == MAIL_SENT and o["attempts"] == 1)),
        ("a message sent with a failure", ("I17 mail", "is sent after"), lambda r: poke(r, "outbox", "failure", 1, lambda i, o: o["state"] == MAIL_SENT)),
        ("a message given up before its third try", ("I17 mail", "is given up after 2 tries"), lambda r: poke(r, "outbox", "attempts", -1, lambda i, o: o["state"] == MAIL_FAILED)),
        ("a message still due after three tries", ("I17 mail", "is still to send after 3 tries"),
         lambda r: poke(r, "outbox", "attempts", 3, lambda i, o: o["state"] == MAIL_DUE and o["attempts"] == 0) and poke(r, "outbox", "failure", 2, lambda i, o: o["state"] == MAIL_DUE and o["attempts"] == 3)),
        ("a failed try with no reason", ("I17 mail", "is to send after 1 tries with failure code 0"), lambda r: poke(r, "outbox", "attempts", 1, lambda i, o: o["state"] == MAIL_DUE and o["attempts"] == 0)),
        ("a message owed in no block", ("I17 mail", "was owed in block 0"),
         lambda r: any(poke(r, "outbox", "queuedBlock", -o["queuedBlock"], lambda j, y, i=i: j == i) for i, o in sorted(decode_rows(r, "outbox").items()))),
        ("an address in the clear", ("I17 mail", "is not a sealed address"), lambda r: clear_address(r)),
        ("an address owing a message that does not exist", ("I17 mail", "and there is none"), lambda r: poke(r, "mailAddress", "receipt", 10**9, lambda i, a: a["receipt"] == 0)),
        ("an address owing its confirmation as its receipt", ("I17 mail", "as its receipt, and that message is not one"),
         lambda r: any(poke(r, "mailAddress", "receipt", a["confirmation"], lambda j, y, i=i: j == i) for i, a in sorted(decode_rows(r, "mailAddress").items()) if a["receipt"] == 0)),
        ("an address never owed a confirmation", ("I17 mail", "never owed a confirmation"),
         lambda r: any(poke(r, "mailAddress", "confirmation", -a["confirmation"], lambda j, y, i=i: j == i) for i, a in sorted(decode_rows(r, "mailAddress").items()))),
        ("a cancelled booking owed no notice", ("I17 mail", "owed no notice of it"),
         lambda r: any(poke(r, "mailAddress", "cancellation", -a["cancellation"], lambda j, y, i=i: j == i) for i, a in sorted(decode_rows(r, "mailAddress").items()) if a["cancellation"])),
        ("a checked-out stay owed no receipt", ("I17 mail", "owed no receipt"),
         lambda r: any(poke(r, "mailAddress", "receipt", -a["receipt"], lambda j, y, i=i: j == i) for i, a in sorted(decode_rows(r, "mailAddress").items()) if a["receipt"])),
        ("guest email on with an untested account", ("I17 mail", "never tested the account"), lambda r: set_setup(r, "tested", bytes(32))),
        ("guest email on with no relay", ("I17 mail", "no relay is connected"), lambda r: set_setup(r, "mailKey", bytes(65))),
        ("a test of an account not authorised", ("I17 mail", "did not authorise"), lambda r: set_setup(r, "tested", bytes([7]) * 32) and set_setup(r, "on", b"\x00")),
        ("a mail key that is no point", ("I17 mail", "no uncompressed P-256 point"), lambda r: set_setup(r, "mailKey", bytes([5]) + bytes([1]) * 64)),
        ("a relay whose grant was ended", ("I17 mail", "not an active mailer's"), lambda r: poke(r, "grant", "active", -1, lambda i, g: g["role"] == MAILER and g["active"])),
        ("a relay with no grant", ("I17 mail", "is not on the roster"), lambda r: poke(r, "mailSetup", "mailerGrant", 10**9)),
        ("a refund's slices that do not sum to what it gave back", ("I5 cash", "not the"), lambda r: poke(r, "refundSlice", "excess", 1)),
        ("a refund drawn from another card than the split calls for", ("I5 cash", "call for"), slice_moved),
        ("a desk slice the gateway still holds", ("I5 cash", "still with the gateway"), desk_slice_held),
        ("a walk whose span is no epoch's", ("rules", "is no epoch's"), lambda r: poke(r, "rules", "walkSections", 1)),
        ("an epoch past the rules defined", ("rules", "past the rules defined"), lambda r: poke(r, "rules", "epoch", len(SECTIONS_AT))),
        ("a walk done short of its span", ("rules", "the walk is at section"), lambda r: r.get("_walk", {}).get(0) is not None and walk_short(r)),
        ("a card giving back more than it captured", ("I5 cash", "it captured"),
         lambda r: poke(r, "payment", "amount", 10**9, lambda i, p: i in r.get("refundSlice", {}) and p["gatewayAuth"] != 0)),
    ]
    caught = 0
    for what, rule, inject in cases:
        rows = {t: {i: bytearray(b) for i, b in rs.items()} for t, rs in base.items()}
        if not inject(rows):
            print(f"CONTROL BROKEN: no row to inject '{what}' into"); continue
        found, _ = laws(rows, counters, day)
        # a case names its rule, or its rule and the words of the one law it breaks, so that a fault caught
        # by another law of the same rule is not scored as a catch
        rule, words = rule if isinstance(rule, tuple) else (rule, "")
        if any(r == rule and words in d for r, d in found):
            caught += 1; print(f"caught: {what} ({rule})")
        else:
            print(f"MISSED: {what}; the twin said {found[:3]}")
    print(f"count: twin faults injected = {len(cases)}")
    print(f"count: twin faults caught = {caught}")
    if caught != len(cases):
        print("TWIN CONTROL FAILED"); return 1
    print("TWIN CONTROL GREEN")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    sys.exit(control(sys.argv[1]) if "--control" in sys.argv[2:] else verdict(sys.argv[1]))
