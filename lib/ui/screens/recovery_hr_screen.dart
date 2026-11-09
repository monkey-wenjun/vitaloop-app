import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:vitaloop/l10n/localized_text.dart';

import '../../data/ble_bridge.dart';
import '../../theme/tokens.dart';
import '../components.dart';

/// 运动后 2 分钟恢复心率。心率带没连或没数据时允许直接跳过，不阻塞保存。
class RecoveryHrScreen extends StatefulWidget {
  const RecoveryHrScreen({super.key});

  @override
  State<RecoveryHrScreen> createState() => _RecoveryHrScreenState();
}

class _RecoveryHrScreenState extends State<RecoveryHrScreen> {
  static const _duration = 120;
  final _ble = BleBridge.instance;
  final List<int> _samples = [];
  Timer? _timer;
  int _left = _duration;

  @override
  void initState() {
    super.initState();
    _sample();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      _sample();
      if (!mounted) return;
      setState(() => _left = (_left - 5).clamp(0, _duration));
      if (_left <= 0) _finish();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _sample() {
    final bpm = _ble.latestHeartRate.value;
    if (bpm > 0 && (_samples.isEmpty || _samples.last != bpm)) {
      _samples.add(bpm);
    }
  }

  void _finish() {
    _timer?.cancel();
    if (!mounted) return;
    Navigator.pop(context, List<int>.from(_samples));
  }

  @override
  Widget build(BuildContext context) {
    final v = context.v;
    return Scaffold(
      backgroundColor: v.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          child: Column(
            children: [
              Row(
                children: [
                  const SizedBox(width: 38),
                  const Spacer(),
                  Text('恢复心率', style: VText.meta.copyWith(color: v.muted)),
                  const Spacer(),
                  TextButton(onPressed: _finish, child: const Text('跳过')),
                ],
              ),
              const Spacer(),
              ValueListenableBuilder<int>(
                valueListenable: _ble.latestHeartRate,
                builder: (context, bpm, _) => Column(
                  children: [
                    Icon(Icons.favorite_rounded, size: 40, color: v.heartInk),
                    const SizedBox(height: 12),
                    Text(
                      bpm > 0 ? '$bpm' : '--',
                      style: VText.h1.copyWith(fontSize: 70, color: v.ink),
                    ),
                    Text(
                      'bpm · 实时心率',
                      style: VText.label.copyWith(color: v.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 26),
              Text(
                _left > 0
                    ? '保持安静站立，还剩 ${_left ~/ 60}:${(_left % 60).toString().padLeft(2, '0')}'
                    : '检测完成',
                style: VText.h3.copyWith(color: v.ink),
              ),
              const SizedBox(height: 8),
              Text(
                '运动后心率下降得越快，通常表示恢复越好。',
                style: VText.label.copyWith(color: v.muted),
              ),
              const SizedBox(height: 22),
              if (_samples.isNotEmpty)
                VCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: VStat(
                          label: '起始',
                          value: '${_samples.first}',
                          unit: 'bpm',
                        ),
                      ),
                      Expanded(
                        child: VStat(
                          label: '当前',
                          value: '${_samples.last}',
                          unit: 'bpm',
                        ),
                      ),
                      Expanded(
                        child: VStat(
                          label: '下降',
                          value:
                              '${(_samples.first - _samples.last).clamp(0, 999)}',
                          unit: 'bpm',
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              VGhostButton(
                label: '结束检测',
                icon: Icons.check_rounded,
                onTap: _finish,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
