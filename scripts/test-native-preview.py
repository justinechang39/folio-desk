#!/usr/bin/env python3
"""Local PDFKit stress check. Optional --pdf arguments stay on this Mac."""
import argparse
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'dist-release/Folio Native Preview.app/Contents/MacOS/folio-native-preview'
parser = argparse.ArgumentParser()
parser.add_argument('--pdf', action='append', default=[])
parser.add_argument('--name', default='native-preview')
parser.add_argument('--skip-build', action='store_true')
args = parser.parse_args()
if len(args.pdf) not in (0, 2):
    parser.error('Pass exactly two --pdf paths, or omit for synthetic fixtures.')
if Path(args.name).name != args.name:
    parser.error('--name must be a filename, not a path.')
if not args.skip_build:
    subprocess.run([str(ROOT / 'scripts/build-native-preview.sh')], cwd=ROOT, check=True)
output = ROOT / 'work' / args.name
output.mkdir(parents=True, exist_ok=True)


def run(paths, name, expect_success):
    report = output / (name + '.json')
    report.unlink(missing_ok=True)
    samples = []
    started = time.monotonic()
    with (output / (name + '.log')).open('w') as log:
        process = subprocess.Popen([str(APP), '--benchmark', '--report', str(report), *map(str, paths)], stdout=log, stderr=log)
        try:
            while process.poll() is None:
                if time.monotonic() - started > 180:
                    raise TimeoutError('Native workload exceeded 180 seconds')
                result = subprocess.run(['ps', '-o', 'rss=', '-p', str(process.pid)], capture_output=True, text=True)
                if result.stdout.strip():
                    samples.append({'seconds': round(time.monotonic() - started, 2), 'rssMiB': round(int(result.stdout.strip()) / 1024, 2)})
                time.sleep(0.5)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    assert (process.returncode == 0) == expect_success, (name, process.returncode, (output / (name + '.log')).read_text())
    data = json.loads(report.read_text())
    if expect_success:
        assert data['steps'] == 1800 and all(data['checks'].values()), data
        if data.get('snapshotAvailable'):
            assert report.with_suffix('.json.png').exists(), 'Missing rendered snapshot'
    else:
        assert data.get('error'), data
    data['elapsedSeconds'] = round(time.monotonic() - started, 2)
    data['processRSSPeakMiB'] = max((sample['rssMiB'] for sample in samples), default=0)
    data['memorySamples'] = samples
    report.write_text(json.dumps(data, indent=2) + '\n')
    print(name, json.dumps({k: v for k, v in data.items() if k != 'memorySamples'}), flush=True)
    return data

fixture = ROOT / 'tests/fixtures'
for invalid in ('invalid.pdf', 'notes.txt', 'locked.pdf'):
    run([fixture / invalid, fixture / 'answers.pdf'], 'reject-' + invalid, False)
paths = [Path(p).expanduser().resolve() for p in args.pdf] or [fixture / 'long.pdf', fixture / 'questions.pdf']
run(paths, 'stress', True)
print('Reports:', output)
