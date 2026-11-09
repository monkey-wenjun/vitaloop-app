import 'package:flutter/widgets.dart' as fw;

import 'ui_translations.dart';

class Text extends fw.StatelessWidget {
  const Text(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    @Deprecated(
      'Use textScaler instead. Kept for source compatibility with Flutter Text.',
    )
    this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null,
       assert(
         textScaler == null || textScaleFactor == null,
         'textScaler cannot be combined with textScaleFactor.',
       );

  const Text.rich(
    fw.InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    @Deprecated(
      'Use textScaler instead. Kept for source compatibility with Flutter Text.',
    )
    this.textScaleFactor,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.semanticsIdentifier,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null,
       assert(
         textScaler == null || textScaleFactor == null,
         'textScaler cannot be combined with textScaleFactor.',
       );

  final String? data;
  final fw.InlineSpan? textSpan;
  final fw.TextStyle? style;
  final fw.StrutStyle? strutStyle;
  final fw.TextAlign? textAlign;
  final fw.TextDirection? textDirection;
  final fw.Locale? locale;
  final bool? softWrap;
  final fw.TextOverflow? overflow;

  @Deprecated(
    'Use textScaler instead. Kept for source compatibility with Flutter Text.',
  )
  final double? textScaleFactor;
  final fw.TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final String? semanticsIdentifier;
  final fw.TextWidthBasis? textWidthBasis;
  final fw.TextHeightBehavior? textHeightBehavior;
  final fw.Color? selectionColor;

  @override
  fw.Widget build(fw.BuildContext context) {
    final languageCode = fw.Localizations.localeOf(context).languageCode;
    final translatedSemantics = semanticsLabel == null
        ? null
        : UiTranslations.instance.translate(
            semanticsLabel!,
            languageCode: languageCode,
          );
    if (textSpan != null) {
      return fw.Text.rich(
        translateInlineSpan(textSpan!, languageCode),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel: translatedSemantics,
        semanticsIdentifier: semanticsIdentifier,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
    }
    return fw.Text(
      data == null
          ? ''
          : UiTranslations.instance.translate(
              data!,
              languageCode: languageCode,
            ),
      style: style,
      strutStyle: strutStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      locale: locale,
      softWrap: softWrap,
      overflow: overflow,
      textScaler: textScaler,
      maxLines: maxLines,
      semanticsLabel: translatedSemantics,
      semanticsIdentifier: semanticsIdentifier,
      textWidthBasis: textWidthBasis,
      textHeightBehavior: textHeightBehavior,
      selectionColor: selectionColor,
    );
  }
}

fw.InlineSpan translateInlineSpan(fw.InlineSpan span, String languageCode) {
  if (span is fw.TextSpan) {
    return fw.TextSpan(
      text: span.text == null
          ? null
          : UiTranslations.instance.translate(
              span.text!,
              languageCode: languageCode,
            ),
      style: span.style,
      children: span.children
          ?.map((child) => translateInlineSpan(child, languageCode))
          .toList(growable: false),
      recognizer: span.recognizer,
      semanticsLabel: span.semanticsLabel == null
          ? null
          : UiTranslations.instance.translate(
              span.semanticsLabel!,
              languageCode: languageCode,
            ),
      mouseCursor: span.mouseCursor,
      onEnter: span.onEnter,
      onExit: span.onExit,
    );
  }
  return span;
}
