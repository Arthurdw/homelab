"""Minimal SMTP sink for scripts/backup/test/alert-selftest.sh. Test use only; listens on 127.0.0.1.

usage: smtp-sink.py <port> <mode> <cert> <key> <outdir> <user> <pass>
  mode: smtps (implicit TLS), starttls, or plain (never offers TLS, so a client must refuse it)
AUTH (PLAIN or LOGIN) is only offered over TLS and is required before MAIL. Handles one connection
at a time; writes each message to <outdir>/msg-N.eml and one line per session to <outdir>/sessions.log.
"""
import base64
import socket
import ssl
import sys

port, mode, cert, key, outdir, user, pw = sys.argv[1:8]
port = int(port)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(5)
n = 0


def session(conn):
    global n
    tls = False
    if mode == "smtps":
        conn = ctx.wrap_socket(conn, server_side=True)
        tls = True
    f = conn.makefile("rwb", buffering=0)

    def send(s):
        f.write((s + "\r\n").encode())

    def recv():
        line = f.readline()
        if not line:
            raise EOFError
        return line.decode().rstrip("\r\n")

    send("220 sink ready")
    authed, mail_from, rcpts, log = False, None, [], []
    while True:
        line = recv()
        cmd = line.split(" ")[0].upper()
        log.append(cmd)
        if cmd in ("EHLO", "HELO"):
            caps = ["250-sink"]
            if mode == "starttls" and not tls:
                caps.append("250-STARTTLS")
            if tls:
                caps.append("250-AUTH PLAIN LOGIN")
            caps.append("250 OK")
            for c in caps:
                send(c)
        elif cmd == "STARTTLS" and mode == "starttls" and not tls:
            send("220 go ahead")
            conn = ctx.wrap_socket(conn, server_side=True)
            tls = True
            f = conn.makefile("rwb", buffering=0)
        elif cmd == "AUTH":
            if not tls:
                send("530 TLS first")
                continue
            parts = line.split(" ")
            if parts[1].upper() == "PLAIN":
                blob = parts[2] if len(parts) > 2 else None
                if blob is None:
                    send("334 ")
                    blob = recv()
                _, u, p = base64.b64decode(blob).decode().split("\0")
            else:
                send("334 " + base64.b64encode(b"Username:").decode())
                u = base64.b64decode(recv()).decode()
                send("334 " + base64.b64encode(b"Password:").decode())
                p = base64.b64decode(recv()).decode()
            if (u, p) == (user, pw):
                authed = True
                send("235 ok")
            else:
                send("535 bad credentials")
        elif cmd == "MAIL":
            if not authed:
                send("530 auth required")
                continue
            mail_from = line
            send("250 ok")
        elif cmd == "RCPT":
            rcpts.append(line)
            send("250 ok")
        elif cmd == "DATA":
            send("354 go")
            body = []
            while True:
                l = recv()
                if l == ".":
                    break
                body.append(l[1:] if l.startswith("..") else l)
            n += 1
            with open(f"{outdir}/msg-{n}.eml", "w") as out:
                out.write(f"X-Sink-Envelope: {mail_from} | {' | '.join(rcpts)}\n")
                out.write("\n".join(body) + "\n")
            send("250 queued")
        elif cmd == "QUIT":
            send("221 bye")
            break
        else:
            send("502 no")
    with open(f"{outdir}/sessions.log", "a") as lf:
        lf.write(f"tls={tls} authed={authed} cmds={','.join(log)}\n")


while True:
    c, _ = srv.accept()
    try:
        session(c)
    except Exception as e:  # keep serving; record the failure
        with open(f"{outdir}/sessions.log", "a") as lf:
            lf.write(f"error: {e!r}\n")
    finally:
        c.close()
