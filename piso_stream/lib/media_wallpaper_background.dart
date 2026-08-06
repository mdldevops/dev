import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class MediaWallpaperBackground extends StatefulWidget {
  const MediaWallpaperBackground({
    super.key,
    required this.path,
    required this.gradientColors,
    this.overlayOpacity = 0.3,
  });

  final String? path;
  final List<Color> gradientColors;
  final double overlayOpacity;

  static const pickerExtensions = <String>[
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
    'bmp',
    'mp4',
    'm4v',
    'mov',
    'webm',
    'mkv',
    '3gp',
  ];

  static const videoExtensions = <String>{
    'mp4',
    'm4v',
    'mov',
    'webm',
    'mkv',
    '3gp',
  };

  static bool isVideoPath(String? path) {
    if (path == null || path.trim().isEmpty || !path.contains('.')) {
      return false;
    }
    return videoExtensions.contains(path.split('.').last.toLowerCase());
  }

  static String mediaTypeLabel(String? path) {
    return isVideoPath(path) ? 'Video' : 'Image';
  }

  @override
  State<MediaWallpaperBackground> createState() =>
      _MediaWallpaperBackgroundState();
}

class _MediaWallpaperBackgroundState extends State<MediaWallpaperBackground> {
  VideoPlayerController? _controller;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    _syncVideoController();
  }

  @override
  void didUpdateWidget(covariant MediaWallpaperBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _syncVideoController();
    }
  }

  @override
  void dispose() {
    _loadVersion++;
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _syncVideoController() async {
    final version = ++_loadVersion;
    final path = widget.path;
    final oldController = _controller;

    if (mounted) {
      setState(() {
        _controller = null;
      });
    } else {
      _controller = null;
    }

    await oldController?.dispose();

    if (path == null || !MediaWallpaperBackground.isVideoPath(path)) {
      return;
    }

    final controller = VideoPlayerController.file(File(path));

    try {
      await controller.initialize();
      await controller.setLooping(true);
      await controller.setVolume(0);
      await controller.play();
    } catch (_) {
      await controller.dispose();
      return;
    }

    if (!mounted || version != _loadVersion) {
      await controller.dispose();
      return;
    }

    setState(() {
      _controller = controller;
    });
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    final hasPath = path != null && path.isNotEmpty;

    if (!hasPath) {
      return _GradientWallpaper(colors: widget.gradientColors);
    }

    final resolvedPath = path!;
    final isVideo = MediaWallpaperBackground.isVideoPath(resolvedPath);
    final Widget media = isVideo
        ? _buildVideoWallpaper()
        : Image.file(
            File(resolvedPath),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                _GradientWallpaper(colors: widget.gradientColors),
          );

    return Stack(
      fit: StackFit.expand,
      children: [
        media,
        Container(color: Colors.black.withValues(alpha: widget.overlayOpacity)),
      ],
    );
  }

  Widget _buildVideoWallpaper() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return _GradientWallpaper(colors: widget.gradientColors);
    }

    final size = controller.value.size;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: size.width,
          height: size.height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}

class _GradientWallpaper extends StatelessWidget {
  const _GradientWallpaper({required this.colors});

  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
    );
  }
}
