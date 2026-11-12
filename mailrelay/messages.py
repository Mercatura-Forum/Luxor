"""The four messages a hotel owes a guest, and the owner's test email, in English and Arabic.

Each is written from the chain's own figures (`mailDue_u`, the same figures the guest's manage page shows),
in the language the guest booked in: plain service messages about one booking, no marketing. They carry the
booking's reference and never a link that can change the booking: the guest keeps the link from their
confirmation page, and a reply reaches the hotel's own address.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""
import datetime, html
from dataclasses import dataclass

DAYS_EN = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
DAYS_AR = ["الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت", "الأحد"]
MONTHS_EN = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
MONTHS_AR = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو", "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"]


@dataclass
class Message:
    to: str
    to_name: str
    subject: str
    text: str
    html: str
    lang: str
    message_id: str     # the same for every attempt of one message: a duplicate is recognisable as one


def day_text(day, lang):
    d = datetime.date(1970, 1, 1) + datetime.timedelta(days=int(day))
    if lang == "ar":
        return f"{DAYS_AR[d.weekday()]} {d.day} {MONTHS_AR[d.month - 1]} {d.year}"
    return f"{DAYS_EN[d.weekday()]} {d.day} {MONTHS_EN[d.month - 1]} {d.year}"


def money(amount, minor_units, currency):
    units = int(minor_units)
    whole, frac = divmod(int(amount), 10 ** units) if units else (int(amount), 0)
    body = f"{whole:,}" + (f".{frac:0{units}d}" if units else "")
    return f"{body} {currency}"


def clean(text):
    """A value from the chain put in a message: no line breaks (so never a header of its own)."""
    return " ".join(str(text).split())


def _lines(row, hotel, lang):
    m = lambda x: money(x, hotel["minorUnits"], hotel["currency"])
    nights = int(row["departure"]) - int(row["arrival"])
    room = clean(row["roomAr"] if lang == "ar" and row["roomAr"] else row["roomEn"])
    plan = clean(row["planAr"] if lang == "ar" and row["planAr"] else row["planEn"])
    if lang == "ar":
        return [
            ("رقم الحجز", row["ref"]),
            ("الوصول", day_text(row["arrival"], "ar") + (f"، من {clean(hotel['checkInText'])}" if hotel.get("checkInText") else "")),
            ("المغادرة", day_text(row["departure"], "ar") + (f"، حتى {clean(hotel['checkOutText'])}" if hotel.get("checkOutText") else "")),
            ("الإقامة", f"{nights} ليلة، {row['rooms']} غرفة، {room}"),
            ("السعر", plan),
            ("الضيوف", f"{row['adults']} بالغ" + (f"، {row['children']} طفل" if int(row["children"]) else "")),
            ("الإجمالي", m(int(row["charged"]) - int(row["credited"]))),
            ("المدفوع", m(row["paid"])),
            ("المتبقي", m(row["outstanding"])),
        ]
    return [
        ("Reference", row["ref"]),
        ("Arrival", day_text(row["arrival"], "en") + (f", from {clean(hotel['checkInText'])}" if hotel.get("checkInText") else "")),
        ("Departure", day_text(row["departure"], "en") + (f", by {clean(hotel['checkOutText'])}" if hotel.get("checkOutText") else "")),
        ("Stay", f"{nights} night{'s' if nights != 1 else ''}, {row['rooms']} room{'s' if int(row['rooms']) != 1 else ''}, {room}"),
        ("Rate", plan),
        ("Guests", f"{row['adults']} adult{'s' if int(row['adults']) != 1 else ''}" + (f", {row['children']} child{'ren' if int(row['children']) != 1 else ''}" if int(row["children"]) else "")),
        ("Total", m(int(row["charged"]) - int(row["credited"]))),
        ("Paid", m(row["paid"])),
        ("Balance", m(row["outstanding"])),
    ]


def render(row, hotel, to, contract):
    """The message owed for one outbox row. `hotel` is `mailerSetup_u`'s row; `to` the opened address."""
    lang = "ar" if row["lang"] == "ar" else "en"
    name = clean(hotel["nameAr"] if lang == "ar" and hotel.get("nameAr") else hotel["nameEn"])
    guest = clean(row["guestName"])
    kind = row["kind"]
    m = lambda x: money(x, hotel["minorUnits"], hotel["currency"])
    if lang == "ar":
        subject, opening = {
            "confirmation": (f"تأكيد حجزك في {name} ({row['ref']})", f"أهلاً {guest}، تم تأكيد حجزك. هذه تفاصيله."),
            "preArrival": (f"نراك {day_text(row['arrival'], 'ar')} في {name}", f"أهلاً {guest}، نتطلع لاستقبالك بعد يومين. هذه تفاصيل إقامتك."),
            "receipt": (f"إيصال إقامتك في {name} ({row['ref']})", f"شكراً لإقامتك معنا يا {guest}. هذا إيصالك."),
            "cancellation": (f"إلغاء حجزك في {name} ({row['ref']})", f"أهلاً {guest}، تم إلغاء حجزك."),
        }[kind]
    else:
        subject, opening = {
            "confirmation": (f"Your booking at {name} is confirmed ({row['ref']})", f"Dear {guest}, your booking is confirmed. Here are its details."),
            "preArrival": (f"See you on {day_text(row['arrival'], 'en')} at {name}", f"Dear {guest}, we look forward to welcoming you in two days. Here is your stay."),
            "receipt": (f"Your receipt from {name} ({row['ref']})", f"Thank you for staying with us, {guest}. Here is your receipt."),
            "cancellation": (f"Your booking at {name} is cancelled ({row['ref']})", f"Dear {guest}, your booking has been cancelled."),
        }[kind]
    lines = _lines(row, hotel, lang)
    extra = []
    if kind == "receipt":
        extra = [("الغرف", m(row["roomTotal"])), ("الإضافات", m(row["extras"])), ("الضرائب", m(row["taxes"]))] if lang == "ar" else \
                [("Rooms", m(row["roomTotal"])), ("Extras", m(row["extras"])), ("Taxes", m(row["taxes"]))]
    if kind == "confirmation" and row.get("refundable") in (True, "true") and int(row.get("cancelDeadline", 0)):
        extra = [("الإلغاء المجاني حتى", day_text(row["cancelDeadline"], "ar"))] if lang == "ar" else [("Free cancellation until", day_text(row["cancelDeadline"], "en"))]
    if kind == "cancellation" and int(row.get("charged", 0)) > int(row.get("credited", 0)):
        extra = [("رسوم الإلغاء", m(int(row["charged"]) - int(row["credited"])))] if lang == "ar" else [("Cancellation fee", m(int(row["charged"]) - int(row["credited"])))]
    closing = ("لتعديل الحجز أو إلغائه استخدم الرابط الذي حفظته عند الحجز، أو رد على هذه الرسالة." if lang == "ar"
               else "To change or cancel, use the link you saved when you booked, or reply to this email.")
    if kind in ("receipt", "cancellation"):
        closing = "للاستفسار رد على هذه الرسالة." if lang == "ar" else "For any question, reply to this email."
    return _assemble(to, guest, subject, opening, lines + extra, closing, name, lang, f"<outbox-{contract}-{row['outboxId']}@luxor.mail>")


def test_message(to, hotel, lang="en", contract=0):
    name = clean(hotel.get("nameEn") or "your hotel")
    if lang == "ar":
        return _assemble(to, "", f"البريد الإلكتروني للضيوف متصل ({clean(hotel.get('nameAr') or name)})",
                         "هذه رسالة تجريبية. إذا وصلتك، فإن حساب البريد الذي ربطته يعمل، ويمكنك تشغيل رسائل الضيوف.", [], "", name, "ar",
                         f"<test-{contract}@luxor.mail>")
    return _assemble(to, "", f"Guest email is connected ({name})",
                     "This is a test. If it reached you, the email account you connected works and you can turn guest email on.", [], "", name, "en",
                     f"<test-{contract}@luxor.mail>")


def _assemble(to, to_name, subject, opening, lines, closing, hotel_name, lang, message_id):
    width = max((len(k) for k, _ in lines), default=0)
    text = "\n".join([opening, ""] + [f"{k.ljust(width)}  {v}" for k, v in lines] + ([""] if lines else []) + ([closing, ""] if closing else []) + [hotel_name])
    d = ' dir="rtl"' if lang == "ar" else ""
    rows = "".join(f"<tr><td style=\"padding:4px 12px 4px 0;color:#555\">{html.escape(k)}</td><td style=\"padding:4px 0\">{html.escape(str(v))}</td></tr>" for k, v in lines)
    body = (f"<!doctype html><html lang=\"{lang}\"{d}><body style=\"font-family:system-ui,sans-serif;line-height:1.5;color:#111\">"
            f"<p>{html.escape(opening)}</p>" + (f"<table>{rows}</table>" if lines else "") +
            (f"<p>{html.escape(closing)}</p>" if closing else "") + f"<p style=\"color:#555\">{html.escape(hotel_name)}</p></body></html>")
    return Message(to=to, to_name=to_name, subject=clean(subject), text=text, html=body, lang=lang, message_id=message_id)
