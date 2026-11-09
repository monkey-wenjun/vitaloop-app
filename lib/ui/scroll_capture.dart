import 'package:flutter/widgets.dart';

/// ListView 自己不是 Scrollable；真正的 ScrollableState 在它的子树里。
///
/// `Scrollable.maybeOf(listViewContext)` 只查祖先，因此会返回 null，长截图就会
/// 静默退化成当前单屏。这里专门向下遍历，拿到列表内部真正可滚动的 position。
ScrollPosition? findDescendantScrollPosition(BuildContext context) {
  final root = context as Element;
  ScrollableState? found;

  void visit(Element element) {
    if (found != null) return;
    if (element is StatefulElement && element.state is ScrollableState) {
      found = element.state as ScrollableState;
      return;
    }
    element.visitChildElements(visit);
  }

  if (root is StatefulElement && root.state is ScrollableState) {
    found = root.state as ScrollableState;
  } else {
    root.visitChildElements(visit);
  }
  return found?.position;
}
