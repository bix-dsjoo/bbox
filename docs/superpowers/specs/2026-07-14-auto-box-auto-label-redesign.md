# 자동 박스 개선 및 자동 라벨 도입 설계

- 작성일: 2026-07-14
- 대상 저장소: `C:\workspace\bbox`
- 원본 데이터: `C:\workspace\bixolon_bakery`
- 현재 detector: `models/bread_yolov8n_1class_tray_v0_2.pt`
- 상태: 사용자 승인 설계

## 1. 목표

현재 자동 박스 기능의 높은 정밀도는 유지하면서 누락을 줄이고, 검출된 빵을 20개 상품 라벨로 자동 분류한다. 확실한 결과는 자동으로 라벨을 지정하고, 애매하거나 데이터 품질 경고가 있는 결과만 빨간 박스로 표시해 사용자가 검토하게 한다.

이번 변경의 핵심 목표는 다음과 같다.

- 자동 박스의 recall과 박스 경계 품질을 균형 있게 개선한다.
- 20개 상품에 대한 자동 라벨을 도입한다.
- classifier를 기본 분류기로 사용하고 embedding은 애매한 경우에만 선택적으로 사용한다.
- 원본 데이터 위치를 `C:\workspace\bixolon_bakery`로 변경한다.
- 네 날짜의 혼합 장면을 균일하게 섞은 5-fold OOF 평가로 모델을 선택한다.
- Windows CPU 워밍업 이후 전체 파이프라인 중앙 지연시간을 1초 이하로 유지한다.

## 2. 현재 상태와 문제

현재 제품 경로는 persistent Python worker에서 YOLOv8n 1-class 모델을 실행한다. 기본 설정은 `imgsz=640`, `conf=0.40`, `iou=0.55`이며, 결과는 좌표와 confidence만 반환된다. Flutter 앱은 모든 결과를 미라벨 `proposal`로 만들고 기존 박스를 교체한다.

현재 운영 모델의 2026-07-14 혼합 장면 30장, GT 150개 평가 결과는 다음과 같다.

- prediction: 112개
- match: 110개
- miss: 40개
- false positive: 2개
- recall: 0.7333
- precision: 0.9821

따라서 주된 문제는 false positive보다 누락이다. 기존 Candidate A는 recall을 높였지만 박스가 느슨해지고 IoU와 지연시간이 악화되어 채택하지 않는다.

과거 classifier와 OpenCLIP 기반 정책 실험 코드는 존재하지만, 제품 경로에서는 결과가 모두 미라벨 proposal로 덮여 실제 계산 결과가 사용되지 않았다. 과거 classifier 학습 데이터와 충분한 재현 평가 결과도 현재 저장소에 남아 있지 않으므로 기존 weight를 검증 없이 다시 배포하지 않는다.

## 3. 범위

### 포함

- 새 raw-data adapter와 versioned dataset manifest
- 1-class detector 후보 재학습 및 비교
- 20-class classifier 학습 및 평가
- 애매한 표본만 대상으로 하는 embedding 검증 후보 비교
- 자동 라벨 상태와 추천 메타데이터 저장
- 박스 및 라벨 배지 시각 규칙 변경
- 빨간 검토 대상 UX와 기존 라벨 단축키 연동
- COCO export 경고 및 제외 규칙 갱신
- worker 프로토콜 확장, 캐시, 오류 격리
- 단위·위젯·통합·성능 테스트

### 제외

- 앱의 기본 이미지 폴더를 raw-data 경로로 고정하는 변경
- 기존 사용자 프로젝트의 경로 자동 마이그레이션
- 원본 JSON 또는 원본 이미지 수정
- 자동 재학습
- 클라우드 학습, 협업 서버, 계정 기능
- 검증되지 않은 모델의 즉시 운영 weight 교체

## 4. 데이터 원본과 라벨 레지스트리

`C:\workspace\bixolon_bakery`는 읽기 전용 원본으로 취급한다. 현재 확인된 구성은 다음과 같다.

- `Bread01`~`Bread20`: 단일 제품 이미지 3,230장
- `Test_20260706`: 45장, annotation 314개
- `Test_20260708`: 3장, annotation 21개
- `Test_20260710`: 5장, annotation 25개
- `Test_20260714`: 30장, annotation 150개
- 혼합 장면 합계: 83장, annotation 510개

새 dataset adapter는 원본 구조를 직접 변경하지 않고 아래 정보를 갖는 canonical manifest를 생성한다.

- 날짜 폴더를 포함한 상대 경로
- SHA-256, width, height
- `single_product` 또는 `mixed_scene` source kind
- category ID와 canonical category name
- 촬영 날짜 또는 source directory
- COCO bbox와 원본 annotation ID
- decode, 경계, 중복, 라벨 불일치 감사 결과

동일한 `E0501.jpg` 같은 파일명이 날짜별로 반복되므로 basename을 ID로 사용하지 않는다. `Test_20260714/E0501.jpg` 같은 상대 경로와 checksum 조합을 canonical key로 사용한다.

category ID 1~20은 `labels.txt`를 기준으로 고정한다. ID 16의 canonical name은 `Grain Campagne`이며, 기존 COCO의 `Grain  Campagne`는 import alias로만 허용한다. 원본 JSON은 수정하지 않는다.

생성 데이터, 보정 annotation, split, 모델, 평가 결과는 저장소의 versioned output 영역에 저장하고 원본 경로에는 쓰지 않는다. 모든 산출물은 입력 checksum, 도구 버전 또는 Git commit, seed, 설정 checksum을 기록한다.

## 5. 전체 아키텍처

권장 파이프라인은 다음과 같다.

`1-class detector -> 20-class classifier -> 조건부 embedding 검증 -> 자동 라벨 정책`

각 구성 요소의 책임은 분리한다.

- dataset catalog: raw-data 구조 해석, 라벨 정규화, manifest와 split 생성
- detector: 이미지에서 빵 bbox와 detection confidence 생성
- classifier: 검출 crop 배치를 20개 상품으로 분류하고 top-k와 margin 반환
- embedding verifier: classifier가 애매한 crop만 prototype 또는 reference와 비교
- suggestion policy: confidence, margin, embedding 일치, 품질 경고를 이용해 흰색 자동 라벨 또는 빨간 검토 대상으로 결정
- Flutter adapter: 결과를 도메인 상태로 변환하고 저장·Undo·export 규칙 적용

Python worker는 모델을 시작 시 한 번만 로드한다. Flutter는 이미지 bytes를 전달하고 worker는 각 박스에 대해 다음 정보를 반환한다.

- 원본 이미지 픽셀 기준 bbox
- detection confidence
- 최종 또는 임시 category ID와 name
- classifier top-3와 점수·margin
- embedding 실행 여부와 일치 결과
- 모델 버전과 정책 버전
- 검토 사유 목록

## 6. 학습 전략

### Detector

다음 세 후보를 동일한 split과 평가 규칙으로 비교한다.

1. 현재 운영 모델
2. 현재 운영 모델에서 균형형 목표로 fine-tuning한 후보
3. COCO 사전학습 YOLOv8n에서 새로 학습한 후보

학습에는 training fold의 실제 혼합 장면과 필요한 경우 단일 제품 이미지로 만든 synthetic 장면을 사용한다. detector 학습 목표는 recall만 높이는 것이 아니라 precision, tightness, IoU, area ratio, latency를 함께 유지하는 것이다.

### Classifier

20-class classifier는 단일 제품 이미지와 training fold 혼합 장면의 GT crop을 사용한다. 혼합 장면 held-out crop은 해당 fold의 학습, threshold 선택, early stopping에 사용하지 않는다.

현재 저장된 과거 classifier weight는 baseline 후보로만 재평가할 수 있으며, provenance와 재현성이 부족하면 신규 학습 후보보다 우선하지 않는다.

### Embedding

embedding은 독립 기본 분류기로 사용하지 않는다. classifier의 top-1 confidence가 낮거나 top-1/top-2 margin이 작은 경우에만 실행한다.

다음 후보를 classifier-only와 비교한다.

- classifier backbone feature prototype
- 경량 image embedding model의 class prototype

embedding이 채택 기준을 충족하지 못하면 제품에서 제외하고 detector와 classifier만 사용한다.

## 7. Synthetic 데이터 정책

Synthetic 데이터는 필수가 아니라 선택적 학습 증강 후보다. 실제 데이터 단독 baseline보다 OOF 결과가 좋아질 때만 채택한다.

우선순위는 단일 제품 이미지에서 얻은 foreground를 실제 tray 계열 배경에 합성하는 geometry-preserving copy-paste 방식이다. 상품 형태나 라벨 정체성을 바꿀 가능성이 있는 생성형 이미지 합성은 기본 범위에서 제외한다.

Synthetic 생성 규칙은 다음과 같다.

- 해당 fold의 training-side 원본만 source로 사용한다.
- 단일 제품 이미지는 OOF 평가 대상이 아닌 보조 학습 pool로 관리하되, 연속 촬영본과 근접 중복을 group으로 묶고 별도 검증용으로 배정한 group은 해당 fold 학습에서 제외한다.
- held-out 혼합 장면, held-out crop, held-out 배경은 사용하지 않는다.
- validation, threshold calibration, 최종 성능 보고에는 synthetic 이미지를 사용하지 않는다.
- 실제 학습 표본을 synthetic이 압도하지 않도록 학습 배치 기준 최대 50%로 제한한다.
- class별 synthetic 수를 기록하고 부족 클래스를 우선 보강한다.
- bbox는 합성된 foreground mask의 실제 최외곽에서 계산한다.
- 과도한 가림, 비현실적 크기, 경계 halo, 잘못된 mask 결과는 자동 제외한다.
- scene seed, source IDs, 변환값, mask checksum, 최종 bbox를 기록한다.

`real-only`와 `real+synthetic`을 동일 조건으로 비교한다. Synthetic 후보가 recall을 높이더라도 박스 tightness, precision, 클래스 정확도 또는 실제 장면 OOF 성능을 악화하면 채택하지 않는다.

## 8. 5-fold 교차검증

혼합 장면 83장을 합쳐 `17/17/17/16/16`장 규모의 5개 fold로 나눈다. 날짜와 multilabel 분포를 가능한 한 균일하게 맞추되 완전한 균일성이 불가능하면 편차를 manifest에 보고한다.

누수 방지 규칙은 다음과 같다.

- 각 실제 혼합 이미지는 정확히 한 번만 OOF 평가 대상이 된다.
- 동일 이미지에서 파생된 crop, 증강, cache는 같은 fold에 둔다.
- held-out 이미지와 그 파생물은 학습, synthetic 배경, threshold 조정에 사용하지 않는다.
- split 생성은 seed와 입력 checksum으로 재현 가능해야 한다.
- 네 날짜의 폴더가 각 fold에 최대한 고르게 분산되어야 한다.

모델 설정과 threshold를 결정한 뒤 전체 83장과 허용된 학습 데이터를 이용해 최종 배포 후보를 학습한다. 성능 주장은 최종 전체 학습 weight가 아니라 5-fold OOF 결과를 근거로 한다.

## 9. 자동 라벨 및 검토 정책

이전의 “모든 결과를 추천만 하고 사용자 승인 후 라벨링” 정책은 사용자가 요청한 빠른 흐름에 맞춰 다음과 같이 변경한다.

### 확실한 결과

classifier가 calibration threshold와 margin 조건을 만족하면 top-1 category를 실제 `labelId`로 자동 지정한다. classifier가 애매했지만 embedding 검증 후 채택 조건을 만족한 경우도 실제 라벨로 자동 지정한다.

- 박스 상태: labeled
- 박스 테두리: 흰색
- COCO export: 포함
- 메타데이터: `source=auto`, 모델 버전, 정책 버전, 점수 저장

### 애매한 결과

classifier와 embedding으로도 충분히 확정할 수 없으면 top-1은 `suggestedLabelId`로만 저장하고 실제 `labelId`는 비워 둔다.

- 박스 상태: `proposal`
- 상태 조건: `labelId=null`, `suggestedLabelId!=null`, `reviewReasons`가 비어 있지 않음
- 박스 테두리: 빨간색
- UI: 경고 아이콘, `검토 필요`, 구체적 사유 표시
- COCO export: 제외
- 오른쪽 패널: top-1과 필요 시 top-2/top-3 표시

빨간 박스를 선택한 상태에서 `Enter`는 표시된 top-1을 승인한다. 기존 `1~0`, `Q~P` 라벨 단축키는 그대로 유지하며 다른 라벨을 직접 지정한다. 후보 순위에 숫자 단축키를 새로 배정하지 않는다.

검토 필요 사유에는 분류 불확실성 외에도 low detection confidence, 너무 작은 박스, 이미지 경계 잘림, 완전 중복 가능성, 비정상적인 aspect 또는 area가 포함될 수 있다.

분류 신뢰도가 높더라도 위 품질 경고가 하나라도 있으면 실제 `labelId`를 자동 지정하지 않는다. top-1은 임시 추천으로만 유지하고 빨간 검토 대상으로 보낸다.

## 10. 시각 규칙과 이미지 확정

- 회색 테두리: 라벨 추천이 없거나 분류 처리 전인 미라벨 proposal
- 빨간색 테두리: 임시 추천은 있으나 사람 확인이 필요한 박스
- 흰색 테두리: 실제 라벨이 지정된 박스
- 라벨명 배지: category별 고유색 배경과 대비되는 글자색
- 선택 상태: category 색을 박스에 쓰지 않고 굵은 강조선과 resize handle로 표현

흰색 배경에서도 식별할 수 있도록 흰색 박스에는 얇은 어두운 외곽 그림자를 추가한다. 빨간 상태는 색상만 사용하지 않고 텍스트와 아이콘을 함께 사용한다.

빨간색 또는 회색 박스가 하나라도 있으면 이미지 확정 버튼을 비활성화한다. 모든 유효 박스가 흰색이어도 AI가 이미지를 자동으로 confirmed 상태로 바꾸지는 않는다. 사용자가 이미지 확정을 실행해야 한다. 확정된 이미지의 박스나 라벨을 수정하면 `needsReview`로 되돌린다.

## 11. 저장과 COCO Export

박스에는 실제 라벨과 추천 정보를 분리해 저장한다.

- `labelId`: 확정된 실제 라벨
- `suggestedLabelId`: 미확정 top-1 추천
- classifier top-k, confidence, margin
- embedding 실행 및 일치 정보
- review reason 목록
- detector, classifier, embedding, policy version
- label source: auto 또는 user

프로젝트 저장 버전은 이전 프로젝트를 열 수 있도록 migration을 제공한다. 기존 labeled 박스는 사용자 라벨로 유지하고 새 모델로 자동 재계산하지 않는다.

COCO에는 유효한 `labelId`가 있는 흰색 박스만 annotation으로 포함한다. 빨간색과 회색 박스는 제외한다. 이미지가 미확정이어도 기존 제품 원칙대로 export할 수 있지만 export 전 다음을 요약한다.

- 미확정 이미지 수
- 흰색 자동 라벨 annotation 수
- 사용자 지정 annotation 수
- 제외되는 빨간 검토 박스 수
- 제외되는 회색 미라벨 박스 수
- 오류 이미지 수

## 12. 재실행, Undo 및 캐시

박스가 없는 이미지에서는 확인 없이 자동 박스를 실행한다. 기존 박스가 있는 이미지에서는 교체 확인을 먼저 받으며 detector와 자동 라벨 결과의 전체 교체를 하나의 Undo transaction으로 기록한다.

새 결과가 완전히 준비되기 전에 기존 박스를 삭제하지 않는다. 사용자가 취소하거나 worker 단계가 실패하면 임시 결과를 폐기하고 기존 상태를 유지한다.

추천 결과 cache key에는 이미지 checksum, 원본 픽셀 bbox, 모델 버전, 정책 버전을 포함한다. 박스를 이동하거나 크기를 변경하면 drag 종료 시 해당 박스 cache만 무효화하고 분류를 다시 실행한다. 수동으로 새 박스를 그린 경우에도 동일한 classifier 및 조건부 embedding 흐름을 실행한다.

## 13. 성능 설계

worker는 detector, classifier, 선택된 embedding과 prototype을 프로세스 시작 시 한 번만 로드한다. detector 결과 crop은 classifier에 배치 입력하고 embedding은 애매한 crop에만 실행한다. 현재 사용자가 선택한 이미지는 백그라운드 대기열보다 우선 처리한다.

Windows CPU 워밍업 이후 목표는 다음과 같다.

- detector + classifier + 조건부 embedding 중앙값: 1초 이하
- 전체 95백분위 지연시간: 2초 이하
- worker 최초 모델 준비: 15초 이하
- UI thread의 입력 중단 없음

성능 목표를 넘으면 embedding 구현을 먼저 제거하거나 경량화한다. 이후 classifier 입력 크기와 배치를 조정한다. detector 정확도를 희생하는 모델 축소는 마지막 선택으로 둔다.

## 14. 오류 처리

- detector 실패: 기존 박스를 유지하고 이미지에 재시도 가능한 오류 표시
- classifier 실패: detector 박스는 유지하되 회색 미라벨 상태로 표시
- embedding 실패: 자동 라벨로 승격하지 않고 빨간 검토 대상으로 처리
- invalid bbox: 경계 보정이 안전한 경우 clamp하고 면적이 0 이하이면 폐기 및 기록
- worker 중단: 한 번 자동 재시작 후 다시 실패하면 AI 기능을 비활성화하고 수동 모드 안내
- 사용자 취소: 임시 결과를 폐기하고 기존 데이터 유지
- 모델 누락 또는 checksum 불일치: 관련 자동 기능을 비활성화하고 원인과 복구 행동 표시
- project save 실패: 메모리 상태를 유지하고 재시도 안내

단계별 실패가 다른 단계의 정상 결과나 기존 사용자 데이터를 파괴하지 않도록 fail-safe로 처리한다.

## 15. Detector 평가 및 채택 기준

평가 전 510개 기존 bbox의 경계, 중복, class, annotation provenance를 점검한다. 현재 detector에서 파생된 GT가 있다면 기존 모델에 유리한 평가가 될 수 있으므로 별도로 표시하고 필요한 보정은 sidecar annotation version으로 관리한다.

주요 지표는 precision, recall, F1, mAP50-95, matched IoU, width/height/area ratio, ground-truth coverage, miss, false positive, Windows CPU latency다.

새 detector는 5-fold OOF 합산 결과에서 다음 조건을 모두 만족할 때만 채택한다.

- recall 0.85 이상이며 현재 모델보다 최소 5%p 향상
- precision 0.97 이상이며 현재보다 1%p 넘게 하락하지 않음
- mAP50-95가 현재보다 낮지 않음
- median area ratio가 0.95~1.05
- median IoU가 현재보다 0.02 넘게 하락하지 않음
- 전체 파이프라인 중앙 지연시간 1초 이하

평균값만 보지 않고 fold별 결과와 paired failure overlay를 함께 검토한다. 하나의 필수 기준이라도 실패하면 현재 모델을 유지한다.

## 16. 자동 라벨 및 Embedding 채택 기준

자동 라벨은 OOF 실제 혼합 장면 crop에서 다음을 측정한다.

- top-1 accuracy와 macro F1
- 클래스별 precision과 recall
- top-3 포함률
- confidence calibration error
- 흰색 자동 라벨 coverage
- 빨간 검토 대상 비율

흰색 자동 라벨 threshold는 전체 OOF precision 98% 이상을 만족하도록 정한다. OOF 표본이 20개 이상인 클래스는 클래스별 precision 95% 이상도 요구한다. 실제 혼합 장면 표본이 부족한 클래스는 더 보수적인 threshold 또는 embedding 일치 조건을 사용하고, 충분한 근거가 없으면 빨간색으로 남긴다.

Embedding은 다음을 모두 만족할 때만 포함한다.

- classifier-only 대비 애매한 표본 accuracy가 최소 3%p 향상하거나, 동일한 98% 자동 라벨 precision에서 빨간 비율을 15% 이상 감소
- 흰색 자동 라벨 precision 하락이 0.5%p 이하
- 전체 중앙 지연시간 1초, 95백분위 2초 이하
- 특정 클래스 개선을 위해 다른 클래스의 필수 precision을 훼손하지 않음

조건을 만족하지 못하면 classifier-only 정책을 채택한다.

## 17. 테스트 전략

### 단위 테스트

- raw-data path와 canonical image key 생성
- label ID 16 alias 정규화
- 5-fold 날짜·클래스 분포와 누수 검사
- synthetic lineage와 held-out source 차단
- classifier ambiguity와 embedding 실행 조건
- 흰색 자동 라벨 및 빨간 임시 추천 상태 전이
- bbox cache invalidation
- COCO export의 빨간·회색 박스 제외
- project migration과 recommendation metadata 직렬화

### 위젯 테스트

- 흰색, 빨간색, 회색 박스 시각 규칙
- 라벨 배지만 category 고유색 사용
- 빨간 박스의 아이콘, 텍스트, 검토 사유 표시
- `Enter`로 top-1 승인
- 기존 `1~0`, `Q~P` 라벨 단축키 유지
- 빨간 또는 회색 박스가 있으면 이미지 확정 비활성화
- 사용자 승인 후 빨간 박스가 흰색으로 변경
- 재실행 확인과 단일 Undo

### 통합 및 성능 테스트

- 이미지 bytes -> detector -> classifier -> 조건부 embedding -> Flutter 상태 반영
- classifier 또는 embedding 실패 시 단계별 fallback
- worker 재시작과 모델 checksum 오류
- 자동 라벨이 포함된 프로젝트 저장·재열기·COCO export
- 실제 Windows CPU warm p50, p95, cold startup 측정
- 83장 전체 OOF prediction 수집과 채택 gate 자동 판정

## 18. 완료 조건

- 새 raw-data adapter가 3,230개 단일 이미지와 83개 혼합 장면, 510개 annotation을 재현 가능하게 catalog한다.
- 5-fold split이 날짜와 label 분포를 보고하고 leakage 검사를 통과한다.
- 현재 모델과 detector 후보의 OOF 비교 보고서가 생성된다.
- 20-class classifier의 OOF 결과와 calibration threshold가 생성된다.
- embedding 채택 또는 제외 판단이 수치로 기록된다.
- synthetic 사용 여부가 real-only ablation 결과로 결정된다.
- 확실한 top-1은 흰색 자동 라벨로 저장된다.
- 애매한 top-1은 실제 label과 분리된 빨간 임시 추천으로 저장된다.
- 라벨 단축키 충돌 없이 빨간 박스를 검토할 수 있다.
- COCO export가 흰색 유효 라벨만 포함하고 제외 항목을 요약한다.
- worker 오류, 취소, 재실행이 기존 사용자 데이터를 손상시키지 않는다.
- Windows CPU 성능 목표와 관련 테스트를 통과한다.
- 기존 운영 모델은 모든 채택 gate가 통과하기 전까지 교체하지 않는다.

## 19. 후속 작업

이 설계 승인 후 별도 구현 계획에서 작업을 다음 순서로 분해한다.

1. raw-data adapter, manifest, 감사 및 5-fold split
2. 평가 harness와 현재 detector baseline 고정
3. detector 후보 및 synthetic ablation
4. classifier 학습, OOF prediction, calibration
5. embedding bake-off와 채택 결정
6. worker protocol과 persistent runtime 확장
7. Flutter 상태 모델, UI, 단축키, 저장 migration
8. COCO export 경고와 제외 규칙
9. 통합·Windows CPU 성능 검증
10. 모델 카드, packaging, 운영 weight 교체 여부 결정
