import 'package:filepicker_windows/filepicker_windows.dart';

abstract class CocoExportDestinationPicker {
  const CocoExportDestinationPicker();

  Future<String?> pickDestination();
}

const cocoExportPickerTitle = 'COCO JSON 내보내기';
const cocoExportFilterSpecification = {'COCO JSON (*.json)': '*.json'};

class WindowsCocoExportDestinationPicker extends CocoExportDestinationPicker {
  const WindowsCocoExportDestinationPicker();

  @override
  Future<String?> pickDestination() async {
    final picker = SaveFilePicker()
      ..title = cocoExportPickerTitle
      ..filterSpecification = cocoExportFilterSpecification
      ..defaultFilterIndex = 0
      ..defaultExtension = 'json'
      ..forceFileSystemItems = true;
    return picker.getFile()?.path;
  }
}
