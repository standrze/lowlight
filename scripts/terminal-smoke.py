#!/usr/bin/env python3
"""Local-only terminal integration test.

Usage: python3 scripts/terminal-smoke.py /absolute/path/to/lowlight
Requires macOS, Python 3, and a built lowlight executable. Uses an ephemeral
loopback endpoint and temporary sessions/files; never connects to a real model.
"""
import os, pty, select, time, subprocess, tempfile, pathlib, threading, json, struct, fcntl, termios, http.server, sys
root = pathlib.Path(tempfile.mkdtemp(prefix='lowlight-smoke-'))
sessions = root/'sessions'; sessions.mkdir()
file = root/'notes with spaces.txt'; file.write_text('attachment snapshot 2468\nsecond line\n')
requests=[]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  data=json.dumps({'data':[{'id':'test-one','context_window':8192,'supported_reasoning_efforts':['low','high']},{'id':'test-two','context_window':8192}]}).encode()
  self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(data)
 def do_POST(self):
  data=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
  requests.append(data)
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  events=[{'choices':[{'index':0,'delta':{'reasoning_content':'Checking the provided text.'}}]}, {'choices':[{'index':0,'delta':{'content':'Answer number %d with needle.'%len(requests)}}]}, {'choices':[{'index':0,'delta':{},'finish_reason':'stop'}]}]
  for ev in events:
   self.wfile.write(('data: '+json.dumps(ev)+'\n\n').encode());self.wfile.flush();time.sleep(.03)
  self.wfile.write(b'data: [DONE]\n\n');self.wfile.flush()
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
binary=str(pathlib.Path(sys.argv[1]).resolve()) if len(sys.argv) > 1 else str(pathlib.Path('.build/debug/lowlight').resolve())
processes=[]; all_output=[]
def launch(resume=None):
 master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',32,130,0,0))
 args=[binary,'--endpoint','http://127.0.0.1:%d/v1'%server.server_port,'--model','test-one','--context-window','8192','--max-tokens','512','--workspace',str(root),'--sessions-directory',str(sessions)]
 if resume: args += ['--resume',resume]
 env=dict(os.environ,TERM='xterm-256color')
 proc=subprocess.Popen(args,stdin=slave,stdout=slave,stderr=slave,env=env,start_new_session=True)
 os.close(slave);processes.append((proc,master));return proc,master

def read(master,seconds=.6):
 result=b'';end=time.monotonic()+seconds
 while time.monotonic()<end:
  if select.select([master],[],[],max(0,end-time.monotonic()))[0]:
   try: data=os.read(master,65536)
   except OSError: break
   if not data: break
   result+=data
 text=result.decode('utf-8',errors='replace');all_output.append(text);return text

def send(master,text,seconds=.6):
 os.write(master,text.encode());return read(master,seconds)
def command(master,text,seconds=.6): return send(master,text+'\r',seconds)
def records():return [json.loads(p.read_text()) for p in sessions.glob('*.json')]
def latest():return max(records(),key=lambda x:x['updatedAt'])
def check(value,msg):
 if not value: raise AssertionError(msg)
 print('PASS',msg,flush=True)
try:
 proc,master=launch();read(master,1.5)
 check(proc.poll() is None,'TUI starts with fixture endpoint')
 output=command(master,'/attach "notes with spaces.txt"')
 check('2468' in output,'attachment preview is visible')
 check(not requests,'preview does not send a model request')
 command(master,'Summarize this attachment',1)
 check(len(requests)==1,'message reaches endpoint once')
 check('attachment snapshot 2468' in requests[0]['messages'][-1]['content'],'attachment is included in model input')
 original=latest(); original_id=original['id']
 check(any(m['role']=='user' and m.get('attachments') and m['attachments'][0]['text'].startswith('attachment snapshot') for m in original['transcript']['messages']),'attachment snapshot saved on user turn')
 command(master,'/retry',1.5)
 check(len(requests)==2,'retry sends automatically after connecting')
 retry=latest()
 check(retry['id']!=original_id and retry['parentID']==original_id,'retry creates a branch')
 check(requests[1]['messages'][-1]['content']==requests[0]['messages'][-1]['content'],'retry preserves prompt and attachment')
 check(not any(m['role']=='assistant' for m in requests[1]['messages']),'retry excludes original answer')
 command(master,'/edit 1',1)
 edit=latest()
 check(edit['draft']=='Summarize this attachment','edit restores selected prompt as draft')
 check(edit['pendingAttachments'][0]['text'].startswith('attachment snapshot'),'edit restores attachment snapshot')
 # clear via terminal editor Ctrl-U may not be supported; select all through repeated backspace.
 send(master,'\x7f'*len('Summarize this attachment'),.2)
 send(master,'A recovered draft',.8)
 check(latest()['draft']=='A recovered draft','unsent draft autosaves before exit')
 draft_id=latest()['id']
 output=send(master,'\x03',.3)
 check(proc.poll() is None and 'Ctrl-C again' in output,'first Ctrl-C confirms without exiting')
 send(master,'\x03',.4);check(proc.wait(timeout=5)==0,'second Ctrl-C saves and exits')
 proc,master=launch(draft_id);out=read(master,1.3)
 check('recovered draft' in out,'resume restores unsent draft in composer')
 send(master,'\x7f'*len('A recovered draft'),.2)
 out=command(master,'/model',2)
 check('Models from this endpoint' in out,'model picker opens')
 send(master,'two',.3);command(master,'',1)
 check(latest()['model']=='test-two','model picker filters and selects')
 # session list searches original model answer, not just title.
 out=command(master,'/sessions needle')
 check('Sessions' in out and 'No matches' not in out,'session picker searches conversation contents')
 command(master,'',1)
 check(latest()['id'] in [original_id,retry['id']],'session picker resumes matching conversation')
 out=command(master,'/search needle')
 check('Search results' in out,'transcript search opens results')
 command(master,'',.3)
 out=command(master,'/export result.md')
 check((root/'result.md').exists(),'Markdown export writes requested path')
 check('needle' in (root/'result.md').read_text(),'export contains answer')
 out=command(master,'/connection')
 check('Server-reported context' in out or '8192' in out,'connection diagnostics display capabilities')
 out=command(master,'/sessions archive '+original_id)
 check(next(r for r in records() if r['id']==original_id)['archived'],'session archive persists')
 command(master,'/sessions restore '+original_id)
 check(not next(r for r in records() if r['id']==original_id)['archived'],'session restore persists')
 # delete noncurrent edit branch, after confirmation.
 command(master,'/sessions delete '+draft_id)
 check(any(r['id']==draft_id for r in records()),'delete requires in-app confirmation')
 command(master,'/sessions delete '+draft_id+' confirm')
 check(not any(r['id']==draft_id for r in records()),'confirmed delete removes session')
 check((sessions/'.trash'/(draft_id+'.json')).exists(),'deleted session has recovery copy')
 send(master,'\x03',.2);send(master,'\x03',.4);proc.wait(timeout=5)
 print('SUCCESS',root,flush=True)
finally:
 (root/'terminal.log').write_text(''.join(all_output))
 (root/'requests.json').write_text(json.dumps(requests,indent=2))
 for proc,master in processes:
  if proc.poll() is None:
   proc.kill();proc.wait(timeout=5)
  os.close(master)
 server.shutdown()
 print('Artifacts:',root,flush=True)
