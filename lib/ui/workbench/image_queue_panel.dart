part of 'workbench_screen.dart';

class _ImageListPanel extends StatelessWidget {
  const _ImageListPanel({required this.controller, required this.project});

  final AppController controller;
  final AnnotationProject project;

  @override
  Widget build(BuildContext context) {
    final confirmedCount = project.images
        .where((image) => image.status == ImageStatus.confirmed)
        .length;
    final errorCount = project.images
        .where((image) => image.status == ImageStatus.error)
        .length;
    final needsReviewCount = project.images
        .where((image) => image.status == ImageStatus.needsReview)
        .length;

    return _PanelSurface(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PanelHeader(
              title: WorkbenchCopy.images,
              summary:
                  '이미지 ${project.images.length}장 · 작업 필요 $needsReviewCount장 · 완료 $confirmedCount장 · 문제 $errorCount장',
            ),
            const SizedBox(height: 12),
            Expanded(
              child: project.images.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: _EmptyActionState(
                        icon: Icons.photo_library_outlined,
                        title: WorkbenchCopy.noImagesYet,
                        message: WorkbenchCopy.chooseFolderToStart,
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: project.images.length,
                      itemBuilder: (context, index) {
                        final image = project.images[index];
                        return _ImageQueueRow(
                          key: ValueKey('image-row-${image.id}'),
                          controller: controller,
                          image: image,
                          selected: image.id == controller.selectedImageId,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ImageQueueRow extends StatelessWidget {
  const _ImageQueueRow({
    super.key,
    required this.controller,
    required this.image,
    required this.selected,
  });

  final AppController controller;
  final AnnotatedImage image;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final subtitle = [
      WorkbenchCopy.imageStatusLabel(image.status),
      '박스 ${image.boxCount}개',
      if (image.unlabeledBoxCount > 0) '라벨 필요 ${image.unlabeledBoxCount}개',
      if (image.labeledBoxCount > 0) '완료 ${image.labeledBoxCount}개',
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? colorScheme.primary.withAlpha(12)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.row),
        child: ListTile(
          selected: selected,
          dense: true,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.row),
          ),
          title: Text(
            image.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: Text(WorkbenchCopy.imageStatusLabel(image.status)),
          onTap: controller.isAutomationRunning
              ? null
              : () => controller.selectImage(image.id),
        ),
      ),
    );
  }
}
