class ProjectHomeCopy {
  const ProjectHomeCopy._();

  static const appTitle = 'BBox 라벨러';
  static const title = '프로젝트 홈';
  static const subtitle = '라벨링 프로젝트를 만들거나 이어서 작업하세요.';
  static const projectName = '프로젝트 이름';
  static const defaultProjectName = '새 라벨링 프로젝트';
  static const createProject = '만들기';
  static const importProjectFile = '프로젝트 파일 가져오기';
  static const importProjectFileHint = '다른 PC에서 저장한 BBox 프로젝트를 가져옵니다.';
  static const noProjects = '프로젝트가 없습니다';
  static const noProjectsMessage = '새 프로젝트를 만들어 이미지 라벨링을 시작하세요.';
  static const projectActions = '프로젝트 작업';
  static const rename = '이름 변경';
  static const delete = '삭제';
  static const cancel = '취소';
  static const renameTitle = '프로젝트 이름 변경';
  static const renameConfirm = '변경';
  static const deleteTitle = '프로젝트 삭제';
  static const deleteMessage = '내부 프로젝트 데이터만 삭제됩니다. 원본 이미지는 삭제되지 않습니다.';

  static String projectSummary({
    required int images,
    required int confirmed,
    required int errors,
  }) {
    return '이미지 $images장 · 완료 $confirmed장 · 문제 $errors장';
  }

  static String actionFailed(Object error) {
    return '프로젝트 작업을 완료하지 못했습니다. 다시 시도하세요. $error';
  }
}
