import 'package:bbox_labeler/ui/workbench_copy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the approved review-candidate instruction exactly', () {
    expect(WorkbenchCopy.chooseReviewCandidate, '추천 라벨을 선택한 뒤 Enter를 누르세요');
  });

  test('uses the approved project snapshot failure copy exactly', () {
    expect(
      WorkbenchCopy.projectFileSaveFailed('disk full'),
      '프로젝트 파일을 저장하지 못했습니다. 경로와 권한을 확인한 뒤 다시 시도하세요. disk full',
    );
  });
}
