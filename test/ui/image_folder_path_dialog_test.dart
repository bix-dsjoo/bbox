import 'package:bbox_labeler/ui/image_folder_path_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ImageFolderPathDialog', () {
    testWidgets('returns the trimmed typed folder path', (tester) async {
      String? selectedPath;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    selectedPath = await showDialog<String>(
                      context: context,
                      builder: (_) =>
                          ImageFolderPathDialog(browseFolder: () async => null),
                    );
                  },
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('image-folder-path-input')),
        r'  C:\workspace\bbox\qa_samples\images  ',
      );
      await tester.tap(find.byKey(const ValueKey('import-image-folder-path')));
      await tester.pumpAndSettle();

      expect(selectedPath, r'C:\workspace\bbox\qa_samples\images');
    });

    testWidgets('browse fills the path without closing the dialog', (
      tester,
    ) async {
      String? selectedPath;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    selectedPath = await showDialog<String>(
                      context: context,
                      builder: (_) => ImageFolderPathDialog(
                        browseFolder: () async => r'C:\한글 이미지',
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('browse-image-folder')));
      await tester.pumpAndSettle();

      expect(find.text(r'C:\한글 이미지'), findsOneWidget);
      expect(selectedPath, isNull);

      await tester.tap(find.byKey(const ValueKey('import-image-folder-path')));
      await tester.pumpAndSettle();

      expect(selectedPath, r'C:\한글 이미지');
    });

    testWidgets('paste fills the path from clipboard without closing', (
      tester,
    ) async {
      String? selectedPath;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              return Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    selectedPath = await showDialog<String>(
                      context: context,
                      builder: (_) => ImageFolderPathDialog(
                        browseFolder: () async => null,
                        readClipboard: () async =>
                            r'C:\workspace\bbox\qa_samples\images',
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('paste-image-folder-path')));
      await tester.pumpAndSettle();

      expect(find.text(r'C:\workspace\bbox\qa_samples\images'), findsOneWidget);
      expect(selectedPath, isNull);

      await tester.tap(find.byKey(const ValueKey('import-image-folder-path')));
      await tester.pumpAndSettle();

      expect(selectedPath, r'C:\workspace\bbox\qa_samples\images');
    });
  });
}
