import 'package:PiliBro/models/common/enum_with_label.dart';

enum AudioOutput implements EnumWithLabel {
  aaudio('AAudio'),
  opensles('OpenSL ES'),
  audiotrack('AudioTrack'),
  ;

  // AAudio 在部分设备（实测 Android 16 的 Galaxy Z Fold6）seek 之后不再向
  // mpv 回报播放位置：audio-pts 停在同一位置抖动，time-pos 随之冻结，画面与
  // 进度条卡住，但音频输出本身正常（听感上声音持续前进）。OpenSL ES 没有该
  // 问题，故默认值让它优先。这里保持枚举顺序不变，避免改变设置页的选项排列；
  // 以后新增音频后端时需要同步更新这个常量。
  static const defaultValue = 'opensles,aaudio,audiotrack';

  @override
  final String label;
  const AudioOutput(this.label);
}
