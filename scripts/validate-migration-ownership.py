#!/usr/bin/env python3
"""Fail closed when the reviewed ChezMoi inventory loses an ownership mapping."""
import json
import os
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parent.parent
inventory=json.loads((root/'migration/chezmoi-af63b22.inventory.json').read_text())
ownership=json.loads((root/'migration/ownership.json').read_text())
source=Path(os.environ.get('CHEZMOI_REFERENCE_SOURCE', Path.home()/'.local/share/chezmoi'))
if inventory['sourceCommit'] != ownership['sourceCommit']:
 raise SystemExit('migration ownership: source commits differ')
allowed={'home-manager','runtime-proton-pass','retired'}
paths=ownership['paths']
if len(paths) != len(inventory['items']):
 raise SystemExit('migration ownership: path count differs from inventory')
for item in inventory['items']:
 entry=paths.get(item['path'])
 if entry is None:
  raise SystemExit(f"migration ownership: unmapped path {item['path']}")
 if entry['owner'] not in allowed or entry['owner'] != item['owner'] or entry['treatment'] != item['treatment']:
  raise SystemExit(f"migration ownership: invalid owner/treatment for {item['path']}")
 replacement=root/entry.get('replacement','')
 if not replacement.is_file():
  raise SystemExit(f"migration ownership: missing concrete replacement for {item['path']}: {replacement}")
# chezmoi managed omits dotfiles nested below managed directories on this
# reference. Verify the source tree directly so .nvim/.gitignore and similar
# leaves cannot disappear from the inventory unnoticed.
try:
 nvim_source_files=subprocess.check_output(
  ['git','-C',str(source),'ls-files','-z','--','dot_config/nvim'], text=False
 ).split(b'\0')
except (OSError, subprocess.CalledProcessError) as error:
 raise SystemExit(f'migration ownership: cannot inspect canonical source: {error}')
for raw in nvim_source_files:
 if not raw:
  continue
 relative=raw.decode()
 target='.config/nvim/'+relative.removeprefix('dot_config/nvim/')
 if target not in paths:
  raise SystemExit(f'migration ownership: nvim source leaf missing from inventory: {target}')
print(f'migration ownership: PASSED ({len(paths)} canonical paths mapped; nvim source complete)')
