#!/usr/bin/env python3
"""3조각 검사(화면 <-> Rails API). 레포 루트에서: python3 tests/check_slice3.py

서버(127.0.0.1:3100)와 bin/sim 은 미리 띄워 둔다. 이 스크립트는 기동하지 않는다.
선택자는 아래 SEL 한 곳에만 둔다(셀의 클래스 계약).
"""
import json
import os
import re
import sys
import time
import uuid
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "tests" / "out"
BASE = "http://127.0.0.1:3100"
LABEL = {"running": "가동", "stopped": "정지", "broken": "고장"}
CONFLICT_TEXT = "다른 곳에서 먼저 바뀌었습니다"
SEL = {
    "canvas": "canvas",
    "hud": ".hud",
    "detail": ".inspect",
    "result": ".cmd-result",
}
TILE = 32  # data/sprites.json sheet.tile. 배율은 화면에 들어가는 최대 정수배라서 실행 중 캔버스 크기로 구한다
LAYOUT = json.loads((ROOT / "data" / "layout.json").read_text(encoding="utf-8"))
SPOT = {m["id"]: m for m in LAYOUT["machines"]}


LOGIN_NAME = os.environ.get("CHECK_USER", "jay")
LOGIN_PASSWORD = os.environ.get("CHECK_PASSWORD", "")


def login(ctx):
    """브라우저 컨텍스트에 로그인 쿠키를 심는다. ctx.request 와 ctx 의 모든 페이지가 같은 쿠키를 쓴다."""
    # 로그인 폼은 CSRF 토큰이 필요하다. 실제 화면에서 폼을 채워 제출한다.
    page = ctx.new_page()
    page.goto(f"{BASE}/login")
    page.fill("#name", LOGIN_NAME)
    page.fill("#password", LOGIN_PASSWORD)
    page.click("input[type=submit]")
    page.wait_for_load_state()
    page.close()
    me = ctx.request.get(f"{BASE}/api/me")
    if me.status != 200:
        sys.exit(f"로그인 실패(/api/me {me.status}). CHECK_USER / CHECK_PASSWORD 환경변수를 확인한다.")


def btn(kind):
    return f'.cmd-btn[data-kind="{kind}"]'


PRODUCED = '.inspect [data-field="produced"]'

results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"[{'PASS' if ok else 'FAIL'}] {name} {detail}".rstrip())


# ---- 서버 직접 호출(사전 조건 맞추기 전용. 검사 대상 동작은 전부 화면으로 한다) ----
def api_state(req):
    return {m["code"]: m for m in req.get(f"{BASE}/api/state").json()["machines"]}


def api_cmd(req, code, kind):
    m = api_state(req)[code]
    return req.post(f"{BASE}/api/commands", data={
        "idempotency_key": str(uuid.uuid4()), "machine_code": code,
        "kind": kind, "base_version": m["version"]})


PATH = {  # (현재, 목표) -> 명령 순서
    ("running", "stopped"): ["stop"], ("broken", "stopped"): ["repair"],
    ("stopped", "running"): ["start"], ("broken", "running"): ["repair", "start"],
    ("running", "broken"): ["break"], ("stopped", "broken"): ["break"],
}


def ensure(req, code, target):
    cur = api_state(req)[code]["state"]
    for kind in PATH.get((cur, target), []):
        api_cmd(req, code, kind)
    return api_state(req)[code]["state"] == target


# ---- 화면 도우미 ----
def open_page(browser, errors, tag=""):
    page = browser.new_page()  # browser 자리에는 로그인된 컨텍스트가 온다
    page.set_viewport_size({"width": 1920, "height": 1080})
    page.on("console", lambda m: errors.append(f"{tag}{m.text}") if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(f"{tag}{e}"))
    page.goto(BASE + "/")
    # 서버가 1코어라 헤드리스 3탭 WebGL 이 느리다(10초에서 실패, 30초에서 통과)
    page.wait_for_selector(SEL["canvas"], timeout=30000)
    page.wait_for_selector(SEL["hud"], timeout=30000)
    return page


def hud_counts(page):
    """.hud 의 '가동 N · 정지 N · 고장 N' 에서 숫자를 읽는다."""
    text = page.locator(SEL["hud"]).first.inner_text()
    return {k: int(m.group(1)) if (m := re.search(rf"{v}\s*(\d+)", text)) else None for k, v in LABEL.items()}


def click_machine(page, code):
    """layout.json 칸 좌표 x 셀 크기 + 캔버스 bounding rect 로 캔버스를 실제 마우스로 누른다.
    기계는 칸 아래변에 앉으므로 칸 가운데에서 위로 1/4 칸 올린 점(그림 안쪽)을 누른다."""
    box = page.locator(SEL["canvas"]).first.bounding_box()
    grid = LAYOUT["grid"]
    zoom = max(1, min(int(box["width"] // (grid["w"] * TILE)), int(box["height"] // (grid["h"] * TILE))))
    cell = TILE * zoom
    m = SPOT[code]
    page.mouse.click(box["x"] + m["x"] * cell + cell / 2, box["y"] + (m["y"] + 1) * cell - cell / 4)


def inspect_text(page):
    loc = page.locator(SEL["detail"])
    return loc.first.inner_text() if loc.count() else ""


def wait_state(page, code, state, ms=3500):
    """선택돼 있는 기계(.inspect 에 code 가 보임)의 상태 글자가 state 가 될 때까지."""
    deadline = time.time() + ms / 1000
    while time.time() < deadline:
        t = inspect_text(page)
        if code in t and LABEL[state] in t:
            return True
        page.wait_for_timeout(150)
    return False


def select(page, code):
    click_machine(page, code)
    page.wait_for_function(
        "c => { const e = document.querySelector('.inspect'); return !!e && e.textContent.includes(c); }",
        arg=code, timeout=3000)


def produced(page):
    m = re.search(r"\d+", page.locator(PRODUCED).first.inner_text().replace(",", ""))
    return int(m.group()) if m else None


def run(browser, req, errors):
    page = open_page(browser, errors)
    page.wait_for_timeout(1500)
    n_canvas = page.locator(SEL["canvas"]).count()
    counts = hud_counts(page)
    n_machines = sum(v or 0 for v in counts.values())
    page.screenshot(path=str(OUT / "s3_full.png"))
    check("① 캔버스 1개 / 기계 12대(.hud 합계, 레이아웃 12칸)",
          n_canvas == 1 and n_machines == 12 and len(SPOT) == 12, f"(canvas {n_canvas}, hud {counts})")

    # ② 정지 -> 새로고침 유지 -> 가동 복귀
    check("② 사전: M6 가동", ensure(req, "M6", "running"))
    page.reload()
    page.wait_for_selector(SEL["hud"], timeout=10000)
    select(page, "M6")
    page.screenshot(path=str(OUT / "s3_detail.png"))
    page.click(btn("stop"))
    check("② 정지 후 3초 안에 M6 '정지'", wait_state(page, "M6", "stopped"))
    page.reload()
    page.wait_for_selector(SEL["hud"], timeout=10000)
    select(page, "M6")
    check("② 새로고침 후에도 M6 '정지'", wait_state(page, "M6", "stopped"),
          f"({inspect_text(page)!r})")
    page.click(btn("start"))
    check("② 가동 버튼으로 되돌림", wait_state(page, "M6", "running"))

    # ③ 생산 수량 증가(30초 관찰, 최대 40초)
    # 상세의 생산 수량은 작업지시가 있어야 늘어난다. 가동 중 + /api/hud 에 work_order 가 있는 기계만 고른다.
    st = api_state(req)
    hud = {m["code"]: m for m in req.get(f"{BASE}/api/hud").json()["machines"]}
    code = next((c for c, m in st.items()
                 if m["state"] == "running" and (hud.get(c) or {}).get("work_order")), None)
    running = [c for c, m in st.items() if m["state"] == "running"]
    check("③ 사전: 가동 중이면서 작업지시가 있는 기계 있음", code is not None,
          "" if code else f"(가동 중 {running}, hud 작업지시 있는 기계 "
          f"{[c for c, m in hud.items() if m.get('work_order')]} — 겹치는 기계가 없어 ③ 을 건너뛸 수 없다)")
    if code:
        select(page, code)
        first = produced(page)
        grew, deadline = False, time.time() + 40
        while time.time() < deadline and not grew:
            page.wait_for_timeout(1000)
            cur = produced(page)
            grew = first is not None and cur is not None and cur > first
        check("③ 상세 생산 수량 증가", grew, f"({code}: {first} -> {produced(page)})")

    # ④ 409: B 는 옛 version 을 쥐고 있어야 하므로 B 의 읽기(GET)를 잠시 막는다
    check("④ 사전: M7 가동", ensure(req, "M7", "running"))
    a = open_page(browser, errors, "A:")
    b = open_page(browser, errors, "B:")
    select(a, "M7")
    select(b, "M7")
    b.route("**/api/state*", lambda r: r.abort())
    b.route("**/api/hud*", lambda r: r.abort())
    a.click(btn("stop"))
    a_ok = wait_state(a, "M7", "stopped")
    b.wait_for_timeout(300)
    b.click(btn("stop"))  # B 화면은 아직 '가동'으로 알고 있다
    try:
        b.wait_for_function(
            "t => [...document.querySelectorAll('.cmd-result')].some(e => e.textContent.includes(t))",
            arg=CONFLICT_TEXT, timeout=4000)
        shown = True
    except Exception:
        shown = False
    b.screenshot(path=str(OUT / "s3_conflict.png"))
    b.unroute("**/api/state*")
    b.unroute("**/api/hud*")
    synced = wait_state(b, "M7", "stopped", 5000)
    check("④ A 정지 성공", a_ok)
    check("④ B 에 409 안내 + 상태 정지로 맞춰짐", shown and synced, f"(안내 {shown}, 동기화 {synced})")
    a.close()
    b.close()
    ensure(req, "M7", "running")

    # ⑤ 고장 -> 수리
    check("⑤ 사전: M8 가동", ensure(req, "M8", "running"))
    page.reload()
    page.wait_for_selector(SEL["hud"], timeout=10000)
    select(page, "M8")
    page.click(btn("break"))
    check("⑤ 고장 버튼 -> '고장'", wait_state(page, "M8", "broken"))
    page.wait_for_selector(btn("repair"), timeout=3000)
    page.screenshot(path=str(OUT / "s3_broken.png"))
    page.click(btn("repair"))
    check("⑤ 수리 버튼 -> '정지'", wait_state(page, "M8", "stopped"))
    ensure(req, "M8", "running")

    page.screenshot(path=str(OUT / "s3_final.png"))  # ⑥
    check("⑥ 스크린샷 저장", all((OUT / f).exists() for f in
          ("s3_full.png", "s3_detail.png", "s3_conflict.png", "s3_broken.png")))
    # ④ 에서 B 페이지는 일부러 읽기를 끊고(abort -> ERR_FAILED) 409 를 받는다. 그 두 종류는 의도된 기록이라 뺀다.
    real = [e for e in errors if not (e.startswith("B:") and "Failed to load resource" in e)]
    check("① 콘솔 에러 0", not real, f"({real[:3]})")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    errors = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context()  # 로그인 쿠키를 화면(페이지)과 서버 직접 호출(req)이 함께 쓴다
        try:
            login(ctx)
            run(ctx, ctx.request, errors)
        finally:
            browser.close()
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} 통과")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
