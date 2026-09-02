#!/usr/bin/env python3
"""Assemble Agent Tooling Tahoe mockups: per-screen preview pages + the gallery artifact."""
import os, re, html, glob, sys

BASE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(BASE, '..', 'render'))
os.makedirs(OUT, exist_ok=True)
CSS = open(os.path.join(BASE, 'shared.css'), encoding='utf-8').read()
SPRITE = open(os.path.join(BASE, 'sprite.html'), encoding='utf-8').read()
ORDER = ['overview','library','skill','mcp','discover','newskill','sync','activity','client','recs','settings']

def ic(name, cls='ic'):
    return f'<svg class="{cls}"><use href="#{name}"/></svg>'

SIDEBAR = [
    ('overview', 'Overview', ic('s-grid'), None),
    ('recs', 'Recommendations', ic('s-bulb'), '<span class="bdg">4</span>'),
    ('discover', 'Discover', ic('s-bag'), None),
    ('h', 'Manage'),
    ('library', 'Library', ic('s-books'), None),
    ('mcp', 'MCP Servers', ic('s-mcp'), None),
    ('sync', 'Sync', ic('s-sync'), '<span class="bdg">6</span>'),
    ('activity', 'Activity', ic('s-clock-arrow'), None),
    ('h', 'Clients'),
    ('client', 'Claude Code', '<svg class="mark"><use href="#b-claude"/></svg>', None),
    ('codex', 'Codex', '<svg class="mark codex"><use href="#b-codex"/></svg>', '<svg class="ic tw"><use href="#s-warn"/></svg>'),
    ('gemini', 'Gemini CLI', '<svg class="mark"><use href="#b-gemini"/></svg>', None),
]

def sidebar(active):
    parts = []
    for item in SIDEBAR:
        if item[0] == 'h':
            parts.append(f'<div class="sb-h">{item[1]}</div>')
            continue
        key, label, icon, trail = item
        on = ' on' if key == active else ''
        parts.append(f'<div class="it{on}">{icon}<span>{label}</span>{trail or ""}</div>')
    parts.append(f'<div class="sb-foot">{ic("s-check-c")}<span>Backed up yesterday, 6:12 PM</span></div>')
    return '<div class="sb">' + ''.join(parts) + '</div>'

MENUBAR = ('<div class="menubar"><span class="apple">&#xF8FF;</span><b>Agent Tooling</b><span>File</span><span>Edit</span>'
           '<span>View</span><span>Window</span><span>Help</span><span class="sp"></span>'
           '<span class="r"><span>Tue Sep 1</span><span>9:41 AM</span></span></div>')
TL = '<div class="tl"><i></i><i></i><i></i></div>'

def parse(path):
    src = open(path, encoding='utf-8').read()
    m = re.search(r'<!--\s*@screen\s+(.*?)-->', src, re.S)
    meta = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
    lede = re.search(r'<!--\s*@lede\s+(.*?)-->', src, re.S)
    meta['lede'] = lede.group(1).strip() if lede else ''
    meta['notes'] = [(a.strip(), b.strip()) for a, b in re.findall(r'<!--\s*@note\s+(.*?)\|(.*?)-->', src, re.S)]
    body = re.sub(r'<!--\s*@(screen|lede|note)\b.*?-->', '', src, flags=re.S).strip()
    meta['body'] = body
    return meta

def window(meta, frags):
    layout = meta.get('layout', 'window')
    if layout == 'window':
        return f'<div class="win">{TL}{sidebar(meta.get("sidebar"))}<div class="paper">{meta["body"]}</div></div>'
    if layout == 'sheet':
        back = frags[meta['backdrop']]
        return (f'<div class="win">{TL}{sidebar(back.get("sidebar"))}<div class="paper">{back["body"]}</div>'
                f'<div class="dim"></div>{meta["body"]}</div>')
    if layout == 'settings':
        return f'<div class="win settings">{TL}{meta["body"]}</div>'
    raise SystemExit('unknown layout ' + layout)

def scene(meta, frags, mode, live=''):
    return f'<div class="scene{live}" data-mode="{mode}"><div class="wall"></div>{MENUBAR}{window(meta, frags)}</div>'

def standalone(meta, frags, mode):
    return (f'<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(meta["title"])} — {mode}</title>'
            f'<style>{CSS}\nbody{{margin:0;background:#111;width:1320px;height:860px;overflow:hidden}}</style></head>'
            f'<body>{SPRITE}{scene(meta, frags, mode, " live")}</body></html>')

frags = {}
for p in glob.glob(os.path.join(BASE, 'screens', '*.html')):
    m = parse(p)
    frags[m['id']] = m

present = [k for k in ORDER if k in frags]
for k in present:
    for mode in ('light', 'dark'):
        open(os.path.join(OUT, f'{k}-{mode}.html'), 'w', encoding='utf-8').write(standalone(frags[k], frags, mode))

# ---------------- gallery ----------------
gallery_tpl = open(os.path.join(BASE, 'gallery.html'), encoding='utf-8').read() if os.path.exists(os.path.join(BASE, 'gallery.html')) else None
if gallery_tpl:
    nav = ''.join(f'<a href="#s-{k}">{html.escape(frags[k]["title"])}</a>' for k in present)
    sections = []
    for k in present:
        m = frags[k]
        notes = ''.join(f'<div><b>{html.escape(a)}</b>{b}</div>' for a, b in m['notes'])
        sections.append(
            f'<section class="shot" id="s-{k}"><header><h2 class="display">{html.escape(m["title"])}</h2>'
            f'<p>{m["lede"]}</p></header><div class="frame">{scene(m, frags, "light")}</div></section>'
            f'<div class="notes">{notes}</div>')
    page = (gallery_tpl.replace('{{CSS}}', CSS).replace('{{SPRITE}}', SPRITE)
            .replace('{{NAV}}', nav).replace('{{SECTIONS}}', ''.join(sections)))
    open(os.path.join(OUT, 'index.html'), 'w', encoding='utf-8').write(page)
    open(os.path.normpath(os.path.join(BASE, '..', 'index.html')), 'w', encoding='utf-8').write(page)
    open(os.path.join(OUT, 'preview.html'), 'w', encoding='utf-8').write(
        '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>:root{color-scheme:light dark}body{margin:0;font:14px -apple-system,BlinkMacSystemFont,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style>'
        '</head><body>' + page + '</body></html>')
    open(os.path.join(OUT, 'preview-dark.html'), 'w', encoding='utf-8').write(
        '<!doctype html><html data-theme="dark"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<style>:root{color-scheme:light dark}body{margin:0;font:14px -apple-system,BlinkMacSystemFont,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style>'
        '</head><body>' + page + '</body></html>')
    print('gallery:', len(page), 'bytes')
print('screens:', ', '.join(present))
