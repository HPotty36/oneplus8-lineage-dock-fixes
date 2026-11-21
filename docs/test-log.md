# 테스트 기록

모든 커널 테스트는 `fastboot boot`로 메모리에만 올려서 했습니다 (재부팅하면 원래 커널로 돌아감).
최종 버전(v5)만 `boot_a`에 플래시했습니다.

## 테스트 절차

시작 전에 독에서 충전기를 뺍니다. 독 안의 기기(특히 키보드)가 이전 테스트 상태를 들고 있지 않도록 전원을 완전히 끊기 위해서입니다.

| 단계 | 동작 | 확인 |
|---|---|---|
| 1 | PC에서 분리 → 충전기 **없이** 독을 폰에 연결 | 모니터·키보드·마우스 |
| 2 | 독에 충전기 연결 | + 충전 |
| 3 | 충전기는 독에 둔 채 독만 폰에서 뺐다가 다시 연결 | 〃 |
| 4 | 독은 둔 채 충전기만 분리 | 〃 |
| 5 | 충전기 다시 연결 | 〃 |
| 6 | 독 분리 → PC 연결 | adb가 재부팅 없이 잡히는지 |

폰에서는 [`scripts/docktest.sh`](../scripts/docktest.sh)가 `/dev/kmsg` 전체와 1초 간격 상태
(Type-C 데이터/전원 역할, 충전 상태, USB 기기 목록, 입력 장치, 허브 런타임 PM 상태)를 기록했습니다.
PC 연결 후 `adb pull`로 가져와 분석했습니다.

---

## 0. 원래 커널 (LineageOS 20261117)

| 시나리오 | 결과 |
|---|---|
| 독 연결 후 충전기 꽂기 | 충전·모니터 OK, 키보드·마우스 끊김 |
| 충전기 꽂힌 독에 연결 | 충전·모니터 OK, USB 기기 전혀 없음 |
| 독 연결 상태에서 충전기 뽑기 | 전부 끊기고 독을 다시 꽂기 전까지 복구 안 됨. 가끔 xHCI 정리가 멈춰 재부팅 전까지 PC 연결도 안 됨 |

로그 근거:
- 충전기를 나중에 꽂으면 독이 PR_Swap(가끔 hard reset)을 요청 → VBUS가 잠깐 끊김 → USB2 허브가 다시 잡힘 →
  바로 다음 순간 `smbchg_set_chargerid_switch_val set value: 1` (D+/D-를 charger-ID 측정 쪽으로 전환)과 동시에 `usb 1-1: USB disconnect`.
- 충전기가 먼저 꽂혀 있으면 폰이 sink로 붙고, 독이 DR_Swap으로 호스트 역할을 넘기는데,
  독의 Source_Caps에 USB Communications Capable 비트가 없어서 `dr_swap()`이 호스트를 시작하지 않음.

## 1. v1 — DR_Swap 시 호스트 시작 + 호스트 모드에서 charger-ID/VOOC 스위치 생략

| 단계 | 결과 |
|---|---|
| 1 | ✅ |
| 2 | ❌ 충전도 안 됨, 키보드·마우스·모니터 전부 안 됨 |
| 3 | 충전·모니터만 |
| 4 | ❌ 전부 안 됨 |
| 6 | ✅ 재부팅 없이 PC 인식 |

분석:
- **단계 2**: PR swap 중 `Error sending PS_RDY: -14`(GoodCRC 없음) → ERROR_RECOVERY에서 포트를 비활성(`power_role=1`)으로 둔 뒤
  다시 DRP로 돌리지 않음. 단계 3에서 독을 다시 꽂을 때 로그에 `reg0x1544[0x1]`(비활성)이 그대로 남아 있었음.
  → OPLUS 코드가 퀄컴 원본 `smb5-lib.c`에 있는 "DRP 복구" 쓰기를 빼먹은 것이 원인. `chg->power_role`만 DUAL로 바꿔서
  이후 `PR_DUAL` 요청도 "이미 DUAL"이라며 무시됨.
- **단계 4**: 같은 버그. PR swap 때 잠근 sink 전용 모드가 그대로 남아, 전원이 끊긴 독(Rd)을 감지하지 못함.
- **단계 3**: 독이 처음엔 sink로 붙었다가 1초쯤 뒤 PR swap → VBUS가 0.5초 끊긴 순간이 USB2 허브 인식 도중이라
  `device not accepting address 3, error -71` 후 다시 인식하지 않음. USB3 쪽(LAN)은 살아 있음.
- charger-ID 스위치 생략은 의도대로 동작 (`USB host mode, keep D+/D- on the USB PHY, skip chargerid switch`).

## 2. v2 — + DRP 복구 + PR swap 완료 1초 뒤 USB 호스트 강제 재시작

| 단계 | 결과 |
|---|---|
| 1 | ✅ |
| 2 | 키보드·마우스 ❌ |
| 3 | ✅ (마우스 먼저, 키보드는 한참 뒤) |
| 4 | 키보드·마우스 ❌ (가상 키보드가 뜸) |
| 5 | 그대로 ❌ |

분석:
- DRP 복구는 동작: 충전기를 빼면 0.25초 안에 폰이 다시 전원을 공급하며 독을 감지.
- 실패한 경우 모두 **독의 첫 번째 허브는 잡히는데 그 아래 기기가 하나도 안 나오고**, 1.4~2.4초 뒤 `DWC3 in low power mode`.
  → 허브 autosuspend 후 깨어나지 못하는 것으로 의심.
- 강제 재시작이 오히려 해로움: 단계 2에서는 PR swap 뒤 마우스와 두 번째 허브가 정상적으로 다시 잡히던 중이었는데
  재시작이 끼어들어 `hub failed to enable device, error -108`, `xHCI host not responding to stop endpoint command`로
  정리에만 6.7초가 걸림.
- 충전기 먼저 꽂은 경우(단계 3) USB3 포트가 `Cannot enable. Maybe the USB cable is bad?`를 4번 반복(약 16초).
  xHCI의 USB2/USB3 루트 허브가 주소 할당 뮤텍스를 공유해서 그동안 USB2 기기 인식도 밀림.
- 재시작 시 `QMP PHY initialization timeout`이 자주 나옴 (DP가 이미 PHY를 쓰는 중).

## 3. v2 + autosuspend 끔 (런타임 `echo -1 > /sys/module/usbcore/parameters/autosuspend`)

강제 재시작은 아직 남아 있는 상태.

| 단계 | 결과 |
|---|---|
| 1 | ✅ |
| 2 | 마우스 ✅, 키보드 ❌ |
| 3 | 마우스 ✅, 키보드 ❌ |
| 4 | ✅ |
| 5 | 마우스 ✅, 키보드는 잠시 뒤 ✅ |

분석:
- **autosuspend가 원인 4로 확인됨** (단계 4가 완전히 복구).
- 키보드는 독 안의 VIA 허브(`1-1.2`) 뒤에 있고 마우스는 첫 번째 허브(`1-1`)에 바로 붙어 있음.
  키보드가 실패할 때는 `device descriptor read/64, error -32`, `Device not responding to setup address`, `error -71`.
- 실패 사례에서는 VIA 칩의 USB3 쪽이 연결된 채(또는 링크 시도 중) USB2 쪽만 재시작되고 있었음.
  USB3가 죽어 있던 경우(재시작 중 QMP 타임아웃)에는 키보드가 항상 정상.

## 4. v3 — 강제 재시작 제거, autosuspend 끔을 부트 옵션으로, "충전기 먼저 연결 시 USB 2.0 전용" 옵션

`policy_engine.hs_only_sink_dfp=1` (런타임) — sink 상태에서 DR_Swap으로 호스트가 될 때만 USB 2.0 전용.

| 단계 | 결과 |
|---|---|
| 1 | ✅ |
| 2 | 마우스 ✅, 키보드는 **키보드 케이블을 다시 꽂으니** ✅ |
| 3 | ✅ 모니터와 동시에 키보드·마우스 (16초 지연 사라짐) |
| 4 | ✅ |
| 5 | 모니터만 ✅ (키보드 다시 꽂아도 ❌) |

분석:
- 단계 2: 키보드만 멈춤. 키보드 케이블을 다시 꽂는 순간 VIA 허브 전체(USB3 `2-1`, USB2 `1-1.2`)가 끊겼다 다시 붙었고
  그 뒤 키보드 정상 → VIA 칩이 리셋되면 복구됨.
- 단계 5: 충전기를 꽂자 독이 PR swap을 **연달아 두 번** 요청. 첫 번째는 `Error sending PS_RDY: -14` → DRP 복구 덕분에
  폰이 다시 source로 붙고 USB2 허브 인식을 시작했는데, 0.5초 뒤 두 번째 PR swap이 인식을 끊음 →
  `device not accepting address 2, error -71` 후 다시 인식하지 않음 (라운드 1 단계 3과 같은 패턴).

## 5. v4 — + 루트 포트 재확인 + 호스트 모드 전체 USB 2.0 전용

부트 옵션: `usbcore.autosuspend=-1 policy_engine.host_hs_only=1`

| 단계 | 결과 |
|---|---|
| 1 | 키보드·마우스 ✅, **모니터 ❌** |
| 2 | 키보드·마우스 ✅, 모니터 ❌ |
| 3 | ✅ |
| 4 | ✅ |
| 5 | ✅ |

분석:
- 모니터 실패 시 `dp_aux_cmd_fifo_tx ... aux write timeout`이 수십 번.
- USB3·DP 콤보 PHY의 공통 블록(Type-C 방향에 따른 레인 선택, USB3+DP 모드)은 USB SS PHY 초기화
  (`msm_ssphy_qmp_init` → `Update TYPEC CTRL(n)`)가 맡고, DP 드라이버는 "USB가 SS 레인을 안 쓸 때"
  (`!multi_func || !peer_usb_comm`)만 직접 설정함. USB 2.0 전용이면 둘 다 안 해서 이전 연결의 설정이 남음.
  방향이 맞으면 동작, 틀리면 AUX 실패.
- 단계 3 이후 성공한 건 독이 source일 때(`peer_usb_comm=0`) DP가 직접 설정했고 그 설정이 이후에도 맞았기 때문.

## 6. v5 — + USB 2.0 전용일 때 DP가 콤보 PHY 직접 설정 (최종, 플래시함)

| 단계 | 결과 |
|---|---|
| 1 | ✅ |
| 2 | ✅ |
| 3 (독을 뒤집어 연결) | 키보드만 ❌ (키보드 다시 꽂아도 ❌) |
| 4 | ✅ |
| 5 | ✅ |

분석:
- 단계 3: 첫 번째 허브와 VIA USB2 허브는 잡혔지만 키보드는 `error -32` → `error -71` → `unable to enumerate`.
  같은 VIA 허브의 LAN 포트도 안 나왔고, 사용자가 키보드를 다시 꽂았는데도 VIA 허브가 포트 변화를 보고하지 않음.
  → VIA 허브가 제어 전송은 되는데 인터럽트/TT 전송이 안 되는 반쯤 고장난 상태로 보임. 독 충전기를 뺐다 꽂으면 복구.
- 같은 시나리오가 v3·v4에서는 성공했으므로 간헐적인 문제. 원인은 [`remaining-tasks.md`](remaining-tasks.md) 참고.
