#!/usr/bin/env python3
"""Exercise recording mixer slot reuse across hold/resume SSRC changes.

Run this against the side-by-side RTPengine/recording-daemon harness, then
verify that the recording log has no "old re-used input channel" errors.
"""
import re
import socket
import struct
import sys
import time
import audioop
import math
import os

NG = ("127.0.0.1", 23222)
PHASE_COUNT = int(os.environ.get("MIXER_PHASE_COUNT", "60"))
PACKET_SLEEP = float(os.environ.get("MIXER_PACKET_SLEEP", "0.02"))
HOLD_SLEEP = float(os.environ.get("MIXER_HOLD_SLEEP", "1.2"))


def bencode(value):
    if isinstance(value, int) and not isinstance(value, bool):
        return b"i%de" % value
    if isinstance(value, str):
        value = value.encode()
    if isinstance(value, bytes):
        return b"%d:%s" % (len(value), value)
    if isinstance(value, list):
        return b"l" + b"".join(bencode(x) for x in value) + b"e"
    if isinstance(value, dict):
        items = sorted(((k.encode() if isinstance(k, str) else k), v)
                       for k, v in value.items())
        return b"d" + b"".join(bencode(k) + bencode(v)
                                for k, v in items) + b"e"
    raise TypeError(type(value))


def bdecode(buf, pos=0):
    if buf[pos:pos + 1] == b"i":
        end = buf.index(b"e", pos)
        return int(buf[pos + 1:end]), end + 1
    if buf[pos:pos + 1] == b"l":
        result = []
        pos += 1
        while buf[pos:pos + 1] != b"e":
            value, pos = bdecode(buf, pos)
            result.append(value)
        return result, pos + 1
    if buf[pos:pos + 1] == b"d":
        result = {}
        pos += 1
        while buf[pos:pos + 1] != b"e":
            key, pos = bdecode(buf, pos)
            result[key], pos = bdecode(buf, pos)
        return result, pos + 1
    end = buf.index(b":", pos)
    size = int(buf[pos:end])
    return buf[end + 1:end + 1 + size], end + 1 + size


def ng(command):
    cookie = ("mixer-ssrc-%d" % time.time_ns()).encode()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(3)
    sock.sendto(cookie + b" " + bencode(command), NG)
    response, _ = sock.recvfrom(65535)
    sock.close()
    body = response.split(b" ", 1)[1]
    result, _ = bdecode(body)
    if result.get(b"result") != b"ok":
        raise RuntimeError(result)
    return result


def sdp_audio(port):
    return ("v=0\r\n" "o=- 0 0 IN IP4 127.0.0.1\r\n" "s=mixer-ssrc\r\n"
            "c=IN IP4 127.0.0.1\r\n" "t=0 0\r\n"
            "m=audio %d RTP/AVP 0 127\r\n" % port
            + "a=rtpmap:0 PCMU/8000\r\n"
            + "a=rtcp:%d\r\n" % (port + 1))


def parse_media(sdp):
    text = sdp.decode() if isinstance(sdp, bytes) else sdp
    return (re.search(r"c=IN IP4 (\S+)", text).group(1),
            int(re.search(r"m=audio (\d+)", text).group(1)))


def rtp_packet(seq, timestamp, ssrc, payload_type=0, payload=b"\xff" * 160):
    return struct.pack("!BBHII", 0x80, payload_type & 0x7f, seq & 0xffff,
                       timestamp & 0xffffffff, ssrc) + payload


def tone_payload(freq, start_sample, count=160):
    pcm = b"".join(struct.pack("<h", int(9000 * math.sin(
        2 * math.pi * freq * (start_sample + i) / 8000)))
                   for i in range(count))
    return audioop.lin2ulaw(pcm, 2)


def send_phase(sockets, destinations, ssrcs, sequences, timestamps,
               sample_offsets, frequencies, count=PHASE_COUNT):
    """Send both logical streams interleaved, as in a live two-leg call."""
    for _ in range(count):
        for side in range(2):
            sockets[side].sendto(
                rtp_packet(sequences[side], timestamps[side], ssrcs[side],
                           payload=tone_payload(frequencies[side],
                                                sample_offsets[side])),
                destinations[side])
            sequences[side] += 1
            timestamps[side] += 160
            sample_offsets[side] += 160
        time.sleep(PACKET_SLEEP)


def send_nat_probes(sockets, destinations, sequences, timestamps):
    """Send PT 127 NAT-pierce packets; recording must ignore them."""
    for _ in range(5):
        for side in range(2):
            sockets[side].sendto(
                rtp_packet(0xffff, 0, 0, payload_type=127, payload=b""),
                destinations[side])
        time.sleep(0.05)


def main():
    call_id = "mixer-ssrc-test-%d" % int(time.time())
    a_port, b_port = 46000, 46002
    offer = ng({"command": "offer", "call-id": call_id, "from-tag": "ftag1",
                "sdp": sdp_audio(a_port), "record-call": "yes",
                "replace": ["origin", "session-connection"]})
    a_destination = parse_media(offer[b"sdp"])
    answer = ng({"command": "answer", "call-id": call_id, "from-tag": "ftag1",
                 "to-tag": "ttag1", "sdp": sdp_audio(b_port), "record-call": "yes"})
    b_destination = parse_media(answer[b"sdp"])
    print("A -> %s:%d, B -> %s:%d" % (a_destination[0], a_destination[1],
                                      b_destination[0], b_destination[1]))
    sockets = [socket.socket(socket.AF_INET, socket.SOCK_DGRAM) for _ in range(2)]
    sockets[0].bind(("127.0.0.1", a_port))
    sockets[1].bind(("127.0.0.1", b_port))
    ssrc_phases = ([0x0A9B50C, 0x0101A0E4, 0xBB215A44, 0x44001122],
                   [0x3FA4A7BF, 0x2F99354D, 0xE7C4F263, 0x55002233])
    destinations = [a_destination, b_destination]
    try:
        sequence = [1000, 2000]
        timestamp = [8000, 12000]
        sample_offsets = [0, 0]
        frequencies = [400, 800]
        print("phase 0: initial media")
        send_phase(sockets, destinations,
                   [ssrc_phases[0][0], ssrc_phases[1][0]], sequence, timestamp,
                   sample_offsets, frequencies)
        print("hold: media pause and PT 127 NAT probes")
        send_nat_probes(sockets, destinations, sequence, timestamp)
        time.sleep(HOLD_SLEEP)

        print("resume: new SSRCs, reset RTP sequence/timestamp")
        sequence = [1000, 2000]
        timestamp = [8000, 12000]
        send_phase(sockets, destinations,
                   [ssrc_phases[0][1], ssrc_phases[1][1]], sequence, timestamp,
                   sample_offsets, frequencies)

        print("re-INVITE: same logical streams, new SSRCs")
        renegotiated = ng({"command": "offer", "call-id": call_id,
                           "from-tag": "ftag1", "sdp": sdp_audio(a_port),
                           "record-call": "yes"})
        destinations[0] = parse_media(renegotiated[b"sdp"])
        renegotiated = ng({"command": "answer", "call-id": call_id,
                           "from-tag": "ftag1", "to-tag": "ttag1",
                           "sdp": sdp_audio(b_port), "record-call": "yes"})
        destinations[1] = parse_media(renegotiated[b"sdp"])
        sequence = [3000, 4000]
        timestamp = [16000, 20000]
        send_phase(sockets, destinations,
                   [ssrc_phases[0][2], ssrc_phases[1][2]], sequence, timestamp,
                   sample_offsets, frequencies)

        print("resume 2: fourth SSRC pair exceeds the old four-slot churn")
        time.sleep(HOLD_SLEEP)
        sequence = [5000, 6000]
        timestamp = [24000, 28000]
        send_phase(sockets, destinations,
                   [ssrc_phases[0][3], ssrc_phases[1][3]], sequence, timestamp,
                   sample_offsets, frequencies)

        # Model packets that were already queued by the first SSRC generation
        # but arrive after its slot has been recycled by the fourth generation.
        print("late packets from old SSRCs after slot reuse")
        late_sequence = [50000, 51000]
        late_timestamp = [40000, 44000]
        late_frequencies = [1200, 1600]
        for _ in range(5):
            for side in range(2):
                sockets[side].sendto(
                    rtp_packet(late_sequence[side], late_timestamp[side],
                               ssrc_phases[side][0],
                               payload=tone_payload(late_frequencies[side],
                                                    sample_offsets[side])),
                    destinations[side])
                late_sequence[side] += 1
                late_timestamp[side] += 160
                sample_offsets[side] += 160
            time.sleep(PACKET_SLEEP)
        time.sleep(max(0.2, HOLD_SLEEP))
    finally:
        for sock in sockets:
            sock.close()
        ng({"command": "delete", "call-id": call_id,
            "from-tag": "ftag1", "to-tag": "ttag1"})
    print("completed SSRC churn test for", call_id)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, KeyError, AttributeError) as error:
        print("mixer SSRC smoke failed:", error, file=sys.stderr)
        sys.exit(2)