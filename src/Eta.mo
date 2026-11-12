/// Eta.mo - a credit note as the Egyptian Tax Authority's credit note (document type "C", version 1.0):
/// the document, its serialisation as the authority states it, and its digest.
///
/// THE SHAPE IS MENTAT'S (`Mentat/src/EtaDocument.mo`), which reads it from the authority's SDK
/// specification and checks its serialisation against the authority's own published example. A hotel's
/// line carries more than one tax (VAT, the service charge, a city tax), so a line here carries its
/// taxes as the `taxableItems` array the specification defines, one item per tax, where Mentat's lines
/// carry one.
///
/// WHAT THE DOCUMENT SAYS, AND FROM WHERE:
///   issuer       the hotel's registration with the authority (`setEtaProfile`): its registration
///                number, branch, address and activity code, and the hotel's name
///   receiver     the guest ("P", a person) for the guest's bill; a payer of a split bill ("B", a
///                business, which is what a second bill at a hotel is for) for theirs
///   references   the invoice the note amends
///   lines        one per line the note takes back, in the note's order: what it was, the amount taken
///                back as one unit, and each of its taxes taken back with its type and sub-type
///                (`setTaxEta`) and its rate
///
/// Luxor does not submit documents to the authority. What a submission needs that the hotel has not
/// given is named in `missing`, in words, rather than filled with a value that looks right: the
/// registration, a tax's codes, the EGS item codes, a business receiver's registration, and the
/// authority's identifier of the invoice (its UUID, given when the invoice was submitted, which is what
/// `references` must then hold in place of the hotel's number).
///
/// The amounts are the ledger's own, as written by the note: the document states them, it does not
/// recompute them.
///
/// Attribution: Thebes Core Team. Licence: Apache 2.0.

import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int "mo:core/Int";
import List "mo:core/List";
import Nat "mo:core/Nat";
import Text "mo:core/Text";

import RowStore "mo:kernel/rows/RowStore";
import CivilDate "mo:kernel/num/CivilDate";
import Json "mo:kernel/codec/JsonTree";
import H "mo:kernel/hash/Sha256Hex";

import CN "CreditNote";
import R "Rows";
import St "Store";
import TA "TextArena";

module {

  public type Address = { branchId : Text; country : Text; governate : Text; regionCity : Text; street : Text; buildingNumber : Text };
  /// B for a business in Egypt, P for a natural person.
  public type Party = { partyType : Text; id : Text; name : Text; address : Address };
  /// Hundredths of a basis point for the rate (14% is 140_000); minor units for the amount.
  public type Tax = { taxType : Text; subType : Text; rate : Nat; amount : Nat };
  public type Line = {
    description : Text;
    itemType : Text;
    itemCode : Text;
    unitType : Text;
    /// Thousandths of a unit.
    quantity : Nat;
    internalCode : Text;
    unitPrice : Nat;
    salesTotal : Nat;
    taxes : [Tax];
  };
  public type Document = {
    documentType : Text;
    documentTypeVersion : Text;
    issuer : Party;
    receiver : Party;
    issueDay : Nat;
    activityCode : Text;
    internalId : Text;
    references : [Text];
    currency : Text;
    exponent : Nat;
    lines : [Line];
  };

  public let CREDIT_NOTE : Text = "C";
  public let VERSION : Text = "1.0";
  /// The receiver's national id is required on a person's document at this total and above (EGP).
  public let PERSON_ID_THRESHOLD_EGP : Nat = 50_000;

  public func noteId(n : Nat) : Text { "CN-" # Nat.toText(n) };
  public func invoiceId(n : Nat) : Text { "INV-" # Nat.toText(n) };

  // ── formatting ──────────────────────────────────────────────────────────────

  /// `value / 10^scale` as decimal text with exactly `scale` fraction digits, sign kept.
  public func dec(value : Int, scale : Nat) : Text {
    let neg = value < 0;
    let mag = Int.abs(value);
    var p = 1;
    var i = 0;
    while (i < scale) { p *= 10; i += 1 };
    var fracText = Nat.toText(mag % p);
    while (Text.size(fracText) < scale) { fracText := "0" # fracText };
    (if (neg) "-" else "") # Nat.toText(mag / p) # (if (scale == 0) "" else "." # fracText)
  };

  func num(value : Int, scale : Nat) : Json.Json { #number(dec(value, scale)) };
  func str(t : Text) : Json.Json { #string(t) };

  public func issuedAt(day : Nat) : Text { CivilDate.toText(day) # "T00:00:00Z" };

  // ── the document tree ───────────────────────────────────────────────────────

  func address(a : Address, withBranch : Bool) : Json.Json {
    let ms = List.empty<(Text, Json.Json)>();
    if (withBranch) List.add(ms, ("branchID", str(a.branchId)));
    List.add(ms, ("country", str(a.country)));
    List.add(ms, ("governate", str(a.governate)));
    List.add(ms, ("regionCity", str(a.regionCity)));
    List.add(ms, ("street", str(a.street)));
    List.add(ms, ("buildingNumber", str(a.buildingNumber)));
    #object_(List.toArray(ms))
  };

  func party(p : Party, isIssuer : Bool) : Json.Json {
    #object_([("address", address(p.address, isIssuer)), ("type", str(p.partyType)), ("id", str(p.id)), ("name", str(p.name))])
  };

  public func lineTax(l : Line) : Nat { var t = 0; for (x in l.taxes.vals()) t += x.amount; t };

  func line(l : Line, currency : Text, exponent : Nat) : Json.Json {
    #object_([
      ("description", str(l.description)),
      ("itemType", str(l.itemType)),
      ("itemCode", str(l.itemCode)),
      ("unitType", str(l.unitType)),
      ("quantity", num(l.quantity, 3)),
      ("internalCode", str(l.internalCode)),
      ("salesTotal", num(l.salesTotal, exponent)),
      ("total", num(l.salesTotal + lineTax(l), exponent)),
      ("valueDifference", num(0, exponent)),
      ("totalTaxableFees", num(0, exponent)),
      ("netTotal", num(l.salesTotal, exponent)),
      ("itemsDiscount", num(0, exponent)),
      ("unitValue", #object_([("currencySold", str(currency)), ("amountEGP", num(l.unitPrice, exponent))])),
      ("discount", #object_([("rate", num(0, 2)), ("amount", num(0, exponent))])),
      ("taxableItems", #array(Array.map<Tax, Json.Json>(l.taxes, func(x) {
        #object_([("taxType", str(x.taxType)), ("amount", num(x.amount, exponent)), ("subType", str(x.subType)), ("rate", num(x.rate, 4))])
      }))),
    ])
  };

  /// The totals per tax type, in order of first appearance.
  public func taxTotals(d : Document) : [(Text, Nat)] {
    let types = List.empty<Text>();
    let sums = List.empty<Nat>();
    for (l in d.lines.vals()) {
      for (x in l.taxes.vals()) {
        var found = false;
        var i = 0;
        while (i < List.size(types)) {
          if (List.at(types, i) == x.taxType) { List.put(sums, i, List.at(sums, i) + x.amount); found := true };
          i += 1;
        };
        if (not found) { List.add(types, x.taxType); List.add(sums, x.amount) };
      };
    };
    Array.tabulate<(Text, Nat)>(List.size(types), func(i) { (List.at(types, i), List.at(sums, i)) })
  };

  public func totals(d : Document) : { sales : Nat; tax : Nat } {
    var sales = 0;
    var tax = 0;
    for (l in d.lines.vals()) { sales += l.salesTotal; tax += lineTax(l) };
    { sales; tax }
  };

  /// The document without its signatures: what is serialised and sealed.
  public func tree(d : Document) : Json.Json {
    let t = totals(d);
    let ms = List.empty<(Text, Json.Json)>();
    List.add(ms, ("issuer", party(d.issuer, true)));
    List.add(ms, ("receiver", party(d.receiver, false)));
    List.add(ms, ("documentType", str(d.documentType)));
    List.add(ms, ("documentTypeVersion", str(d.documentTypeVersion)));
    List.add(ms, ("dateTimeIssued", str(issuedAt(d.issueDay))));
    List.add(ms, ("taxpayerActivityCode", str(d.activityCode)));
    List.add(ms, ("internalID", str(d.internalId)));
    List.add(ms, ("references", #array(Array.map<Text, Json.Json>(d.references, func(r) { str(r) }))));
    List.add(ms, ("invoiceLines", #array(Array.map<Line, Json.Json>(d.lines, func(l) { line(l, d.currency, d.exponent) }))));
    List.add(ms, ("totalDiscountAmount", num(0, d.exponent)));
    List.add(ms, ("totalSalesAmount", num(t.sales, d.exponent)));
    List.add(ms, ("netAmount", num(t.sales, d.exponent)));
    List.add(ms, ("taxTotals", #array(Array.map<(Text, Nat), Json.Json>(taxTotals(d), func((ty, a)) { #object_([("taxType", str(ty)), ("amount", num(a, d.exponent))]) }))));
    List.add(ms, ("totalAmount", num(t.sales + t.tax, d.exponent)));
    List.add(ms, ("extraDiscountAmount", num(0, d.exponent)));
    List.add(ms, ("totalItemsDiscountAmount", num(0, d.exponent)));
    #object_(List.toArray(ms))
  };

  func quoted(t : Text) : Text { "\"" # t # "\"" };

  /// The authority's serialisation: every name upper-cased and quoted, every value quoted as written,
  /// members in document order, an array as its name and then its name before each element.
  public func serialize(j : Json.Json) : Text {
    switch (j) {
      case (#string s) quoted(s);
      case (#number n) quoted(n);
      case (#bool b) quoted(if (b) "true" else "false");
      case (#null_) quoted("");
      case (#array xs) { var out = ""; for (x in xs.vals()) { out #= serialize(x) }; out };
      case (#object_ ms) {
        var out = "";
        for ((k, v) in ms.vals()) {
          let name = quoted(Text.toUpper(k));
          switch (v) {
            case (#array xs) { out #= name; for (x in xs.vals()) { out #= name # serialize(x) } };
            case _ { out #= name # serialize(v) };
          };
        };
        out
      };
    }
  };

  public func json(d : Document) : Text { Json.emit(tree(d)) };
  public func digest(d : Document) : Blob { H.sha256(Text.encodeUtf8(serialize(tree(d)))) };

  // ── a credit note, read from the ledger ─────────────────────────────────────

  func describe(c : St.Ctx, bookingId : Nat, id : Nat, l : R.FolioLine) : (Text, Text) {
    let a = c.s.arena;
    switch (l.kind) {
      case (#roomNight) {
        let (code, name) = switch (St.booking(c.s, bookingId)) {
          case (?b) { switch (St.roomType(c.s, b.roomTypeId)) { case (?rt) (rt.code, TA.get(a, rt.nameEn)); case null ("", "Room") } };
          case null ("", "Room");
        };
        (name # ", night of " # CivilDate.toText(l.night), "ROOM-" # code)
      };
      case (#extra) {
        switch (St.charge(c.x, id)) {
          case (?ch) { switch (St.extra(c.x, ch.extraId)) { case (?e) (TA.get(a, e.nameEn), "EXTRA-" # e.code); case null ("Extra", "EXTRA") } };
          case null ("Extra", "EXTRA");
        }
      };
      case (#penalty) ("Cancellation charge", "PENALTY");
      case _ ("", "");
    }
  };

  /// Credit note `number` as the authority's document, and what a submission of it would still need.
  public func creditNote(c : St.Ctx, number : Nat) : ?{ doc : Document; missing : [Text] } {
    let ?cn = St.creditNote(c.x, number) else return null;
    let ?p = St.property(c.s) else return null;
    let a = c.s.arena;
    let missing = List.empty<Text>();
    let profile = St.etaProfile(c.x);
    let issuer : Party = switch profile {
      case (?f) {
        { partyType = "B"; id = TA.get(a, f.issuerId); name = TA.get(a, p.nameEn);
          address = { branchId = TA.get(a, f.branchId); country = f.country; governate = TA.get(a, f.governate); regionCity = TA.get(a, f.regionCity); street = TA.get(a, f.street); buildingNumber = TA.get(a, f.buildingNumber) } }
      };
      case null {
        List.add(missing, "the hotel's registration with the authority: its registration number, branch, address and activity code");
        { partyType = "B"; id = ""; name = TA.get(a, p.nameEn); address = { branchId = ""; country = ""; governate = ""; regionCity = ""; street = ""; buildingNumber = "" } }
      };
    };
    let noAddress = { branchId = ""; country = ""; governate = ""; regionCity = ""; street = ""; buildingNumber = "" };
    let receiver : Party = if (cn.payerId == 0) {
      let name = switch (St.booking(c.s, cn.bookingId)) { case (?b) TA.get(a, b.guestName); case null "" };
      { partyType = "P"; id = ""; name; address = noAddress }
    } else {
      let name = switch (St.payer(c.x, cn.payerId)) { case (?y) TA.get(a, y.name); case null "" };
      List.add(missing, "the registration number and address of " # name # ", who receives this note");
      { partyType = "B"; id = ""; name; address = noAddress }
    };
    let lines = List.empty<Line>();
    var cur : ?Line = null;
    var curTaxes = List.empty<Tax>();
    let unnamed = List.empty<Text>();
    func close() {
      switch cur { case (?l) List.add(lines, { l with taxes = List.toArray(curTaxes) }); case null {} };
      cur := null;
      curTaxes := List.empty<Tax>();
    };
    for (id in Nat.range(cn.firstLine, cn.firstLine + cn.lines)) {
      switch (St.folioLine(c.s, id), St.creditLine(c.x, id)) {
        case (?l, ?cl) {
          switch (St.folioLine(c.s, cl.source)) {
            case (?src) {
              if (CN.isTax(src.kind)) {
                let ruleId = src.code;
                let (rate, ruleCode) = switch (RowStore.get<R.TaxRule>(c.s.taxes, R.taxRule, ruleId)) {
                  case (?r) (if (r.kind == #percent) r.bps * 100 else 0, r.code);
                  case null (0, Nat.toText(ruleId));
                };
                let (taxType, subType) = switch (St.taxEta(c.x, ruleId)) {
                  case (?e) (e.taxType, e.subType);
                  case null { if (List.indexOf<Text>(unnamed, Text.equal, ruleCode) == null) List.add(unnamed, ruleCode); ("", "") };
                };
                List.add(curTaxes, { taxType; subType; rate; amount = l.amount });
              } else {
                close();
                let (description, internalCode) = describe(c, cn.bookingId, cl.source, src);
                cur := ?{ description; itemType = "EGS"; itemCode = ""; unitType = "EA"; quantity = 1000; internalCode; unitPrice = l.amount; salesTotal = l.amount; taxes = [] };
              };
            };
            case null {};
          };
        };
        case _ {};
      };
    };
    close();
    for (code in List.values(unnamed)) List.add(missing, "the authority's tax type and sub-type of tax " # code);
    List.add(missing, "the EGS item code of each line, as registered with the authority");
    List.add(missing, "the authority's identifier of invoice " # invoiceId(cn.invoice) # ", which replaces " # invoiceId(cn.invoice) # " in references once that invoice is submitted");
    if (cn.payerId == 0 and p.currency == "EGP") {
      var unit = 1;
      var i = 0;
      while (i < p.minorUnits) { unit *= 10; i += 1 };
      if (cn.total >= PERSON_ID_THRESHOLD_EGP * unit) List.add(missing, "the guest's national id, which the authority asks for on a document of " # Nat.toText(PERSON_ID_THRESHOLD_EGP) # " EGP and above");
    };
    let doc : Document = {
      documentType = CREDIT_NOTE; documentTypeVersion = VERSION; issuer; receiver; issueDay = cn.issuedDay;
      activityCode = switch profile { case (?f) f.activityCode; case null "" };
      internalId = noteId(number); references = [invoiceId(cn.invoice)];
      currency = p.currency; exponent = p.minorUnits; lines = List.toArray(lines);
    };
    ?{ doc; missing = List.toArray(missing) }
  };
}
