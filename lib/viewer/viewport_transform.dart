import 'package:flutter/material.dart';

class ViewportTransform {
  const ViewportTransform({
    required this.imageSize,
    required this.viewportSize,
    required this.baseScale,
    required this.zoom,
    required this.pan,
  });

  factory ViewportTransform.fit({
    required Size imageSize,
    required Size viewportSize,
    double zoom = 1,
    Offset pan = Offset.zero,
  }) {
    final widthScale = viewportSize.width / imageSize.width;
    final heightScale = viewportSize.height / imageSize.height;
    final baseScale = widthScale < heightScale ? widthScale : heightScale;
    return ViewportTransform(
      imageSize: imageSize,
      viewportSize: viewportSize,
      baseScale: baseScale.isFinite && baseScale > 0 ? baseScale : 1,
      zoom: zoom <= 0 ? 1 : zoom,
      pan: pan,
    );
  }

  factory ViewportTransform.fitInside({
    required Size imageSize,
    required Size viewportSize,
    double paddingFactor = 1,
    double zoom = 1,
    Offset pan = Offset.zero,
  }) {
    final safePadding = paddingFactor.isFinite && paddingFactor > 0
        ? paddingFactor.clamp(0.05, 1).toDouble()
        : 1.0;
    final paddedViewport = Size(
      viewportSize.width * safePadding,
      viewportSize.height * safePadding,
    );
    final widthScale = paddedViewport.width / imageSize.width;
    final heightScale = paddedViewport.height / imageSize.height;
    final baseScale = widthScale < heightScale ? widthScale : heightScale;
    return ViewportTransform(
      imageSize: imageSize,
      viewportSize: viewportSize,
      baseScale: baseScale.isFinite && baseScale > 0 ? baseScale : 1,
      zoom: zoom <= 0 ? 1 : zoom,
      pan: pan,
    );
  }

  final Size imageSize;
  final Size viewportSize;
  final double baseScale;
  final double zoom;
  final Offset pan;

  double get scale => baseScale * zoom;

  Size get renderedImageSize =>
      Size(imageSize.width * scale, imageSize.height * scale);

  Offset get imageOrigin {
    return Offset(
      (viewportSize.width - renderedImageSize.width) / 2 + pan.dx,
      (viewportSize.height - renderedImageSize.height) / 2 + pan.dy,
    );
  }

  Offset originalToScreen(Offset original) {
    return Offset(
      imageOrigin.dx + original.dx * scale,
      imageOrigin.dy + original.dy * scale,
    );
  }

  Offset screenToOriginal(Offset screen) {
    return Offset(
      (screen.dx - imageOrigin.dx) / scale,
      (screen.dy - imageOrigin.dy) / scale,
    );
  }

  Rect originalRectToScreen(Rect original) {
    final topLeft = originalToScreen(original.topLeft);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      original.width * scale,
      original.height * scale,
    );
  }

  Rect screenRectToOriginal(Rect screen) {
    final topLeft = screenToOriginal(screen.topLeft);
    return Rect.fromLTWH(
      topLeft.dx,
      topLeft.dy,
      screen.width / scale,
      screen.height / scale,
    );
  }

  Offset clampOriginalPoint(Offset original) {
    return Offset(
      original.dx.clamp(0, imageSize.width).toDouble(),
      original.dy.clamp(0, imageSize.height).toDouble(),
    );
  }
}
