#!/usr/bin/env python3
import argparse
import json
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Optional


@dataclass(frozen=True)
class Source:
    kind: str  # 'zip' | 'dir'
    path: Path
    root: str

    def read_text(self, rel: str) -> str:
        if self.kind == 'dir':
            return (self.path / self.root / rel).read_text(encoding='utf-8')
        with zipfile.ZipFile(self.path) as zf:
            with zf.open(f"{self.root}{rel}") as f:
                return f.read().decode('utf-8')


def detect_root_in_zip(zf: zipfile.ZipFile) -> str:
    # pick the first top-level directory
    roots = set()
    for name in zf.namelist():
        if '/' in name:
            roots.add(name.split('/', 1)[0] + '/')
    if len(roots) == 1:
        return next(iter(roots))
    # fallback: common pattern
    for r in sorted(roots):
        if r.endswith('/'):
            return r
    raise SystemExit('Cannot detect skin root folder in zip; pass --root')


def open_source(path: str, root: Optional[str]) -> Source:
    p = Path(path)
    if p.is_dir():
        detected = root or ''
        if not detected:
            # choose first subdir as root
            subs = [d.name + '/' for d in p.iterdir() if d.is_dir()]
            if len(subs) == 1:
                detected = subs[0]
            else:
                raise SystemExit('Cannot detect root folder in directory; pass --root')
        return Source(kind='dir', path=p, root=detected)

    if not p.exists():
        raise SystemExit(f'Not found: {p}')
    with zipfile.ZipFile(p) as zf:
        detected = root + '/' if root and not root.endswith('/') else (root or detect_root_in_zip(zf))
    return Source(kind='zip', path=p, root=detected)


def parse_width(expr: Any, base: float) -> float:
    if expr is None:
        return base
    if isinstance(expr, (int, float)):
        return float(expr)
    if not isinstance(expr, str):
        return base
    if '/' in expr:
        num_s, den_s = expr.split('/', 1)
        return float(num_s) / float(den_s) * base
    return float(expr)


def pick_conditional_style(foreground_style: Any, *, ascii_mode: bool, return_key_type: Optional[int]) -> Any:
    # foreground_style can be:
    # - 'styleName'
    # - ['styleName1', ...]
    # - [{'conditionKey':..., 'styleName':...}, ...]
    if not isinstance(foreground_style, list) or not foreground_style:
        return foreground_style

    if all(isinstance(x, str) for x in foreground_style):
        return foreground_style

    if all(isinstance(x, dict) and 'conditionKey' in x and 'styleName' in x for x in foreground_style):
        for entry in foreground_style:
            ck = entry.get('conditionKey')
            cv = entry.get('conditionValue')
            if ck == 'rime$ascii_mode':
                if cv is None and ascii_mode:
                    return entry['styleName']
                if cv is False and not ascii_mode:
                    return entry['styleName']
            if ck == '$returnKeyType' and return_key_type is not None:
                values = entry.get('conditionValue')
                if isinstance(values, list) and return_key_type in values:
                    return entry['styleName']
        return foreground_style[0].get('styleName')

    return foreground_style


def as_list(x: Any) -> list[Any]:
    if x is None:
        return []
    if isinstance(x, list):
        return x
    return [x]


def svg_escape(s: str) -> str:
    return (
        s.replace('&', '&amp;')
        .replace('<', '&lt;')
        .replace('>', '&gt;')
        .replace('"', '&quot;')
        .replace("'", '&#39;')
    )


def main() -> None:
    ap = argparse.ArgumentParser(description='Preview Hamster3 keyboard layout as SVG (approx).')
    ap.add_argument('source', help='Path to .cskin (zip) or extracted skin directory')
    ap.add_argument('theme', choices=['light', 'dark'])
    ap.add_argument('keyboard', help='Keyboard name, e.g. pinyinPortrait')
    ap.add_argument('--root', help='Skin root folder name (e.g. ios-csheng)', default=None)
    ap.add_argument('--ascii', action='store_true', help='Preview with ascii_mode=true')
    ap.add_argument('--return-key-type', type=int, default=None, help='Optional $returnKeyType')
    ap.add_argument('--out', help='Output SVG path (default: stdout)', default=None)
    args = ap.parse_args()

    src = open_source(args.source, args.root)
    raw = src.read_text(f'{args.theme}/{args.keyboard}.yaml')
    # These yaml files are actually JSON.
    obj = json.loads(raw)

    base_w = 1125.0
    rows = obj.get('keyboardLayout') or []
    if not isinstance(rows, list) or not rows:
        raise SystemExit('keyboardLayout not found')

    keyboard_h = float(obj.get('keyboardHeight') or 0) or 240.0
    row_h = keyboard_h / len(rows)

    # background style
    kb_style = obj.get('keyboardStyle') or {}
    kb_bg_name = kb_style.get('backgroundStyle')
    kb_bg = obj.get(kb_bg_name) if isinstance(kb_bg_name, str) else None
    kb_bg_color = None
    if isinstance(kb_bg, dict) and kb_bg.get('buttonStyleType') == 'geometry':
        kb_bg_color = kb_bg.get('normalColor')

    # button background insets by style name
    def bg_insets(style_name: str) -> tuple[float, float, float, float, float]:
        style = obj.get(style_name)
        if not isinstance(style, dict):
            return 0.0, 0.0, 0.0, 0.0, 0.0
        insets = style.get('insets') or {}
        top = float(insets.get('top') or 0)
        left = float(insets.get('left') or 0)
        bottom = float(insets.get('bottom') or 0)
        right = float(insets.get('right') or 0)
        cr = float(style.get('cornerRadius') or 0)
        return top, left, bottom, right, cr

    def bg_color(style_name: str) -> Optional[str]:
        style = obj.get(style_name)
        if not isinstance(style, dict):
            return None
        return style.get('normalColor')

    svg: list[str] = []
    svg.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{base_w}" height="{keyboard_h}" viewBox="0 0 {base_w} {keyboard_h}">'  # noqa: E501
    )
    if kb_bg_color:
        svg.append(f'<rect x="0" y="0" width="{base_w}" height="{keyboard_h}" fill="{kb_bg_color}" />')

    y = 0.0
    for row in rows:
        hstack = row.get('HStack') if isinstance(row, dict) else None
        subviews = hstack.get('subviews') if isinstance(hstack, dict) else None
        if not isinstance(subviews, list):
            y += row_h
            continue

        x = 0.0
        for cell in subviews:
            name = cell.get('Cell') if isinstance(cell, dict) else None
            if not isinstance(name, str) or name not in obj:
                continue

            btn = obj[name]
            if not isinstance(btn, dict):
                continue

            size = btn.get('size') or {}
            w = parse_width(size.get('width'), base_w)
            bg = btn.get('backgroundStyle')

            top_i, left_i, bottom_i, right_i, cr = bg_insets(bg) if isinstance(bg, str) else (0, 0, 0, 0, 0)
            inner_x = x + left_i
            inner_y = y + top_i
            inner_w = max(0.0, w - left_i - right_i)
            inner_h = max(0.0, row_h - top_i - bottom_i)

            fill = bg_color(bg) if isinstance(bg, str) else None
            if fill:
                svg.append(
                    f'<rect x="{inner_x:.2f}" y="{inner_y:.2f}" width="{inner_w:.2f}" height="{inner_h:.2f}" rx="{cr:.2f}" fill="{fill}" />'  # noqa: E501
                )

            fg = btn.get('foregroundStyle')
            fg = pick_conditional_style(fg, ascii_mode=args.ascii, return_key_type=args.return_key_type)
            style_names = as_list(fg)
            for style_name in style_names:
                if not isinstance(style_name, str):
                    continue
                style = obj.get(style_name)
                if not isinstance(style, dict):
                    continue
                if style.get('buttonStyleType') != 'text':
                    continue

                txt = style.get('text')
                if not isinstance(txt, str) or not txt:
                    continue

                center = style.get('center') or {}
                cx = float(center.get('x') or 0.5)
                cy = float(center.get('y') or 0.5)
                tx = inner_x + inner_w * cx
                ty = inner_y + inner_h * cy

                font_size = float(style.get('fontSize') or 16)
                color = style.get('normalColor') or '#000000'

                svg.append(
                    f'<text x="{tx:.2f}" y="{ty:.2f}" text-anchor="middle" dominant-baseline="middle" font-family="-apple-system, system-ui, sans-serif" font-size="{font_size}" fill="{color}">{svg_escape(txt)}</text>'  # noqa: E501
                )

            x += w

        y += row_h

    svg.append('</svg>')
    out = '\n'.join(svg) + '\n'

    if args.out:
        Path(args.out).write_text(out, encoding='utf-8')
    else:
        print(out, end='')


if __name__ == '__main__':
    main()
