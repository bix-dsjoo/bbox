# 빠른 Detector A/B 개선 설계

## 목적

기존 배포 detector를 신규 모델 선택 기준에서 제외하고 Candidate A와 Candidate B의 약점을 각각 한 번씩 개선한다. 짧은 선별 학습으로 한 후보를 고른 뒤, 선택된 후보만 5-fold 교차검증과 전체 데이터 최종 학습을 수행한다.

상세한 지표 최적화보다 실제 자동 박스 작업에서 중요한 누락, 오탐, 박스 경계 품질을 빠르게 개선하는 것이 목적이다.

## 기존 detector 처리

- `bread_yolov8n_1class_tray_v0_2.pt`는 신규 후보의 합격 기준과 최종 배포 후보에서 제외한다.
- A 계열 추가 학습의 초기 가중치와 과거 결과 재현을 위해 파일과 평가 자료는 보관한다.
- 새 모델이 최종 승격되기 전에는 파일을 삭제하거나 덮어쓰지 않는다.
- 새 모델이 manifest에 승격되면 기존 가중치는 `deprecated` 자산으로 분류하고 Windows 배포 패키지에서 제외한다.

## 후보 개선

### Candidate A2

Candidate A의 높은 recall을 유지하면서 느슨하거나 중복되는 박스를 줄인다.

- 기존 detector 가중치에서 fine-tuning한다.
- 현재 실제 학습 데이터와 fold 격리를 그대로 사용한다.
- 강한 기하 변형을 추가하지 않는다.
- 학습 후반 mosaic를 끄고 원본 객체 경계에 맞춘 box regression을 유도한다.
- confidence 후보는 소수의 고정값만 비교하며 held-out test 결과로 조정하지 않는다.

### Candidate B2

Candidate B의 타이트한 박스 품질을 유지하면서 밀집·겹침 장면의 누락을 줄인다.

- COCO 사전학습 YOLOv8n 가중치에서 학습한다.
- 각 fold의 train 부분에 이미 포함된 밀집·겹침 실제 장면을 반복 노출한다.
- 빠른 개선 주기에서는 실제 학습 데이터만 사용한다. 합성 장면은 두 후보가 모두 선별에 실패했을 때 별도 후속 작업으로 다룬다.
- confidence 후보는 A2와 동일한 소수의 고정값만 비교한다.

## 빠른 선별

1. A2와 B2를 동일한 고정 fold 하나에서 짧게 학습한다.
2. 동일한 validation 이미지와 동일한 박스 매칭 규칙으로 평가한다.
3. 결과는 다음 우선순위로 정렬한다.
   1. 누락 객체 수가 적은 후보
   2. 오탐 박스 수가 적은 후보
   3. median matched IoU가 높은 후보
   4. CPU median latency가 낮은 후보
4. 한 이미지에서 정답 객체를 두 개 이상 놓친 후보는 선별에서 제외한다.
5. 더 좋은 후보 하나만 전체 5-fold 단계로 보낸다.

선별용 fold와 학습 epoch 수는 실행 전에 설정 파일에 고정하고 결과를 본 뒤 변경하지 않는다.

## 최종 확인

- 선택된 설정만 기존의 균일한 5-fold 분할로 다시 학습하고 OOF 예측을 합산한다.
- fold별 train/validation/test 격리와 prediction provenance 검증은 유지한다.
- 복잡한 기존 detector 상대 안전 게이트는 사용하지 않는다.
- 최종 OOF 결과에서도 한 이미지당 두 개 이상 누락이 없어야 한다.
- 누락 수, 오탐 수, median matched IoU, CPU median latency를 보고한다.
- `Test_20260714`는 기존 정책대로 다른 세 날짜 폴더와 균일하게 섞어 OOF 평가한다. 각 이미지는 자신을 학습하지 않은 fold 모델로만 추론하며, 이 날짜의 결과만 보고 별도 설정이나 threshold를 수동 조정하지 않는다.
- 최종 시각 확인은 `Test_20260714`의 OOF prediction으로 30장 contact sheet를 만든다.
- 최종 확인을 통과하면 전체 실제 학습 데이터로 한 번 학습하고 새 버전의 가중치와 manifest를 생성한다.

## 배포 변경

- manifest의 detector 파일명과 SHA-256을 새 최종 가중치로 교체한다.
- worker는 manifest가 가리키는 새 detector만 로드한다.
- Flutter 자동 박스 상태 정책은 변경하지 않는다.
  - 자동 라벨 확정: 흰색 박스
  - 애매한 추천: 빨간색 박스
  - 실패 또는 미분류: 회색 박스
  - 라벨명 영역만 고유 색상
  - 기존 숫자·문자 라벨 단축키 유지
  - Enter로 빨간 추천 승인
- Windows 패키징 목록과 release 검증은 새 detector 파일명을 사용한다.

## 실패 처리

- A2와 B2가 모두 빠른 선별 조건을 만족하지 못하면 배포 모델을 만들지 않고 데이터 보완 필요로 기록한다.
- 선택된 후보가 5-fold에서 이미지당 두 개 이상 누락을 만들면 최종 학습과 manifest 승격을 중단한다.
- 학습 중단이나 검증 실패 시 기존 가중치와 현재 프로젝트 manifest를 삭제하지 않는다.
- 새 manifest와 가중치 검증이 모두 끝난 뒤에만 기존 detector를 배포 대상에서 제거한다.

## 검증 산출물

- A2/B2 빠른 선별 설정과 결과 JSON
- 선택 후보의 fold별 OOF prediction과 합산 보고서
- 누락 또는 오탐이 발생한 이미지 목록
- `Test_20260714` 30장 비교 contact sheet
- 최종 가중치 SHA-256과 갱신된 pipeline manifest
- Windows 배포 자산 검사 결과

## 범위 제외

- A+B 동시 추론 앙상블
- 장면별 모델 라우팅
- detector 구조 변경 또는 대형 모델 도입
- 빠른 개선 주기의 합성 데이터 추가
- 수백 개 confidence/NMS 조합 탐색
- 기존 detector 파일의 즉시 영구 삭제
