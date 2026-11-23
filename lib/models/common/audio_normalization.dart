import 'dart:math' as math;

import 'package:PiliBro/models/video/play/url.dart' show Volume;
import 'package:PiliBro/utils/storage_pref.dart';
import 'package:media_kit/media_kit.dart' show Player;

enum AudioNormalization {
  disable('禁用'),
  // ref https://github.com/KRTirtho/spotube/commit/da10ab2e291d4ba4d3082b9a6ae535639fb8f1b7
  dynaudnorm('预设 dynaudnorm', 'dynaudnorm=g=5:f=250:r=0.9:p=0.5'),
  loudnorm('预设 loudnorm', 'loudnorm=I=-16:LRA=11:TP=-1.5'),
  custom('自定义参数'),
  ;

  final String title;
  final String param;
  const AudioNormalization(this.title, [this.param = '']);

  static String getTitleFromConfig(String config) => switch (config) {
    '0' => disable.title,
    '1' => dynaudnorm.title,
    '2' => loudnorm.title,
    _ => config,
  };

  static String getParamFromConfig(String config) => switch (config) {
    '0' => disable.param,
    '1' => dynaudnorm.param,
    '2' => loudnorm.param,
    _ => config,
  };

  static final loudnormRegExp = RegExp('loudnorm=([^,]+)');

  static String parse(Volume? volume, String param) {
    if (volume != null && volume.isNotEmpty) {
      return param.replaceFirstMapped(
        loudnormRegExp,
        (i) =>
            'loudnorm=${volume.format(
              Map.fromEntries(
                i.group(1)!.split(':').map((item) {
                  final parts = item.split('=');
                  return MapEntry(parts[0].toLowerCase(), num.parse(parts[1]));
                }),
              ),
            )}',
      );
    } else {
      return param.replaceFirst(
        loudnormRegExp,
        AudioNormalization.getParamFromConfig(Pref.fallbackNormalization),
      );
    }
  }
}

mixin AudioNormalizationMixin {
  late final _audioNormalization = Pref.audioNormalization;
  late final enableAudioNormalization = _audioNormalization != '0';
  late final _param = AudioNormalization.getParamFromConfig(
    _audioNormalization,
  );

  /// 在已有的 af（倍速音调补偿）后接上音量均衡，经 lavfi 交给 mpv；
  /// 跟着当前音轨走，不依赖音轨编号
  String? audioFilter(Volume? volume, [String? af]) {
    if (enableAudioNormalization) {
      final normalization = AudioNormalization.parse(volume, _param);
      if (normalization.isNotEmpty) {
        af = af == null
            ? 'lavfi=[$normalization]'
            : '$af,lavfi=[$normalization]';
      }
    }
    _baseAf = af;
    return _joinAf(af, _alimiter);
  }

  // 变速、均衡这部分滤镜；>100% 音量的限幅滤镜接在它后面，两者共用同一条 af 链
  String? _baseAf;
  String? _alimiter;

  static String? _joinAf(String? base, String? boost) =>
      base == null ? boost : (boost == null ? base : '$base,$boost');

  /// mpv 的 volume 属性是三次方曲线（`gain = (volume / 100) ^ 3`），且这层
  /// 增益直接乘在 PCM 样值上：200% 就是 8 倍（+18dB），300% 是 27 倍
  /// （+28.6dB）。B 站音频峰值本就接近满刻度，放大后越过 0dBFS 被硬削波，
  /// 听感就是粗糙、发闷、带毛刺。
  ///
  /// 这里让 mpv 的 volume 恒 <= 100，把 >100% 的增益挪进 af 滤镜链，用
  /// alimiter 自身的 level_in 放大、再限幅在 0dBFS 以内。增益按 mpv 原来的
  /// 三次方曲线换算，听感响度与旧版一致，只是不再破音。
  ///
  /// 只用 alimiter 是因为 Android 版 media_kit 自带的 libmpv 只编进了
  /// alimiter / aresample / equalizer / dynaudnorm / loudnorm 几个音频滤镜，
  /// 没有 libavfilter 的 volume 滤镜，用它会导致整条音频链初始化失败（静音）。
  ///
  /// 我们的变速、音频均衡也走 af，所以限幅滤镜要接在它们后面（见 [audioFilter]），
  /// 不能单独覆盖 af 属性。
  ///
  /// [volume] 为线性倍数，1.0 即 100%
  Future<void>? setVolumeCapped(Player? player, double volume) {
    assert(volume >= 0);
    if (player == null) return null;
    final boost = _boostAf(volume);
    // 拖动音量时增益连续变化，重建滤镜链开销偏大，
    // 增益按 0.5dB 取整，值未变化时跳过
    if (_alimiter != boost) {
      _alimiter = boost;
      player.setProperty('af', _joinAf(_baseAf, boost) ?? '');
    }
    return player.setVolume(boost == null ? volume * 100 : 100);
  }

  /// [volume] > 1.0 时返回防削波的增益滤镜串，否则返回 null。
  ///
  /// level=0 关闭 alimiter 的自动电平（不做归一化），limit=1 即 0dBFS。
  static String? _boostAf(double volume) {
    if (volume <= 1.0) return null;
    // mpv 的音量是三次方曲线：gain = v^3
    final db = (60 * math.log(volume) / math.ln10 * 2).round() / 2;
    final gain = math.pow(10, db / 20).toDouble();
    return 'alimiter=level_in=${gain.toStringAsFixed(3)}:limit=1:level=0';
  }
}
