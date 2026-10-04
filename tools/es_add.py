#!/usr/bin/env python3
"""Add or replace Spanish UI strings in quickshell/es.js.

usage: tools/es_add.py pairs.json      ({"English source text": "Spanish", ...})

Keys are the exact English text as written in shell.qml (or the backend);
tests/run.sh fails on keys that no longer appear anywhere.
"""
import json, os, sys

p = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'quickshell', 'es.js')
t = open(p, encoding='utf-8').read()
pairs = json.load(open(sys.argv[1], encoding='utf-8'))
head, rest = t.split('var ES = {\n', 1)
body, tail = rest.split('\n};', 1)
lines = body.split('\n')
def q(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
for k, v in pairs.items():
    key = q(k)
    lines = [l for l in lines if not l.startswith('    ' + key + ': ')]
    lines.append('    %s: %s,' % (key, q(v)))
lines.sort(key=lambda l: l.strip())
open(p, 'w', encoding='utf-8').write(head + 'var ES = {\n' + '\n'.join(l for l in lines if l.strip()) + '\n};' + tail)
print('%d string(s) in es.js' % len(pairs))
