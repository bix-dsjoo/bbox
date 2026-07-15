import 'package:filepicker_windows/filepicker_windows.dart';

abstract class ProjectTransferPicker {
  const ProjectTransferPicker();

  Future<String?> pickImportFile();

  Future<String?> pickSnapshotDestination();
}

const projectImportPickerTitle = 'BBox 프로젝트 파일 가져오기';
const projectSavePickerTitle = 'BBox 프로젝트 파일 저장';
const projectFileFilterSpecification = {
  'BBox 프로젝트 (*.bbox.json)': '*.bbox.json',
};

class WindowsProjectTransferPicker extends ProjectTransferPicker {
  const WindowsProjectTransferPicker();

  @override
  Future<String?> pickImportFile() async {
    final picker = OpenFilePicker()
      ..title = projectImportPickerTitle
      ..filterSpecification = projectFileFilterSpecification
      ..defaultExtension = 'bbox.json'
      ..fileMustExist = true
      ..forceFileSystemItems = true;
    return picker.getFile()?.path;
  }

  @override
  Future<String?> pickSnapshotDestination() async {
    final picker = SaveFilePicker()
      ..title = projectSavePickerTitle
      ..filterSpecification = projectFileFilterSpecification
      ..defaultExtension = 'bbox.json'
      ..forceFileSystemItems = true;
    return picker.getFile()?.path;
  }
}
