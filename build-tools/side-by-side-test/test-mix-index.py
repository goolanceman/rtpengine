#!/usr/bin/env python3
"""Offline model of mix_get_index idle-guard (no ffmpeg). Exit 0 on pass."""
from __future__ import annotations

IDLE_US = 1_000_000
MAX = 16


class Mix:
    def __init__(self, n=4):
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
            reuse, any_live = self.n, False
            for i in range(self.n):
                if self.stream_ref[i] is not stream:
                    continue
                if not self.idle(i):
                    any_live = True
                    break
                if reuse == self.n:
                    reuse = i
            if not any_live and reuse < self.n:
                self.reset(reuse)
                return self.assign(reuse, ssrc, stream)
        nxt = media_sdp_id if False else self.next_idx
        if nxt < self.n and (self.input_ref[nxt] is None or (
                self.stream_ref[nxt] is stream and self.idle(nxt))):
            if self.input_ref[nxt] is not None and self.input_ref[nxt] is not ssrc:
                self.reset(nxt)
            return self.assign(nxt, ssrc, stream)
        for i in range(self.n):
            if self.input_ref[i] is None:
                return self.assign(i, ssrc, stream)
        raise AssertionError("slots exhausted")

    def add(self, idx, ssrc):
        if self.input_ref[idx] is not ssrc:
            raise RuntimeError("old re-used input channel")
        self.last_use[idx] = self.now


def expect(cond, msg):
    if not cond:
        raise SystemExit("FAIL: " + msg)


def main():
    tag1, a, b = object(), object(), object()
    m = Mix(4)
    i0 = m.get(a, tag1); m.add(i0, a)
    m.now = 100_000  # 100ms later, overlapping SSRC
    i1 = m.get(b, tag1)
    expect(i1 != i0, "overlap must get a new slot")
    m.add(i0, a)  # original SSRC still mixes
    m.add(i1, b)
    m.now = 2_000_000
    c = object()
    i2 = m.get(c, tag1)
    expect(i2 in (i0, i1), "idle stream slot must be reused")
    try:
        m.add(i2, a)
        raise SystemExit("FAIL: stolen slot must reject old SSRC")
    except RuntimeError:
        pass
    i0b = m.get(a, tag1)
    expect(i0b != i2, "live-again SSRC after steal gets its own slot")

    # A full mixer must not evict a live SSRC. Dropping mixed output is safer
    # than corrupting the active channel and producing a persistent mismatch.
    full = Mix(2)
    s1, s2, s3 = object(), object(), object()
    full.add(full.get(s1, object()), s1)
    full.add(full.get(s2, object()), s2)
    try:
        full.get(s3, object())
        raise SystemExit("FAIL: live slot must not be evicted when mixer is full")
    except AssertionError:
        pass
    print("OK mix-index: overlap keeps slots, idle reuses, no silent steal")


if __name__ == "__main__":
    main()
