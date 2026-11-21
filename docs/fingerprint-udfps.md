# 외부 모니터(120Hz) 연결 시 화면 지문 인식 실패

## 증상

외부 모니터를 연결하면 화면 내 지문 센서(UDFPS)로 잠금 해제가 안 됨. 모니터를 60Hz로 낮추면 동작하지만 주사율을 포기하고 싶지 않음.

## 원인

1. Android 17 SurfaceFlinger는 여러 디스플레이 중 주사율이 가장 높은 디스플레이를 기준(pacesetter)으로 삼고,
   더 느린 디스플레이를 GPU 합성으로 강제함 (`setForcedClientCompositionLayerStacks`,
   `force_slower_follower_gpu_composition`). 외부 모니터 120Hz가 기준이 되면 내장 화면이 "느린 쪽"이 됨.
2. LineageOS의 UDFPS 처리는 손가락 눌림 레이어(z-order `0x41000033`)가 HWC를 거쳐 커널까지 전달되는 것에 의존함:
   SurfaceFlinger → HWC가 `PLANE_CUST=2` 설정 → 커널 `sde_crtc_onscreenfinger_atomic_check`가 `fingerprint status: pressed`
   → Goodix HAL이 "UI ready"를 받음.
3. 내장 화면이 GPU 합성으로 강제되면 이 레이어가 HWC에 개별 레이어로 전달되지 않아 커널이 눌림을 모름
   → HAL에서 `GF_ERROR_UI_READY_TIMEOUT`.

## 해결

`/data/local.prop` (이 빌드는 `ALLOW_LOCAL_PROP_OVERRIDE`가 켜져 있어 init이 부팅 시 읽음, SurfaceFlinger 시작 전에 적용):

```
debug.sf.force_slower_follower_gpu_composition_platform=false
```

파일 권한: `root:root 0644`, SELinux `u:object_r:system_data_file:s0`. 파일은 [`config/local.prop`](../config/local.prop).

- 재부팅 후 `getprop`과 SurfaceFlinger dump에서 두 플래그 모두 false 확인.
- 120Hz 외부 모니터 연결 상태에서 지문 잠금 해제 3/3 성공.
- `/data`에 있으므로 LineageOS 업데이트 후에도 유지됨.

참고: 이 설정은 Android 17의 "느린 디스플레이 GPU 합성 강제" 동작만 끕니다. 지금까지 눈에 띄는 부작용은 확인되지 않았습니다.
