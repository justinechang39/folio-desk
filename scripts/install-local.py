#!/usr/bin/env python3
"""Install the locally built app after a graceful quit, with a compressed backup."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'dist-release/Folio Desk.app'
DESTINATION = Path('/Applications/Folio Desk.app')
PREVIEW = Path('/Applications/Folio Native Preview.app')
REGISTRY = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
parser = argparse.ArgumentParser()
parser.add_argument('--remove-preview', action='store_true')
args = parser.parse_args()

def identifier(app):
    with (app / 'Contents/Info.plist').open('rb') as file:
        return plistlib.load(file)['CFBundleIdentifier']

assert identifier(SOURCE) == 'io.github.justinechang39.foliodesk'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(SOURCE)], check=True)
for app, expected in [(DESTINATION, 'io.github.justinechang39.foliodesk'), (PREVIEW, 'io.github.justinechang39.foliodesk.nativepreview')]:
    if app == PREVIEW and not args.remove_preview: continue
    if app.exists():
        if app.is_symlink() or identifier(app) != expected:
            raise RuntimeError(f'Refusing to replace an unexpected app: {app}')
ids = ['io.github.justinechang39.foliodesk']
if args.remove_preview: ids.append('io.github.justinechang39.foliodesk.nativepreview')
swift = '''import AppKit
let ids = Set(CommandLine.arguments.dropFirst())
let apps = NSWorkspace.shared.runningApplications.filter { ids.contains($0.bundleIdentifier ?? "") }
for app in apps { _ = app.terminate() }
let until = Date().addingTimeInterval(20)
while apps.contains(where: { !$0.isTerminated }) && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
if apps.contains(where: { !$0.isTerminated }) { fputs("Folio has not quit. Finish any save dialog and retry.\\n", stderr); exit(1) }
'''
subprocess.run(['swift', '-e', swift, *ids], check=True)
data = Path.home() / 'Library/Application Support/io.github.justinechang39.foliodesk'
data.mkdir(parents=True, exist_ok=True)
session = data / 'session.json'
if session.exists():
    # Keep an exact snapshot even if the running old app just saved on quit.
    backup = data / ('session.install-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '.json')
    shutil.copy2(session, backup)
if DESTINATION.exists():
    backups = data / 'Backups'
    backups.mkdir(exist_ok=True)
    archive = backups / ('Folio-Desk-before-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '.zip')
    subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(DESTINATION), str(archive)], check=True)
    subprocess.run([REGISTRY, '-u', str(DESTINATION)], capture_output=True)
    shutil.rmtree(DESTINATION)
subprocess.run(['ditto', str(SOURCE), str(DESTINATION)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(DESTINATION)], check=True)
subprocess.run([REGISTRY, '-f', str(DESTINATION)], check=True)
if args.remove_preview and PREVIEW.exists():
    subprocess.run([REGISTRY, '-u', str(PREVIEW)], capture_output=True)
    shutil.rmtree(PREVIEW)
    print('Removed Folio Native Preview.')
subprocess.run(['open', str(DESTINATION)], check=True)
print('Installed and opened Folio Desk. Existing workspaces are preserved.')
