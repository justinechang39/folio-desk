#!/usr/bin/env python3
"""Collect dependency license files into the distributable, without local paths."""
import json, pathlib, subprocess
root=pathlib.Path(__file__).resolve().parent.parent
output=['Folio Desk — third-party license texts\n\nSee THIRD_PARTY_NOTICES.md for the dependency overview.\n']
def add(name,version,license,directory,explicit=None):
    output.append(f'\n{"="*72}\n{name} {version}\nDeclared license: {license}\n')
    found=[]
    if explicit and (directory/explicit).is_file():found.append(directory/explicit)
    found += [p for p in directory.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','LICENCE','COPYING','NOTICE','COPYRIGHT'))]
    for path in sorted(set(found)):
        output.append(f'\n--- {path.name} ---\n'+path.read_text(errors='replace')+'\n')
metadata=json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version','1','--filter-platform','aarch64-apple-darwin'],cwd=root))
for p in sorted(metadata['packages'],key=lambda p:(p['name'],p['version'])):
    if p['name']=='folio-desk':continue
    add(p['name'],p['version'],p.get('license','See upstream license'),pathlib.Path(p['manifest_path']).parent,p.get('license_file'))
(root/'licenses').mkdir(exist_ok=True)
(root/'licenses/ThirdPartyLicenses.txt').write_text(''.join(output))
