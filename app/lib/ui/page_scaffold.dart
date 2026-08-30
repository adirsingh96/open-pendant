import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_theme.dart';
import 'circle_button.dart';
import 'mesh_backdrop.dart';

/// Shared editorial page shell: circular back button, big title, optional
/// caption and header actions, content constrained to the app column.
class PageScaffold extends StatelessWidget {
  const PageScaffold({
    super.key,
    required this.title,
    required this.body,
    this.caption,
    this.actions = const [],
    this.bottom,
  });

  final String title;
  final Widget body;
  final String? caption;
  final List<Widget> actions;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const MeshBackdrop(),
        Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: Row(
                        children: [
                          CircleIconButton(
                            icon: LucideIcons.arrowLeft,
                            iconSize: 16,
                            onTap: () => Navigator.pop(context),
                            tooltip: 'Back',
                          ),
                          const Spacer(),
                          ...actions,
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(28, 14, 28, 0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: AppText.display.copyWith(fontSize: 26),
                          ),
                          if (caption != null) ...[
                            const SizedBox(height: 6),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 360),
                              child: Text(
                                caption!,
                                style: AppText.sub.copyWith(fontSize: 12.5),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(child: body),
                    if (bottom != null) bottom!,
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Grab handle for bottom sheets.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.only(top: 10),
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: AppColors.lineStrong,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
