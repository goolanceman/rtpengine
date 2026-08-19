#!/usr/bin/env python3
"""Offline model of mix_get_index idle-guard (no ffmpeg). Exit 0 on pass."""
from __future__ import annotations

IDLE_US = 1_000_000
MAX = 16
DEFAULT = 6


class Mix:
    def __init__(self, n=DEFAULT):
        self.n = n
        self.input_ref = [None] * MAX
        self.stream_ref = [None] * MAX
        self.last_use = [None] * MAX  # us or None
        self.next_idx = 0
        self.now = 0

    def idle(self, i):
        if self.input_ref[i] is None:
            return True
        if self.last_use[i] is None:
            return False
        return (self.now - self.last_use[i]) >= IDLE_US

    def reset(self, i):
        self.input_ref[i] = None
        self.stream_ref[i] = None
        self.last_use[i] = None

    def assign(self, i, ssrc, stream):
        self.input_ref[i] = ssrc
        self.stream_ref[i] = stream
        if i >= self.next_idx:
            self.next_idx = i + 1
        return i

    def get(self, ssrc, stream, media_sdp_id=0):
        for i in range(self.n):
            if self.input_ref[i] is ssrc:
                return i
        if stream is not None:
            for i in range(self.n):
                if self.stream_ref[i] is stream:
                    return i
        nxt = media_sdp_id if False else self.next_idx
        if nxt < self.n and self.input_ref[nxt] is None:
            return self.assign(nxt, ssrc, stream)
        for i in range(self.n):
            if self.input_ref[i] is None:
                return self.assign(i, ssrc, stream)
        raise AssertionError("slots exhausted")

    def add(self, idx, ssrc, stream):
        if self.stream_ref[idx] is not stream:
            raise RuntimeError("old re-used input channel")
        self.input_ref[idx] = ssrc
        self.last_use[idx] = self.now


def expect(cond, msg):
    if not cond:
        raise SystemExit("FAIL: " + msg)


def main():
    tag1, a, b = object(), object(), object()
    m = Mix(4)
    i0 = m.get(a, tag1); m.add(i0, a, tag1)
    m.now = 100_000  # 100ms later, overlapping SSRC
    i1 = m.get(b, tag1)
    expect(i1 == i0, "SSRC churn must keep the logical stream slot")
    m.add(i0, a, tag1)  # old generation still mixes
    m.add(i1, b, tag1)  # new generation stays on the same channel
    other = m.get(object(), tag1)
    expect(other == i0, "all SSRC generations of one stream share one slot")
    m.now = 2_000_000
    c = object()
    i2 = m.get(c, tag1)
    expect(i2 == i0, "logical stream slot must not be recycled during SSRC churn")
    m.add(i2, c, tag1)

    tag2 = object()
    b_slot = m.get(object(), tag2)
    expect(b_slot != i0, "different logical streams must not overlap")
    m.add(b_slot, object(), tag2)
    try:
        m.add(i0, object(), tag2)
        raise SystemExit("FAIL: a stream must not enter another stream's channel")
    except RuntimeError:
        pass

    # A full mixer must not evict a live logical stream.
    full = Mix(2)
    s1, s2, s3 = object(), object(), object()
    stream1, stream2, stream3 = object(), object(), object()
    full.add(full.get(s1, stream1), s1, stream1)
    full.add(full.get(s2, stream2), s2, stream2)
    try:
        full.get(s3, stream3)
        raise SystemExit("FAIL: live slot must not be evicted when mixer is full")
    except AssertionError:
        pass

    # The production defaults provide six logical slots, while the compile-time
    # ceiling allows up to sixteen without treating SSRC generations as slots.
    default = Mix()
    default_ssrcs = [object() for _ in range(DEFAULT)]
    default_streams = [object() for _ in range(DEFAULT)]
    default_slots = [default.get(ssrc, stream)
                     for ssrc, stream in zip(default_ssrcs, default_streams)]
    expect(default_slots == list(range(DEFAULT)),
           "default mixer must provide six logical slots")

    maximum = Mix(MAX)
    maximum_ssrcs = [object() for _ in range(MAX)]
    maximum_streams = [object() for _ in range(MAX)]
    maximum_slots = [maximum.get(ssrc, stream)
                     for ssrc, stream in zip(maximum_ssrcs, maximum_streams)]
    expect(maximum_slots == list(range(MAX)),
           "mixer must support sixteen logical slots")
    print("OK mix-index: logical slots survive SSRC churn without overlap")


if __name__ == "__main__":
    main()
