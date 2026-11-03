#!/usr/bin/env python3
"""Pick the distribution identity an export signs with, by its SHA-1.

The export plists name the certificate "Apple Distribution", which xcodebuild reads as "the newest installed identity of
that name". On a Mac holding two (one made there, one imported from another Mac), the newest can be one the App Store
profiles don't include, and the export fails ("Provisioning profile … doesn't include signing certificate …"). So this
finds the one Apple Distribution identity that every profile the export names holds and that this keychain can sign
with, and writes a copy of the export plist with signingCertificate set to its SHA-1; everything else in it stays. None,
several, a named profile not installed, or two installed copies of one profile that hold different certificates: it
stops and names the profiles and the hashes. Where several qualify, EXPORT_SIGNING_SHA1 may name one of them (and only
one of them) to sign with; it never picks on its own.

    [EXPORT_SIGNING_SHA1=<hash>] export-identity.py <ExportOptions plist> <the copy to write>

For tests: --profiles DIR (a folder of profiles; there a profile may be a plain plist) and --identities FILE (what
`security find-identity -v -p codesigning` prints).
"""
import argparse
import datetime
import glob
import hashlib
import os
import plistlib
import re
import subprocess
import sys

PROFILES = os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")


def short(hashes):
    return " ".join(sorted(h[:8] for h in hashes)) or "none"


def read_profile(path, plain_ok):
    with open(path, "rb") as f:
        data = f.read()
    if plain_ok and data.lstrip().startswith((b"<?xml", b"bplist")):
        return plistlib.loads(data)
    out = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True)
    return plistlib.loads(out.stdout) if out.returncode == 0 and out.stdout else None


def distribution_identities(listing):
    # The valid identities only (-v), "  5) 3CD0…D988 "Apple Distribution: Name (TEAM)"".
    return {m.group(1) for m in re.finditer(r'^\s*\d+\)\s+([0-9A-F]{40})\s+"Apple Distribution: ', listing, re.M)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("export_options")
    ap.add_argument("out")
    ap.add_argument("--profiles")
    ap.add_argument("--identities")
    a = ap.parse_args()

    with open(a.export_options, "rb") as f:
        opts = plistlib.load(f)
    team = opts.get("teamID")
    names = sorted(set(opts.get("provisioningProfiles", {}).values()))
    if not names:
        sys.exit(f"{a.export_options} names no provisioning profiles.")

    # Each named profile as installed: expired copies and other teams' are skipped, as Xcode skips them.
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    copies = {}
    for path in sorted(glob.glob(os.path.join(a.profiles or PROFILES, "*"))):
        p = read_profile(path, plain_ok=bool(a.profiles))
        if not p or p.get("Name") not in names:
            continue
        expires = p.get("ExpirationDate")
        if expires and expires.replace(tzinfo=None) < now:
            continue
        if team and team not in p.get("TeamIdentifier", []):
            continue
        certs = frozenset(hashlib.sha1(c).hexdigest().upper() for c in p.get("DeveloperCertificates", []))
        copies.setdefault(p["Name"], []).append((os.path.basename(path), certs))

    missing = [n for n in names if n not in copies]
    if missing:
        sys.exit("No installed profile named " + ", ".join(f'"{n}"' for n in missing) + ".")
    held = {}
    for n in names:
        if len({c for _, c in copies[n]}) > 1:
            listed = "; ".join(f"{f}: {short(c)}" for f, c in copies[n])
            sys.exit(f'Two installed copies of "{n}" hold different certificates ({listed}). Remove the stale one.')
        held[n] = copies[n][0][1]

    if a.identities:
        with open(a.identities) as f:
            listing = f.read()
    else:
        listing = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"], capture_output=True, text=True).stdout
    have = distribution_identities(listing)
    common = set.intersection(*(set(c) for c in held.values())) & have
    # Where two or more qualify (both certificates in every profile and in this keychain), any of them signs, but which is
    # the person's choice: EXPORT_SIGNING_SHA1 names one, and only one of those qualifying is taken.
    chosen = os.environ.get("EXPORT_SIGNING_SHA1", "").strip().upper()
    lines = "\n".join(f'  "{n}": {short(held[n])}' for n in names)
    if chosen and chosen not in common:
        sys.exit(f"EXPORT_SIGNING_SHA1 {chosen} isn't an Apple Distribution identity in this keychain held by every profile "
                 f"the export uses ({short(common)}).\n  keychain: {short(have)}\n{lines}")
    if chosen:
        common = {chosen}
    if len(common) != 1:
        choose = "\n  Set EXPORT_SIGNING_SHA1 to the full hash of one of them to sign with it." if common else ""
        sys.exit(f"{'No' if not common else 'More than one'} Apple Distribution identity in this keychain is held by every "
                 f"profile the export uses ({short(common)}).\n  keychain: {short(have)}\n{lines}{choose}")

    sha = common.pop()
    opts["signingCertificate"] = sha
    with open(a.out, "wb") as f:
        plistlib.dump(opts, f)
    print(f"    signing with Apple Distribution {sha}, held by: " + ", ".join(names))


if __name__ == "__main__":
    main()
