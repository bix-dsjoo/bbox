# 자동 라벨 정책 및 Detector 재학습 수정 설계

- 작성일: 2026-07-14
- 원천 데이터: `C:\workspace\bixolon_bakery` (읽기 전용)
- 기준 브랜치: `codex/auto-box-auto-label`
- 상태: 사용자 승인 설계

## 1. 결정 사항

기존 자동 박스·자동 라벨 설계의 구조는 유지하되 classifier 자동 라벨의 `98% precision`을 절대 합격 기준으로 사용하지 않는다. 새 20-class classifier의 누수 방지 5-fold OOF에서 관측한 자동 지정 precision 약 `94.6%`, coverage 약 `61.8%`를 현재 허용 가능한 기준선으로 채택한다. 이 수치는 고정 목표가 아니라 승인된 현행 품질 기준선이며, 실제 배포 threshold의 재계산 결과는 별도로 기록한다.

최종 파이프라인은 다음과 같다.

`선택된 1-class detector -> 새 20-class classifier -> 자동 라벨 또는 빨간 검토`

현재 embedding 후보는 classifier-only보다 성능이 낮으므로 제품에서 제외하고 manifest에 `kind=none`으로 기록한다.

## 2. Classifier 정책 수정

### 2.1 유지하는 원칙

- 새로 학습한 canonical 20-class YOLO classifier를 사용한다.
- held-out mixed image는 해당 fold의 학습, validation, threshold 선택, prototype 생성에 사용하지 않는다.
- 기존 19-class weight는 비교용 baseline으로만 유지하고 제품 모델로 선택하지 않는다.
- confidence와 top-1/top-2 margin이 모두 deployment policy를 만족해야 실제 `labelId`를 자동 지정한다.
- 기준을 만족하지 못하면 top-1은 `suggestedLabelId`에만 저장하고 실제 `labelId`는 비워 둔다.

### 2.2 98% 강제 게이트 제거

다음 규칙을 제거한다.

- OOF precision이 98%보다 낮으면 모든 class를 conservative로 바꾸는 전역 fail-close
- 98%를 맞추지 못했다는 이유만으로 white coverage를 0으로 만드는 처리

대신 다음을 적용한다.

- fold별 threshold는 해당 fold와 분리된 validation prediction으로만 계산한다.
- fold별 held-out 결과는 cross-fitted policy 성능으로 보고한다.
- 단일 deployment threshold는 다섯 fold의 validation-derived policy만 사용해 결정하며 held-out label을 threshold 튜닝에 사용하지 않는다.
- deployment policy를 held-out OOF prediction에 그대로 적용한 precision, coverage, red-review rate를 최종 보고한다.
- 현재 승인 기준선은 precision 약 94.6%, coverage 약 61.8%다. 재계산 결과가 이 값과 달라도 숨기지 않고 manifest와 모델 카드에 실제 값을 기록한다.

### 2.3 평가 코드 결함 수정

재학습 없이 다음 세 결함을 먼저 수정한다.

1. Verifier calibration과 verifier 평가는 서로 분리된 fold에서 수행한다. 같은 held-out label로 threshold를 선택하고 성능을 보고하지 않는다.
2. 최종 안전성 검사는 fold 임시 policy가 아니라 실제로 manifest에 기록할 deployment policy를 held-out prediction에 적용해 수행한다.
3. confidence/margin 후보를 512개로 균일 축소하지 않는다. 정렬된 score를 누적 sweep하여 정확한 최대 coverage 해를 계산한다.

Verifier는 수정 후에도 후보를 재평가하지만, 기존 결과처럼 classifier-only를 개선하지 못하면 `none`을 유지한다.

## 3. 새 Detector 학습

### 3.1 후보

동일한 split, seed, augmentation, image size와 평가 코드로 다음 세 모델을 비교한다.

1. 기준선: 현재 `bread_yolov8n_1class_tray_v0_2.pt`
2. 후보 A: 현재 detector weight에서 real-only fine-tuning
3. 후보 B: generic `yolov8n.pt`에서 real-only fine-tuning

승인된 background와 mask evidence가 없으므로 synthetic 후보는 생성하지 않는다. 선택 보고서에는 `disabled_reason=no_approved_backgrounds`를 기록한다.

### 3.2 Fold 사용

held-out fold `k`마다 다음을 강제한다.

- test: mixed-scene fold `k`
- validation: mixed-scene fold `(k + 1) % 5`
- train: 나머지 세 mixed-scene fold
- test image와 파생 crop은 train, validation, augmentation, threshold 선택에 포함하지 않는다.
- confidence threshold는 validation prediction으로 고정한 뒤 held-out inference를 수행한다.

83개 mixed image와 510개 GT bbox는 정확히 한 번씩 held-out 평가에 사용한다. 모든 fold prediction은 원본 좌표, raw confidence, operational prediction, 전체 호출 latency를 저장한다.

### 3.3 Detector 채택 기준

Classifier의 98% 규칙만 제거하며 detector 기준은 유지한다.

- recall `>= 0.85`
- 현재 detector 대비 recall `>= 0.05` 향상
- precision `>= 0.97`
- 현재 detector 대비 precision 하락 `<= 0.01`
- mAP50-95가 현재 detector 이상
- median area ratio `0.95` 이상 `1.05` 이하
- median IoU 하락 `<= 0.02`
- detector + classifier 전체 warm median latency `<= 1000ms`

모든 조건을 만족한 후보만 채택한다. 둘 다 실패하면 현재 detector를 유지한다. 둘 이상 통과하면 recall, mAP50-95, precision, latency 순으로 비교하되 모든 수치는 paired fold 결과와 failure overlay를 함께 확인한다.

채택 후보가 있을 때만 전체 real annotation으로 최종 detector weight를 학습한다. 후보가 없으면 기존 detector 파일과 hash를 manifest에 유지한다.

## 4. Pipeline Manifest

manifest schema version 1에는 다음을 기록한다.

- detector 파일, SHA-256, image size, confidence, IoU
- classifier 파일, SHA-256, image size, accept confidence, accept margin
- classifier OOF precision, coverage, red-review rate와 policy version
- verifier `{kind: none, file: null, sha256: null}`
- canonical label ID 1~20과 name
- bbox 품질 규칙과 모델 선택 보고서 경로

manifest 생성기는 파일 부재, hash 불일치, label 순서 불일치, threshold 범위 오류가 있으면 쓰기를 거부한다. 98% 미달 자체는 더 이상 manifest 생성 실패 조건이 아니다.

## 5. Worker 동작

Python worker는 manifest를 읽고 detector와 classifier를 프로세스 시작 시 한 번만 로드한다.

1. 이미지 bytes를 detector에 전달한다.
2. 유효 detector bbox를 원본 픽셀 기준으로 clamp한다.
3. 모든 bbox crop을 classifier에 한 batch로 전달한다.
4. confidence와 margin이 deployment policy를 만족하면 `labelId`를 지정한다.
5. 만족하지 못하면 `suggestedLabelId`와 review reason만 반환한다.

Fallback은 단계별로 분리한다.

- detector 실패: 기존 annotation을 유지하고 재시도 가능한 이미지 오류 표시
- classifier 실패: detector box를 회색 미라벨 proposal로 반환
- manifest/hash 실패: 자동 기능을 비활성화하고 수동 라벨링은 유지
- verifier는 `none`이므로 로드하거나 호출하지 않음

## 6. Flutter 상태와 시각 규칙

### 6.1 박스 표시

- 자동 라벨 완료: 흰색 박스
- 사용자가 직접 라벨 지정: 흰색 박스
- 애매한 top-1 추천: 빨간색 박스
- classifier 실패 또는 미분류: 회색 박스
- 오류 또는 유효하지 않은 bbox: 빨간 경고 패턴과 오류 아이콘
- label 고유 색상: 박스 선이 아니라 라벨명 배지 또는 텍스트에만 적용
- 선택 상태: 기존 박스색 위에 별도 강조선과 resize handle 표시

색상만으로 상태를 전달하지 않고 `자동 라벨`, `검토 필요`, `미분류` 텍스트 또는 아이콘을 함께 표시한다.

### 6.2 단축키

- 기존 `1~0`, `Q~P` 라벨 지정 단축키는 변경하지 않는다.
- `Enter`는 현재 선택된 빨간 추천 박스에 top-1이 있을 때만 추천을 승인한다.
- 승인 시 `suggestedLabelId`를 `labelId`로 복사하고 source를 `user`로 기록하며 박스를 흰색으로 전환한다.
- 빨간 박스가 아니거나 추천이 없으면 `Enter` 자동 승인은 실행하지 않는다.
- Undo는 승인 전의 빨간 추천 상태를 한 transaction으로 복원한다.

## 7. 저장과 COCO Export

박스에는 실제 라벨과 추천 정보를 분리해 저장한다.

- `labelId`
- `suggestedLabelId`
- classifier top-3, confidence, margin
- review reasons
- detector/classifier/policy version
- label source: `auto` 또는 `user`

COCO annotation에는 유효한 `labelId`가 있는 흰색 박스만 포함한다. 빨간 추천 박스와 회색 미라벨 박스는 제외하며 export 전에 각 제외 수를 요약한다. 기존 프로젝트는 migration 후 기존 사용자 라벨을 그대로 유지하고 AI로 재판정하지 않는다.

## 8. 테스트 전략

### Python

- exact calibration sweep이 512개 초과 score에서도 최대 coverage를 찾는지 검증
- verifier calibration/evaluation fold 분리
- manifest에 기록할 deployment policy 자체를 OOF prediction에 적용하는 검증
- detector train/validation/test key disjointness
- detector 후보 paired OOF와 원본 좌표 prediction artifact
- manifest hash, label 순서, threshold 검증
- classifier failure 시 회색 proposal fallback

### Flutter

- 자동 라벨 흰색, 애매한 추천 빨간색, 미분류 회색 표시
- label명만 고유 색상 적용
- `Enter` 승인과 Undo
- `1~0`, `Q~P` 단축키 유지와 충돌 방지
- 빨간/회색 박스의 COCO 제외
- 프로젝트 저장/재열기 후 추천 metadata 복원

### 통합 및 성능

- 이미지 bytes -> detector -> classifier -> Flutter 상태 반영
- `Test_20260706/08/10/14` 전체 83장 회귀 실행
- warm median `<= 1s`, p95 `<= 2s`, cold start `<= 15s`
- Windows packaging에 manifest와 선택된 detector/classifier만 포함
- verifier와 폐기된 연구 weight가 패키지에 포함되지 않음

## 9. 완료 기준

- classifier 정책이 98% 강제 실패 없이 실제 deployment threshold와 OOF 성능을 보고한다.
- 새 detector 두 후보의 leakage-safe 5-fold 보고서가 생성된다.
- detector gate 결과에 따라 새 후보 또는 현재 detector가 결정적으로 선택된다.
- manifest가 선택된 detector와 새 20-class classifier를 정확한 hash로 참조한다.
- worker가 자동 라벨, 빨간 추천, 회색 fallback을 구분해 반환한다.
- Flutter가 승인된 색상·단축키·Enter 동작을 구현한다.
- 저장, 재열기, Undo, COCO export가 상태 규칙을 보존한다.
- Python, Flutter, 통합, Windows packaging 검증이 통과한다.
