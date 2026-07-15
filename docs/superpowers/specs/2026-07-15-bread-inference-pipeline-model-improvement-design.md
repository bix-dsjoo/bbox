# 빵 자동 박스 추론 파이프라인 및 모델 개선 설계

- 작성일: 2026-07-15
- 원천 데이터: `C:\workspace\bixolon_bakery`
- 대상 앱: `bbox`
- 상태: 사용자 승인 설계

## 1. 목적

현재 자동 박스 파이프라인의 detector 누락을 줄이고, mixed-scene에서 사실상 동작하지 않는 classifier를 다시 학습한다. 모델 선택, 앱 공통 상태 정책, runtime manifest, Windows 패키징을 하나의 재현 가능한 배포 계약으로 묶는다.

최우선 목표는 추론 속도보다 다음 두 가지다.

1. 실제 빵 객체 누락 최소화
2. 잘못된 SKU 자동 라벨 최소화

흰색 자동 확정, 빨간 검토, 회색 라벨 미정 기준은 앱 전체에 공통으로 적용한다. 최종 사용자나 프로젝트별 설정으로 노출하지 않는다.

## 2. 확인된 현재 상태

### 2.1 원천 데이터

2026-07-15 재감사 결과는 다음과 같다.

- 전체 이미지: 3,313장
- 단일 상품 이미지: 3,230장
- COCO 등록 mixed-scene 이미지: 83장
- COCO bbox: 510개
- category: canonical ID 1~20
- 미등록 또는 누락 이미지: 0장
- 유효하지 않거나 이미지 경계를 벗어난 bbox: 0개
- 동일 이미지 내 완전 중복 bbox: 0개
- exact duplicate 이미지 hash group: 0개
- 서로 다른 mixed 날짜 사이의 duplicate 이미지: 0개

`C:\workspace\bixolon_bakery`는 읽기 전용 입력이다. catalog, split, crop, 학습 데이터, prediction, report, weight는 모두 `bbox` 저장소 아래의 versioned output에 생성한다.

### 2.2 현재 detector

현재 작업 중 manifest가 가리키는 `bread_detector_tight_fold4_rebuilt.pt`를 수정된 `Test_20260714` COCO GT 30장·150박스에서 worker와 동일한 설정으로 재평가한 결과는 다음과 같다.

- prediction: 146개
- match: 144개
- miss: 6개
- false positive: 2개
- recall: 0.9600
- precision: 0.9863

이 모델은 전체 데이터 최종 학습 모델이 아니라 과거 fold-4 weight다. 현재 수치는 비교 기준으로만 사용하고 자동 승격하지 않는다.

### 2.3 현재 classifier

현재 작업 중 manifest가 가리키는 classifier는 다음 상태다.

- quick rebuild dataset: 단일 상품 3,230장
- mixed GT crop: 0장
- 최초 학습: 3 epoch
- 후속 12-epoch run: 2 epoch까지만 기록됨
- 단일 상품 클래스별 앞 10장 평가 top-1: 0.835
- `Test_20260714` GT crop top-1: 0.1333
- detector crop top-1: 0.1528
- matched detector box 144개 전부 `review`
- 흰색 자동 확정: 0개

manifest에 기록된 classifier OOF precision/coverage는 이 weight의 실제 동작을 설명하지 못한다. 따라서 현재 classifier weight와 해당 OOF metadata는 배포 근거로 사용하지 않는다.

### 2.4 배포 계약 불일치

- Git 기준 manifest와 작업 중 manifest가 서로 다른 detector/classifier를 가리킨다.
- Git 기준 일부 content-addressed weight는 현재 `models` 폴더에 없다.
- 작업 중 manifest는 검증되지 않은 quick rebuild classifier를 가리킨다.
- packaged isolated Python에서 sibling worker module import와 필수 runtime module 설치를 보완하는 미커밋 변경이 존재한다.

이 설계는 기존 dirty 변경과 `outputs\quick_rebuild`를 보존한다. 새 산출물은 별도 output root에만 생성한다.

## 3. 범위

### 포함

- canonical catalog 재생성과 checksum audit
- 촬영 그룹 단위 deterministic 5-fold split
- 1-class bread detector 후보 학습과 OOF 선택
- 20-class classifier 후보 학습과 OOF 선택
- GT crop과 OOF detector crop 양쪽의 classifier 평가
- 앱 공통 자동 라벨 정책 calibration
- manifest schema v2와 모델 내부 class-map 검증
- persistent worker의 proposal 정렬, NMS, crop batch 처리 개선
- Flutter 상태 보존 회귀 테스트
- Windows runtime 및 installer asset 검증
- 최종 weight, manifest, 모델 카드, 실패 사례 시각화

### 제외

- 원천 이미지나 COCO JSON 수정
- 프로젝트별 또는 사용자별 threshold 설정
- cloud 학습·동기화·계정 기능
- pseudo-label을 정답으로 사용하는 학습
- detector와 classifier 동시 ensemble
- 대형 foundation detector 또는 외부 API 도입
- 검증 전 현재 weight나 manifest 삭제

## 4. 전체 아키텍처

```text
읽기 전용 원천 데이터
C:\workspace\bixolon_bakery
        │
        ├─ 단일 상품 3,230장
        └─ COCO mixed scene 83장·510박스
        ↓
checksum catalog + capture-group split
        ↓
Detector grouped OOF → detector winner
        ↓
OOF detector box + GT crop/jitter
        ↓
Classifier grouped OOF → classifier winner
        ↓
raw metric + global policy curve
        ↓
전체 데이터 최종 학습
        ↓
weight/hash/manifest/report prospective audit
        ↓
worker·Flutter·Windows 검증 후 원자적 승격
```

모델의 raw score 생성과 앱 공통 상태 정책을 분리한다. 모델 선택은 detector recall/precision/IoU와 classifier top-1/macro recall로 수행한다. 흰색·빨간색·미정 비율은 별도의 policy curve로 결정한다.

## 5. Catalog와 데이터 경계

### 5.1 Canonical 입력

다음을 catalog 계약으로 고정한다.

- `labels.txt`는 canonical ID 1~20과 정확히 일치해야 한다.
- `Bread01`~`Bread20` 디렉터리가 모두 존재해야 한다.
- `Test_20260706`, `Test_20260708`, `Test_20260710`, `Test_20260714`의 실제 이미지 파일과 각 COCO `images` 목록은 정확히 일치해야 한다.
- 등록된 모든 이미지는 decode와 SHA-256 계산을 통과해야 한다.
- COCO image dimension은 실제 decode dimension과 일치해야 한다.
- bbox는 유한한 양수 `xywh`이고 이미지 경계 안에 있어야 한다.
- category name의 연속 공백은 canonical 비교 시 정규화하지만, 저장되는 registry는 canonical 이름만 사용한다.

등록되지 않은 이미지나 누락된 이미지가 한 장이라도 있으면 학습을 시작하지 않는다.

### 5.2 Capture group

이미지 단위 랜덤 split을 사용하지 않는다.

- 단일 상품 capture group은 `BreadXX`와 파일명의 마지막 `(frame index)`를 제거한 stem으로 만든다. 예를 들어 같은 각도·촬영 series의 `(1)`~`(24)`는 한 fold에 유지한다.
- mixed capture group은 source date와 이미지별 category ID multiset으로 만든다. 동일 날짜에서 같은 상품 구성을 촬영한 E/H/M 변형은 같은 group에 유지한다.
- 같은 group은 train, validation, held-out 중 하나에만 존재할 수 있다.
- group 생성 결과와 구성원 목록을 versioned JSON으로 기록한다.

### 5.3 Split

- seed와 split schema version을 고정한 stratified group 5-fold를 사용한다.
- class coverage와 fold별 image/box 수 차이를 최소화한다.
- 각 mixed image와 bbox는 정확히 한 번 held-out OOF 평가된다.
- held-out group은 학습, augmentation, early stopping, threshold 선택, crop 생성에 사용할 수 없다.
- split 재생성 시 입력 catalog hash와 설정 hash가 같으면 byte-identical 결과를 내야 한다.

## 6. Detector 개선

### 6.1 후보

- Baseline: 현재 `bread_detector_tight_fold4_rebuilt.pt` 재평가 전용
- D1: 현재 detector weight에서 제한적 real-only fine-tuning
- D2: COCO 사전학습 YOLOv8n에서 real-only 학습
- D3: COCO 사전학습 YOLOv8s에서 real-only 학습

모든 후보는 입력 크기 640, 동일 fold, 동일 seed, 동일 평가 matcher를 사용한다. 강한 random crop과 과도한 mosaic는 사용하지 않는다. 학습 후반에는 mosaic를 끄고 실제 객체 경계 box regression을 유도한다.

### 6.2 평가

각 fold에서 validation group으로 confidence threshold를 선택한 뒤 held-out group에 적용한다. held-out label로 threshold를 조정하지 않는다.

저장 지표는 다음과 같다.

- prediction, match, miss, false positive
- image별 miss와 false positive
- precision, recall
- matched IoU median과 p10
- width/height/area ratio
- under-sized box count
- CPU detector median/p95 latency
- raw confidence와 operational prediction
- fold model hash와 prediction provenance

### 6.3 선택 규칙

다음 조건을 통과하지 못한 후보는 제외한다.

- 한 이미지의 최대 miss가 1 이하
- precision 0.98 이상
- median IoU 0.90 이상
- 전체 pipeline CPU warm median 1초 이하

통과 후보는 다음 순서로 선택한다.

1. 전체 miss가 적음
2. false positive가 적음
3. median IoU가 높음
4. p10 IoU가 높음
5. CPU latency가 낮음

최종 후보는 현재 baseline과 동일한 grouped OOF 평가에서 전체 miss를 줄여야 한다.

## 7. Classifier 개선

### 7.1 후보

- 현재 quick rebuild classifier는 seed와 후보에서 제외한다.
- C1: ImageNet 사전학습 YOLOv8n-cls
- C2: ImageNet 사전학습 YOLOv8s-cls

모델 내부 class index는 명시적인 manifest map을 통해 canonical label ID 1~20에 연결한다.

### 7.2 학습 입력

- 단일 상품 3,230장
- train fold의 mixed GT crop
- train fold에서만 생성한 bbox jitter crop
- train fold에서만 생성한 0~5% context crop

validation과 held-out 평가는 증강하지 않은 원본 GT crop과 OOF detector crop을 모두 사용한다.

### 7.3 Domain-balanced sampling

단일 상품 이미지 수가 mixed crop을 압도하지 않도록 classifier training adapter에 deterministic domain-balanced sampler를 사용한다.

- 한 epoch의 sampling 목표는 single domain 50%, mixed domain 50%다.
- 각 domain 안에서는 category를 균등하게 선택한다.
- category 안에서는 capture group을 먼저 균등하게 선택한 뒤 image/crop을 선택한다.
- mixed crop이 적은 category는 같은 crop을 복제 저장하지 않고 online augmentation을 다르게 적용한다.
- sampler seed, epoch, selected source key를 training artifact에 기록한다.

### 7.4 평가와 선택

classifier raw 평가에는 다음을 포함한다.

- top-1, top-3 accuracy
- macro recall과 class별 recall
- confusion matrix
- negative log likelihood와 calibration error
- GT crop과 OOF detector crop의 성능 차이
- batch CPU median/p95 latency

후보 통과 조건은 OOF detector crop 기준으로 다음과 같다.

- top-1 accuracy 0.90 이상
- macro recall 0.85 이상

통과 후보는 top-1, macro recall, calibration error, CPU latency 순으로 선택한다.

## 8. 앱 공통 자동 라벨 정책

모델 선택 후 OOF detector crop score로 confidence와 top-1/top-2 margin 조합을 평가한다.

- 각 조합의 accepted precision, coverage, red-review rate, unavailable rate를 기록한다.
- accepted precision 0.98 이상인 조합만 기본 정책 후보가 된다.
- 후보 중 coverage가 가장 높은 조합을 기본 manifest 값으로 선택한다.
- 동률이면 macro accepted recall이 높은 조합, 그다음 더 높은 margin threshold를 선택한다.
- 조건을 만족하는 조합이 없으면 classifier를 배포하지 않는다.

이 값은 앱 전체에 적용되는 배포 상수다. UI나 프로젝트 설정으로 노출하지 않는다. 재학습 없이 manifest를 바꿀 수는 있지만, 변경할 때마다 prospective policy report와 worker 회귀를 다시 실행한다.

## 9. Runtime과 manifest v2

### 9.1 Manifest

manifest schema v2에는 다음을 저장한다.

- detector file, SHA-256, imgsz, confidence, NMS IoU
- classifier file, SHA-256, imgsz, crop padding ratio
- class index → canonical label ID map
- accept confidence와 margin
- conservative class 목록
- bbox 품질 기준
- pipeline version과 policy version

성능 보고서와 앱 전용 분석 정보는 manifest에 섞지 않고 sidecar report로 저장한다.

### 9.2 Startup 검증

worker는 모델 생성 전에 manifest schema와 sibling path를 검증하고, 생성 직후 다음을 검증한다.

- detector task와 class count
- classifier task와 class count 20
- classifier 내부 class name/index와 manifest class map
- weight SHA-256
- threshold 범위
- canonical label registry

어느 하나라도 다르면 자동 기능을 시작하지 않는다.

### 9.3 추론 흐름

1. image bytes decode
2. detector inference
3. manifest confidence와 단일 NMS 적용
4. confidence 상위 `maxProposals` 선택
5. 선택 박스를 화면 위치순으로 정렬
6. OOF에서 선택한 공통 padding으로 classifier crop 생성
7. 전체 crop batch classifier inference
8. class-map 검증과 top candidates 생성
9. 앱 공통 정책과 bbox 품질 규칙 적용
10. worker protocol v2 결과 반환

현재처럼 공간 위치순으로 정렬한 뒤 `maxProposals`를 자르지 않는다. 밀집 이미지의 하단·우측 객체를 confidence와 무관하게 버릴 수 있기 때문이다.

박스 제거용 NMS는 한 단계만 사용한다. 완전 중복 의심은 무조건 제거하지 않고 review reason으로 표시한다.

### 9.4 상태 계약

- 흰색: policy를 통과한 자동 라벨 또는 사용자 라벨
- 빨간색: 유효한 top-1 suggestion이 있지만 검토가 필요한 박스
- 회색: classifier unavailable 또는 suggestion을 만들 수 없는 박스
- label 고유 색상: label badge에만 사용

자동 pipeline은 이미지를 확정하지 않는다.

## 10. 오류 처리와 rollback

- registered image decode/hash/dimension 오류: catalog 생성 실패
- bbox/category 오류: catalog 생성 실패
- capture group overlap 또는 held-out leakage: split/학습 실패
- 중단된 training: completion artifact와 weight hash가 일치하지 않으면 재사용 금지
- detector inference 실패: 기존 annotation 유지, request error 반환
- classifier inference 실패: detector box를 회색 proposal로 반환
- manifest/hash/class-map 실패: 자동 기능 비활성화, 수동 라벨링 유지
- policy calibration gate 실패: 새 classifier 배포 중단
- prospective worker 회귀 실패: 새 manifest와 weight 승격 중단

새 산출물은 `outputs/model_improvement/bread_pipeline_v2_20260715` 아래에 생성한다. 최종 weight와 manifest는 모든 audit가 끝난 후에만 `models`에 게시한다. 기존 모델은 rollback 근거로 보존하지만 installer에는 활성 manifest가 참조하는 모델만 포함한다.

## 11. 테스트 전략

### 11.1 데이터 테스트

- 3,313 images, 3,230 singles, 83 mixed images, 510 bbox 회귀 검사
- file/COCO exact registry
- decode, checksum, dimension, category, bbox 검증
- exact duplicate와 cross-date duplicate 검사
- capture group 생성과 deterministic split
- train/validation/held-out group disjointness
- 원천 폴더 작업 전후 checksum 동일성

### 11.2 단위 테스트

- single/mixed capture group 생성
- group-stratified fold 결정성
- domain-balanced sampler의 domain/category/group 균형
- bbox jitter와 padding clamp
- detector one-to-one matcher와 threshold 선택
- confidence top-K 이후 spatial sort
- class-map 검증과 잘못된 model names 거부
- policy precision/coverage curve와 tie-break
- manifest v2 schema, hash, threshold 검증
- incomplete training artifact 재사용 거부

### 11.3 모델·파이프라인 테스트

- 모든 후보 1-fold smoke training
- 통과 후보 grouped 5-fold OOF
- 각 image의 정확히 한 번 held-out inference
- fold weight hash와 prediction provenance
- 83장 OOF contact sheet
- miss/false-positive/classification-error 확대 시트
- GT crop과 OOF detector crop classifier 비교
- 실제 bytes → detector → batch classifier → policy worker 회귀

### 11.4 Flutter와 Windows 테스트

- accepted/review/unavailable worker 결과 parsing
- classifier failure gray fallback
- atomic box replacement과 Undo
- 저장·재열기 후 automation metadata 복원
- 빨간/회색 box의 COCO 제외
- manifest v2 startup failure에서 수동 workflow 유지
- isolated Python worker sibling module import
- release directory에 활성 weight와 필수 runtime module만 존재
- cold start, warm median, warm p95 smoke test

## 12. 완료 기준

다음을 모두 만족해야 완료로 판단한다.

- canonical data audit가 0 issue로 통과한다.
- source data checksum이 작업 전후 동일하다.
- grouped split leakage 검사가 통과한다.
- detector가 baseline 대비 전체 miss를 줄인다.
- detector image별 최대 miss가 1 이하이다.
- detector precision이 0.98 이상이다.
- detector median IoU가 0.90 이상이다.
- classifier OOF detector crop top-1이 0.90 이상이다.
- classifier macro recall이 0.85 이상이다.
- accepted precision 0.98 이상인 공통 policy 지점이 존재한다.
- 전체 CPU warm median latency가 1초 이하이다.
- final weight filename, SHA-256, manifest가 일치한다.
- 83장 worker 회귀와 Flutter 핵심 흐름이 통과한다.
- Windows release asset audit와 installer smoke test가 통과한다.
- 기존 dirty 변경과 `outputs\quick_rebuild`를 덮어쓰지 않는다.

## 13. 산출물

- canonical catalog와 audit JSON
- capture-group manifest와 deterministic 5-fold split
- detector 후보별 fold weight, prediction, report
- classifier 후보별 fold weight, confusion, calibration report
- OOF detector crop policy curve
- 83장 OOF contact sheet와 실패 사례 시트
- winner selection report와 모델 카드
- 전체 데이터 final detector/classifier weight
- content-addressed model files와 manifest v2
- prospective handoff audit
- Windows release asset audit와 smoke-test 결과
