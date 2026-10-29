import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_svg/svg.dart';

/// The coin icon at [path] with an [outline] ring around it, for cards
/// painted in the coin's own color, where the icon would blend in.
class OutlinedCoinIcon extends StatelessWidget {
  const OutlinedCoinIcon({
    super.key,
    required this.path,
    required this.outline,
    this.size = 24,
    this.thickness = 1.5,
  });

  final String path;
  final Color outline;
  final double size;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final ring = SvgPicture.file(
      File(path),
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(outline, BlendMode.srcIn),
    );
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // The icon's silhouette, shifted around a circle.
          for (var i = 0; i < 12; i++)
            Transform.translate(
              offset: Offset.fromDirection(i * pi / 6, thickness),
              child: ring,
            ),
          SvgPicture.file(File(path), width: size, height: size),
        ],
      ),
    );
  }
}
