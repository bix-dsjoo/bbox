import 'package:bbox_labeler/ui/coco_export_destination_picker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('uses the owned native COCO JSON save-picker configuration', () {
    expect(cocoExportPickerTitle, 'COCO JSON 내보내기');
    expect(cocoExportFilterSpecification, {'COCO JSON (*.json)': '*.json'});
  });
}
