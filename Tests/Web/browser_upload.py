"""Chrome integration: actual bundled page, folder selection, hashing and resume.

The fixture implements the documented upload wire contract; native Swift server
integration runs separately on iPad/macOS. No private music or external service.
"""
from pathlib import Path
import hashlib
import http.server
import json
import os
import tempfile
import threading
import time
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
WEB = ROOT / "App/Resources/Web"
uploads = {}

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_): pass
    def send_json(self, value, code=200):
        body=json.dumps(value).encode();self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    def auth(self):
        if self.headers.get('Authorization')!='Bearer 123456':self.send_json({'error':'bad code'},401);return False
        return True
    def do_GET(self):
        file=WEB/('index.html' if self.path=='/' else self.path.lstrip('/'))
        if file.is_file() and file.parent==WEB:
            data=file.read_bytes();self.send_response(200);self.send_header('Content-Length',str(len(data)));self.send_header('Content-Type',{'html':'text/html','js':'text/javascript','css':'text/css'}[file.suffix[1:]]);self.end_headers();self.wfile.write(data)
        else:self.send_json({},404)
    def do_POST(self):
        if not self.auth():return
        if self.path=='/api/uploads':
            body=json.loads(self.rfile.read(int(self.headers['Content-Length'])));key=hashlib.sha256((body['path']+body['sha256']).encode()).hexdigest()
            entry=uploads.setdefault(key,{**body,'id':key,'offset':0,'completed':False,'data':bytearray()});self.send_json({k:v for k,v in entry.items() if k!='data'})
        else:
            key=self.path.split('/')[3];entry=uploads[key]
            assert len(entry['data'])==entry['size'] and hashlib.sha256(entry['data']).hexdigest()==entry['sha256']
            entry['completed']=True;self.send_json({'completed':True})
    def do_PUT(self):
        if not self.auth():return
        key=self.path.split('/')[3];entry=uploads[key];offset=int(self.headers['X-Upload-Offset']);data=self.rfile.read(int(self.headers['Content-Length']))
        if offset!=entry['offset']:self.send_json({'error':'offset'},409);return
        assert len(data)<=1048576;entry['data'].extend(data);entry['offset']+=len(data);time.sleep(.025)
        try:self.send_json({k:v for k,v in entry.items() if k!='data'})
        except (BrokenPipeError,ConnectionResetError):pass

def main():
    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
    with tempfile.TemporaryDirectory() as temporary, sync_playwright() as p:
        folder=Path(temporary)/'Music';(folder/'Album').mkdir(parents=True)
        (folder/'Album/track.flac').write_bytes(os.urandom(6*1048576+71));(folder/'Album/track.lrc').write_text('[00:01.00]hello',encoding='utf-8')
        chrome=Path('C:/Program Files/Google/Chrome/Application/chrome.exe')
        browser=p.chromium.launch(executable_path=str(chrome) if chrome.exists() else None,headless=True)
        page=browser.new_page(viewport={'width':1280,'height':980});errors=[];page.on('pageerror',lambda e:errors.append(str(e)))
        page.goto(f'http://127.0.0.1:{server.server_port}');page.locator('#code').fill('123456');page.locator('#folderInput').set_input_files(str(folder))
        page.wait_for_function("document.querySelector('#summary').textContent === '2 / 2 个文件完成'",timeout=30000)
        assert len(uploads)==2 and all(x['completed'] for x in uploads.values());assert not errors,errors
        output=ROOT/'TestResults';output.mkdir(exist_ok=True);page.screenshot(path=str(output/'wifi-transfer-chrome.png'),full_page=True)
        # Re-selecting the same folder must not append duplicate jobs.
        page.locator('#folderInput').set_input_files(str(folder));assert page.locator('#list li').count()==2
        # New page simulates browser restart; server offsets permit resumption.
        for entry in uploads.values():
            if entry['path'].endswith('.flac'):entry['data']=entry['data'][:1048576];entry['offset']=1048576;entry['completed']=False
        page.reload();page.locator('#code').fill('123456');page.locator('#folderInput').set_input_files(str(folder))
        page.wait_for_function("document.querySelector('#summary').textContent === '2 / 2 个文件完成'",timeout=30000)
        assert all(x['completed'] and len(x['data'])==x['size'] for x in uploads.values())
        browser.close()
    server.shutdown();print('PASS: Chrome folder upload, bounded chunks, independent hashes, duplicate prevention, resumed upload; no JS errors')
if __name__=='__main__':main()
