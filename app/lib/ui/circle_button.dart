import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Quiet circular icon button for the dark editorial system.
/// The `dark` flag is kept for call-site compatibility; both render dark.
class CircleIconButton extends StatelessWidget {
  const CircleIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.dark = false,
    this.size = 38,
    this.iconSize = 17,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool dark;
  final double size;
  final double iconSize;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final btn = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.line),
      ),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Icon(icon, size: iconSize, color: AppColors.ink),
        ),
      ),
    );
    if (tooltip == null) {
      return btn;
    }
    return Tooltip(message: tooltip!, child: btn);
  }
}
