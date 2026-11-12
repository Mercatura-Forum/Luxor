"""The little Candid the relay speaks: arguments of nat, text and bool, and replies decoded from their
bytes (vectors of records of nat, int, text and bool, with options), so a guest's name in Arabic comes
back exactly as the contract holds it, never through a printer's escapes.

Attribution: Thebes Core Team. Licence: Apache 2.0.
"""

PRIM = {-1: "null", -2: "bool", -3: "nat", -4: "int", -5: "nat8", -15: "text", -24: "principal", -8: "nat64", -7: "nat32"}


def uleb(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def sleb(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if (n == 0 and not b & 0x40) or (n == -1 and b & 0x40):
            out.append(b)
            return bytes(out)
        out.append(b | 0x80)


def field_hash(name):
    h = 0
    for b in name.encode():
        h = (h * 223 + b) % (1 << 32)
    return h


def encode(args):
    """args: a list of (type, value), type nat, text or bool."""
    code = {"nat": -3, "text": -15, "bool": -2}
    out = bytearray(b"DIDL") + uleb(0) + uleb(len(args))
    for t, _ in args:
        out += sleb(code[t])
    for t, v in args:
        if t == "nat":
            out += uleb(int(v))
        elif t == "bool":
            out += bytes([1 if v else 0])
        else:
            b = v.encode()
            out += uleb(len(b)) + b
    return bytes(out)


class _Reader:
    def __init__(self, data):
        self.d, self.i = data, 0

    def byte(self):
        if self.i >= len(self.d):
            raise ValueError("a reply that ends early")
        b = self.d[self.i]
        self.i += 1
        return b

    def take(self, n):
        if self.i + n > len(self.d):
            raise ValueError("a reply that ends early")
        b = self.d[self.i:self.i + n]
        self.i += n
        return b

    def uleb(self):
        n = shift = 0
        while True:
            b = self.byte()
            n |= (b & 0x7F) << shift
            shift += 7
            if not b & 0x80:
                return n

    def sleb(self):
        n = shift = 0
        while True:
            b = self.byte()
            n |= (b & 0x7F) << shift
            shift += 7
            if not b & 0x80:
                return n - (1 << shift) if b & 0x40 else n


def decode(data):
    """The reply's values. A record is a dict keyed by field hash; `named` maps names onto it."""
    r = _Reader(bytes(data))
    if r.take(4) != b"DIDL":
        raise ValueError("not a Candid reply")
    table = []
    for _ in range(r.uleb()):
        op = r.sleb()
        if op in (-19, -18):        # vec, opt
            table.append((op, r.sleb()))
        elif op == -20:             # record
            fields = [(r.uleb(), r.sleb()) for _ in range(r.uleb())]
            table.append((op, fields))
        else:
            raise ValueError(f"a type the relay does not read ({op})")
    types = [r.sleb() for _ in range(r.uleb())]

    def value(t):
        if t >= 0:
            op, inner = table[t]
            if op == -19:
                n = r.uleb()
                if inner == -5:
                    return r.take(n)
                return [value(inner) for _ in range(n)]
            if op == -18:
                return value(inner) if r.byte() else None
            return {h: value(ft) for h, ft in inner}
        kind = PRIM.get(t)
        if kind == "nat":
            return r.uleb()
        if kind == "int":
            return r.sleb()
        if kind == "bool":
            return r.byte() == 1
        if kind == "text":
            return r.take(r.uleb()).decode("utf-8")
        if kind == "nat8":
            return r.byte()
        if kind == "nat32":
            return int.from_bytes(r.take(4), "little")
        if kind == "nat64":
            return int.from_bytes(r.take(8), "little")
        if kind == "null":
            return None
        if kind == "principal":
            if r.byte() != 1:
                raise ValueError("an opaque principal")
            return r.take(r.uleb()).hex()
        raise ValueError(f"a type the relay does not read ({t})")

    return [value(t) for t in types]


def named(record, names):
    """A record's fields under their names; a name the record lacks is left out."""
    out = {}
    for n in names:
        h = field_hash(n)
        if h in record:
            out[n] = record[h]
    return out
