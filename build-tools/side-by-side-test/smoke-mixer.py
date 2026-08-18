#!/usr/bin/env python3
"""Send PCMU with SSRC changes into the side-by-side test mixer."""
import re
import socket
import struct
import sys
import time

NG = ("127.0.0.1", 23222)


def bencode(x):
    if isinstance(x, int) and not isinstance(x, bool):
        return b"i%de" % x
    if isinstance(x, bytes):
        return b"%d:%s" % (len(x), x)
    if isinstance(x, str):
        return bencode(x.encode())
    if isinstance(x, list):
        return b"l" + b"".join(bencode(i) for i in x) + b"e"
    if isinstance(x, dict):
        items = sorted(((k.encode() if isinstance(k, str) else k), v) for k, v in x.items())
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError(type(x))


def bdecode(buf, i=0):
    if buf[i:i + 1] == b"i":
        j = buf.index(b"e", i)
        return int(buf[i + 1:j]), j + 1
    if buf[i:i + 1] == b"l":
        out, i = [], i + 1
        while buf[i:i + 1] != b"e":
            v, i = bdecode(buf, i)
            out.append(v)
        return out, i + 1
    if buf[i:i + 1] == b"d":
        out, i = {}, i + 1
        while buf[i:i + 1] != b"e":
            k, i = bdecode(buf, i)
            v, i = bdecode(buf, i)
            out[k] = v
        return out, i + 1
    j = buf.index(b":", i)
    n = int(buf[i:j])
    s = buf[j + 1:j + 1 + n]
    return s, j + 1 + n


def ng(cmd):
    cookie = b"mixfix"
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    s.sendto(cookie + b" " + bencode(cmd), NG)
    data, _ = s.recvfrom(65535)
    s.close()
    body = data.split(b" ", 1)[1]
    parsed, _ = bdecode(body)
    print("NG", cmd["command"], parsed.get(b"result", b"?"))
    return parsed


def sdp_audio():
    return (
        "v=0\r\n"
        "o=- 0 0 IN IP4 127.0.0.1\r\n"
        "s=mixer-ssrc\r\n"
        "c=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\n"
        "m=audio 45000 RTP/AVP 0\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
    )


def parse_media(sdp):
    text = sdp.decode() if isinstance(sdp, bytes) else sdp
    ip = re.search(r"c=IN IP4 (\S+)", text).group(1)
    port = int(re.search(r"m=audio (\d+)", text).group(1))
    return ip, port


def rtp_pkt(seq, ts, ssrc):
    return struct.pack("!BBHII", 0x80, 0, seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc) + (b"\xFF" * 160)


def send_burst(sock, dest, ssrc, start_seq, start_ts, n=25):
    for i in range(n):
        sock.sendto(rtp_pkt(start_seq + i, start_ts + i * 160, ssrc), dest)
        time.sleep(0.02)
    return start_seq + n, start_ts + n * 160


def main():
    callid = "mixer-ssrc-test-%d" % int(time.time())
    print("call-id", callid)
    offer = ng({
        "command": "offer",
        "call-id": callid,
        "from-tag": "ftag1",
        "sdp": sdp_audio(),
        "record-call": "yes",
        "replace": ["origin", "session-connection"],
    })
    if offer.get(b"result") != b"ok":
        print("offer failed", offer)
        sys.exit(2)
    b_ip, b_port = parse_media(offer[b"sdp"])
    answer = ng({
        "command": "answer",
        "call-id": callid,
        "from-tag": "ftag1",
        "to-tag": "ttag1",
        "sdp": sdp_audio(),
        "record-call": "yes",
    })
    if answer.get(b"result") != b"ok":
        print("answer failed", answer)
        sys.exit(2)
    a_ip, a_port = parse_media(answer[b"sdp"])
    print("A -> %s:%d   B -> %s:%d" % (a_ip, a_port, b_ip, b_port))
    sa = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sb = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sa.bind(("127.0.0.1", 0))
    sb.bind(("127.0.0.1", 0))
    a_ssrcs = [0x0A9B50C, 0x0101A0E4, 0xBB215A44]
    b_ssrcs = [0x3FA4A7BF, 0x2F99354D, 0xE7C4F263]
    aseq = bseq = 1000
    ats = bts = 8000
    for i, (assrc, bssrc) in enumerate(zip(a_ssrcs, b_ssrcs)):
        print("burst %d A=0x%x B=0x%x" % (i, assrc, bssrc))
        aseq, ats = send_burst(sa, (a_ip, a_port), assrc, aseq, ats)
        bseq, bts = send_burst(sb, (b_ip, b_port), bssrc, bseq, bts)
        time.sleep(0.3)
    sa.close()
    sb.close()
    time.sleep(0.5)
    ng({"command": "delete", "call-id": callid})
    time.sleep(1.5)
    open("/tmp/mixer-ssrc-callid.txt", "w").write(callid)
    print("done", callid)


if __name__ == "__main__":
    main()
