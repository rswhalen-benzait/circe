#!/usr/bin/env python3
"""Keep the installer self-contained: embed the canonical video wrapper verbatim."""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
directory = Path(__file__).resolve().parent
installer = directory / 'setup-circe-host.sh'
source = (directory / 'circe-video.sh').read_text()
begin = '# BEGIN GENERATED CIRCE VIDEO WRAPPER\n'
end = '# END GENERATED CIRCE VIDEO WRAPPER\n'
text = installer.read_text()
assert text.count(begin) == 1 and text.count(end) == 1, 'Installer must have exactly one wrapper block'
before, remaining = text.split(begin, 1)
_, after = remaining.split(end, 1)
generated = before + begin + 'write_user_file "$LIBEXEC/video" 700 <<\'CIRCE_VIDEO_WRAPPER\'\n' + source + 'CIRCE_VIDEO_WRAPPER\n' + end + after
if args.check:
    if generated != text:
        raise SystemExit('Embedded video wrapper is stale; run python3 scripts/linux/embed-video-wrapper.py')
else:
    installer.write_text(generated)
