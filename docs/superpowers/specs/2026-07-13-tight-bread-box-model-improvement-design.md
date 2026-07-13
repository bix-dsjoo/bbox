# 빵 외곽 박스 검출 개선 설계

- 작성일: 2026-07-13
- 대상 앱: `bbox`
- 원본 데이터: `C:\workspace\bakery_vision\data\raw\bixolon_bakery`
- 기준 모델: `models/bread_yolov8n_1class_tray_v0_2.pt`
- 상태: 사용자 승인 설계

## 1. 목표

위에서 촬영한 다중 빵 장면에서 빵은 검출하지만 예측 bounding box가 실제 빵 외곽보다 안쪽으로 작게 잡히는 오류를 줄인다.

목표 박스는 인위적인 여백을 추가하지 않고, 보이는 빵의 최외곽에 맞춘 tight bounding box다. 상품 SKU 분류는 이번 범위에 포함하지 않으며 모든 상품을 단일 `bread` 클래스로 학습한다.

## 2. 현재 상태와 제약

원본 데이터는 다음과 같이 구성되어 있다.

- 단일 상품 이미지: 2,057장
- 라벨 레지스트리: 20개
- 단일 상품 이미지가 있는 라벨: 19개
- 단일 상품 이미지가 없는 라벨: `mini_bread`
- 실제 혼합 장면: 5장
- 실제 혼합 장면 COCO 박스: 25개
- 데이터 검수 상태: `unreviewed`
- 데이터 split 상태: `unassigned`

단일 상품 이미지는 검은 턴테이블 위에서 촬영되었고 실제 혼합 장면은 위에서 촬영한 다중 객체 장면이다. 두 촬영 환경 사이에는 domain gap이 있다. 추가 실제 혼합 장면을 확보할 수 없으므로, 합성 장면으로 학습량을 늘리되 모델 선택과 개선 판정에는 실제 혼합 장면만 사용한다.

기존 배포 모델은 YOLOv8n 기반 1-class 빵 검출기이며 앱 worker는 기본 입력 크기 640으로 CPU 추론한다.

## 3. 범위

### 포함

- 실제 혼합 장면 25개 박스의 tight-box 기준 재검수
- 단일 상품 이미지의 전경 추출과 품질 검수
- 위쪽 촬영 다중 빵 합성 장면 생성
- 실제 장면 기준 5-fold leave-one-scene-out 교차검증
- 현재 모델 추가 학습 후보와 COCO 사전학습 후보 비교
- 박스 크기 편향, 포함률, IoU, 미검출, 오검출, CPU 지연 평가
- 최종 모델 후보와 모델 카드 생성

### 제외

- SKU 자동 분류
- 새 촬영 데이터 수집
- 원본 데이터 수정
- 앱 추론 계약 변경
- 검증 전 기존 배포 모델 교체
- 박스 후처리 확장으로 학습 결함을 숨기는 방식

## 4. 데이터 정책

`C:\workspace\bakery_vision\data\raw\bixolon_bakery` 아래의 이미지, manifest, label registry, COCO annotation은 읽기 전용 감사 입력으로 취급한다. 교정 annotation, 전경 자산, 합성 데이터, split, 평가 결과는 `bbox` 저장소의 별도 versioned 출력에 생성한다.

모든 생성 산출물은 다음 lineage를 기록한다.

- 원본 상대 경로와 SHA-256
- 입력 dataset 및 annotation version
- 생성 도구 version 또는 Git commit
- 설정 checksum과 random seed
- 전경 추출 상태와 제외 사유
- 합성 객체별 원본 이미지 ID와 적용 변환

원본 데이터의 라이선스와 사용 권한은 현재 문서화되지 않았으므로, 생성 모델의 운영 배포 전 별도 확인이 필요하다.

## 5. 실제 박스 재검수

현재 25개 COCO 박스는 모두 `unreviewed`이므로 학습 또는 평가 전에 오버레이 시트로 검수한다.

tight-box 기준은 다음과 같다.

- 보이는 빵 픽셀의 좌·상·우·하 최외곽을 포함한다.
- 그림자, 트레이, 종이, 주변 빵은 포함하지 않는다.
- 가려진 부분을 추정해 박스를 확장하지 않는다.
- 이미지 경계에서 잘린 빵은 보이는 영역까지만 포함한다.
- 인위적인 고정 여백이나 비율 여백을 추가하지 않는다.

교정 결과는 새 annotation version으로 저장한다. 기존 `mixed_scene_instances.json`은 변경하지 않는다. 각 박스에는 검수 상태와 원본 annotation ID를 기록한다.

## 6. 전경 추출과 합성 데이터

단일 상품 이미지에서 빵 전경 mask를 생성하고 mask의 tight rectangle을 box 정답으로 사용한다. 자동 mask를 바로 승인하지 않고 접촉 시트와 자동 품질 규칙으로 검수한다.

다음 전경은 제외한다.

- mask가 비어 있거나 여러 비관련 영역으로 분리됨
- 빵의 일부가 눈에 띄게 잘림
- 턴테이블 또는 배경이 크게 포함됨
- foreground coverage가 설정된 안전 범위를 벗어남
- 경계 halo나 구멍이 심함
- 이미지 decode 또는 checksum 검증 실패

승인된 전경은 실제 위쪽 촬영 조건을 모사하는 배경 위에 배치한다. 허용 증강은 크기, 회전, 위치, 밝기·색상 변화, 약한 원근 변화와 제한된 겹침이다. 실제 빵 외곽을 잘라낼 수 있는 강한 crop, 과도한 mosaic, 비현실적인 원근과 겹침은 제한한다.

합성 box는 변환된 mask의 최외곽에서 계산한다. 각 scene은 배경 ID, scene seed, 객체별 원본 ID, 변환값, mask checksum과 최종 box를 기록한다.

## 7. Split과 누수 방지

실제 혼합 장면 5장을 기준으로 leave-one-scene-out 교차검증을 수행한다. 각 fold에서 실제 장면 4장은 학습 보조에 사용하고 1장은 평가에만 사용한다.

held-out 장면은 해당 fold에서 다음 모든 경로로부터 제외한다.

- 실제 학습 이미지와 annotation
- 합성 배경 또는 배경 template
- threshold 및 하이퍼파라미터 선택
- early stopping과 모델 선택

합성 이미지는 train에만 사용하고 독립 성능 증거로 사용하지 않는다. 각 fold의 평가 결과를 합치면 5장 25개 실제 박스 각각에 대해 학습 시 보지 않은 예측을 한 번씩 얻는다.

원본 단일 상품 연속 촬영본은 독립 개체로 간주하지 않는다. 합성 학습 자산으로는 사용할 수 있지만 실제 평가 표본 수를 늘린 것으로 계산하지 않는다.

## 8. 모델 후보와 학습

동일 데이터와 평가 조건에서 다음 두 후보를 비교한다.

### 후보 A: 현재 모델 추가 학습

`bread_yolov8n_1class_tray_v0_2.pt`에서 시작해 교정된 실제 장면과 개선된 합성 장면으로 fine-tuning한다. 현재 모델의 검출 능력을 유지하면서 박스 회귀 편향을 교정하는 것이 목적이다.

### 후보 B: COCO 사전학습 모델 재학습

COCO 사전학습 YOLOv8n에서 시작해 같은 데이터로 fine-tuning한다. 현재 모델이 기존 합성 box의 작은 박스 편향을 강하게 학습했을 가능성에 대비한다.

기본 입력 크기는 앱 worker와 같은 640으로 유지한다. 두 후보는 동일한 fold, seed 집합, augmentation 범위와 평가 threshold 정책을 사용한다. confidence threshold는 실제 평가 결과를 본 뒤 모델별로 유리하게 조정하지 않고, 교차검증 전에 고정하거나 train-only calibration으로 결정한다.

## 9. 평가 지표

기준 모델과 후보 모델을 실제 5장 25개 박스에서 동일한 매칭 규칙으로 비교한다. 합성 validation mAP는 학습 진단에만 사용한다.

주요 지표는 다음과 같다.

- `width_ratio = predicted_width / ground_truth_width`
- `height_ratio = predicted_height / ground_truth_height`
- `area_ratio = predicted_area / ground_truth_area`
- `ground_truth_coverage = intersection_area / ground_truth_area`
- matched box IoU
- recall과 미검출 개수
- 이미지당 false positive 개수
- Windows CPU 이미지당 추론 시간

`width_ratio < 0.95` 또는 `height_ratio < 0.95`인 matched prediction을 작은 박스 오류로 집계한다. 기준 모델 결과를 먼저 고정한 뒤 후보 모델을 평가한다.

## 10. 채택 기준

후보 모델은 교차검증 합산 결과에서 다음 조건을 모두 만족해야 한다.

- 작은 박스 오류 비율이 기준 모델보다 최소 30% 감소
- median ground-truth coverage가 기준 모델보다 개선
- median IoU가 기준 모델보다 개선
- 미검출 개수가 증가하지 않음
- 이미지당 false positive가 기준 모델보다 0.2개를 초과해 증가하지 않음
- Windows CPU median 추론 시간이 기준 모델보다 20% 이상 느려지지 않음

25개 박스는 작은 표본이므로 평균만 보고 채택하지 않는다. 장면별 결과, 각 박스의 paired 전후 비교, 실패 사례 오버레이를 함께 검토한다. 조건을 통과하는 후보가 없으면 기존 모델을 유지하고 실패 원인을 데이터, mask, 합성 장면, 학습 설정으로 구분해 기록한다.

## 11. 최종 학습과 배포 후보

교차검증으로 후보 유형과 학습 설정을 선택한 후, 실제 5장 전체와 승인된 합성 train 데이터를 사용해 최종 배포 후보를 학습한다. 최종 모델은 교차검증을 다시 수행한 것처럼 보고하지 않는다. 성능 주장은 fold별 held-out 결과에만 근거한다.

최종 산출물은 다음을 포함한다.

- versioned model weight
- 모델 카드
- 데이터·코드·설정 checksum
- fold별 및 합산 평가 JSON
- 기준 모델과 후보 모델의 전후 오버레이 시트
- 실패 사례 목록
- CPU latency report

기존 `models/bread_yolov8n_1class_tray_v0_2.pt`는 덮어쓰지 않는다. 새 모델은 별도 이름으로 생성하고 평가 결과와 사용자 확인을 거친 뒤 앱 runtime model 승격을 별도 변경으로 수행한다.

## 12. 오류 처리

- 원본 checksum 또는 manifest 참조가 다르면 해당 입력을 사용하지 않고 실패한다.
- COCO box가 이미지 밖이거나 면적이 0 이하면 변환을 중단한다.
- held-out 장면이 train 또는 합성 배경에 포함되면 해당 fold 생성을 실패한다.
- 승인되지 않은 mask 또는 빈 mask는 합성 입력에서 제외한다.
- 합성 장면을 제한된 재시도 횟수 안에 만들지 못하면 부분 dataset을 게시하지 않는다.
- 학습 중단 시 기존 model weight와 dataset을 변경하지 않는다.
- 평가 prediction 수와 image ID가 맞지 않으면 비교 리포트를 생성하지 않는다.

## 13. 테스트 전략

### 단위 테스트

- COCO `xywh`와 YOLO normalized coordinate 변환
- mask 변환 후 tight bounding box 계산
- box clamp와 유효성 검증
- 작은 박스 오류와 ground-truth coverage 계산
- prediction-to-ground-truth matching
- 설정과 seed의 결정성

### 데이터 검증 테스트

- 원본 2,057장, 실제 장면 5장, 실제 박스 25개 회귀 검사
- label registry 20개와 단일 상품 coverage 19개 구분
- checksum, decode, 중복 경로와 누락 참조 검사
- 승인 mask만 합성 입력으로 사용하는 fail-closed 검사
- held-out 장면의 train·background 누수 검사

### 파이프라인 테스트

- 소량 전경과 장면을 사용하는 합성 smoke test
- 짧은 YOLO smoke training과 validation
- 기준·후보 평가 리포트 schema 검사
- 동일 입력과 seed의 split 및 합성 재현성
- Windows CPU worker 추론 smoke test

## 14. 완료 조건

- 실제 25개 박스의 tight-box 검수본과 오버레이가 존재한다.
- 승인된 전경 목록과 제외 사유가 기록된다.
- 합성 데이터가 seed와 lineage로 재현된다.
- 5개 fold 모두 held-out 누수 검증을 통과한다.
- 기준 모델과 후보 A/B의 실제 장면 비교 결과가 생성된다.
- 채택 기준의 각 항목이 수치와 paired 사례로 보고된다.
- 최종 후보 모델과 모델 카드가 별도 version으로 생성된다.
- 원본 데이터와 기존 배포 모델 checksum이 작업 전후 동일하다.
- 관련 단위·데이터·파이프라인 테스트가 통과한다.

## 15. 후속 작업

새 후보가 채택 기준을 통과하면 별도 변경에서 다음을 수행한다.

1. 앱 runtime model 승격
2. packaging model 목록과 checksum 갱신
3. worker 기본 threshold 확인
4. Flutter detector 및 packaging 테스트 실행
5. Windows release smoke test

