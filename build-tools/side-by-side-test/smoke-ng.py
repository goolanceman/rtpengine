#!/usr/bin/env python3
"""NG smoke against side-by-side test daemon on 127.0.0.1:23222 only."""
import socket
import sys
import time

NG = ("127.0.0.1", 23222)


def bencode(x):
    if isinstance(x, bool):
        raise TypeError("bool")
    if isinstance(x, int):
        return b"i%de" % x
    if isinstance(x, bytes):
        return b"%d:%s" % (len(x), x)
    if isinstance(x, str):
        return bencode(x.encode())
    if isinstance(x, list):
        return b"l" + b"".join(bencode(i) for i in x) + b"e"
    if isinstance(x, dict):
        items = sorted(
            ((k.encode() if isinstance(k, str) else k), v) for k, v in x.items()
        )
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError(type(x))


def ng(cmd):
    cookie = b"sbyside"
    payload = cookie + b" " + bencode(cmd)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    s.sendto(payload, NG)
    try:
        data, _ = s.recvfrom(65535)
    except Exception as e:
        print("NG error:", e)
        sys.exit(2)
    finally:
        s.close()
    print("NG OK:", data[:200])
    return data


def main():
    callid = "side-by-side-test-%d" % int(time.time())
    sdp = (
        "v=0\r\n"
        "o=- 0 0 IN IP4 127.0.0.1\r\n"
        "s=side-by-side\r\n"
        "c=IN IP4 127.0.0.1\r\n"
        "t=0 0\r\n"
        "m=audio 45000 RTP/AVP 0\r\n"
        "a=rtpmap:0 PCMU/8000\r\n"
    )
    print("call-id", callid)
    print("--- offer record-call=yes ---")
    ng(
        {
            "command": "offer",
            "call-id": callid,
            "from-tag": "ftag1",
            "sdp": sdp,
            "record-call": "yes",
            "metadata": "session_id:SIDEBYSIDE|calling:1001|called:2002",
            "replace": ["origin", "session-connection"],
        }
    )
    time.sleep(0.5)
    print("--- answer ---")
    ng(
        {
            "command": "answer",
            "call-id": callid,
            "from-tag": "ftag1",
            "to-tag": "ttag1",
            "sdp": sdp,
            "record-call": "yes",
        }
    )
    time.sleep(0.8)
    print("--- delete ---")
    ng({"command": "delete", "call-id": callid})
    time.sleep(1.2)
    open("/tmp/side-by-side-callid.txt", "w").write(callid)
    print("done", callid)


if __name__ == "__main__":
    main()
