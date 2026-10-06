#!/usr/bin/env python3
"""첫 조각 검사. 레포 루트에서: python3 tests/check_slice1.py

가정(페이지 담당 cell 과 맞춰야 하는 선택자):
  - 게임 캔버스: 페이지의 첫 <canvas>
  - 상태 패널: #panel  (기계 목록·상세 텍스트가 이 안에 들어간다)
  - 상태 라벨: 가동 / 정지 / 불량
"""
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "out"
FACTORY = ROOT / "data" / "factory.json"
PORT = 8790
URL = f"http://127.0.0.1:{PORT}/"
LABEL = {"running": "가동", "stopped": "정지", "defect": "불량"}
MAX_LINES = 300

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}".rstrip())


def canvas_pixels(png_bytes):
    """PNG 바이트 -> 해시, 가능하면 달라진 픽셀 수도."""
    return hashlib.sha256(png_bytes).hexdigest()


def diff_pixels(a, b):
    try:
        from PIL import Image, ImageChops
        import io
        ia = Image.open(io.BytesIO(a)).convert("RGB")
        ib = Image.open(io.BytesIO(b)).convert("RGB")
        if ia.size != ib.size:
            return -1
        bbox = ImageChops.difference(ia, ib).getbbox()
        if bbox is None:
            return 0
        d = ImageChops.difference(ia, ib).convert("L")
        return sum(1 for p in d.getdata() if p)
    except ImportError:
        return None


def check_line_counts():
    skip = {"vendor", "assets", "out", ".git", "node_modules"}
    over, total = [], 0
    for p in ROOT.rglob("*"):
        if not p.is_file() or skip & set(p.relative_to(ROOT).parts):
            continue
        if p.suffix not in {".js", ".html", ".css", ".py", ".json", ".md"}:
            continue
        total += 1
        n = len(p.read_text(encoding="utf-8").splitlines())
        if n > MAX_LINES:
            over.append(f"{p.relative_to(ROOT)}={n}")
    check("⑥ 모든 파일 300줄 이하", not over and total > 0, f"(검사 {total}개, 초과: {over})")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    original = FACTORY.read_bytes()
    state = json.loads(original)
    server = subprocess.Popen(
        [sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1"],
        cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(1)
        run_browser(state, original)
    finally:
        FACTORY.write_bytes(original)  # ⑤ 에서 바꾼 원본 복원
        server.terminate()
        server.wait(timeout=5)
    check_line_counts()
    check("원본 factory.json 복원", FACTORY.read_bytes() == original)
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} 통과")
    sys.exit(1 if failed else 0)


def run_browser(state, original):
    errors = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page(viewport={"width": 1280, "height": 800})
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.goto(URL)
        page.wait_for_selector("canvas", timeout=10000)
        page.wait_for_timeout(1500)  # 에셋 로드·첫 그리기

        canvas = page.locator("canvas").first
        box = canvas.bounding_box()
        size = canvas.evaluate("c => [c.width, c.height]")
        check("② canvas 존재, 크기 > 0", bool(box) and box["width"] > 0 and box["height"] > 0 and size[0] > 0,
              f"(css {box and (box['width'], box['height'])}, 내부 {size})")

        # ③ 움직임: 다른 시각에 찍은 두 장
        t1 = time.time()
        a = canvas.screenshot(path=str(OUT / "shot_a.png"))
        page.wait_for_timeout(2000)
        t2 = time.time()
        b = canvas.screenshot(path=str(OUT / "shot_b.png"))
        n = diff_pixels(a, b)
        moved = canvas_pixels(a) != canvas_pixels(b) and (n is None or n > 0)
        check("③ 2초 간격 캔버스 픽셀이 다르다", moved,
              f"(촬영 간격 {t2 - t1:.2f}s, 달라진 픽셀 {n})")

        # ④ 기계 클릭 -> 패널 (좌표는 factory.json 과 배율로 계산)
        grid = state["grid"]
        sx = box["width"] / grid["w"]
        sy = box["height"] / grid["h"]
        ok4, detail4 = True, []
        for m in state["machines"]:
            page.mouse.click(box["x"] + (m["x"] + 0.5) * sx, box["y"] + (m["y"] + 0.5) * sy)
            page.wait_for_timeout(300)
            txt = page.locator("#panel").inner_text()
            hit = m["name"] in txt and str(m["processed"]) in txt and LABEL[m["state"]] in txt
            ok4 &= hit
            detail4.append(f"{m['name']}={'ok' if hit else 'miss'}")
        page.screenshot(path=str(OUT / "panel_after_click.png"))
        check("④ 기계 클릭 -> 패널에 이름·상태·처리 수량", ok4, "(" + ", ".join(detail4) + ")")

        # ⑤ factory.json 변경 -> 5초 안에 목록 반영 (선택 해제 후 목록 상태에서 확인)
        target = next(m for m in state["machines"] if m["state"] != "defect")
        changed = json.loads(original)
        for m in changed["machines"]:
            if m["id"] == target["id"]:
                m["state"] = "defect"
        changed["version"] += 1
        page.keyboard.press("Escape")
        page.mouse.click(box["x"] + 2, box["y"] + 2)  # 빈 곳 클릭으로 선택 해제 시도
        FACTORY.write_text(json.dumps(changed, ensure_ascii=False, indent=2), encoding="utf-8")
        t0 = time.time()
        seen = False
        while time.time() - t0 < 5:
            lines = [l for l in page.locator("#panel").inner_text().splitlines() if target["name"] in l]
            if any("불량" in l for l in lines):
                seen = True
                break
            page.wait_for_timeout(250)
        page.screenshot(path=str(OUT / "after_defect.png"))
        check("⑤ state 변경+version 증가 -> 5초 안에 패널 '불량'", seen,
              f"({target['name']}, {time.time() - t0:.2f}s)")

        check("① 콘솔 에러 0", not errors, f"({errors})")
        browser.close()


if __name__ == "__main__":
    main()
