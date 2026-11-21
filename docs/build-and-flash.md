# 빌드, 부트 이미지 재패키징, 테스트, 플래시

## 1. 커널 소스

```sh
git clone https://github.com/LineageOS/android_kernel_oneplus_sm8250 -b lineage-24.0
cd android_kernel_oneplus_sm8250
git checkout 078365e53          # 20261117 nightly에 들어간 커널
git apply /path/to/patches/op8-dock-fixes-v5.patch
```

## 2. 설정과 빌드

설정은 폰에서 그대로 가져왔습니다 (`kona-perf_defconfig` + `oplus.config` 결과물).

```sh
adb root
adb pull /proc/config.gz && gunzip config.gz
mkdir -p ../out && cp config ../out/.config

make O=../out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
     olddefconfig
make O=../out ARCH=arm64 LLVM=1 LLVM_IAS=1 \
     CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
     -j$(nproc) Image
```

- 사용한 컴파일러: Ubuntu clang 18.1.3 (원래 커널은 Android clang 22.0.2 r596125). ThinLTO + CFI + SCS 그대로.
- 결과물: `out/arch/arm64/boot/Image` (약 57MB). 2코어 기준 전체 빌드 30분, 수정 후 재빌드 15~20분 (대부분 LTO 링크).
- 모듈은 `gspca_main.ko` 하나뿐이라 vermagic 불일치는 무시.

## 3. 부트 이미지 재패키징

boot는 header v2 (kernel + ramdisk + dtb). 원본 boot 이미지를 풀어서 커널만 바꾸고 부트 옵션 두 개를 추가합니다.
[`scripts/repack-boot.sh`](../scripts/repack-boot.sh) 참고. 필요 도구: AOSP `mkbootimg` (`unpack_bootimg.py`, `mkbootimg.py`).

```sh
# 원본 boot_a 백업 (폰에서)
adb root
adb shell "dd if=/dev/block/by-name/boot_a of=/sdcard/boot_a_stock_backup.img"
adb pull /sdcard/boot_a_stock_backup.img

./scripts/repack-boot.sh boot_a_stock_backup.img out/arch/arm64/boot/Image boot-dockfix.img
```

추가하는 부트 옵션:

| 옵션 | 의미 |
|---|---|
| `usbcore.autosuspend=-1` | USB 기기·허브 자동 절전 끔 (독 아래 허브가 잠들었다 못 깨는 문제) |
| `policy_engine.host_hs_only=1` | 호스트 모드를 USB 2.0 전용으로 (런타임에 `/sys/module/policy_engine/parameters/host_hs_only`로 변경 가능, 독을 다시 꽂을 때 적용) |

이 스크립트에 20261117 빌드의 원본 boot_a와 v5 커널을 넣으면, 실제로 플래시한 이미지와 SHA-256이 같게 나옵니다
(`7afd3a8eac38337baead9577e98e75e504a60f014742b0a40c9035c2494438fd`).

원본과 같은 인자로 다시 묶으면 원본과 바이트 단위로 같은 이미지가 나오는 것을 먼저 확인했습니다
(파티션 끝의 AVB 푸터는 제외). 언락 상태라 서명 없이 부팅되고 `verifiedbootstate=orange`가 됩니다.

## 4. 테스트 (플래시 없이)

```sh
adb reboot bootloader
fastboot boot boot-dockfix.img     # 메모리에만 올림. 재부팅하면 원래 커널
```

기록기 실행:

```sh
adb push scripts/docktest.sh /data/local/tmp/
adb root
adb shell "rm -rf /data/local/tmp/docktest; nohup setsid sh /data/local/tmp/docktest.sh >/dev/null 2>&1 </dev/null &"
# ... 테스트 후 PC에 다시 연결
adb pull /data/local/tmp/docktest
python3 scripts/kmsg2txt.py docktest/kmsg.txt > kmsg.log
python3 scripts/summarize_state.py docktest/state.txt
```

## 5. 플래시와 롤백

```sh
adb reboot bootloader
fastboot flash boot_a boot-dockfix.img     # 현재 슬롯 확인: fastboot getvar current-slot
fastboot reboot

# 롤백
fastboot flash boot_a boot_a_stock_backup.img
```

플래시 후 확인:

```sh
adb shell "cat /proc/version; cat /proc/cmdline | tr ' ' '\n' | grep -E 'usbcore|policy_engine'"
```
