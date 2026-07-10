# Reference-Managed Image Manifest Design

## Context

프로젝트의 이미지 관리 모델을 폴더 연결 방식에서 이미지 manifest 방식으로
변경한다. 사용자는 프로젝트에 이미지를 추가하고 제거한다고 느껴야 하며,
폴더는 프로젝트와 1:1로 연결되는 대상이 아니라 이미지를 한꺼번에 추가하기 위한
입력 수단이다.

프로젝트당 약 6000장의 이미지를 다룰 수 있어야 하므로 MVP의 기본 저장 방식은
원본 이미지 복사가 아니라 원본 파일 참조다. 앱은 원본 이미지를 수정하지 않고,
프로젝트 JSON에는 라벨링 대상 이미지의 정규화된 원본 경로와 annotation 상태를
저장한다.

현재 구현과 기존 설계 문서는 `imageFolderPath + relativePath`를 중심으로 되어
있지만, 이 설계에서는 기존 프로젝트 파일 호환과 마이그레이션을 범위에서 제외한다.
새 프로젝트 모델은 새 schema로 다시 정의한다.

## Product Decision

선택한 모델은 `Reference-managed image manifest`다.

- 프로젝트는 이미지 폴더 하나를 소유하지 않는다.
- 프로젝트는 이미지 파일 N개의 manifest를 소유한다.
- 이미지 파일은 여러 폴더, 드라이브, 네트워크 경로에서 올 수 있다.
- `이미지 추가`는 파일 선택 또는 폴더 선택으로 동작한다.
- `이미지 제거`는 프로젝트 manifest에서 제외하는 동작이며 원본 파일을 삭제하지
  않는다.
- 앱은 원본 경로를 참조하되, 원본 이미지 자체를 수정하거나 이동하거나 복사하지
  않는다.

## User Scope

MVP에서 제공할 사용자 기능:

- 새 프로젝트 생성
- 프로젝트 열기
- 파일 단위 이미지 추가
- 폴더 단위 이미지 추가
- 추가 중 스캔 진행률 표시
- 중복 이미지 건너뛰기
- 이미지 목록에서 프로젝트 제거
- 원본 파일 누락 상태 표시
- 누락 이미지가 있어도 프로젝트 열기
- 누락 이미지가 있어도 COCO export 경고 후 진행 가능
- 원본 이미지를 직접 삭제하지 않는 안전한 UX

MVP에서 제외할 기능:

- 원본 이미지 자동 복사
- 폴더 live sync
- 폴더 재스캔 diff
- 기존 `imageFolderPath` 프로젝트 마이그레이션
- 이미지 파일 hash 기반 고급 중복 감지
- 원본 경로 일괄 재연결
- 프로젝트 번들 백업과 이미지 포함 백업
- cloud storage, 계정, 협업

## Storage Layout

프로젝트 파일은 앱 내부 프로젝트 라이브러리에 저장한다. AppData에는 이미지가
아니라 프로젝트 JSON과 프로젝트 목록 index만 저장한다.

```text
%APPDATA%\BBoxLabeler\
  projects\
    index.json
    <project-id>\
      project.bbox.json
      thumbnails\
        <image-id>.webp
```

`thumbnails`는 선택 사항이다. MVP 구현에서 썸네일 캐시를 만들지 않는다면 폴더를
생성하지 않아도 된다.

원본 이미지는 사용자가 선택한 기존 위치에 그대로 둔다.

```text
D:\dataset\camera_01\a.jpg
E:\samples\b.png
\\nas\vision\c.jpeg
```

## Data Model

`AnnotationProject`에서 `imageFolderPath`를 제거한다. 이미지 위치는 프로젝트가
아닌 각 이미지가 가진다.

권장 JSON shape:

```json
{
  "schemaVersion": 2,
  "name": "BBox Project",
  "status": "ready",
  "labels": [],
  "images": [
    {
      "id": 1,
      "sourcePath": "D:\\dataset\\camera_01\\a.jpg",
      "displayName": "a.jpg",
      "importedFrom": "D:\\dataset\\camera_01",
      "width": 1920,
      "height": 1080,
      "status": "needsReview",
      "boxes": [],
      "errorMessage": null
    }
  ],
  "detectorName": "dummy",
  "lastSavedAt": "2026-07-07T00:00:00.000Z"
}
```

### Image Fields

- `id`: 프로젝트 안에서 안정적인 정수 ID다. COCO `image.id`에도 사용한다.
- `sourcePath`: 원본 이미지의 정규화된 절대 경로다.
- `displayName`: UI와 export 기본 file name에 쓰는 짧은 이름이다.
- `importedFrom`: 파일 선택 또는 폴더 선택 당시의 입력 root다. 감사와 UX 표시용이며
  이미지 로드의 source of truth는 `sourcePath`다.
- `width`, `height`: 원본 이미지 픽셀 크기다.
- `status`: 기존 이미지 상태를 유지한다. 누락 파일은 `error` 상태와
  `errorMessage`로 표현한다.
- `boxes`: 원본 이미지 픽셀 좌표 기준 bbox 목록이다.

`relativePath`는 제거한다. 프로젝트가 더 이상 단일 이미지 폴더 root를 가지지 않기
때문이다.

## Import Flow

### Add Image Files

사용자가 `이미지 추가`에서 파일을 선택하면 앱은 선택된 파일 목록을 순회한다.

1. 지원 확장자와 파일 존재 여부를 확인한다.
2. 경로를 정규화한다.
3. 이미 manifest에 같은 정규화 경로가 있으면 건너뛴다.
4. 이미지 크기를 읽는다.
5. detector를 실행한다.
6. 결과를 `needsReview` 또는 `error` 이미지로 manifest에 추가한다.
7. 자동 저장한다.

### Add Image Folder

사용자가 폴더를 선택하면 앱은 폴더를 재귀 스캔한다. 폴더는 프로젝트에 연결되지
않고, 스캔 시점에 발견된 이미지 파일만 manifest에 추가된다.

폴더에서 나중에 이미지가 추가되거나 삭제되어도 프로젝트가 자동으로 바뀌지 않는다.
사용자가 같은 폴더를 다시 `이미지 추가`하면 새로 발견된 경로만 추가되고 기존 경로는
중복으로 건너뛴다.

### Import Progress

6000장 규모에서 UI가 멈추면 안 된다. import는 비동기 큐로 실행하고 아래 상태를
컨트롤러가 노출한다.

```dart
class ImageImportProgress {
  final int discoveredCount;
  final int processedCount;
  final int addedCount;
  final int skippedDuplicateCount;
  final int failedCount;
  final String? currentFileName;
  final bool isCancelling;
}
```

MVP에서 isolate 사용은 필수는 아니지만, UI thread를 오래 막는 동기 루프는 피한다.
스캔, decode, detector는 작은 batch 단위로 진행 상태를 갱신한다.

## Duplicate Policy

MVP 중복 기준은 정규화된 절대 경로다.

- Windows 경로 비교는 대소문자 차이를 무시한다.
- `/`와 `\` 차이는 정규화한다.
- 동일 파일명이더라도 경로가 다르면 다른 이미지로 취급한다.
- 파일 크기, 수정 시각, hash 기반 중복 감지는 MVP 이후로 둔다.

중복 파일은 import 결과에 `skipped`로 집계하고 사용자 작업을 막지 않는다.

## Remove Flow

이미지 목록에는 `프로젝트에서 제거` 액션을 제공한다.

제거 동작:

- manifest에서 해당 이미지를 제거한다.
- 해당 이미지의 box annotation도 함께 제거된다.
- 원본 파일은 삭제하지 않는다.
- 삭제 전 확인을 받는다.
- MVP에서는 undo/redo 스택으로 복구 가능하게 한다.

여러 이미지를 선택해 일괄 제거하는 기능은 MVP 이후로 둔다. 단, 컨트롤러 API는 나중에
일괄 제거로 확장하기 쉽게 설계한다.

## Missing Source Handling

원본 참조 방식의 가장 큰 리스크는 원본 파일 누락이다. 앱은 누락을 복구 가능한 상태로
다룬다.

확인 시점:

- 프로젝트 열기 직후 전체 6000장을 즉시 검사하지 않는다.
- 선택한 이미지를 로드할 때 파일 존재를 확인한다.
- export 전 검증에서 전체 manifest의 존재 여부를 확인한다.
- 사용자가 명시적으로 `이미지 파일 검증`을 실행하면 전체를 검사한다.

누락 상태:

- 이미지 뷰어는 원본 파일을 찾을 수 없다는 빈 상태를 보여준다.
- 이미지 목록은 오류 배지를 표시한다.
- 기존 annotation은 삭제하지 않는다.
- COCO export에서는 옵션에 따라 누락 이미지를 제외하거나 경고 후 포함할 수 있다.

MVP에서는 일괄 재연결 기능을 만들지 않는다. 대신 누락 경고와 프로젝트에서 제거
액션을 명확히 제공한다.

## COCO Export

COCO export는 기존 원칙을 유지한다.

- `images`에는 export 대상 이미지가 포함된다.
- `annotations`에는 labeled이고 유효한 bbox만 포함된다.
- proposal box는 export하지 않는다.
- category ID는 프로젝트 label ID를 사용한다.

`images.file_name` 정책:

기본은 `displayName`을 사용한다. 같은 file name이 충돌하면 안정적인 prefix를 붙인다.

```text
a.jpg
image_000002_a.jpg
```

옵션:

- 전체 이미지 export
- 확정 이미지만 export
- 빈 이미지 포함 여부
- 누락 이미지 제외 여부
- 이미지 파일 복사 여부

이미지 파일 복사 옵션을 켜면 export 폴더 아래에 `images/`를 만들고 참조 원본을
복사한다. 복사 실패 파일은 export 전 blocking error로 처리한다.

## UI Design

### Start And Empty State

새 프로젝트를 만들면 workbench는 빈 이미지 목록을 보여준다. 주요 액션은
`이미지 추가`다.

빈 상태 문구는 짧게 유지한다.

```text
아직 이미지가 없습니다.
파일 또는 폴더를 추가해 라벨링을 시작하세요.
```

### Toolbar

기존 `이미지 폴더` 버튼을 `이미지 추가`로 바꾼다. 메뉴 또는 dialog에서 두 가지
입력을 제공한다.

- 파일 추가
- 폴더 추가

### Image List

이미지 목록은 기존 정보에 더해 원본 위치를 알 수 있게 한다.

- 썸네일 또는 대체 아이콘
- `displayName`
- 상태
- box 수
- 미라벨 box 수
- 라벨 완료 box 수
- 원본 파일 누락 배지

이미지 행의 context menu 또는 inspector에 `프로젝트에서 제거`를 제공한다.

### Import Progress Surface

이미지 추가 중에는 모달보다 방해가 적은 상단 또는 하단 progress surface를 선호한다.

표시 정보:

- 처리 수: `1240 / 6000`
- 추가 수
- 중복 건너뜀 수
- 실패 수
- 취소 버튼

취소 시 이미 추가된 이미지는 유지하고 자동 저장한다. 취소는 rollback이 아니라
부분 완료다.

### Loading States

6000장 규모에서는 사용자가 앱이 멈췄다고 느끼지 않도록 모든 긴 작업에 명시적인
로딩 상태를 제공한다. 로딩 표시는 작업 종류에 따라 다르게 보인다.

- 프로젝트 열기: project home 또는 workbench 진입 전에 전체 화면 loading state를
  보여준다.
- 이미지 목록 초기 표시: manifest는 먼저 표시하고, 썸네일은 행 단위로 늦게 로드한다.
- 이미지 선택: 중앙 viewer에는 선택한 파일명과 spinner를 보여주고, 원본 파일 존재
  확인과 decode가 끝나면 이미지를 표시한다.
- 이미지 추가: import progress surface를 사용한다.
- detector 실행: import progress 안에서 현재 처리 중 파일명과 처리 수를 보여준다.
- export 검증과 이미지 복사: export dialog 안에서 진행 상태를 보여주고 완료 전 중복
  클릭을 막는다.

이미지 viewer의 로딩은 기존 이미지를 갑자기 지우지 않는다. 사용자가 다음 이미지를
선택하면 새 이미지가 준비될 때까지 중앙 영역에는 loading state를 표시하고, 오른쪽
inspector는 선택 이미지의 manifest 정보와 box 목록을 즉시 갱신한다. 원본 decode가
실패하면 viewer만 오류 상태로 바뀌고 annotation 데이터는 유지한다.

짧은 작업은 화면 깜빡임을 줄이기 위해 즉시 spinner를 띄우지 않아도 된다. 단,
150ms 이상 걸릴 수 있는 작업은 loading state가 보이도록 설계한다.

## Architecture

### annotation

`AnnotatedImage` 모델을 `sourcePath` 중심으로 변경한다.

권장 필드:

```dart
class AnnotatedImage {
  final int id;
  final String sourcePath;
  final String displayName;
  final String? importedFrom;
  final int width;
  final int height;
  final ImageStatus status;
  final List<BoundingBox> boxes;
  final String? errorMessage;
}
```

`AnnotationProject.imageFolderPath`는 제거한다.

### image_import

`ImageScanner.scanFolder(rootPath)`는 유지하되 결과는 절대 경로 중심으로 바꾼다.
파일 선택 import를 위해 `scanFiles(List<String> filePaths)`를 추가한다.

권장 책임:

- 지원 이미지 필터링
- 절대 경로 정규화
- 이미지 메타데이터 읽기
- decode 실패 결과 생성
- 진행률 콜백 또는 stream 제공

### project

`ProjectStore`는 schema version 2만 저장/로드한다. 기존 schema 1 호환은 구현하지
않는다.

`ProjectLibraryEntry`에서 `imageFolderPath`를 제거하고 아래 metadata를 유지한다.

- image count
- confirmed image count
- error image count
- updated at

### detector

detector 인터페이스는 이미지 파일 경로를 받을 수 있어야 한다. 기존
`detect(image, imagePath: ...)` 형태는 유지 가능하다.

### ui

`AppController.importImagesFromFolder`를 아래 액션들로 대체한다.

- `addImageFiles(List<String> filePaths)`
- `addImagesFromFolder(String folderPath)`
- `removeImageFromProject(int imageId)`
- `validateSourceFiles()`

컨트롤러는 import와 별도로 viewer loading 상태를 노출한다.

```dart
class ImageViewLoadState {
  final int? imageId;
  final bool isLoading;
  final Object? error;
}
```

프로젝트 열기, 이미지 추가, export처럼 앱 전체 작업 흐름에 영향을 주는 작업은
별도의 activity 상태로 노출한다.

```dart
enum ProjectActivity {
  idle,
  openingProject,
  importingImages,
  loadingImage,
  validatingSources,
  exportingCoco,
}
```

기존 `reconnectSelectedProjectImageFolder`와 missing folder banner는 제거한다.

## Error Handling

처리할 오류:

- 선택한 파일이 사라짐
- 선택한 폴더 접근 불가
- 지원하지 않는 확장자
- 이미지 decode 실패
- detector 실패
- import 중 일부 실패
- 원본 파일 누락
- 이미지 로딩 또는 디코딩 실패
- export 중 이미지 복사 실패
- autosave 실패

일부 이미지 실패는 전체 import를 막지 않는다. 실패 항목은 이미지별 `error` 상태나
import summary에 남긴다.

저장 실패는 기존처럼 in-memory 변경을 버리지 않고 retry 가능하게 한다.

## Performance Requirements

프로젝트당 6000장을 기준으로 한다.

- 전체 원본 이미지를 메모리에 올리지 않는다.
- 선택한 이미지만 원본 decode한다.
- 썸네일은 필요할 때 생성하고 캐시한다.
- import 진행 중 UI interaction을 막지 않는다.
- 이미지 선택 시 원본 decode가 느려도 toolbar, image list, inspector는 계속 반응한다.
- 이미지 viewer는 로딩 중에도 고정된 크기를 유지해 레이아웃이 흔들리지 않게 한다.
- 파일 존재 검사는 명시적 검증이나 export 전 검증에서 수행한다.
- 목록 렌더링은 lazy list를 사용한다.
- detector는 순차 또는 제한된 동시성 큐로 실행한다.

## Testing

단위 테스트:

- `AnnotatedImage` sourcePath JSON save/load
- 프로젝트 schema version 2 save/load
- `imageFolderPath`가 없는 project JSON 생성
- 파일 목록 import에서 중복 경로 건너뛰기
- 폴더 import에서 여러 하위 폴더 이미지 추가
- 원본 경로가 다른 같은 파일명 이미지 허용
- 이미지 제거 시 원본 파일이 삭제되지 않음
- 누락 파일 검증 결과
- COCO export file_name 충돌 처리
- 누락 이미지 제외 export

위젯 테스트:

- 빈 프로젝트에서 `이미지 추가`가 primary action으로 보임
- 파일 추가 후 이미지 목록 갱신
- 폴더 추가 후 기존 이미지가 교체되지 않고 append됨
- 중복 추가 시 건너뛰기 summary 표시
- 프로젝트 열기 중 loading state 표시
- 이미지 선택 후 viewer loading state 표시
- 이미지 decode 실패 시 viewer 오류 상태와 annotation 유지
- 이미지 제거 확인 dialog
- 누락 원본 이미지 상태 표시

통합 테스트:

- 새 프로젝트 생성
- 폴더에서 이미지 추가
- 다른 폴더에서 파일 추가
- 라벨 지정
- 이미지 확정
- 프로젝트 저장 후 재열기
- sourcePath 기반 이미지 로드 확인
- 큰 이미지 선택 시 loading state 후 viewer 표시 확인
- COCO export 생성 확인
- 프로젝트에서 이미지 제거 후 원본 파일 존재 확인

## Implementation Notes

기존 코드는 버리는 전제로 마이그레이션을 만들지 않는다. 다만 변경 지점은 명확하다.

- `AnnotationProject.imageFolderPath` 제거
- `AnnotatedImage.relativePath` 제거
- `_imageFile(project, image)`는 `File(image.sourcePath)`로 변경
- `importImagesFromFolder`는 append import로 변경
- 기존 replace confirmation 제거
- start/project home의 missing image folder 표시 제거
- project index의 image folder metadata 제거
- 테스트 fixture를 sourcePath 기반으로 재작성

## Self Review

이 설계는 프로젝트와 폴더의 1:1 대응을 제거하고 이미지별 원본 경로 manifest를
source of truth로 삼는다. 6000장 규모에서 원본 복사를 피하면서도 사용자가 파일 또는
폴더 단위로 이미지를 추가/제거하는 UX를 제공한다. 기존 schema 마이그레이션은 명시적
out of scope이며, 원본 누락, 중복, export file name 충돌, autosave, 테스트 범위를
구체적으로 다룬다. 미완성 표시는 남기지 않았다.
