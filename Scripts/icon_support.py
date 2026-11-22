"""Pure-stdlib macOS AppIcon.icns generator for Agent Stats."""
import math
import pathlib
import struct
import zlib


def _clamp(value, low=0.0, high=1.0):
    return low if value < low else (high if value > high else value)


def _mix(a, b, t):
    return a + (b - a) * t


def _blend_over(bg_r, bg_g, bg_b, bg_a, fg_r, fg_g, fg_b, fg_a):
    if fg_a <= 0.0:
        return bg_r, bg_g, bg_b, bg_a
    if fg_a >= 1.0:
        return fg_r, fg_g, fg_b, 1.0
    out_a = fg_a + bg_a * (1.0 - fg_a)
    if out_a <= 0.0:
        return 0.0, 0.0, 0.0, 0.0
    inv = 1.0 - fg_a
    return (
        (fg_r * fg_a + bg_r * bg_a * inv) / out_a,
        (fg_g * fg_a + bg_g * bg_a * inv) / out_a,
        (fg_b * fg_a + bg_b * bg_a * inv) / out_a,
        out_a,
    )


def _rounded_box_sdf(px, py, half_w, half_h, radius):
    qx = abs(px) - half_w + radius
    qy = abs(py) - half_h + radius
    ox = qx if qx > 0.0 else 0.0
    oy = qy if qy > 0.0 else 0.0
    inside = qx if qx > qy else qy
    if inside > 0.0:
        inside = 0.0
    return math.hypot(ox, oy) + inside - radius


def _segment_sdf(px, py, ax, ay, bx, by):
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    denom = vx * vx + vy * vy
    t = _clamp((wx * vx + wy * vy) / denom) if denom > 0.0 else 0.0
    dx = wx - vx * t
    dy = wy - vy * t
    return math.hypot(dx, dy)


def _arc_sdf(dx, dy, radius, half_thickness, start_deg, end_deg):
    # Screen coordinates: 0 deg = right, 90 deg = down, 135 deg = bottom-left,
    # 270 deg = top, 405 deg (45 deg) = bottom-right.
    angle = math.degrees(math.atan2(dy, dx))
    if angle < 90.0:
        angle += 360.0
    clamped = start_deg if angle < start_deg else (end_deg if angle > end_deg else angle)
    rad = math.radians(clamped)
    cx = math.cos(rad) * radius
    cy = math.sin(rad) * radius
    return math.hypot(dx - cx, dy - cy) - half_thickness


def _png_chunk(tag, data):
    body = tag + data
    return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body) & 0xFFFFFFFF)


def _encode_png(width, height, rows):
    raw = bytearray()
    for row in rows:
        raw.append(0)
        raw.extend(row)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    idat = zlib.compress(bytes(raw), level=6)
    return b'\x89PNG\r\n\x1a\n' + _png_chunk(b'IHDR', ihdr) + _png_chunk(b'IDAT', idat) + _png_chunk(b'IEND', b'')


def render_icon_png(size):
    half_box = size * 0.402
    corner = size * 0.178
    center = size * 0.5
    gauge_cx = center
    gauge_cy = size * 0.525
    gauge_r = size * 0.232
    stroke_half = size * 0.025
    dot_r = size * 0.014
    tick_r = gauge_r * 0.69
    tick_angles = [135.0, 180.0, 225.0, 270.0, 315.0, 360.0, 405.0]
    ticks = [(math.cos(math.radians(a)) * tick_r, math.sin(math.radians(a)) * tick_r) for a in tick_angles]

    needle_rad = math.radians(320.0)
    needle_len = gauge_r * 0.78
    needle_ax = math.cos(needle_rad) * (size * 0.018)
    needle_ay = math.sin(needle_rad) * (size * 0.018)
    needle_bx = math.cos(needle_rad) * needle_len
    needle_by = math.sin(needle_rad) * needle_len
    hub_r = size * 0.040

    gauge_bound = gauge_r + stroke_half + 4.0
    shadow_offset_y = size * 0.016
    shadow_blur = size * 0.032

    rows = []
    for y in range(size):
        row = bytearray(size * 4)
        py = (y + 0.5) - center
        t_grad = _clamp(((y + 0.5) - (center - half_box)) / (half_box * 2.0))
        # Subtle curved gradient from bright Apple blue (#389BFF) to deep blue (#0053D6)
        grad_r = _mix(56.0, 0.0, t_grad) / 255.0
        grad_g = _mix(155.0, 83.0, t_grad) / 255.0
        grad_b = _mix(255.0, 214.0, t_grad) / 255.0

        dy_gauge = (y + 0.5) - gauge_cy
        in_gauge_y = abs(dy_gauge) <= gauge_bound

        for x in range(size):
            px = (x + 0.5) - center
            r, g, b, a = 0.0, 0.0, 0.0, 0.0

            # Soft drop shadow outside the tile
            sd_shadow = _rounded_box_sdf(px, py - shadow_offset_y, half_box, half_box, corner)
            if sd_shadow < shadow_blur:
                shadow_t = _clamp(1.0 - sd_shadow / shadow_blur)
                a = 0.24 * shadow_t * shadow_t

            sd_tile = _rounded_box_sdf(px, py, half_box, half_box, corner)
            tile_cov = _clamp(0.5 - sd_tile)
            if tile_cov > 0.0:
                # Subtle top-edge highlight inside tile
                highlight = _clamp(1.0 - abs(sd_tile + 1.5) / 2.2) * _clamp(1.0 - t_grad * 1.8) * 0.28
                tr = _clamp(grad_r + highlight)
                tg = _clamp(grad_g + highlight)
                tb = _clamp(grad_b + highlight * 0.7)
                r, g, b, a = _blend_over(r, g, b, a, tr, tg, tb, tile_cov)

                if in_gauge_y:
                    dx_gauge = (x + 0.5) - gauge_cx
                    if abs(dx_gauge) <= gauge_bound:
                        # Subtle translucent full 270-degree track arc
                        sd_track = _arc_sdf(dx_gauge, dy_gauge, gauge_r, stroke_half, 135.0, 405.0)
                        track_cov = _clamp(0.5 - sd_track)
                        if track_cov > 0.0:
                            r, g, b, a = _blend_over(r, g, b, a, 1.0, 1.0, 1.0, track_cov * 0.30 * tile_cov)

                        # Active bright arc up to the needle
                        sd_active = _arc_sdf(dx_gauge, dy_gauge, gauge_r, stroke_half, 135.0, 320.0)
                        active_cov = _clamp(0.5 - sd_active)
                        if active_cov > 0.0:
                            r, g, b, a = _blend_over(r, g, b, a, 1.0, 1.0, 1.0, active_cov * 0.96 * tile_cov)

                        # Gauge dots along inner arc
                        for tx, ty in ticks:
                            sd_dot = math.hypot(dx_gauge - tx, dy_gauge - ty) - dot_r
                            dot_cov = _clamp(0.5 - sd_dot)
                            if dot_cov > 0.0:
                                r, g, b, a = _blend_over(r, g, b, a, 1.0, 1.0, 1.0, dot_cov * 0.72 * tile_cov)

                        # Needle and center hub
                        sd_needle = _segment_sdf(dx_gauge, dy_gauge, needle_ax, needle_ay, needle_bx, needle_by) - (size * 0.017)
                        sd_hub = math.hypot(dx_gauge, dy_gauge) - hub_r
                        needle_cov = _clamp(0.5 - min(sd_needle, sd_hub))
                        if needle_cov > 0.0:
                            r, g, b, a = _blend_over(r, g, b, a, 1.0, 1.0, 1.0, needle_cov * tile_cov)

            offset = x * 4
            row[offset] = int(r * 255.0 + 0.5)
            row[offset + 1] = int(g * 255.0 + 0.5)
            row[offset + 2] = int(b * 255.0 + 0.5)
            row[offset + 3] = int(a * 255.0 + 0.5)
        rows.append(bytes(row))
    return _encode_png(size, size, rows)


def build_icns_bytes():
    chunks = []
    for chunk_type, size in ((b'ic08', 256), (b'ic09', 512)):
        png = render_icon_png(size)
        chunks.append(chunk_type + struct.pack('>I', len(png) + 8) + png)
    body = b''.join(chunks)
    return b'icns' + struct.pack('>I', len(body) + 8) + body


def write_app_icon(destination):
    target = pathlib.Path(destination)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(build_icns_bytes())
    return target
