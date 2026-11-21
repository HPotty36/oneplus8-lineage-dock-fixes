# OnePlus 8 (LineageOS 24) — USB-C 독 + 충전 + 유선 키보드/마우스 커널 수정 기록

OnePlus 8 (instantnoodle)을 USB-C 독에 꽂아 데스크톱처럼 쓰면서 겪은 문제를 추적하고 고친 기록입니다.
목표는 **독 하나에 모니터 + 유선 키보드·마우스 + 충전기를 동시에** 물려 쓰는 것이었습니다.

> **English summary** — Kernel fixes for using a OnePlus 8 (LineageOS 24.0, kernel 4.19, SM8250) with a
> USB-C dock that has power pass-through. Stock behaviour: plugging the charger into the dock drops all USB
> input devices, plugging the phone into an already-powered dock gives no USB host at all, and unplugging the
> charger leaves the port dead until re-insertion. Root causes found: (1) the PD policy engine only starts the
> USB host on DR_Swap if the partner's Source_Caps advertise USB communication, (2) OPLUS charger code switches
> D+/D- away from the USB PHY for charger-ID detection even in host mode, (3) OPLUS dropped upstream's
> "restore DRP" register write after a PR swap / error recovery, leaving the port sink-only or disabled,
> (4) hub autosuspend + broken wakeup behind the dock, (5) a VIA hub inside the dock misbehaving when its
> SuperSpeed and USB 2.0 halves get out of sync. See [`patches/`](patches/) and [`docs/`](docs/).

## 환경

| 항목 | 내용 |
|---|---|
| 폰 | OnePlus 8 (IN2017, `instantnoodle`), 부트로더 언락 |
| ROM | LineageOS 24.0 (Android 17) nightly 20261117, userdebug |
| 커널 | `android_kernel_oneplus_sm8250` lineage-24.0 @ `078365e53` (4.19.325) |
| 독 | USB-C 허브 (DP Alt Mode + 전원 패스스루). 내부: USB2 허브 `214b:7250`, VIA USB3 허브 `2109:0815`/`2109:2815`, Billboard `177a:963d`, Realtek RTL8153 LAN `0bda:8153` |
| 주변기기 | 모니터 ULTRON 2457C (1080p 120Hz, DP), Keychron Q1 (`3434:0107`, 풀스피드), Endgame Gear 무선 수신기 (`3367:1961`) |

## 현재 상태 (v5 커널, boot_a에 플래시됨)

| 시나리오 | 원래 커널 | v5 |
|---|---|---|
| 충전기 없이 독 연결 | 모두 동작 | ✅ 모두 동작 |
| 독 연결 후 충전기 꽂기 | 충전·모니터만, 키보드·마우스 끊김 | ✅ 모두 동작 |
| 충전기 꽂힌 독에 폰 연결 | 충전·모니터만, USB 호스트 없음 | ⚠️ 대부분 동작, **가끔 키보드만 안 잡힘** |
| 독 연결 상태에서 충전기 뽑기 | 전부 먹통 (재연결 전까지) | ✅ 모두 동작 |
| 다시 충전기 꽂기 | — | ✅ 모두 동작 |
| 독 분리 후 PC 연결 (adb) | 가끔 USB 꼬여서 재부팅 필요 | ✅ 바로 인식 |
| 외부 모니터 120Hz + 지문 인식 | 지문 실패 | ✅ 동작 (`/data/local.prop`) |

남은 문제와 다음 실험 계획은 [`docs/remaining-tasks.md`](docs/remaining-tasks.md)에 있습니다.

## 수정 내용 요약

| # | 증상 | 원인 | 수정 위치 |
|---|---|---|---|
| 1 | 충전기 꽂힌 독에 연결하면 USB 호스트가 안 켜짐 | 독이 DR_Swap으로 호스트 역할을 넘겨도 Source_Caps의 USB Communications Capable 비트가 0이면 `dr_swap()`이 호스트를 시작하지 않음 | `drivers/usb/pd/policy_engine.c` |
| 2 | 충전기를 나중에 꽂으면 USB 2.0 기기 끊김 | OPLUS 충전 코드가 charger-ID 측정용으로 D+/D-를 USB PHY에서 떼어냄 (GPIO 스위치, VOOC 스위치) | `drivers/power/oplus/charger_ic/oplus_battery_msm8250.c`, `drivers/power/oplus/vooc_ic/oplus_vooc_fw.c` |
| 3 | PR swap 실패·충전기 분리 후 포트가 죽은 채로 남음 | OPLUS가 퀄컴 원본 `smblib_set_prop_pr_swap_in_progress()`의 "DRP 복구" 레지스터 쓰기를 빼먹음. 포트가 sink 전용(0x2) 또는 비활성(0x1)으로 남는데 `chg->power_role`만 DUAL로 바뀌어 이후 요청도 무시됨 | `oplus_battery_msm8250.c` |
| 4 | 허브는 잡히는데 그 아래 기기가 안 나옴 | USB autosuspend로 허브가 잠든 뒤 깨어나지 못함 | 부트 옵션 `usbcore.autosuspend=-1` |
| 5 | 역할 전환 중 인식하던 허브를 다시 안 찾음 | 인식 도중 기기가 사라졌다 돌아와도 루트 포트 변화 이벤트가 오지 않음 (추정) | `drivers/usb/core/hub.c` (1.5초 뒤 재확인) |
| 6 | 독 안 VIA 허브 뒤 키보드가 멈춤 / 충전기 먼저 꽂으면 USB3 링크 실패로 16초 지연 | VIA 허브의 USB3·USB2 두 쪽 상태 불일치 (추정) | 부트 옵션 `policy_engine.host_hs_only=1` (호스트 모드 USB 2.0 전용) |
| 7 | 6번 적용 시 모니터가 안 나옴 (DP AUX timeout) | 콤보 PHY 공통 블록(레인 방향·모드)을 USB SS PHY가 설정해 왔는데 SS를 안 쓰면 아무도 설정 안 함 | `techpack/display/msm/dp/dp_display.c`, `include/linux/usb/usbpd.h` |
| — | 외부 모니터 120Hz일 때 지문 인식 실패 | Android 17 SurfaceFlinger가 느린 디스플레이(내장 화면)를 GPU 합성으로 강제 → UDFPS 레이어가 HWC를 안 거쳐 커널이 "손가락 눌림"을 못 받음 | `/data/local.prop` (커널 무관) |

전체 패치: [`patches/op8-dock-fixes-v5.patch`](patches/op8-dock-fixes-v5.patch) (`078365e53` 기준 diff)

## 업데이트 후에도 유지하기

LineageOS 업데이트는 boot 파티션을 덮어써서 커널 수정이 사라집니다. 이 저장소가 자동으로 처리합니다.

1. **GitHub Actions**가 매일 새 LineageOS 빌드를 확인하고, 그 빌드의 커널 커밋에 패치를 얹어 빌드한 뒤
   패치된 boot 이미지를 [Releases](https://github.com/HPotty36/oneplus8-lineage-dock-fixes/releases)에 올립니다.
2. 업데이트를 설치한 뒤 폰을 PC에 연결하고 한 줄 실행:
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\flash-dockfix.ps1 -Reboot
   ```
   두 슬롯을 보고 새 빌드가 들어간 슬롯에 맞는 이미지를 받아 확인 후 기록합니다.

자세한 내용: [`docs/auto-update.md`](docs/auto-update.md)

## 문서

- [`docs/test-log.md`](docs/test-log.md) — 라운드별 테스트 절차, 결과, 로그 근거
- [`docs/fingerprint-udfps.md`](docs/fingerprint-udfps.md) — 외부 모니터 연결 시 지문 인식 문제
- [`docs/build-and-flash.md`](docs/build-and-flash.md) — 커널 빌드, 부트 이미지 재패키징, 테스트·플래시·롤백
- [`docs/auto-update.md`](docs/auto-update.md) — 업데이트 후 자동 재적용 (GitHub Actions + 설치 스크립트)
- [`docs/remaining-tasks.md`](docs/remaining-tasks.md) — 남은 과제

## 스크립트

- [`scripts/docktest.sh`](scripts/docktest.sh) — 폰에서 커널 로그(`/dev/kmsg`)와 1초 간격 USB/PD 상태를 기록 (adb 연결이 끊겨도 계속 동작)
- [`scripts/kmsg2txt.py`](scripts/kmsg2txt.py) — `/dev/kmsg` 원본을 `[초] 메시지` 형식으로 변환
- [`scripts/summarize_state.py`](scripts/summarize_state.py) — 상태 기록에서 변화 시점만 뽑아 요약
- [`scripts/repack-boot.sh`](scripts/repack-boot.sh) — 기존 boot 이미지에 새 커널과 부트 옵션을 넣어 재패키징

## 주의

- 언락된 부트로더, 루트(adb root) 환경 기준입니다. 부트 이미지를 바꾸기 전에 반드시 원본을 백업하세요.
- `host_hs_only=1`이면 독의 USB-A·LAN 포트가 USB 2.0 속도로 동작합니다.
- LineageOS 업데이트는 boot 파티션을 덮어쓰므로 커널 수정이 사라집니다 (`/data/local.prop`은 유지). 위의 자동 재적용 방법을 쓰세요.
- 패치와 릴리스의 커널 바이너리는 리눅스 커널과 같은 GPL-2.0을 따릅니다. 각 릴리스에 정확한 커널 커밋, 패치, 설정을 함께 적어 둡니다.
