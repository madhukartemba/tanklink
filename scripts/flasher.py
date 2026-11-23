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


PAGE = """<!doctype html><meta charset=utf-8><title>TankLink flasher</title>
<style>
body{font:15px -apple-system,sans-serif;max-width:880px;margin:30px auto;padding:0 16px;color:#222}
h1{font-size:22px;margin-bottom:4px} .sub{color:#666;margin-bottom:10px}
label{display:block;margin:14px 0 4px;font-weight:600}
select,button{font-size:15px;padding:9px 14px} select{min-width:340px}
button{cursor:pointer;margin:14px 8px 0 0;border-radius:6px}
.go{background:#0a7d3b;color:#fff;border:0}.alt{border:1px solid #999;background:#f4f4f4}
.stop{background:#b3261e;color:#fff;border:0}
button:disabled{opacity:.35;cursor:not-allowed}
#banner{margin:18px 0 8px;padding:14px 16px;border-radius:8px;font-size:16px;font-weight:600;display:flex;align-items:center;gap:12px;background:#eef1f4}
#banner.run{background:#e6f0ff;color:#0b4fb3}#banner.ok{background:#e3f6ea;color:#0a7d3b}#banner.bad{background:#fdeaea;color:#b3261e}
#banner small{font-weight:400;display:block;color:#444;margin-top:2px}
.spin{width:18px;height:18px;border:3px solid #9bbcf0;border-top-color:#0b4fb3;border-radius:50%;animation:s 0.8s linear infinite;display:none}
.run .spin{display:block}@keyframes s{to{transform:rotate(360deg)}}
#bar{height:8px;background:#dde3ea;border-radius:4px;overflow:hidden;display:none}#bar div{height:100%;width:0;background:#0b4fb3;transition:width .3s}
pre{background:#111;color:#ddd;padding:12px;border-radius:6px;height:360px;overflow:auto;font-size:12px;white-space:pre-wrap}
.hint{color:#666;font-size:13px;margin-top:6px}
</style>
<h1>TankLink flasher</h1><div class=sub>Pick what to flash and where, then press a green button.</div>
<label>1. Firmware</label>
<select id=target><option value=pump>Pump node</option><option value=tank>Tank node</option></select>
<label>2. USB port <button class=alt style="margin:0 0 0 8px;padding:3px 8px" onclick=loadPorts()>Refresh</button></label>
<select id=port></select>
<div class=hint id=phint></div>
<label>3. Action</label>
<button class=go id=bf onclick="start('build_flash','Building and flashing')">Build + Flash</button>
<button class=alt id=f onclick="start('flash','Flashing')">Flash only</button>
<button class=alt id=b onclick="start('build','Building')">Build only</button>
<button class=alt id=e onclick="if(confirm('Erase the whole flash? This clears pairing.'))start('erase_flash','Erasing flash')">Erase flash</button>
<button class=stop id=s onclick="fetch('/stop',{method:'POST'})" disabled>Stop</button>
<div id=banner><div class=spin></div><div><span id=bt>Ready</span><small id=bs>Nothing running yet.</small></div></div>
<div id=bar><div></div></div>
<pre id=log>The build and flash output will show up here.</pre>
<script>
const $=id=>document.getElementById(id);let what='';
async function loadPorts(){const p=await (await fetch('/ports')).json();
 $('port').innerHTML=p.length?p.map(x=>`<option>${x}</option>`).join(''):'<option value="">(no USB board found)</option>';
 $('phint').textContent=p.length?'':'Plug the board in with a data USB cable, then press Refresh.'}
async function start(action,label){
 what=label;const need=action!='build';
 if(need&&!$('port').value){banner('bad','No USB port selected','Plug in the board and press Refresh.');return}
 banner('run',label+'...','Starting. The first output can take a few seconds.');
 $('log').textContent='Starting...';
 const r=await fetch('/start',{method:'POST',body:JSON.stringify({action,target:$('target').value,port:$('port').value})});
 if(!r.ok)banner('bad','Could not start',await r.text())}
function banner(cls,t,s){$('banner').className=cls;$('bt').textContent=t;$('bs').textContent=s}
let t0=0;
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
