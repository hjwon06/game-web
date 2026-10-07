#!/usr/bin/env python3
"""3조각 검사(화면 <-> Rails API). 레포 루트에서: python3 tests/check_slice3.py

서버(127.0.0.1:3100)와 bin/sim 은 미리 띄워 둔다. 이 스크립트는 기동하지 않는다.
선택자는 아래 SEL 한 곳에만 둔다(셀의 클래스 계약).
"""
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
    "row": ".machine-row",
    "detail": ".machine-detail",
    "result": ".machine-detail .cmd-result",
}


def row(code):
    return f'.machine-row[data-id="{code}"]'


def btn(kind):
    return f'.machine-detail .cmd-btn[data-kind="{kind}"]'


PRODUCED = '.machine-detail .detail-value.num[data-field="produced"]'

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
    page = browser.new_page(viewport={"width": 1280, "height": 800})
    page.on("console", lambda m: errors.append(f"{tag}{m.text}") if m.type == "error" else None)
    page.on("pageerror", lambda e: errors.append(f"{tag}{e}"))
    page.goto(BASE + "/")
    page.wait_for_selector(SEL["canvas"], timeout=10000)
    page.wait_for_selector(SEL["row"], timeout=10000)
    return page


def row_text(page, code):
    return page.locator(row(code)).inner_text()


def wait_row_state(page, code, state, ms=3500):
    deadline = time.time() + ms / 1000
    while time.time() < deadline:
        if LABEL[state] in row_text(page, code):
            return True
        page.wait_for_timeout(150)
    return False


def select(page, code):
    page.click(row(code))
    page.wait_for_selector(SEL["detail"], timeout=3000)


def produced(page):
    m = re.search(r"\d+", page.locator(PRODUCED).first.inner_text().replace(",", ""))
    return int(m.group()) if m else None


def run(browser, req, errors):
    page = open_page(browser, errors)
    page.wait_for_timeout(1500)
    n_canvas = page.locator(SEL["canvas"]).count()
    n_rows = page.locator(SEL["row"]).count()
    page.screenshot(path=str(OUT / "s3_full.png"))
    check("① 캔버스 1개 / 목록 행 12개", n_canvas == 1 and n_rows == 12, f"(canvas {n_canvas}, 행 {n_rows})")

    # ② 정지 -> 새로고침 유지 -> 가동 복귀
    check("② 사전: M6 가동", ensure(req, "M6", "running"))
    page.reload()
    page.wait_for_selector(row("M6"), timeout=10000)
    select(page, "M6")
    page.screenshot(path=str(OUT / "s3_detail.png"))
    page.click(btn("stop"))
    check("② 정지 후 3초 안에 목록 M6 '정지'", wait_row_state(page, "M6", "stopped"))
    page.reload()
    page.wait_for_selector(row("M6"), timeout=10000)
    check("② 새로고침 후에도 M6 '정지'", wait_row_state(page, "M6", "stopped"),
          f"({row_text(page, 'M6')!r})")
    select(page, "M6")
    page.click(btn("start"))
    check("② 가동 버튼으로 되돌림", wait_row_state(page, "M6", "running"))

    # ③ 생산 수량 증가(30초 관찰, 최대 40초)
    st = api_state(req)
    code = next((c for c, m in st.items() if m["state"] == "running"), None)
    check("③ 사전: 가동 중 기계 있음", code is not None)
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
    a_ok = wait_row_state(a, "M7", "stopped")
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
    synced = wait_row_state(b, "M7", "stopped", 5000)
    check("④ A 정지 성공", a_ok)
    check("④ B 에 409 안내 + 상태 정지로 맞춰짐", shown and synced, f"(안내 {shown}, 동기화 {synced})")
    a.close()
    b.close()
    ensure(req, "M7", "running")

    # ⑤ 고장 -> 수리
    check("⑤ 사전: M8 가동", ensure(req, "M8", "running"))
    page.reload()
    page.wait_for_selector(row("M8"), timeout=10000)
    select(page, "M8")
    page.click(btn("break"))
    check("⑤ 고장 버튼 -> '고장'", wait_row_state(page, "M8", "broken"))
    page.wait_for_selector(btn("repair"), timeout=3000)
    page.screenshot(path=str(OUT / "s3_broken.png"))
    page.click(btn("repair"))
    check("⑤ 수리 버튼 -> '정지'", wait_row_state(page, "M8", "stopped"))
    ensure(req, "M8", "running")

    page.screenshot(path=str(OUT / "s3_final.png"))  # ⑥
    check("⑥ 스크린샷 저장", all((OUT / f).exists() for f in
          ("s3_full.png", "s3_detail.png", "s3_conflict.png", "s3_broken.png")))
    check("① 콘솔 에러 0", not errors, f"({errors[:3]})")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    errors = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        req = pw.request.new_context()
        try:
            run(browser, req, errors)
        finally:
            browser.close()
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} 통과")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
