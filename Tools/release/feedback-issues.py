#!/usr/bin/env python3
"""Pull TestFlight feedback (screenshot notes) and crash submissions from App Store Connect and
file each new one as a GitHub issue on the tracker, so testers' reports land on the same board
as everything else.

    Tools/release/feedback-issues.py                       # file everything new
    Tools/release/feedback-issues.py --dry-run             # print what would be filed
    Tools/release/feedback-issues.py --since 2026-09-29    # ignore reports older than that

Needs ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH in Tools/release/.env (never committed) and a
`gh` login with repo scope. Each issue body carries `<!-- asc:<submission id> -->`, which is how a
report already filed is recognised on the next run. Tester emails never go into the issue: the
tracker is public. Crash logs are attached as a collapsed section, trimmed to the crashed thread."""
import json, os, re, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
REPO = 'vory-dev/vory'
APP = '6814980297'
API = 'https://api.appstoreconnect.apple.com/v1'
DRY = '--dry-run' in sys.argv
SINCE = sys.argv[sys.argv.index('--since') + 1] if '--since' in sys.argv else ''

env = {}
for line in open(os.path.join(HERE, '.env')):
    line = line.strip()
    if line.startswith('export '): line = line[7:]
    if '=' in line and not line.startswith('#'):
        k, v = line.split('=', 1); env[k] = os.path.expandvars(v.strip().strip('"').strip("'"))

TOK = subprocess.check_output(['swift', os.path.join(HERE, 'asc-jwt.swift')],
                              env={**os.environ, 'ASC_KEY_ID': env['ASC_KEY_ID'], 'ASC_ISSUER_ID': env['ASC_ISSUER_ID'], 'ASC_KEY_PATH': env['ASC_KEY_PATH']}).decode().strip()

def asc(path):
    req = urllib.request.Request(path if path.startswith('http') else API + path, headers={'Authorization': f'Bearer {TOK}'})
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read() or b'{}')

def gh(*a):
    r = subprocess.run(['gh', *a], capture_output=True, text=True)
    if r.returncode: print('gh error:', r.stderr.strip()[:300], file=sys.stderr)
    return r.stdout.strip()

# Everything already filed, by ASC submission id.
filed = set()
for i in json.loads(gh('issue', 'list', '--repo', REPO, '--state', 'all', '--limit', '1000', '--json', 'body') or '[]'):
    filed.update(re.findall(r'<!-- asc:([A-Za-z0-9_-]+) -->', i.get('body') or ''))

def build_name(d, rel):
    inc = {i['id']: i.get('attributes', {}).get('version') for i in d.get('included', []) if i.get('type') == 'builds'}
    return inc.get((rel.get('build') or {}).get('data', {}).get('id'), '?')

def crashed_thread(text):
    """The header plus the crashed thread of an Apple crash log, so the issue stays readable."""
    head = text.split('\n\n', 1)[0]
    lines = text.split('\n')
    out, keep = [], False
    for ln in lines:
        if re.match(r'^Thread \d+ Crashed', ln): keep = True
        elif keep and (re.match(r'^Thread \d+', ln) or ln.startswith('Thread ') and 'crashed with' in ln): break
        if keep: out.append(ln)
    return head + '\n\n' + '\n'.join(out[:60])

new = 0
for kind, label in (('betaFeedbackScreenshotSubmissions', 'feedback'), ('betaFeedbackCrashSubmissions', 'crash')):
    d = asc(f'/apps/{APP}/{kind}?limit=50&sort=-createdDate&include=build')
    for x in d.get('data', []):
        sid = x['id']
        if sid in filed: continue
        a = x.get('attributes', {})
        if SINCE and (a.get('createdDate') or '') < SINCE: continue
        build = build_name(d, x.get('relationships', {}))
        comment = (a.get('comment') or '').strip()
        device = f"{a.get('deviceModel', '?')} · iOS {a.get('osVersion', '?')} · build {build}"
        if label == 'crash':
            title = 'Crash: ' + (comment.splitlines()[0][:70] if comment else f'{a.get("deviceModel", "?")} on build {build}')
            labels = ['crash', 'from-testflight']
            body = f'<!-- asc:{sid} -->\nTestFlight crash report. {device}. {a.get("createdDate", "")}\n\n'
            if comment: body += f'> {comment}\n\n'
            try:
                log = asc(f'/betaFeedbackCrashSubmissions/{sid}/crashLog').get('data', {}).get('attributes', {}).get('logText')
            except Exception:
                log = None
            if log:
                body += '<details><summary>Crashed thread</summary>\n\n```\n' + crashed_thread(log) + '\n```\n</details>\n'
        else:
            first = comment.splitlines()[0] if comment else 'Screenshot with no note'
            title = first[:80]
            labels = ['from-testflight', 'needs-approval']
            body = f'<!-- asc:{sid} -->\nTestFlight feedback. {device}. {a.get("createdDate", "")}\n\n> ' + comment.replace('\n', '\n> ')
            shots = len(a.get('screenshots') or [])
            if shots: body += f'\n\n{shots} screenshot(s) attached in App Store Connect.'
        new += 1
        print(('DRY ' if DRY else 'filing ') + f'[{label}] {title}')
        if DRY: continue
        args = ['issue', 'create', '--repo', REPO, '--title', title, '--body', body, '--milestone', 'Backlog']
        for l in labels: args += ['--label', l]
        url = gh(*args)
        # Onto the board too; its "Item added" workflow files it under Inbox.
        if url: gh('project', 'item-add', '1', '--owner', 'matt0975', '--url', url)
        time.sleep(0.5)
print(f'{new} new report(s)' + (' (dry run)' if DRY else ' filed'))
