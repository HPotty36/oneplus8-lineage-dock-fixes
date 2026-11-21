# LineageOS 업데이트 후에도 독 수정 유지하기

LineageOS 업데이트는 boot 파티션을 통째로 새로 씁니다. 커널 수정은 boot 이미지 안에 있으므로 업데이트할 때마다 사라집니다.
(지문 설정 `/data/local.prop`은 `/data`에 있어서 유지됩니다.)

이 저장소는 두 가지로 이걸 자동화합니다.

## 1. 새 빌드가 나오면 패치된 boot 이미지를 자동으로 만듦 (GitHub Actions)

[`.github/workflows/build-dockfix-boot.yml`](../.github/workflows/build-dockfix-boot.yml)이 매일 06:37(KST)에 돕니다.

1. `download.lineageos.org` API에서 instantnoodle 최신 빌드를 찾음. 그 빌드용 릴리스가 이미 있으면 종료.
2. 그 빌드의 `boot.img`와 `build-manifest.xml`을 받아 SHA-256 확인.
3. 매니페스트에서 **그 빌드에 실제로 들어간 커널 커밋**을 찾아 그 커밋으로 커널 소스를 받음.
   LineageOS가 커널을 업데이트해도 그 위에 패치를 얹으므로 보안 패치 등은 그대로 따라감.
4. 원본 boot.img 커널에 내장된 설정(`extract-ikconfig`)을 그대로 쓰고, `patches/op8-dock-fixes-<VERSION>.patch`를 적용해 빌드 (clang 18).
5. 원본 boot.img의 램디스크·DTB는 그대로 두고 커널만 바꾸고 부트 옵션 두 개를 추가 (`scripts/repack-boot.sh`).
6. GitHub 릴리스 `<빌드날짜>-<패치버전>` (예: `20261124-v5`)으로 올림.
   첨부: `boot-dockfix-*.img`, `.sha256`, 커널 설정, `build-info.json`.

패치가 새 커널에 안 맞으면 워크플로가 실패하고 GitHub가 저장소 주인에게 메일을 보냅니다. 그때는 패치를 고쳐야 합니다.

수동 실행:

```sh
gh workflow run build-dockfix-boot.yml -R HPotty36/oneplus8-lineage-dock-fixes            # 최신 빌드
gh workflow run build-dockfix-boot.yml -R HPotty36/oneplus8-lineage-dock-fixes -f date=20261117
```

## 2. 폰에 설치: `tools/flash-dockfix.ps1`

업데이트를 설치한 뒤(재부팅 전이든 후든) 폰을 PC에 연결하고 실행합니다.

```powershell
powershell -ExecutionPolicy Bypass -File tools\flash-dockfix.ps1 -Reboot
```

하는 일:

1. `adb root`로 두 boot 슬롯(`boot_a`, `boot_b`)의 해시를 읽음.
2. LineageOS가 공개한 boot.img 해시와 비교해 **각 슬롯에 어떤 빌드가 들어 있는지** 알아냄.
   - 업데이트 설치 직후(재부팅 전)라면 새 빌드는 비활성 슬롯에 들어 있음 → 그 슬롯에 씀 → 재부팅 한 번으로 끝.
   - 이미 재부팅했다면 현재 슬롯에 씀 → 한 번 더 재부팅.
3. 그 빌드용 패치 이미지를 이 저장소 릴리스에서 받아 SHA-256 확인 → 폰에 올려 다시 확인 → `dd`로 기록 → 파티션을 읽어 한 번 더 확인.
4. 이미 패치된 슬롯은 건너뜀. 알 수 없는 이미지가 들어 있는 슬롯은 건드리지 않음.

옵션:

| 옵션 | 동작 |
|---|---|
| `-Reboot` | 끝나면 재부팅 |
| `-Yes` | 확인 질문 없이 진행 |
| `-Restore` | 패치된 슬롯에 원래 LineageOS boot.img를 다시 씀 (롤백) |
| `-Force` | 현재 슬롯의 이미지를 알아볼 수 없을 때(직접 빌드한 이미지 등) 실행 중인 빌드로 간주 |

fastboot가 필요 없고, 원본 boot.img는 LineageOS 서버에서 다시 받을 수 있어서 따로 백업하지 않습니다.

## 검증

- 첫 자동 빌드 `20261117-v5`를 이 스크립트(`-Force`)로 boot_a에 설치 → 재부팅 후 커널 `...-dockfix-...`, 부트 옵션 두 개 적용, 커널 오류 없음, Wi-Fi 정상 확인.
- 다시 실행하면 boot_a를 `dock-fix 20261117-v5`로 알아보고 아무것도 하지 않음.
- 자동 빌드 이미지는 직접 테스트한 v5와 램디스크·DTB·부트 옵션이 같고, 커널은 같은 소스·설정·컴파일러(clang 18.1.3)로 빌드됨.

## 안전장치

- 빌드 날짜가 다른 이미지는 절대 쓰지 않음 (슬롯별로 원본 해시로 빌드를 확인).
- 새 슬롯이 부팅에 계속 실패하면 A/B 부트로더가 이전 슬롯으로 되돌아감.
- 언락된 부트로더라서 서명이 다른 boot로도 부팅됨 (`verifiedbootstate=orange`, 지금과 같음).

## 한계

- 업데이트 후 PC에 연결해 스크립트를 한 번 실행해야 함.
  폰 안에서 완전히 자동으로 하려면 앱이 쓸 수 있는 루트 권한이 필요한데, 이 빌드는 `adb root`만 있음.
- 새 빌드가 나온 뒤 워크플로가 돌 때까지(최대 하루 + 빌드 30분) 이미지가 없을 수 있음. 급하면 위의 수동 실행.
