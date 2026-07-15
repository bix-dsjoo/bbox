import 'package:bbox_labeler/ui/project_transfer_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the owned native BBox project picker configuration', () {
    expect(projectImportPickerTitle, 'BBox 프로젝트 파일 가져오기');
    expect(projectSavePickerTitle, 'BBox 프로젝트 파일 저장');
    expect(projectFileFilterSpecification, {
      'BBox 프로젝트 (*.bbox.json)': '*.bbox.json',
    });
  });
}
