#!/usr/bin/env python3
"""TankLink flasher: a tiny local web UI to build and flash pump or tank firmware.

Run:  python3 scripts/flasher.py   (opens http://127.0.0.1:8765)
Only listens on localhost. Uses ESP-IDF at ~/esp/esp-idf.
"""
import glob, json, os, subprocess, threading, webbrowser
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

state = {"running": False, "log": "", "proc": None, "status": "idle"}
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
        state.update(running=True, status="running", log="$ %s  (%s)\n\n" % (cmd, TARGETS[target]))
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
body{font:15px -apple-system,sans-serif;max-width:860px;margin:30px auto;padding:0 16px;color:#222}
h1{font-size:22px} label{display:block;margin:14px 0 4px;font-weight:600}
select,button{font-size:15px;padding:8px 12px} select{min-width:340px}
button{cursor:pointer;margin-right:8px;margin-top:14px}
.go{background:#0a7d3b;color:#fff;border:0;border-radius:6px}
.alt{border:1px solid #999;background:#f4f4f4;border-radius:6px}
.stop{background:#b3261e;color:#fff;border:0;border-radius:6px}
button:disabled{opacity:.4;cursor:default}
pre{background:#111;color:#ddd;padding:12px;border-radius:6px;height:380px;overflow:auto;font-size:12px;white-space:pre-wrap}
#st{font-weight:600;margin-left:6px}
</style>
<h1>TankLink flasher</h1>
<label>Firmware</label>
<select id=target><option value=pump>Pump node</option><option value=tank>Tank node</option></select>
<label>USB port <button class=alt style="margin:0 0 0 8px;padding:3px 8px" onclick=loadPorts()>Refresh</button></label>
<select id=port></select>
<div>
<button class=go id=bf onclick="start('build_flash')">Build + Flash</button>
<button class=alt id=f onclick="start('flash')">Flash only</button>
<button class=alt id=b onclick="start('build')">Build only</button>
<button class=alt id=e onclick="if(confirm('Erase the whole flash? This clears pairing.'))start('erase_flash')">Erase flash</button>
<button class=stop id=s onclick="fetch('/stop',{method:'POST'})" disabled>Stop</button>
<span id=st></span></div>
<pre id=log></pre>
<script>
const $=id=>document.getElementById(id);
async function loadPorts(){const p=await (await fetch('/ports')).json();
 $('port').innerHTML=p.length?p.map(x=>`<option>${x}</option>`).join(''):'<option value="">(no USB board found)</option>'}
async function start(action){
 const r=await fetch('/start',{method:'POST',body:JSON.stringify({action,target:$('target').value,port:$('port').value})});
 if(!r.ok)alert(await r.text())}
async function poll(){
 const s=await (await fetch('/state')).json();const l=$('log');
 const bottom=l.scrollTop+l.clientHeight>=l.scrollHeight-20;
 if(l.textContent!==s.log){l.textContent=s.log;if(bottom)l.scrollTop=l.scrollHeight}
 $('st').textContent=s.status;
 ['bf','f','b','e'].forEach(i=>$(i).disabled=s.running);$('s').disabled=!s.running;
 $('st').style.color=s.status.startsWith('failed')?'#b3261e':s.status=='done'?'#0a7d3b':'#222'}
loadPorts();setInterval(poll,500);
</script>"""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, body, ctype="application/json", code=200):
        b = body.encode()
        self.send_response(code); self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        if self.path == "/ports": self.send(json.dumps(ports()))
        elif self.path == "/state":
            with lock: self.send(json.dumps({k: state[k] for k in ("running", "log", "status")}))
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
