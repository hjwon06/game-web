# tests

첫 조각(움직이는 공장 화면) 검사. 파이썬 playwright 로 실제 브라우저를 띄운다.

## 실행

```bash
# 레포 루트에서 정적 서버
python3 -m http.server 8790 --bind 127.0.0.1 &

# 다른 터미널에서
pip install playwright && playwright install chromium   # 최초 1회
python3 tests/check_slice1.py
```

스크린샷은 `tests/out/` 에 저장된다(.gitignore 대상).

## 검사 항목

1. 콘솔 에러 0건
2. canvas 가 있고 크기가 0보다 크다
3. 2초 간격으로 찍은 캔버스 스크린샷 두 장의 픽셀이 다르다 (벨트·상자가 움직임)
4. `data/factory.json` 의 기계 좌표와 캔버스 배율로 계산한 위치를 클릭하면 패널에 그 기계 이름이 나온다
5. `factory.json` 의 기계 하나를 `defect` 로 바꾸고 `version` 을 1 올리면 5초 안에 패널 목록에서 그 기계가 "불량"으로 바뀐다 (검사 후 원본 복원)
6. 모든 소스 파일이 300줄 이하

## 변이 검사

`src/scene_factory.js` 의 `update()` 에서 상자 이동(`box.s += ...`)을 주석 처리하고 돌리면 3번이 실패해야 한다. 확인 후 반드시 되돌린다.
