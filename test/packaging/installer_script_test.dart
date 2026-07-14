import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('installer script does not broadly exclude dependency folder names', () {
    final script = File('installer/bbox_labeler.iss').readAsStringSync();

    for (final broadExclude in [
      r'datasets\*',
      r'outputs\*',
      r'qa_samples\*',
      r'research\*',
      r'build\*',
      r'dist\*',
    ]) {
      expect(script, isNot(contains(broadExclude)));
    }
  });

  test(
    'installer helper guards against development folders at release root',
    () {
      final script = File(
        'tools/packaging/build_windows_installer.ps1',
      ).readAsStringSync();

      expect(script, contains('Release root contains development-only folder'));
    },
  );

  test('installer helper requires manifest-selected pipeline assets', () {
    final script = File(
      'tools/packaging/build_windows_installer.ps1',
    ).readAsStringSync();

    expect(script, contains('tools\\detectors\\bread_box_worker.py'));
    expect(script, contains('models\\bread_pipeline_manifest.json'));
    expect(script, contains(r'$pipelineManifest.detector.file'));
    expect(script, contains(r'$pipelineManifest.classifier.file'));
    expect(script, isNot(contains('bread_yolov8n_1class_tray_v0_2.pt')));
    expect(script, isNot(contains('FastSAM')));
    expect(script, isNot(contains('AllowMissingDetectorRuntime')));
  });

  test('installer helper enforces an exact release model allowlist', () {
    final installerHelper = File(
      'tools/packaging/build_windows_installer.ps1',
    ).readAsStringSync();
    final script = File(
      'tools/packaging/verify_release_models.ps1',
    ).readAsStringSync();

    expect(installerHelper, contains('verify_release_models.ps1'));
    expect(script, contains(r'$allowedReleaseModelPaths = @('));
    expect(script, contains(r'$pipelineManifest.detector.file'));
    expect(script, contains(r'$pipelineManifest.classifier.file'));
    expect(script, contains(r'Get-ChildItem -LiteralPath $releaseRoot'));
    expect(script, contains(r'-Filter "*.pt"'));
    expect(script, contains(r'$unexpectedReleaseModels'));
    expect(script, contains('Release contains an unexpected detector model'));
    expect(script, isNot(contains(r'$forbiddenPath')));
  });

  test('release model verifier accepts only the exact model set', () async {
    final tempDir = Directory.systemTemp.createTempSync('bbox-release-models-');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final modelsDir = Directory(
      '${tempDir.path}${Platform.pathSeparator}models',
    )..createSync(recursive: true);
    const detectorName = 'bread_detector_candidate_b2_recall_v2.pt';
    const classifierName = 'bread_classifier_content_addressed.pt';
    File(
      '${modelsDir.path}${Platform.pathSeparator}$detectorName',
    ).writeAsBytesSync(const [1]);
    File(
      '${modelsDir.path}${Platform.pathSeparator}$classifierName',
    ).writeAsBytesSync(const [2]);
    File(
      '${modelsDir.path}${Platform.pathSeparator}bread_pipeline_manifest.json',
    ).writeAsStringSync(
      '{"detector":{"file":"$detectorName"},'
      '"classifier":{"file":"$classifierName"}}',
    );
    final verifier = File(
      'tools/packaging/verify_release_models.ps1',
    ).absolute.path;

    final exact = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      verifier,
      '-ReleaseRoot',
      tempDir.path,
    ]);
    expect(exact.exitCode, 0, reason: '${exact.stdout}${exact.stderr}');

    File(
      '${tempDir.path}${Platform.pathSeparator}research-only.pt',
    ).writeAsBytesSync(const [3]);
    final extra = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      verifier,
      '-ReleaseRoot',
      tempDir.path,
    ]);
    expect(extra.exitCode, isNot(0));
    expect(
      '${extra.stdout}${extra.stderr}',
      contains('Release contains an unexpected detector model'),
    );
  });

  test(
    'installer helper validates release assets after build and before ISCC',
    () {
      final script = File(
        'tools/packaging/build_windows_installer.ps1',
      ).readAsStringSync();

      final requiredAssetsIndex = script.indexOf(r'$requiredAssetPaths = @(');
      final buildIndex = script.indexOf(r'if (-not $SkipFlutterBuild)');
      final releaseRootIndex = script.indexOf(
        r'$releaseRoot = Join-Path (Get-Location).Path',
      );
      final releaseValidationIndex = script.indexOf(
        r'$absoluteReleaseRequiredPath = Join-Path $releaseRoot $requiredPath',
      );
      final isccIndex = script.indexOf(r'$iscc = Find-Iscc');

      expect(requiredAssetsIndex, isNonNegative);
      expect(buildIndex, greaterThan(requiredAssetsIndex));
      expect(releaseRootIndex, greaterThan(buildIndex));
      expect(releaseValidationIndex, greaterThan(releaseRootIndex));
      expect(isccIndex, greaterThan(releaseValidationIndex));

      final releaseValidation = script.substring(releaseRootIndex, isccIndex);
      expect(
        releaseValidation,
        contains(r'foreach ($requiredPath in $requiredAssetPaths)'),
      );
      expect(
        releaseValidation,
        contains('Required release asset was not found'),
      );
    },
  );

  test('Windows build installs only manifest-selected pipeline assets', () {
    final script = File(
      'windows/CMakeLists.txt',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    final cleanupStart = script.indexOf('install(CODE "\n  file(REMOVE\n');
    final cleanupEnd = script.indexOf('" COMPONENT Runtime)', cleanupStart);
    expect(cleanupStart, isNonNegative);
    expect(cleanupEnd, isNonNegative);

    final cleanup = script.substring(cleanupStart, cleanupEnd);
    final activeRules = script.replaceRange(
      cleanupStart,
      cleanupEnd + '" COMPONENT Runtime)'.length,
      '',
    );

    expect(
      activeRules,
      contains(
        r'set(BBOX_BREAD_WORKER_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../tools/detectors/bread_box_worker.py")',
      ),
    );
    expect(activeRules, contains(r'install(FILES "${BBOX_BREAD_WORKER_FILE}"'));
    expect(
      activeRules,
      contains(
        r'set(BBOX_PIPELINE_MANIFEST_FILE "${CMAKE_CURRENT_SOURCE_DIR}/../models/bread_pipeline_manifest.json")',
      ),
    );
    expect(activeRules, contains('BBOX_DETECTOR_MODEL_FILE'));
    expect(activeRules, contains('BBOX_CLASSIFIER_MODEL_FILE'));
    expect(
      activeRules,
      contains(r'install(FILES "${BBOX_PIPELINE_MANIFEST_FILE}"'),
    );
    expect(activeRules, isNot(contains('bread_yolov8n_1class_tray_v0_2.pt')));
    expect(activeRules, isNot(contains('BBOX_MODEL_DIR')));
    expect(activeRules, isNot(contains('FILES_MATCHING')));
    expect(activeRules, isNot(contains('PATTERN "*.pt"')));
    expect(activeRules, isNot(contains('PATTERN "*.npz"')));

    for (final stale in [
      'FastSAM-s.pt',
      'fastsam_detector.py',
      'bread_vision_detector.py',
      'bread_classifier_yolov8n_cls_best.pt',
      'bread_yolov8n_1class_best.pt',
    ]) {
      expect(cleanup, contains(stale));
      expect(activeRules, isNot(contains(stale)));
    }
  });

  test('installer upgrade removes stale detector assets', () {
    final script = File('installer/bbox_labeler.iss').readAsStringSync();
    for (final stale in [
      r'{app}\FastSAM-s.pt',
      r'{app}\tools\detectors\fastsam_detector.py',
      r'{app}\tools\detectors\bread_vision_detector.py',
      r'{app}\models\bread_classifier_yolov8n_cls_best.pt',
      r'{app}\models\bread_yolov8n_1class_best.pt',
    ]) {
      expect(script, contains(stale));
    }
  });

  test('installer clears stale bundled Python runtime before reinstalling', () {
    final script = File('installer/bbox_labeler.iss').readAsStringSync();

    expect(
      script,
      contains(r'Type: filesandordirs; Name: "{app}\runtime\python"'),
    );
  });

  test('installer deletes stale development folders only at app root', () {
    final script = File('installer/bbox_labeler.iss').readAsStringSync();

    for (final appRootFolder in [
      'datasets',
      'train',
      'outputs',
      'qa_samples',
      'research',
    ]) {
      expect(
        script,
        contains('Type: filesandordirs; Name: "{app}\\$appRootFolder"'),
      );
    }
  });
}
