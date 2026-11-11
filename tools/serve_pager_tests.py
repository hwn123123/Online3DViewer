#!/usr/bin/env python3
"""Serve the offline viewer and synthetic byte-range fixtures on loopback."""
from http.server import ThreadingHTTPServer,SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import unquote,urlparse
root=Path.cwd();assets=root/'build/ios/WebAssets';fixtures=root/'build/ios/memory-stream-tests/fixtures'
class H(SimpleHTTPRequestHandler):
 def translate_path(self,path):
  path=unquote(urlparse(path).path)
  if path.startswith('/models/'):return str(fixtures/path[8:])
  if path.startswith('/previous/'):return str(root/'build/ios/native-mesh-tests/browser-fixtures'/path[10:])
  return str(assets/path.lstrip('/'))
 def log_message(self,*a):pass
 def send_head(self):
  if 'Range' not in self.headers:return super().send_head()
  f=open(self.translate_path(self.path),'rb');f.seek(0,2);n=f.tell();a,b=self.headers['Range'][6:].split('-');a=int(a);b=min(n-1,int(b));self.send_response(206);self.send_header('Content-Length',b-a+1);self.send_header('Content-Range',f'bytes {a}-{b}/{n}');self.end_headers();f.seek(a);self.range_remaining=b-a+1;return f
 def copyfile(self,source,output):
  if hasattr(self,'range_remaining'):output.write(source.read(self.range_remaining));del self.range_remaining
  else:super().copyfile(source,output)
print('http://127.0.0.1:8097',flush=True);ThreadingHTTPServer(('127.0.0.1',8097),H).serve_forever()
