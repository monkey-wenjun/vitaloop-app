import 'package:flutter/material.dart';

import '../theme/tokens.dart';

IconData sportIcon(String sport) {
  if (sport.contains('strength') ||
      sport.contains('free_training') ||
      sport.contains('core') ||
      sport.contains('力量')) {
    return Icons.fitness_center_rounded;
  }
  if (sport.contains('cycling') ||
      sport.contains('spinning') ||
      sport.contains('骑行')) {
    return Icons.directions_bike_rounded;
  }
  if (sport.contains('swim') || sport.contains('游泳')) return Icons.pool_rounded;
  if (sport.contains('hiking') ||
      sport.contains('climb') ||
      sport.contains('徒步') ||
      sport.contains('登山')) {
    return Icons.hiking_rounded;
  }
  if (sport.contains('walking') || sport == 'walk' || sport.contains('健走')) {
    return Icons.directions_walk_rounded;
  }
  if (sport.contains('rowing')) return Icons.rowing_rounded;
  if (sport.contains('yoga')) return Icons.self_improvement_rounded;
  return Icons.directions_run_rounded;
}

Color sportTint(BuildContext context, String sport) {
  final v = context.v;
  if (sport.contains('strength') ||
      sport.contains('free_training') ||
      sport.contains('core') ||
      sport.contains('力量')) {
    return v.tintPurple;
  }
  if (sport.contains('cycling') ||
      sport.contains('spinning') ||
      sport.contains('骑行')) {
    return v.tintGreen;
  }
  if (sport.contains('swim') || sport.contains('游泳')) return v.tintSky;
  if (sport.contains('hiking') ||
      sport.contains('climb') ||
      sport.contains('徒步') ||
      sport.contains('登山')) {
    return v.tintPeach;
  }
  if (sport.contains('walking') || sport == 'walk' || sport.contains('健走')) {
    return v.tintPeach;
  }
  return v.tintBlue;
}

Color sportInk(BuildContext context, String sport) {
  final v = context.v;
  if (sport.contains('strength') ||
      sport.contains('free_training') ||
      sport.contains('core') ||
      sport.contains('力量')) {
    return v.purpleInk;
  }
  if (sport.contains('cycling') ||
      sport.contains('spinning') ||
      sport.contains('骑行')) {
    return v.greenInk;
  }
  if (sport.contains('swim') || sport.contains('游泳')) return v.skyInk;
  if (sport.contains('hiking') ||
      sport.contains('climb') ||
      sport.contains('徒步') ||
      sport.contains('登山')) {
    return v.warnInk;
  }
  if (sport.contains('walking') || sport == 'walk' || sport.contains('健走')) {
    return v.warnInk;
  }
  return v.blueInk;
}
