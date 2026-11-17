"""Probe real provider responses using local tags; never uploads audio or writes lyric text.

Usage: python Scripts/verify_live_lyrics.py --music-root PATH --report TestResults/lyrics-live.json
Uses mutagen for local metadata. Public regression tests exercise the actual Swift parsers.
"""
import argparse
import base64
import concurrent.futures
import json
from pathlib import Path
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zlib

from mutagen import File


def normalize(value):
    return ''.join(c for c in unicodedata.normalize('NFKD', value).casefold() if c.isalnum())


def matches(candidate, target):
    title, artist, duration = candidate
    target_title, target_artist, target_duration = target
    def base(value): return normalize(re.sub(r'[(（\[]\s*cover\s*[)）\]]', '', value, flags=re.I))
    if base(title) != base(target_title): return False
    for version in ['live', 'remix', 'instrumental', '伴奏', 'acoustic', 'animever', 'tvsize', 'shortver', 'カラオケ']:
        if (version in normalize(title)) != (version in normalize(target_title)): return False
    if abs(duration - target_duration) > 5: return False
    names = lambda value: {normalize(part) for part in re.split(r'\s*[/;&、]\s*|\s+feat\.?\s+', value, flags=re.I)}
    return bool(names(artist) & names(target_artist))


def get(base, query=None):
    url = base + ('?' + urllib.parse.urlencode(query) if query else '')
    request = urllib.request.Request(url, headers={'User-Agent': 'PureTone/0.4.0 (https://github.com/windbullet/windblower)', 'Referer': 'https://music.163.com/'})
    with urllib.request.urlopen(request, timeout=12) as response:
        return json.load(response)


def probe(name, target, album):
    title, artist, duration = target
    try:
        if name == 'LRCLIB':
            try:
                values = [get('https://lrclib.net/api/get', {'track_name': title, 'artist_name': artist, 'duration': round(duration)})]
            except urllib.error.HTTPError as error:
                if error.code != 404: raise
                values = get('https://lrclib.net/api/search', {'q': artist + ' ' + title})
            for value in values:
                if matches((value.get('trackName', ''), value.get('artistName', ''), value.get('duration', 0)), target):
                    if value.get('lyricsfile') or value.get('syncedLyrics') or value.get('plainLyrics'):
                        return {'source': name, 'matched': True, 'quality': 'word' if value.get('hasWordSync') else 'line' if value.get('syncedLyrics') else 'plain'}
        elif name == '网易云':
            search = get('https://music.163.com/api/search/get', {'s': artist + ' ' + title, 'type': 1, 'limit': 10})
            for song in search.get('result', {}).get('songs', []):
                if not matches((song.get('name', ''), ' / '.join(a.get('name', '') for a in song.get('artists', [])), song.get('duration', 0)/1000), target): continue
                value = get('https://music.163.com/api/song/lyric/v1', {'id': song['id'], 'lv': -1, 'tv': -1, 'rv': -1, 'yv': -1})
                if value.get('yrc', {}).get('lyric') or value.get('lrc', {}).get('lyric'):
                    return {'source': name, 'matched': True, 'quality': 'word' if value.get('yrc', {}).get('lyric') else 'line'}
        else:
            search = get('https://lyrics.kugou.com/search', {'ver': 1, 'man': 'no', 'client': 'pc', 'keyword': artist + ' - ' + title, 'duration': int(duration*1000)})
            for candidate in search.get('candidates', [])[:6]:
                if not matches((candidate.get('song', ''), candidate.get('singer', ''), candidate.get('duration', 0)/1000), target): continue
                value = get('https://lyrics.kugou.com/download', {'ver': 1, 'client': 'pc', 'id': candidate['id'], 'accesskey': candidate['accesskey'], 'fmt': 'krc', 'charset': 'utf8'})
                raw = base64.b64decode(value.get('content', ''))
                if raw[:4] != b'krc1': continue
                key = bytes([64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105])
                text = zlib.decompress(bytes(c ^ key[i % 16] for i, c in enumerate(raw[4:]))).decode('utf-8')
                if re.search(r'\[\d+,\d+\]', text):
                    return {'source': name, 'matched': True, 'quality': 'word' if re.search(r'<\d+,\d+,\d+>', text) else 'line'}
        return {'source': name, 'matched': False, 'detail': 'No matching version with lyrics'}
    except Exception as error:
        return {'source': name, 'matched': False, 'detail': str(error)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--music-root', required=True)
    parser.add_argument('--report', default='TestResults/lyrics-live.json')
    args = parser.parse_args()
    if hasattr(sys.stdout, 'reconfigure'): sys.stdout.reconfigure(encoding='utf-8')
    root = Path(args.music_root)
    # Cover Japanese/Chinese/English, Cover versions, missing lyrics, and both containers.
    artists = ['MyGO!!!!!', 'Vaundy', 'RAISE A SUILEN', "Poppin'Party", 'YOASOBI', 'STARSET', 'The Score', '草东没有派对', '鱼韵', 'Imagine Dragons']
    selected = []
    for artist in artists:
        files = sorted(p for p in (root/artist).rglob('*') if p.suffix.lower() in ['.flac', '.mp3'])
        if files: selected.append(next((p for p in files if p.suffix.lower() == '.mp3'), files[0]))
    # Include an album track whose title in older indexes may contain the track number.
    extra = root/'MyGO!!!!!/迷跡波/008-春日影 (MyGO!!!!! ver.).flac'
    if extra.is_file() and extra not in selected: selected.append(extra)
    results = []
    for path in selected:
        metadata = File(path, easy=True)
        target = (metadata.get('title', [path.stem])[0], metadata.get('artist', [path.parent.parent.name])[0], metadata.info.length)
        album = metadata.get('album', [''])[0]
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            sources = list(executor.map(lambda source: probe(source, target, album), ['网易云', '酷狗', 'LRCLIB']))
        entry = {'title': target[0], 'artist': target[1], 'format': path.suffix, 'duration': target[2],
                 'embedded_lyrics': bool(metadata.get('lyrics') or metadata.get('unsyncedlyrics')), 'sources': sources}
        entry['found'] = entry['embedded_lyrics'] or any(result['matched'] for result in sources)
        results.append(entry)
        print(json.dumps(entry, ensure_ascii=False), flush=True)
    report = {'tested': len(results), 'found': sum(result['found'] for result in results), 'results': results,
              'note': 'Local tags + real requests only; no audio uploaded, no lyric text stored. Native Swift tests also verify providers/parsing.'}
    output = Path(args.report); output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print('Matched:', report['found'], '/', report['tested'])


if __name__ == '__main__': main()
