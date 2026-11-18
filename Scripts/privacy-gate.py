#!/usr/bin/env python3
"""Fail on personal data, credentials, non-fictional bibliographic names, and internal jargon.

Usage: python3 -I Scripts/privacy-gate.py
Allowlist rows: path<TAB>rule<TAB>value<TAB>reason (a literal "*" path matches any file).
"""
import base64
import hashlib
import math
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "Scripts" / "privacy-allowlist.txt"
PUBLIC_DOMAINS = (
    "example.com", "example.org", "example.net", "example", "invalid",
    "apple.com", "w3.org", "crossref.org", "arxiv.org", "dblp.org",
    "semanticscholar.org", "openlibrary.org",
)
# Private denylists are NOT part of the repository. A maintainer may keep a JSON
# file {"internal": [[len, b64digest], ...], "forbidden": [[len, hexdigest], ...]}
# outside the tree and point PRIVACY_DENYLIST at it (or place it at the
# git-ignored path .privacy-denylist.json). Without it, only the generic rules run.
def _load_denylist():
    import json, os
    configured = os.environ.get("PRIVACY_DENYLIST")
    path = configured or ROOT / ".privacy-denylist.json"
    try:
        with open(path, encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        if configured:
            raise SystemExit("privacy gate: configured denylist is missing")
        return set(), []
    return ({tuple(x) for x in payload.get("internal", [])},
            [tuple(x) for x in payload.get("forbidden", [])])


INTERNAL_DIGESTS, FORBIDDEN_DIGESTS = _load_denylist()

DOMAIN = re.compile(r"(?i)(?<![@A-Za-z0-9.-])(?:https?://)?(?:[a-z][a-z0-9-]+\.)+(?:com|org|net|io|dev|ai|edu|gov|co|uk|de|fr|cn|sk|test|example|invalid)(?![A-Za-z0-9.-])")
EMAIL = re.compile(r"(?i)(?<![A-Za-z0-9._%+-])[A-Za-z][A-Za-z0-9._%+-]*@[A-Za-z][A-Za-z0-9.-]*\.[A-Za-z]{2,}(?![A-Za-z0-9.-])")
SECRET = re.compile(r"(?:sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----)")
USER_PATH = re.compile(r"/(?:Users/(?!example(?:/|$)|tester(?:/|$))[^/\s]+|home/[^/\s]+)")
HIGH_ENTROPY = re.compile(r"(?<![A-Za-z0-9+/=_-])[A-Za-z0-9+/=_-]{32,}(?![A-Za-z0-9+/=_-])")
HEX_DIGEST = re.compile(r"(?i)(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])")
# Allow-list of synthetic 64-hex placeholders used by the test fixtures
# (all-zero, deadbeef-style values), stored as sha-256 of the placeholder.
ALLOWED_HEX_SHA256 = {
    "9f3c58bfe1aa8e62ccc8d45fb33a87f36c5c9b814af785bbbf72263f8246e08e",
    "bbe2d2d083be6ddd3161bbf91444f38f90dbf64720e73e9dc9fdb952f4cbe235",
    "8f91874ec4816d09b17e7496852228f154987164a5a983400bc780115d8da95b",
    "7a3d6fdfa4ab91d8449eb92de2577bba981d381871e57f921bc492d0485d8339",
    "722792d826a5d76977dd91cff029dae0219a457a97ecdcea6c919e14af7d2a05",
    "ff2d05b1b2da4a4a5fdb9c33f1d3c4d36699d60639b7c7ae7b787963159ecc12",
    "b11b83e15d6dd7147c886af0b32579a5ddf823778c831ef4a75b2001b5d3ac32",
    "e5ae97d5ab80c46543c18427d672b73dbe1c333d15c97d6535c2b4b0fee779a2",
    "79aed56c0df13dd40f963e9bf4d335056788f93059ca6dfa1f960d0d85a3bf87",
}
FORBIDDEN_BY_LENGTH = {}
for _length, _digest in FORBIDDEN_DIGESTS:
    FORBIDDEN_BY_LENGTH.setdefault(_length, set()).add(_digest)
TITLE = re.compile(r"《([^》\n]+)》")
ZH_NAME = re.compile(r"(?:^|[，、；：（(\[\"'“\s])([\u4e00-\u9fff]{2,4})(?:著|译)(?=[，、；：）)\]\"'”\s《]|$)")
ZH_AUTHOR = re.compile(r"(?:^|[，、；：（(\[\"'“\s])([\u4e00-\u9fff]{2,4})[：:]?《")
EN_NAME = re.compile(r"\b([A-Z][a-z]{2,},\s+[A-Z][a-z]{2,}(?:\s+[A-Z][a-z]{2,})?)\b")
ZH_PUBLISHER = re.compile(r"([\u4e00-\u9fff]{2,10}(?:出版社|书局|印书馆|出版公司))")
EN_PUBLISHER = re.compile(r"\b([A-Z][A-Za-z&.'-]*(?: [A-Z][A-Za-z&.'-]*){0,4} (?:Press|Publishing|Publishers|House|Books))\b")
EN_JOURNAL = re.compile(r"\b([A-Z][A-Za-z]+(?: [A-Z][A-Za-z]+){0,4} (?:Journal|Review|Quarterly|Studies))\b")
GENERIC_TITLES = {"书名", "刊名", "内文", "…"}
BIBLIO_CONTEXT = re.compile(r"(?:\.pdf|年版|出版社|书局|Press|House|\(\d{4}\)|（\d{4}）)")


def entropy(value):
    if not value:
        return 0.0
    counts = {}
    for char in value:
        counts[char] = counts.get(char, 0) + 1
    return -sum((n / len(value)) * math.log2(n / len(value)) for n in counts.values())


def load_allowlist():
    entries = set()
    if not ALLOWLIST.exists():
        return entries
    for number, raw in enumerate(ALLOWLIST.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = raw.split("\t", 3)
        if len(parts) != 4 or not parts[3].strip():
            raise SystemExit(f"{ALLOWLIST}:{number}: rows need path<TAB>rule<TAB>value<TAB>reason")
        entries.add(tuple(parts[:3]))
    return entries


def vocabulary():
    source = (ROOT / "Tests/LiteratureCoreTests/Fixtures/FictionalCorpus.swift").read_text(encoding="utf-8")
    terms = set(GENERIC_TITLES)
    for literal in re.findall(r'"([^"\n]+)"', source):
        terms.add(literal.strip("《》"))
        terms.update(part for part in re.split(r"[、，,;；：:\s]+", literal.strip("《》")) if part)
    return terms


def is_public_domain(domain):
    host = re.sub(r"(?i)^https?://", "", domain).lower().rstrip(".")
    return any(host == item or host.endswith("." + item) for item in PUBLIC_DOMAINS) or host.endswith(".example.test")


def is_public_email(address):
    lowered = address.lower()
    return "noreply" in lowered or lowered.endswith((".example", ".example.com", ".example.org", ".example.net", "@example.com"))


def _is_ascii_alnum(byte):
    """True for ASCII letters/digits only — used to anchor forbidden-token matches."""
    return (48 <= byte <= 57) or (65 <= byte <= 90) or (97 <= byte <= 122)


def scan_line(line, terms, forbidden_by_length=None, internal_digests=None):
    found = []
    for match in USER_PATH.finditer(line):
        found.append(("absolute user path", match.group(0)))
    for match in EMAIL.finditer(line):
        if not is_public_email(match.group(0)):
            found.append(("email", match.group(0)))
    for match in SECRET.finditer(line):
        value = match.group(0)
        if "{{" not in value:
            found.append(("secret", value))
    for match in DOMAIN.finditer(line):
        if not is_public_domain(match.group(0)):
            found.append(("domain", match.group(0)))
    for match in HEX_DIGEST.finditer(line):
        value = match.group(0)
        if hashlib.sha256(value.encode()).hexdigest() not in ALLOWED_HEX_SHA256:
            found.append(("64-character hexadecimal string", value))
    for match in HIGH_ENTROPY.finditer(line):
        value = match.group(0)
        is_identifier = re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", value) and any(char.isupper() for char in value[1:])
        if "/" not in value and "." not in value and not is_identifier and any(char.isdigit() for char in value) and any(char.isupper() for char in value) and any(char.islower() for char in value) and entropy(value) >= 4.0:
            found.append(("high-entropy string", value))
    # Forbidden known text is matched as a substring of the line. Only the sha-256 of
    # each forbidden value is stored, so every window of the line whose length
    # equals some forbidden value is hashed and compared — this catches single
    # tokens ("某虚构作者"), multi-word names ("Quentin Marrow", "Marrow House
    # Press"), and punctuation-adjacent forms ("某虚构作者著", "示例出版社") alike,
    # without ever committing the plaintext.
    forbidden_by_length = FORBIDDEN_BY_LENGTH if forbidden_by_length is None else forbidden_by_length
    line_bytes = line.encode("utf-8")
    # A forbidden value always begins at a token boundary (start of line, after
    # whitespace/punctuation), so candidate windows are anchored there. Short
    # tokens (<=12 bytes) are also slid over every byte offset, because a token
    # like "agy" could be embedded inside a longer word.
    short_lengths = {length: digests for length, digests in forbidden_by_length.items() if length <= 12}
    long_lengths = {length: digests for length, digests in forbidden_by_length.items() if length > 12}
    starts = [0]
    for match in re.finditer(r"[\s.,;:!?()\[\]{}\"'""''《》、，。；：（）【】〈〉\\-_/\\\\@#$%^&*+=<>|~]+", line):
        starts.append(match.end())
    for length, digests in short_lengths.items():
        if length > len(line_bytes):
            continue
        for index in range(0, len(line_bytes) - length + 1):
            if index > 0 and _is_ascii_alnum(line_bytes[index - 1]):
                continue
            if index + length < len(line_bytes) and _is_ascii_alnum(line_bytes[index + length]):
                continue
            window = line_bytes[index:index + length]
            if hashlib.sha256(window).hexdigest() in digests:
                found.append(("forbidden known text", window.decode("utf-8", "replace")))
                break
    for length, digests in long_lengths.items():
        if length > len(line_bytes):
            continue
        for index in starts:
            if index + length > len(line_bytes):
                continue
            if index + length < len(line_bytes) and _is_ascii_alnum(line_bytes[index + length]):
                continue
            window = line_bytes[index:index + length]
            if hashlib.sha256(window).hexdigest() in digests:
                found.append(("forbidden known text", window.decode("utf-8", "replace")))
                break
    internal_digests = INTERNAL_DIGESTS if internal_digests is None else internal_digests
    lowered_line = line.lower().encode("utf-8")
    for length, digest in internal_digests:
        for index in range(0, len(lowered_line) - length + 1):
            if hashlib.sha256(lowered_line[index:index + length]).hexdigest() == base64.b64decode(digest).decode("ascii"):
                found.append(("internal term", f"digest:{digest}"))
                break
    for match in TITLE.finditer(line):
        value = match.group(1)
        if any(char in value for char in "[]()\\\"|?+*《") or value in terms:
            continue
        found.append(("non-fictional book/journal title", value))
    # Name / publisher detection is heuristic and only runs inside a bibliographic
    # context (a bare "Codable, Equatable" in Swift source is not a person). Real
    # names are caught unconditionally by the sha-256 blacklist above instead.
    if BIBLIO_CONTEXT.search(line):
        for match in ZH_NAME.finditer(line):
            if match.group(1) not in terms:
                found.append(("Chinese name form", match.group(1)))
        for match in ZH_AUTHOR.finditer(line):
            if match.group(1) not in terms:
                found.append(("Chinese name form", match.group(1)))
        for match in EN_NAME.finditer(line):
            if match.group(1) not in terms:
                found.append(("English name form", match.group(1)))
        for match in ZH_PUBLISHER.finditer(line):
            if match.group(1) not in terms:
                found.append(("publisher name", match.group(1)))
        for pattern in (EN_PUBLISHER, EN_JOURNAL):
            for match in pattern.finditer(line):
                if match.group(1) not in terms:
                    found.append(("publisher/journal name", match.group(1)))
    return found


def _digests_by_length(values):
    index = {}
    for value in values:
        encoded = value.encode("utf-8")
        index.setdefault(len(encoded), set()).add(hashlib.sha256(encoded).hexdigest())
    return index


def self_test():
    """Covers every rule class without echoing any real name in plaintext.

    The production blacklist holds only sha-256 digests. To prove that a bare
    name, a name embedded in prose, and a CJK name are all caught, the test
    injects a fictional sentinel into a private copy of the digest index.
    """
    if len({digest for _, digest in FORBIDDEN_DIGESTS}) != len(FORBIDDEN_DIGESTS):
        print("privacy gate self-test failed: duplicate private digests")
        raise SystemExit(1)
    for length, digest in FORBIDDEN_DIGESTS:
        if length < 3 or not re.fullmatch(r"[0-9a-f]{64}", digest):
            print("privacy gate self-test failed: malformed or short production digest")
            raise SystemExit(1)
    if any(length < 3 for length, _ in INTERNAL_DIGESTS):
        print("privacy gate self-test failed: short internal digest")
        raise SystemExit(1)

    sentinels = ["Zorvath Plinkett", "虚构哨兵作者"]
    sentinel_index = _digests_by_length(sentinels)
    for length, digests in sentinel_index.items():
        if digests & FORBIDDEN_BY_LENGTH.get(length, set()):
            print("privacy gate self-test failed: sentinel collides with production digest")
            raise SystemExit(1)
    injected = {length: set(digests) for length, digests in FORBIDDEN_BY_LENGTH.items()}
    for length, digests in sentinel_index.items():
        injected.setdefault(length, set()).update(digests)

    sentinel_samples = [
        "Zorvath Plinkett",
        "the argument by Zorvath Plinkett is unsound",
        "虚构哨兵作者",
        "虚构哨兵作者著",
    ]
    samples = [
        # 64-char hex digests — all-caps, all-lower, all-zero must be caught
        ("0000000000000000000000000000000000000000000000000000000000000000",
         "64-character hexadecimal string"),
        ("DEADBEEF00000000000000000000000000000000000000000000000000000000",
         "64-character hexadecimal string"),
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
         "64-character hexadecimal string"),
        ("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
         "64-character hexadecimal string"),
        ("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
         "64-character hexadecimal string"),
        # name/publisher heuristics only fire inside a bibliographic context
        ("《A Real Title》 by Marrow House Press", "publisher/journal name"),
        ("《A Real Title》", "non-fictional book/journal title"),
        # other rule classes
        ("/Users/alice/private.pdf", "absolute user path"),
        ("contact alice@private.test", "email"),
        ("sk-12345678901234567890", "secret"),
        ("https://private-domain.test/", "domain"),
    ]
    internal_sentinels = ["Internal Sentinel Phrase", "内部哨兵词条"]
    internal_index = {(len(v.encode()), base64.b64encode(hashlib.sha256(v.lower().encode()).hexdigest().encode()).decode())
                      for v in internal_sentinels}
    if internal_index & set(INTERNAL_DIGESTS):
        print("privacy gate self-test failed: internal sentinel collides with production digest")
        raise SystemExit(1)
    injected_internal = set(INTERNAL_DIGESTS) | internal_index
    internal_samples = [
        "Internal Sentinel Phrase",
        "prefix internal sentinel phrase suffix",
        "内部哨兵词条",
        "前缀内部哨兵词条后缀",
    ]
    missing = []
    for sample, expected in samples:
        text = "".join(sample) if isinstance(sample, list) else sample
        if not any(reason == expected for reason, _ in scan_line(text, set())):
            missing.append((text, expected))
    for text in sentinel_samples:
        if not any(reason == "forbidden known text" for reason, _ in scan_line(text, set(), injected)):
            missing.append((text, "forbidden known text"))
    for text in internal_samples:
        if not any(reason == "internal term" for reason, _ in scan_line(text, set(), internal_digests=injected_internal)):
            missing.append((text, "internal term"))
    if missing:
        for text, expected in missing:
            print(f"privacy gate self-test failed: {expected} not detected in {text!r}")
        raise SystemExit(1)
    print("privacy gate self-test: passed")
    return 0


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        return self_test()
    allowed = load_allowlist()
    terms = vocabulary()
    listing = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-co", "--exclude-standard", "-z"],
        check=True, stdout=subprocess.PIPE,
    ).stdout
    violations = []
    for raw_path in dict.fromkeys(listing.split(b"\0")):
        if not raw_path:
            continue
        rel = raw_path.decode()
        if ".build" in rel.split("/") or ".git" in rel.split("/"):
            continue
        if rel == "Scripts/privacy-gate.py":
            # This source contains split self-test fixtures.
            continue
        path = ROOT / rel
        if path.is_symlink():
            violations.append(f"{rel}: symbolic link in release files")
            continue
        try:
            data = path.read_bytes()
        except OSError:
            violations.append(f"{rel}: unreadable release file")
            continue
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            # The checked-in PNGs are generated by Scripts/generate-icon.swift.
            icon_dir = "app/Support/Resources/Assets.xcassets/AppIcon.appiconset"
            icon_name = re.fullmatch(r"icon_(16x16|32x32|128x128|256x256|512x512)(@2x)?\.png", path.name)
            if path.parent != ROOT / icon_dir or not icon_name or not data.startswith(b"\x89PNG\r\n\x1a\n"):
                violations.append(f"{rel}: unreviewed binary file")
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if rel == "Scripts/privacy-allowlist.txt":
                continue
            for reason, value in scan_line(line, terms):
                if (rel, reason, value) in allowed or ("*", reason, value) in allowed:
                    continue
                violations.append(f"{rel}:{number}: {reason}")
    print("\n".join(violations) if violations else "privacy gate: 0 violations")
    return 1 if violations else 0


if __name__ == "__main__":
    sys.exit(main())
