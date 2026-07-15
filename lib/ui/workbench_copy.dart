import '../annotation/models.dart';

class WorkbenchCopy {
  const WorkbenchCopy._();

  static const autoBoxesShortcut = 'Ctrl+B';
  static const completeAndNextShortcut = 'Ctrl+Enter';

  static String missingSourceCount(int count) =>
      '원본 이미지 $count'
      '개를 찾을 수 없습니다';
  static const labelingDataPreserved = '라벨링 데이터는 보존되어 있습니다.';
  static const relinkFiles = '파일로 다시 연결';
  static const relinkFolder = '폴더로 다시 연결';

  static String relinkSummary({
    required int matched,
    required int unresolved,
    required int ambiguous,
  }) => '$matched개 연결 · $unresolved개 미해결 · $ambiguous개 중복 후보';

  static String relinkFilesFailed(Object error) =>
      '파일을 다시 연결하지 못했습니다. 선택한 파일을 확인한 뒤 다시 시도하세요. $error';

  static String relinkFolderFailed(Object error) =>
      '폴더를 다시 연결하지 못했습니다. 폴더 접근 권한과 파일 위치를 확인한 뒤 다시 시도하세요. $error';

  static const activityReady = '준비됨';
  static const automationEditingLocked = '자동 작업 중: 편집 잠김';

  static const projectHome = '프로젝트 홈';
  static const projectHomeTooltip = '프로젝트 홈으로 돌아가기';
  static const saveProjectTooltip = '프로젝트 저장';
  static const saveProjectFile = '프로젝트 파일 저장';
  static const undo = '실행 취소';
  static const redo = '다시 실행';
  static const imageFolder = '이미지 폴더';
  static const chooseImageFolder = '이미지 폴더 선택';
  static const imageAdd = '이미지 추가';
  static const addImageFiles = '이미지 파일 추가';
  static const addImageFolder = '이미지 폴더 추가';
  static const cocoExport = 'COCO 내보내기';
  static const saved = '저장됨';
  static const saving = '저장 중';
  static const saveFailed = '저장 실패';
  static const images = '이미지';
  static const all = '전체';
  static const needsReview = '검토 필요';
  static const confirmed = '완료';
  static const error = '문제 있음';
  static const unlabeled = '라벨 필요';
  static const noImagesYet = '이미지가 없습니다';
  static const chooseFolderToStart = '라벨링할 이미지 폴더를 선택하세요';
  static const originalImagesUnchanged = '원본 이미지는 수정하지 않습니다.';
  static const selectImageFromQueue = '박스를 검토할 이미지를 목록에서 선택하세요';
  static const noImageSelected = '선택된 이미지 없음';
  static const selectImageForInspector = '검토할 이미지를 선택하세요';
  static const selectImageShort = '이미지를 선택하세요';
  static const selectedImage = '선택 이미지';
  static const details = '상세';
  static const imageActions = '이미지 작업';
  static const labels = '라벨';
  static const boxes = '박스';
  static const boxesNone = '박스 없음';
  static const inspectorWorkTab = '작업';
  static const inspectorTableTab = '표 보기';
  static const boxTableUnlabeled = '미라벨';
  static const boxesLabeledComplete = '라벨 완료';
  static const selectedBox = '선택 박스';
  static const newLabel = '새 라벨';
  static const createLabel = '라벨 생성';
  static const createLabelTooltip = '라벨 생성';
  static const duplicateLabel = '이미 존재하는 라벨 이름입니다.';
  static const enterLabelName = '라벨 이름을 입력하세요';
  static const noBoxes = '박스 없음';
  static const unlabeledBox = '라벨 필요';
  static const completionBlockedInvalidImage = '문제 있는 이미지는 완료할 수 없습니다';
  static const proposalBox = '자동 박스';
  static const labeledBox = '라벨 완료';
  static const invalidBox = '문제 있음';
  static const confirm = '완료';
  static const confirmNoObject = '객체 없음으로 완료';
  static const completeAndNext = '완료하고 다음';
  static const completeNoObjectAndNext = '객체 없음, 다음';
  static const confirmNoObjectAvailable = '박스가 없으면 객체 없음으로 완료할 수 있습니다.';
  static const deleteSelectedBox = '선택 박스 삭제';
  static const removeImageFromProject = '이미지 제거';
  static const removeImageTitle = '선택 이미지 제거';
  static const removeImageMessage = '선택한 이미지를 프로젝트에서 제거합니다.';
  static const loadingImage = '이미지 로딩 중';
  static const replaceImagesTitle = '이미지 목록 다시 불러오기';
  static const replaceImagesMessage = '현재 이미지 목록을 선택한 폴더 내용으로 바꾸시겠어요?';
  static const cancel = '취소';
  static const importImages = '가져오기';
  static const importScanning = '이미지 스캔 중...';
  static const close = '닫기';
  static const continueAction = '계속';
  static const selectMoveTool = '선택';
  static const selectMoveTooltip = '박스 선택, 이동, 크기 조절';
  static const drawBoxTool = '박스 그리기';
  static const drawBoxTooltip = '새 박스 그리기 (B)';
  static const panTool = '이동';
  static const panTooltip = '이미지 이동 (Space)';
  static const autoBoxes = '자동 박스';
  static const autoBoxesTooltip = '현재 이미지에서 자동 박스 찾기';
  static const autoBoxesPreparingModel = '모델 준비 중';
  static const autoBoxesRunning = '자동 박스 찾는 중';
  static const autoBoxesRestartingModel = '모델 다시 시작 중';
  static const autoBoxesRetry = '자동 박스 다시 시도';
  static const autoBoxesModelUnavailable =
      '자동 박스 모델을 준비하지 못했습니다. 기존 박스는 유지됩니다. 설치 파일과 모델을 확인한 뒤 다시 시도하세요.';
  static const autoBoxesLoadingModel = '모델 불러오는 중... 첫 실행은 조금 오래 걸릴 수 있습니다.';
  static const autoBoxesEmpty = '자동 박스를 찾지 못했습니다.';
  static const autoBoxesFileUnavailable =
      '이미지 파일을 읽을 수 없습니다. 기존 박스는 유지됩니다. NAS 연결과 파일 권한을 확인한 뒤 다시 시도하세요.';
  static const autoBoxesDecodeFailed =
      '이미지를 해석하지 못했습니다. 기존 박스는 유지됩니다. 파일 손상 여부를 확인하거나 다른 형식으로 변환해 다시 시도하세요.';
  static const autoBoxesWorkerFailed =
      '자동 박스 작업 프로세스를 복구하지 못했습니다. 기존 박스는 유지됩니다. 다시 시도하고 계속 실패하면 앱을 다시 시작하세요.';
  static const autoBoxesFailed =
      '자동 박스를 찾지 못했습니다. 기존 박스는 유지됩니다. 잠시 후 다시 시도하세요.';
  static const autoBoxesReplacementConfirmationRequired =
      '기존 박스를 교체하려면 먼저 확인해 주세요.';
  static const autoBoxesReplaceTitle = '기존 박스를 교체할까요?';
  static const autoBoxesReplaceMessage =
      '현재 이미지의 기존 박스를 모두 지우고 자동 박스 결과로 교체합니다.';
  static const autoBoxesReplaceConfirm = '교체하고 실행';
  static const autoBoxesCancelled = '자동 박스 작업을 취소했습니다.';
  static const cancelAutoBoxes = '자동 박스 취소';
  static const automaticLabel = '자동 라벨';
  static const reviewRequired = '검토 필요';
  static const chooseReviewCandidate = '추천 라벨을 선택하고 Enter를 누르세요';
  static const applyReviewCandidate = '선택한 라벨 적용 · Enter';
  static const noReviewCandidates = '추천 결과 없음';
  static const noReviewCandidatesHint = '빠른 라벨 버튼 또는 단축키로 라벨을 선택하세요.';
  static const labelSelectionRequired = '라벨 선택 필요';
  static const suggestionReviewRequired = '추천 검토 필요';
  static const unclassified = '미분류';
  static const assignedLabel = '라벨 지정';
  static const reviewReasonClassifierAmbiguous = '분류 결과가 애매합니다.';
  static const reviewReasonVerifierFailed = '추가 검증을 통과하지 못했습니다.';
  static const reviewReasonEdgeClipped = '객체가 이미지 가장자리에 걸쳐 있습니다.';
  static const reviewReasonPossibleDuplicate = '겹치거나 중복된 박스일 수 있습니다.';

  static String reviewReasonLabel(String reason) {
    return switch (reason) {
      'classifier_ambiguous' || 'low_margin' => reviewReasonClassifierAmbiguous,
      'verifier_failed' => reviewReasonVerifierFailed,
      'edge_clipped' => reviewReasonEdgeClipped,
      'possible_duplicate' => reviewReasonPossibleDuplicate,
      _ => '자동 라벨을 확인해 주세요.',
    };
  }

  static const automationTools = '자동화';
  static const editTools = '편집';
  static const viewTools = '보기';
  static const moreAutomationActions = '자동화 더보기';
  static const clearBoxesMenuItem = '박스 전체 삭제';
  static const zoomOut = '축소';
  static const zoomFit = '화면 맞춤';
  static const zoomIn = '확대';
  static const clearBoxes = '박스 전체 삭제';
  static const clearBoxesTooltip = '현재 이미지의 모든 박스를 삭제합니다';
  static const clearBoxesTitle = '박스 전체 삭제';
  static String clearBoxesCountMessage(int count) =>
      '현재 이미지의 박스 $count개를 삭제할까요?';
  static const clearBoxesConfirm = '삭제';
  static const labelSelectorHint = '라벨 검색 또는 새 라벨 입력';
  static const assignLabel = '라벨 지정';
  static const createTypedLabel = '입력한 라벨 생성';
  static const noMatchingLabels = '일치하는 라벨이 없습니다.';
  static const noLabelShortcuts = '라벨 단축키가 없습니다';
  static const addLabelsEmpty = '라벨을 추가하세요';
  static const manageLabels = '라벨 관리';
  static const allWorkImagesCompleted = '모든 작업 가능한 이미지를 완료했습니다';

  static String importComplete(int added, int skipped, int errors) {
    final parts = ['이미지 $added개 추가'];
    if (skipped > 0) {
      parts.add('$skipped개 건너뜀');
    }
    if (errors > 0) {
      parts.add('$errors개 오류');
    }
    return parts.join(' · ');
  }

  static String autoBoxesCreated(int count) => '자동 박스 $count개 생성';

  static String projectFileSaved(String path) => '프로젝트 파일을 저장했습니다: $path';

  static String projectFileSaveFailed(Object error) =>
      '프로젝트 파일을 저장하지 못했습니다. 경로와 권한을 확인한 뒤 다시 시도하세요: $error';

  static String exportAutoLabeledBoxes(int count) => '자동 라벨 박스: $count';

  static String exportUserLabeledBoxes(int count) => '사용자 라벨 박스: $count';

  static String exportReviewRequiredBoxes(int count) => '제외되는 검토 필요 박스: $count';

  static String exportUnclassifiedBoxes(int count) => '제외되는 미분류 박스: $count';

  static String invalidBoxCount(int count) => '유효하지 않은 박스 $count개';

  static String unlabeledBoxCount(int count) => '라벨 필요 박스 $count개';

  static String boxDisplayNumber(int number) => '#$number';

  static String boxDisplayTitle(int number, String label) => '#$number $label';

  static String boxSemanticLabel({
    required int number,
    required String label,
    required bool selected,
  }) {
    final selectedSuffix = selected ? ', 선택됨' : '';
    return '박스 #$number, $label$selectedSuffix';
  }

  static String selectedBoxDisplayTitle(int number, String label) =>
      '#$number · $label';

  static String imageStatusLabel(ImageStatus status) {
    return switch (status) {
      ImageStatus.queued => '대기',
      ImageStatus.detecting => '탐지 중',
      ImageStatus.needsReview => '검토 필요',
      ImageStatus.confirmed => '완료',
      ImageStatus.error => '문제 있음',
    };
  }
}
