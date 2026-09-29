#!/usr/bin/env python3
"""Package the upstream translation catalog without any network build step."""
import json
from pathlib import Path
root=Path(__file__).resolve().parent.parent
resources=root/'build/Codenotch Local.app/Contents/Resources'
catalog=json.loads((root/'Sources/Localizable.xcstrings').read_text())
by_language={}
for key, entry in catalog['strings'].items():
    for language, localized in entry.get('localizations',{}).items():
        value=localized.get('stringUnit',{}).get('value')
        if value is not None:
            by_language.setdefault(language,{})[key]=value
for language, entries in by_language.items():
    folder=resources/(language+'.lproj');folder.mkdir(parents=True,exist_ok=True)
    def quote(s):
        return '"'+s.replace('\\','\\\\').replace('"','\\"').replace('\n','\\n').replace('\r','\\r')+'"'
    (folder/'Localizable.strings').write_text('\n'.join(f'{quote(k)} = {quote(v)};' for k,v in entries.items()))
