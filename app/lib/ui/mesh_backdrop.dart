import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Near-black warm canvas with one faint amber breath at the top —
/// barely there, just enough that the dark isn't dead.
class MeshBackdrop extends StatelessWidget {
  const MeshBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(color: AppColors.paper),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.6, -1.2),
            radius: 1.1,
            colors: [Color(0x1FFF7A33), Color(0x00FF7A33)],
          ),
        ),
      ),
    );
  }
}
