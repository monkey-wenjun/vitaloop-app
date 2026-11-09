import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../l10n/sleep_copy.dart';
import '../../theme/tokens.dart';
import '../components.dart';
import '../nav.dart';
import 'sleep/sleep_controller.dart';
import 'sleep/sleep_style.dart';
import 'sleep/sleep_widgets.dart';

class SleepDetailScreen extends StatefulWidget {
  const SleepDetailScreen({super.key, this.day});

  final int? day;

  @override
  State<SleepDetailScreen> createState() => _SleepDetailScreenState();
}

class _SleepDetailScreenState extends State<SleepDetailScreen> {
  late final SleepController _controller = SleepController(day: widget.day);

  @override
  void initState() {
    super.initState();
    unawaited(_controller.load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: context.v.bg,
      body: SafeArea(
        bottom: false,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final options = [l10n.rangeDay, l10n.rangeWeek, l10n.rangeMonth];
            return ListView(
              padding: SleepStyle.pagePadding,
              children: [
                VDetailHeader(title: l10n.sleepDetails),
                VSegmented(
                  options: options,
                  index: _controller.rangeIndex,
                  onChanged: (index) => unawaited(_controller.setRange(index)),
                  margin: const EdgeInsets.only(top: 0, bottom: 13),
                ),
                if (_controller.rangeIndex == 0)
                  _nightContent(context)
                else
                  _periodContent(context),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _nightContent(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_controller.loadingNight) {
      return const Padding(
        padding: EdgeInsets.only(top: 140),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_controller.error != null) {
      return SleepEmptyCard(title: l10n.noSleepNight, body: _controller.error!);
    }
    final data = _controller.night;
    if (data == null) {
      return SleepEmptyCard(
        title: l10n.noSleepNight,
        body: l10n.noSleepNightBody,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SleepNightHero(data: data),
        const SizedBox(height: SleepStyle.sectionGap),
        _responsivePair(
          context,
          first: SleepNightChartCard(data: data),
          second: SleepCompositionCard(data: data),
          breakpoint: 760,
          firstFlex: 7,
          secondFlex: 4,
        ),
        const SizedBox(height: SleepStyle.sectionGap),
        _responsivePair(
          context,
          first: SleepHealthCard(data: data),
          second: SleepApneaCard(
            records: _controller.apnea,
            loading: _controller.loadingApnea,
          ),
          breakpoint: 760,
          firstFlex: 7,
          secondFlex: 4,
        ),
      ],
    );
  }

  Widget _periodContent(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_controller.loadingPeriod) {
      return const Padding(
        padding: EdgeInsets.only(top: 140),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_controller.error != null) {
      return SleepEmptyCard(title: l10n.noSleepRange, body: _controller.error!);
    }
    final period = _controller.period;
    if (period == null || period.nights == 0) {
      return SleepEmptyCard(
        title: l10n.noSleepRange,
        body: l10n.noSleepRangeBody,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SleepPeriodHero(
          period: period,
          rangeLabel: l10n.sleepRangeName(period.rangeIndex),
        ),
        const SizedBox(height: SleepStyle.sectionGap),
        _responsivePair(
          context,
          first: SleepTrendCard(period: period),
          second: SleepPeriodCompositionCard(period: period),
          breakpoint: 760,
          firstFlex: 7,
          secondFlex: 4,
        ),
      ],
    );
  }

  Widget _responsivePair(
    BuildContext context, {
    required Widget first,
    required Widget second,
    required double breakpoint,
    required int firstFlex,
    required int secondFlex,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < breakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              first,
              const SizedBox(height: SleepStyle.sectionGap),
              second,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: firstFlex, child: first),
            const SizedBox(width: SleepStyle.sectionGap),
            Expanded(flex: secondFlex, child: second),
          ],
        );
      },
    );
  }
}
