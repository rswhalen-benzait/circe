#!/usr/bin/env python3
"""Keep the installer self-contained: embed the canonical media helpers verbatim."""
from pathlib import Path
import argparse

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
directory = Path(__file__).resolve().parent
installer = directory / 'setup-circe-host.sh'
text = installer.read_text()
generated = text
for helper in ('video', 'audio'):
    source = (directory / f'circe-{helper}.sh').read_text()
    marker = f'CIRCE {helper.upper()} WRAPPER'
    begin = f'# BEGIN GENERATED {marker}\n'
    end = f'# END GENERATED {marker}\n'
    assert generated.count(begin) == 1 and generated.count(end) == 1, f'Installer must have exactly one {helper} block'
    before, remaining = generated.split(begin, 1)
    _, after = remaining.split(end, 1)
    delimiter = f'CIRCE_{helper.upper()}_WRAPPER'
    generated = before + begin + f'write_user_file "$LIBEXEC/{helper}" 700 <<\'{delimiter}\'\n' + source + delimiter + '\n' + end + after
if args.check:
    if generated != text:
        raise SystemExit('Embedded media helpers are stale; run python3 scripts/linux/embed-video-wrapper.py')
else:
    installer.write_text(generated)
