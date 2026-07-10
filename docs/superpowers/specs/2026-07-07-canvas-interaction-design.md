# Canvas Interaction Redesign

## Goal

중앙 이미지 캔버스에서 마우스 동작을 예측 가능하게 만든다. 확대 상태에서 이미지를 움직이려 했는데 새 박스가 생기거나, 박스 이동과 크기 변경이 섞여 느껴지는 문제를 해결한다.

이 설계는 구현 전에 마우스 입력 모델, 도구 모드, 우선순위, 시각 피드백을 먼저 고정한다.

## Current Problem

현재 중앙 영역은 `WorkbenchScreen` 안에서 다음 구조로 되어 있다.

- `_ViewerPanel`: 중앙 전체 패널, 확대/축소 툴바와 `InteractiveViewer` 포함
- `_ImageCanvas`: 실제 이미지와 박스 오버레이가 있는 영역
- `_OverlayBox`: 박스 선택, 이동, 우하단 리사이즈 핸들 처리

현재 문제는 `_ImageCanvas` 전체에 드래그로 새 박스를 만드는 `GestureDetector`가 있고, 바깥에는 패닝/확대를 담당하는 `InteractiveViewer`가 같이 있다는 점이다. 사용자가 마우스를 누르고 움직이는 순간 앱이 "새 박스 생성", "이미지 패닝", "박스 이동", "박스 크기 변경" 중 어떤 의도인지 명확히 확정하지 못한다.

결과적으로 다음 문제가 생긴다.

- 확대 상태에서 배경을 드래그하면 이미지 이동 대신 새 박스가 생긴다.
- 선택 박스를 움직이는지, 크기를 바꾸는지 피드백이 약하다.
- 박스 생성 모드가 항상 켜진 것처럼 느껴진다.
- 사용자가 현재 어떤 도구 상태인지 알기 어렵다.
- 드래그 도중 동작이 바뀌는 것처럼 느껴져 버벅임으로 인식된다.

## Research Notes

조사한 실제 라벨링 도구들은 대부분 "도구 모드"와 "제스처 우선순위"를 명확히 분리한다.

- CVAT은 `Cursor`, `Move the image`, `Rectangle` 도구를 분리한다. 이미지 이동 도구는 편집 없이 이미지만 움직인다. 또한 마우스 휠 버튼을 누르면 객체를 무시하고 이미지 이동을 우선한다.
- Roboflow Annotate는 `Drag and Select`와 `Bounding Box Tool(B)`를 분리한다. 선택 모드에서는 배경 드래그가 패닝이고, 박스 도구에서만 새 박스를 그린다.
- Supervisely는 `Pan & Move Scene Tool(1)`과 `Select Figure Tool(2)`를 분리한다. 패닝 도구에서는 어노테이션을 수정하지 않는다.
- Label Studio는 region 생성, 선택, 수정 흐름을 분리하고 이미지 줌 컨트롤을 별도 기능으로 둔다.

참고 문서:

- CVAT Controls Sidebar: https://docs.cvat.ai/docs/annotation/annotation-editor/controls-sidebar/
- CVAT Shortcuts: https://docs.cvat.ai/docs/getting_started/shortcuts/
- Roboflow Annotate: https://docs.roboflow.com/annotate/use-roboflow-annotate
- Roboflow Keyboard Shortcuts: https://docs.roboflow.com/annotate/use-roboflow-annotate/keyboard-shortcuts
- Supervisely Navigation & Selection Tools: https://docs.supervisely.com/labeling/labeling-tools/navigation-and-selection-tools
- Label Studio Labeling Guide: https://labelstud.io/guide/labeling/
- Label Studio Image Tag: https://labelstud.io/tags/image

## Recommended Interaction Model

추천 방식은 "기본 선택/패닝 모드 + 명시적 박스 그리기 모드 + 임시 패닝 modifier"다.

### 1. 기본 모드: 선택/이동

앱을 열었을 때 기본 모드는 선택/이동 모드다.

동작:

- 박스 클릭: 박스 선택
- 선택된 박스 내부 드래그: 박스 이동
- 선택된 박스 핸들 드래그: 박스 크기 변경
- 배경 클릭: 선택 해제
- 배경 드래그: 이미지 패닝
- 마우스 휠: 커서 위치 기준 확대/축소

이 모드에서는 배경 드래그로 새 박스를 만들지 않는다. 사용자는 확대 후 이미지를 끌어 움직일 수 있다고 기대하기 때문이다.

### 2. 박스 그리기 모드

새 박스는 명시적으로 박스 그리기 모드에서만 만든다.

진입:

- 툴바의 박스 아이콘 클릭
- 단축키 `B`

동작:

- 캔버스 배경 드래그: 새 박스 생성
- 박스 위 클릭: 기존 박스 선택
- `Esc`: 그리기 취소 후 선택/이동 모드로 복귀
- 박스 생성 완료 후 기본값은 선택/이동 모드로 자동 복귀

선택 옵션:

- `B`를 한 번 누르면 1회 박스 생성 후 선택/이동 모드 복귀
- `B`를 다시 누르거나 툴바 토글 고정 시 연속 박스 생성 모드 유지

MVP에서는 1회 생성 후 자동 복귀를 기본으로 한다. 반복 생성이 필요하면 툴바 토글로 유지할 수 있게 확장한다.

### 3. 패닝 모드

패닝은 두 방식으로 제공한다.

- `Space`를 누르고 있는 동안 임시 패닝
- 손 아이콘 도구를 선택하면 지속 패닝 모드

패닝 모드에서는 박스를 선택하거나 수정하지 않는다. 이 상태에서 드래그는 항상 이미지 이동이다.

### 4. 제스처 우선순위

마우스 down 순간에 동작을 확정한다. 드래그 도중 다른 동작으로 바뀌지 않는다.

우선순위:

1. 리사이즈 핸들 위에서 down: `resizingBox`
2. 선택된 박스 내부에서 down: `movingBox`
3. 선택되지 않은 박스 위에서 down: `selectingBox`
4. Space 또는 손 도구 상태에서 배경 down: `panningCanvas`
5. 박스 그리기 모드에서 배경 down: `drawingBox`
6. 기본 선택/이동 모드에서 배경 down: `panningCanvas`

이 우선순위로 "움직이려 했는데 새 박스가 생김"을 막는다.

## Cursor And Visual Feedback

사용자는 현재 동작을 마우스 커서와 화면 피드백만으로 예측할 수 있어야 한다.

커서:

- 선택/이동 기본: `basic`
- 박스 위 hover: `click`
- 선택 박스 내부 hover: `move`
- 리사이즈 핸들 hover: 방향성 resize cursor
- 박스 그리기 모드 배경 hover: `crosshair`
- Space 패닝 또는 손 도구: `grab`, 드래그 중 `grabbing`

시각 피드백:

- 현재 도구는 상단/캔버스 툴바에서 선택 상태로 표시
- 박스 그리기 모드에서는 캔버스 위에 얇은 crosshair 가이드 표시
- 드래그로 새 박스를 그릴 때 반투명 preview rectangle 표시
- 박스 이동 중에는 선택 박스 outline과 좌표가 안정적으로 따라옴
- 리사이즈 중에는 핸들이 강조되고 박스 크기 preview가 즉시 반영
- 패닝 중에는 박스 preview를 만들지 않음

## Proposed UI Changes

중앙 캔버스 상단 툴바에 최소 도구를 추가한다.

- 선택/이동: 화살표 또는 cursor 아이콘
- 박스: 사각형 아이콘, 단축키 `B`
- 손: hand 아이콘, Space 임시 패닝 안내는 tooltip에만 표시
- 확대/축소/화면 맞춤은 기존 버튼 유지

툴팁 예:

- 선택/이동: "박스 선택, 이동, 크기 변경"
- 박스: "새 박스 그리기 (B)"
- 손: "이미지 이동 (Space)"

화면에 긴 사용법 설명은 넣지 않는다. 필요한 정보는 tooltip과 커서 상태로 전달한다.

## Architecture

현재 `_ViewerPanel`, `_ImageCanvas`, `_OverlayBox`에 분산된 포인터 처리를 정리한다.

새로운 로컬 상태:

- `CanvasTool`
  - `select`
  - `drawBox`
  - `pan`
- `CanvasPointerAction`
  - `idle`
  - `panningCanvas`
  - `drawingBox`
  - `movingBox`
  - `resizingBox`
  - `selectingBox`

`_ViewerPanelState`는 선택된 도구와 zoom/pan transform을 관리한다.

`_ImageCanvasState`는 pointer down 시점에 hit-test를 하고 `CanvasPointerAction`을 확정한다.

`_OverlayBox`는 표시와 hit 영역만 담당하게 축소한다. 박스 이동/리사이즈의 실제 제스처 판정은 캔버스 레벨에서 일관되게 처리하는 방향이 좋다.

## Coordinate Rules

저장은 계속 원본 이미지 픽셀 좌표 기준이다.

- 화면 좌표 -> 이미지 표시 좌표 -> 원본 이미지 좌표 순서로 변환
- zoom/pan transform은 표시 좌표에만 영향을 준다.
- 박스 생성, 이동, 리사이즈는 모두 원본 이미지 좌표로 clamp한다.
- 박스는 이미지 경계 밖으로 나가지 않는다.
- 최소 박스 크기는 기존 규칙처럼 2px 이상을 유지한다.

좌표 변환은 별도 helper로 분리해 단위 테스트한다.

## Error And Edge Cases

- 아주 작은 드래그는 클릭으로 취급하고 새 박스를 만들지 않는다.
- 박스 그리기 중 `Esc`를 누르면 preview를 버리고 선택/이동 모드로 돌아간다.
- 이미지 밖 드래그는 이미지 경계로 clamp한다.
- 확대 상태에서 빈 배경 드래그는 항상 패닝이다.
- 박스와 박스가 겹쳐 있을 때는 가장 위에 그려지는 박스를 먼저 선택한다.
- 리사이즈 핸들은 최소 10-14px 화면 크기로 유지해 확대/축소 상태에서도 잡기 쉽도록 한다.

## Testing

단위 테스트:

- hit-test 우선순위
- 화면 좌표와 원본 이미지 좌표 변환
- 배경 드래그가 선택 모드에서는 패닝으로 판정됨
- 박스 그리기 모드에서만 새 박스 생성
- 리사이즈 핸들이 박스 이동보다 우선함
- Space 임시 패닝이 현재 도구보다 우선함

위젯 테스트:

- 기본 모드 배경 드래그는 `addBox`를 호출하지 않음
- `B` 후 드래그하면 새 박스 생성
- 새 박스 생성 후 선택/이동 모드로 복귀
- 선택 박스 내부 드래그는 박스 이동
- 리사이즈 핸들 드래그는 박스 크기 변경
- 손 도구 또는 Space 중 드래그는 박스 변경 없이 패닝

통합 테스트:

- 확대 후 이미지 패닝
- 확대 후 박스 선택, 이동, 리사이즈
- 확대 후 박스 그리기 모드에서 새 박스 생성
- undo/redo가 이동, 리사이즈, 생성에 대해 계속 동작

## Non-Goals

이번 작업에서는 다음을 하지 않는다.

- 다중 선택
- 회전 박스
- 폴리곤/세그멘테이션
- 박스 edge resize 전체 지원
- 커스텀 단축키 설정 화면
- 마우스 설정 프리셋

## Implementation Phasing

1. 캔버스 도구 상태와 툴바 추가
2. 배경 드래그 기본 동작을 패닝으로 변경
3. 박스 그리기 모드에서만 새 박스 생성
4. 박스 이동/리사이즈 hit-test 우선순위 정리
5. 커서와 preview 피드백 추가
6. 좌표 변환 helper와 테스트 보강

## Acceptance Criteria

- 확대 상태에서 배경 드래그를 하면 이미지가 이동하고 새 박스가 생기지 않는다.
- 새 박스는 박스 그리기 모드에서만 생성된다.
- 사용자는 커서와 선택된 툴바 버튼으로 현재 동작을 예측할 수 있다.
- 박스 이동과 크기 변경이 명확히 구분된다.
- Space를 누른 동안에는 어떤 도구 상태에서도 이미지 패닝이 우선한다.
- 모든 박스 좌표는 원본 이미지 픽셀 기준으로 저장된다.
- 기존 저장, 라벨 지정, 확정, COCO export 동작은 유지된다.
