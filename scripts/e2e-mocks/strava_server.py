"""Stand-in for Strava's OAuth sign-in and upload API, for emulator tests of TrailMind's Strava link.

    python strava_server.py <log-file> <port>

It checks what the app sends the way Strava would (Client ID and secret, the redirect and scopes, bearer tokens that
expire, a multipart GPX upload with a time on every point) and writes one line per request to the log, so a test can
check them. Control URL for tests:  /__fail?n=2&code=503  makes the next n uploads fail with that status.
"""
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

LOG, PORT = sys.argv[1], int(sys.argv[2])
CLIENT_ID, CLIENT_SECRET, CODE = "12345", "mocksecret1234567890", "MOCKCODE"
ATHLETE = {"id": 987654, "username": "forest_walker", "firstname": "Graham", "lastname": "Hosking"}

lock = threading.Lock()
state = {"next_id": 1000, "fail": 0, "fail_code": 503, "polls": {}, "externals": set(), "uploads": {}, "refresh_token": "REFRESH1"}
# The first token expires within minutes, so the app has to refresh it before its first upload.
tokens = {"ACCESS1": time.time() + 120}


def log(line):
    with lock:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def multipart(body, ctype):
    boundary = re.search(r"boundary=(.+)$", ctype).group(1).strip('"').encode()
    fields, files = {}, {}
    for part in body.split(b"--" + boundary):
        if not part.strip() or part.strip() == b"--":
            continue
        head, _, data = part.partition(b"\r\n\r\n")
        if data.endswith(b"\r\n"):
            data = data[:-2]
        name = re.search(rb'name="([^"]*)"', head).group(1).decode()
        filename = re.search(rb'filename="([^"]*)"', head)
        if filename:
            files[name] = (filename.group(1).decode(), data)
        else:
            fields[name] = data.decode("utf-8")
    return fields, files


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body=None, ctype="application/json"):
        payload = body if isinstance(body, bytes) else (json.dumps(body).encode() if body is not None else b"")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def bearer(self):
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        return token if tokens.get(token, 0) > time.time() else None

    def do_GET(self):
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        if u.path == "/oauth/mobile/authorize":
            log(f"GET authorize client_id={q.get('client_id')} redirect_uri={q.get('redirect_uri')} scope={q.get('scope')} "
                f"response_type={q.get('response_type')} state={q.get('state')}")
            if q.get("client_id") != CLIENT_ID:
                return self.reply(400, {"message": "Bad Request", "errors": [{"resource": "Application", "field": "client_id", "code": "invalid"}]})
            back = f"trailmind://localhost/strava?state={q.get('state', '')}&code={CODE}&scope=read,activity:write"
            page = f'<html><body><h1>Authorize TrailMind</h1><a id="authorize" href="{back}">Authorize</a></body></html>'
            return self.reply(200, page.encode(), "text/html")
        m = re.fullmatch(r"/api/v3/uploads/(\d+)", u.path)
        if m:
            token = self.bearer()
            log(f"GET upload-status id={m.group(1)} auth={'ok' if token else 'bad'}")
            if not token:
                return self.reply(401, {"message": "Authorization Error", "errors": [{"resource": "Athlete", "field": "access_token", "code": "invalid"}]})
            uid = int(m.group(1))
            state["polls"][uid] = state["polls"].get(uid, 0) + 1
            up = state["uploads"].get(uid, {})
            base = {"id": uid, "id_str": str(uid), "external_id": up.get("external_id"), "error": None,
                    "status": "Your activity is still being processed.", "activity_id": None}
            if up.get("duplicate"):
                base.update(error=f"{up.get('name')}.gpx duplicate of activity 4242", status="There was an error processing your activity.")
            elif state["polls"][uid] >= 2:
                base.update(status="Your activity is ready.", activity_id=555000 + uid)
            return self.reply(200, base)
        if u.path == "/__fail":
            state["fail"], state["fail_code"] = int(q.get("n", 1)), int(q.get("code", 503))
            return self.reply(200, {"ok": True})
        self.reply(404, {"message": "Not Found"})

    def do_POST(self):
        u = urlparse(self.path)
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if u.path == "/oauth/token":
            f = {k: v[0] for k, v in parse_qs(body.decode()).items()}
            grant = f.get("grant_type")
            log(f"POST token grant_type={grant} client_id={f.get('client_id')} secret_ok={f.get('client_secret') == CLIENT_SECRET} "
                f"code={f.get('code')} refresh_token={f.get('refresh_token')}")
            if f.get("client_id") != CLIENT_ID or f.get("client_secret") != CLIENT_SECRET:
                return self.reply(401, {"message": "Authorization Error", "errors": [{"resource": "Application", "field": "client_id", "code": "invalid"}]})
            if grant == "authorization_code":
                if f.get("code") != CODE:
                    return self.reply(400, {"message": "Bad Request", "errors": [{"resource": "AuthorizationCode", "field": "code", "code": "invalid"}]})
                return self.reply(200, {"token_type": "Bearer", "expires_at": int(tokens["ACCESS1"]), "expires_in": 120,
                                        "refresh_token": state["refresh_token"], "access_token": "ACCESS1", "athlete": ATHLETE})
            if grant == "refresh_token":
                if f.get("refresh_token") != state["refresh_token"]:
                    return self.reply(400, {"message": "Bad Request", "errors": [{"resource": "RefreshToken", "field": "refresh_token", "code": "invalid"}]})
                state["refresh_token"] = state["refresh_token"] + "N"
                access = "ACCESS" + str(len(state["refresh_token"]))
                tokens[access] = time.time() + 21600
                return self.reply(200, {"token_type": "Bearer", "expires_at": int(tokens[access]), "expires_in": 21600,
                                        "refresh_token": state["refresh_token"], "access_token": access})
            return self.reply(400, {"message": "Bad Request"})
        if u.path == "/oauth/deauthorize":
            log(f"POST deauthorize auth={'ok' if self.bearer() else 'bad'}")
            return self.reply(200, {"access_token": "x"})
        if u.path == "/api/v3/uploads":
            token = self.bearer()
            fields, files = multipart(body, self.headers.get("Content-Type", ""))
            gpx = files.get("file", ("", b""))[1].decode("utf-8", "replace")
            log(f"POST upload auth={'ok' if token else 'bad'} name={fields.get('name')!r} activity_type={fields.get('activity_type')} "
                f"data_type={fields.get('data_type')} external_id={fields.get('external_id')} description={fields.get('description')!r} "
                f"file={files.get('file', ('', b''))[0]} trkpts={gpx.count('<trkpt')} times={gpx.count('<time>')}")
            if not token:
                return self.reply(401, {"message": "Authorization Error", "errors": [{"resource": "Athlete", "field": "access_token", "code": "invalid"}]})
            if state["fail"] > 0:
                state["fail"] -= 1
                return self.reply(state["fail_code"], {"message": "Service Unavailable" if state["fail_code"] >= 500 else "Rate Limit Exceeded"})
            state["next_id"] += 1
            uid = state["next_id"]
            ext = fields.get("external_id")
            state["uploads"][uid] = {"external_id": ext, "name": fields.get("name"), "duplicate": ext in state["externals"]}
            state["externals"].add(ext)
            return self.reply(201, {"id": uid, "id_str": str(uid), "external_id": ext, "error": None,
                                    "status": "Your activity is still being processed.", "activity_id": None})
        self.reply(404, {"message": "Not Found"})

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
