"""Read the frame-mark strip drawn by RappTestPage (same rule as Sources/RappCore/FrameMark.swift).

18 cells of `cell_px` pixels starting at (x0, y0): cell 0 black, cell 1 white (sync), cells 2..17 are
bits 15..0 of the frame number, black = 1. A cell reads as the mean luma of its centre 8x8 px, < 128 = black.
Channel order does not matter for the black/white cells, so RGBA and BGRA buffers both work.
"""

CELLS = 18


def _cell_luma(buf, width, x0, y0, cell_px, i):
    half = 4
    cx = x0 + i * cell_px + cell_px // 2
    cy = y0 + cell_px // 2
    total = 0
    for y in range(cy - half, cy + half):
        row = (y * width + cx - half) * 4
        for x in range(8):
            o = row + x * 4
            total += (buf[o] * 299 + buf[o + 1] * 587 + buf[o + 2] * 114) // 1000
    return total // 64


def read_mark(rgba, width, x0, y0, cell_px):
    """Frame number in the strip at (x0, y0), or None if the sync cells do not read black, white
    (or the strip lies outside the buffer)."""
    if x0 < 4 or y0 < 4 or cell_px < 8 or (y0 + cell_px // 2 + 4) * width * 4 > len(rgba) \
            or x0 + CELLS * cell_px > width:
        return None
    luma = lambda i: _cell_luma(rgba, width, x0, y0, cell_px, i)
    if not (luma(0) < 128 and luma(1) >= 128):
        return None
    n = 0
    for i in range(2, CELLS):
        n = (n << 1) | (1 if luma(i) < 128 else 0)
    return n


def _draw(n, width, height, x0, y0, cell_px):
    buf = bytearray(b"\xff" * (width * height * 4))
    cells = [True, False] + [(n >> b) & 1 == 1 for b in range(15, -1, -1)]
    for i, black in enumerate(cells):
        if not black:
            continue
        for y in range(y0, y0 + cell_px):
            for x in range(x0 + i * cell_px, x0 + (i + 1) * cell_px):
                o = (y * width + x) * 4
                buf[o:o + 3] = b"\0\0\0"
    return bytes(buf)


if __name__ == "__main__":
    W, H, X0, Y0, C = 480, 64, 12, 12, 24
    for n in (0, 1, 65535, 12345):
        assert read_mark(_draw(n, W, H, X0, Y0, C), W, X0, Y0, C) == n, n
    scaled = _draw(777, 960, 128, 24, 24, 48)  # a 2x canvas
    assert read_mark(scaled, 960, 24, 24, 48) == 777
    assert read_mark(bytes(b"\xff" * (W * H * 4)), W, X0, Y0, C) is None  # all white: cell 0 not black
    assert read_mark(bytes(W * H * 4), W, X0, Y0, C) is None  # all black: cell 1 not white
    print("frame_mark self-test ok")
