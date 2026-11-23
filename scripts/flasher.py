#!/usr/bin/env python3
"""TankLink flasher: a tiny local web UI to build and flash pump or tank firmware.

Run:  python3 scripts/flasher.py   (opens http://127.0.0.1:8765)
Only listens on localhost. Uses ESP-IDF at ~/esp/esp-idf.
"""
import glob, json, os, re, subprocess, threading, time, webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")
PORT = 8765
TARGETS = {"pump": "pump_node", "tank": "tank_node"}
ACTIONS = {
    "build_flash": "idf.py -p {port} build flash",
    "flash": "idf.py -p {port} flash",
    "build": "idf.py build",
    "erase_flash": "idf.py -p {port} erase-flash",
    "monitor_stop": None,
}

state = {"running": False, "log": "", "proc": None, "status": "idle", "start": 0, "action": "", "target": ""}
lock = threading.Lock()


def ports():
    found = []
    for pat in ("/dev/cu.usbmodem*", "/dev/cu.usbserial*", "/dev/cu.wchusbserial*", "/dev/cu.SLAB*"):
        found += glob.glob(pat)
    return sorted(found)


def idf_env_prefix():
    prefix = ""
    envs = sorted(glob.glob(os.path.join(HOME, ".espressif/python_env/idf6.1_py*_env")))
    if envs and not os.environ.get("IDF_PYTHON_ENV_PATH"):
        prefix += 'export IDF_PYTHON_ENV_PATH="%s"; ' % envs[-1]
    return prefix + '. "%s/esp/esp-idf/export.sh" >/dev/null 2>&1 || { echo "ESP-IDF export.sh failed"; exit 1; }; ' % HOME


def run_job(target, action, port):
    cmd = ACTIONS[action].format(port=port)
    script = idf_env_prefix() + "cd '%s' && %s" % (os.path.join(ROOT, TARGETS[target]), cmd)
    with lock:
        state.update(running=True, status="running", start=time.time(), action=action, target=target,
                     log="$ %s  (%s)\n\nLoading ESP-IDF...\n" % (cmd, TARGETS[target]))
    p = subprocess.Popen(["bash", "-c", script], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1, errors="replace")
    state["proc"] = p
    for line in p.stdout:
        with lock:
            state["log"] += line
    code = p.wait()
    with lock:
        state.update(running=False, proc=None, status="done" if code == 0 else "failed (exit %d)" % code)


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>TankLink flasher</title>
<style>
:root{--bg:#0b0d12;--card:#141821;--line:#232a38;--txt:#e7ecf4;--mut:#8b96a9;--acc:#3DDC97;--acc2:#1FA97A;--ok:#3DDC97;--bad:#ef4444}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;color:var(--txt);font:15px/1.45 Inter,-apple-system,"SF Pro Text",system-ui,sans-serif;
background:radial-gradient(900px 500px at 10% -10%,#0f3d33 0,transparent 60%),radial-gradient(800px 500px at 100% 0,#0c3a3f 0,transparent 55%),var(--bg)}
main{max-width:900px;margin:0 auto;padding:36px 20px 60px}
header{display:flex;align-items:center;gap:14px;margin-bottom:26px}
.logo{width:44px;height:44px;border-radius:12px;background:linear-gradient(135deg,var(--acc),var(--acc2));display:grid;place-items:center;font-size:22px;box-shadow:0 8px 30px #3ddc9744}
h1{font-size:24px;margin:0;letter-spacing:-.02em}.sub{color:var(--mut);font-size:13px}
.card{background:color-mix(in srgb,var(--card) 85%,transparent);backdrop-filter:blur(10px);border:1px solid var(--line);border-radius:16px;padding:20px;margin-bottom:16px}
.step{font-size:11px;letter-spacing:.12em;text-transform:uppercase;color:var(--mut);margin-bottom:10px;font-weight:600}
.seg{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.seg button{all:unset;cursor:pointer;text-align:center;padding:16px;border-radius:12px;border:1px solid var(--line);background:#0f131b;transition:.15s}
.seg button:hover{border-color:#2a5a4c}
.seg button.on{border-color:var(--acc);background:linear-gradient(180deg,#123a2f,#0d2a23);box-shadow:0 0 0 3px #3ddc9722}
.seg b{display:block;font-size:16px}.seg span{color:var(--mut);font-size:12px}
.row{display:flex;gap:10px}
select{flex:1;appearance:none;background:#0f131b;color:var(--txt);border:1px solid var(--line);border-radius:10px;padding:12px 14px;font-size:14px;font-family:ui-monospace,Menlo,monospace}
select:focus{outline:none;border-color:var(--acc)}
.btn{cursor:pointer;border:1px solid var(--line);background:#1a2030;color:var(--txt);border-radius:10px;padding:12px 18px;font-size:14px;font-weight:600;transition:.15s}
.btn:hover:not(:disabled){background:#222a3e;transform:translateY(-1px)}
.btn.pri{border:0;color:#04251a;background:linear-gradient(135deg,var(--acc),var(--acc2));box-shadow:0 8px 24px #1fa97a44}
.btn.pri:hover:not(:disabled){background:linear-gradient(135deg,#5af0b0,#2cc08f)}
.btn.stop{background:#3a1519;border-color:#6b1f26;color:#ff8d95}
.btn.danger{color:#ff8d95}
.btn:disabled{opacity:.35;cursor:not-allowed}
.actions{display:flex;flex-wrap:wrap;gap:10px}
.hint{color:var(--mut);font-size:13px;margin-top:8px}
#banner{display:flex;align-items:center;gap:14px;border-radius:16px;padding:16px 20px;margin-bottom:16px;border:1px solid var(--line);background:var(--card)}
#banner .ic{width:36px;height:36px;border-radius:50%;display:grid;place-items:center;font-size:18px;background:#1c2333;flex:none}
#banner.run{border-color:#1f8a64;background:#0d2a23}#banner.run .ic{background:none;border:3px solid #1f8a64;border-top-color:var(--acc);animation:s .8s linear infinite;font-size:0}
#banner.ok{border-color:#1c6b3a;background:#0e2a1e}#banner.ok .ic{background:var(--ok);color:#04210f}
#banner.bad{border-color:#7a2630;background:#25101a}#banner.bad .ic{background:var(--bad);color:#fff}
#banner b{font-size:16px;display:block}#banner small{color:var(--mut)}
@keyframes s{to{transform:rotate(360deg)}}
#bar{height:6px;background:#1c2333;border-radius:3px;overflow:hidden;margin:-6px 0 16px;display:none}
#bar div{height:100%;width:0;background:linear-gradient(90deg,var(--acc),var(--acc2));transition:width .3s}
pre{margin:0;background:#07090d;border:1px solid var(--line);border-radius:12px;padding:14px;height:340px;overflow:auto;font:12px/1.5 ui-monospace,Menlo,monospace;color:#b9c4d8;white-space:pre-wrap}
</style>
<main>
<header><div class=logo>⚡</div><div><h1>TankLink flasher</h1><div class=sub>Build and flash pump or tank firmware</div></div></header>
<div class=card><div class=step>1 · Firmware</div>
<div class=seg id=seg><button class=on data-v=pump><b>Pump node</b><span>ESP32-C3 SuperMini</span></button><button data-v=tank><b>Tank node</b><span>XIAO ESP32-C3</span></button></div></div>
<div class=card><div class=step>2 · USB port</div>
<div class=row><select id=port></select><button class=btn onclick=loadPorts()>Refresh</button></div>
<div class=hint id=phint></div></div>
<div class=card><div class=step>3 · Action</div>
<div class=actions>
<button class="btn pri" id=bf onclick="start('build_flash','Building and flashing')">Build + Flash</button>
<button class=btn id=f onclick="start('flash','Flashing')">Flash only</button>
<button class=btn id=b onclick="start('build','Building')">Build only</button>
<button class="btn danger" id=e onclick="if(confirm('Erase the whole flash? This clears pairing.'))start('erase_flash','Erasing flash')">Erase flash</button>
<button class="btn stop" id=s onclick="fetch('/stop',{method:'POST'})" disabled>Stop</button></div></div>
<div id=banner><div class=ic id=ic></div><div><b id=bt>Ready</b><small id=bs>Nothing running yet.</small></div></div>
<div id=bar><div></div></div>
<pre id=log>The build and flash output will show up here.</pre>
</main>
<script>
const $=id=>document.getElementById(id);let what='',target='pump';
document.querySelectorAll('#seg button').forEach(b=>b.onclick=()=>{target=b.dataset.v;
 document.querySelectorAll('#seg button').forEach(x=>x.classList.toggle('on',x==b))});
async function loadPorts(){const p=await (await fetch('/ports')).json();
 $('port').innerHTML=p.length?p.map(x=>`<option>${x}</option>`).join(''):'<option value="">(no USB board found)</option>';
 $('phint').textContent=p.length?'':'Plug the board in with a data USB cable, then press Refresh.'}
async function start(action,label){
 what=label;
 if(action!='build'&&!$('port').value){banner('bad','No USB port selected','Plug in the board and press Refresh.');return}
 banner('run',label+'...','Starting. The first output can take a few seconds.');
 $('log').textContent='Starting...';
 const r=await fetch('/start',{method:'POST',body:JSON.stringify({action,target,port:$('port').value})});
 if(!r.ok)banner('bad','Could not start',await r.text())}
function banner(cls,t,s){$('banner').className=cls;$('bt').textContent=t;$('bs').textContent=s;
 $('ic').textContent=cls=='ok'?'✓':cls=='bad'?'✕':''}
async function poll(){
 const s=await (await fetch('/state')).json();const l=$('log');
 const bottom=l.scrollTop+l.clientHeight>=l.scrollHeight-20;
 if(s.log&&l.textContent!==s.log){l.textContent=s.log;if(bottom)l.scrollTop=l.scrollHeight}
 ['bf','f','b','e'].forEach(i=>$(i).disabled=s.running);$('s').disabled=!s.running;
 const bar=$('bar');bar.style.display=s.running&&s.pct>=0?'block':'none';bar.firstChild.style.width=s.pct+'%';
 if(s.running){const m=Math.floor(s.elapsed/60),sec=s.elapsed%60;
  banner('run',(what||'Working')+'...',(s.step||'Running')+'  ·  '+m+'m '+sec+'s'+(s.pct>=0?'  ·  '+s.pct+'%':''))}
 else if(s.status=='done')banner('ok','Finished OK',s.last_msg)
 else if(s.status.startsWith('failed'))banner('bad','Failed','See the end of the log below. '+s.hint)}
loadPorts();setInterval(poll,500);poll();
</script>"""


def summary():
    log, running = state["log"], state["running"]
    pct, step = -1, "Loading ESP-IDF"
    m = re.findall(r"\[(\d+)/(\d+)\]", log)
    if m:
        pct, step = int(100 * int(m[-1][0]) / max(int(m[-1][1]), 1)), "Compiling"
    if "Connecting" in log: step, pct = "Connecting to the board", -1
    if "Writing at" in log:
        w = re.findall(r"Writing at 0x[0-9a-f]+\.\.\. \((\d+) %\)", log)
        step, pct = "Writing to the board", int(w[-1]) if w else -1
    if "Hash of data verified" in log and running: step = "Verifying"
    if "Hard resetting" in log: step = "Rebooting the board"
    t, a = TARGETS.get(state["target"], ""), state["action"]
    ok = {"build": "Built. Nothing was flashed.", "erase_flash": "Flash erased. Flash firmware next."}.get(
        a, "Flashed and the board is rebooting.")
    hint = "No port? Close any serial monitor and re-plug the board." if "could not open port" in log.lower() or "Failed to connect" in log else ""
    return {"running": running, "log": log, "status": state["status"], "pct": pct, "step": step,
            "elapsed": int(time.time() - state["start"]) if running else 0, "last_msg": ok, "hint": hint}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, body, ctype="application/json", code=200):
        b = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        if self.path == "/ports": self.send(json.dumps(ports()))
        elif self.path == "/state":
            with lock: self.send(json.dumps(summary()))
        else: self.send(PAGE, "text/html")

    def do_POST(self):
        if self.path == "/stop":
            p = state.get("proc")
            if p: p.terminate()
            return self.send("{}")
        if self.path != "/start": return self.send("not found", "text/plain", 404)
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        target, action, port = req.get("target"), req.get("action"), req.get("port", "")
        if target not in TARGETS or not ACTIONS.get(action):
            return self.send("bad request", "text/plain", 400)
        if "{port}" in ACTIONS[action] and port not in ports():
            return self.send("Pick a connected USB port first.", "text/plain", 400)
        if state["running"]: return self.send("A job is already running.", "text/plain", 409)
        threading.Thread(target=run_job, args=(target, action, port), daemon=True).start()
        self.send("{}")


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print("TankLink flasher at http://127.0.0.1:%d  (Ctrl+C to quit)" % PORT)
    threading.Timer(0.5, lambda: webbrowser.open("http://127.0.0.1:%d" % PORT)).start()
    try: srv.serve_forever()
    except KeyboardInterrupt: pass
