#!/usr/bin/env python3
"""Two isolated Lowlight TUI clients against a local Midnight server.
Usage: python3 scripts/shared-cache-smoke.py BINARY http://127.0.0.1:18089/v1
"""
import fcntl,json,os,pty,re,select,struct,subprocess,sys,tempfile,termios,time,urllib.request
from pathlib import Path
binary=sys.argv[1];endpoint=sys.argv[2]
with urllib.request.urlopen(endpoint+'/models') as response:model=json.load(response)['data'][0]['id']
root=Path(tempfile.mkdtemp(prefix='lowlight-shared-'))
system='Answer each arithmetic question briefly. '+('A quiet garden has green trees, blue flowers and stone paths. '*40)
clients=[]
def drain(seconds=.1):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        ready,_,_=select.select([c[1] for c in clients],[],[],.05)
        for fd in ready:
            try:os.read(fd,65536)
            except OSError:pass

def messages(directory):
    result=[]
    for path in directory.glob('*.json'):
        try:result.extend(json.loads(path.read_text()).get('transcript',{}).get('messages',[]))
        except (OSError,json.JSONDecodeError):pass
    return result
try:
    for index in range(2):
        directory=root/str(index);directory.mkdir();sessions=directory/'sessions';sessions.mkdir()
        config=directory/'config.json';config.write_text('{}')
        master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',40,150,0,0))
        proc=subprocess.Popen([binary,'--config',str(config),'--endpoint',endpoint,'--model',model,
            '--max-tokens','32','--system-prompt',system,'--workspace',str(directory),
            '--sessions-directory',str(sessions),'--api-key-env','LOWLIGHT_TEST_UNUSED_KEY'],
            stdin=slave,stdout=slave,stderr=slave,cwd=directory,
            env={**os.environ,'TERM':'xterm-256color','LOWLIGHT_TEST_UNUSED_KEY':''},start_new_session=True)
        os.close(slave);clients.append((proc,master,sessions))
    drain(2)
    for _,fd,_ in clients:os.write(fd,b'What is 3 plus 3?\r')
    deadline=time.monotonic()+45
    while not all(any(m.get('role')=='assistant' and m.get('text') for m in messages(d)) for _,_,d in clients):
        assert time.monotonic()<deadline,'Timed out waiting for both answers'
        assert all(p.poll() is None for p,_,_ in clients),'Client exited unexpectedly'
        drain()
    for _,fd,_ in clients:os.write(fd,b'/usage\r')
    notices=[]
    deadline=time.monotonic()+10
    while len(notices)<2:
        drain()
        notices=[m['text'] for _,_,d in clients for m in messages(d)
                 if m.get('role')=='notice' and 'input tokens cached' in m.get('text','')]
        assert time.monotonic()<deadline,'Usage notice not saved'
    assert any(int(re.search(r'\((\d+) input tokens cached\)',n).group(1))>0 for n in notices),notices
    for notice in notices:print(notice)
    assert all('knowledge' not in m for _,_,d in clients for m in messages(d))
    print('PASS installed Lowlight: two overlapping clients, visible cached usage, no retrieval metadata')
finally:
    for p,fd,_ in clients:
        if p.poll() is None:os.write(fd,b'\x03')
    drain(.5)
    for p,fd,_ in clients:
        if p.poll() is None:p.terminate()
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.kill();p.wait()
        os.close(fd)
