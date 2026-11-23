import 'package:PiliBro/utils/bili_device.dart';

/// 首页推荐来源。设置里存一个整数：低 4 位依次是 Web、手机、平板、桌面勾没勾，
/// 往上四个字节依次是四者的权重（1～255，没存过的按 1）
enum RcmdSource {
  web('Web 推荐', null),
  phone('手机推荐', BiliApp.phone),
  hd('平板推荐', BiliApp.hd),
  desktop('桌面端推荐', null)
  ;

  final String label;
  final BiliApp? app;
  const RcmdSource(this.label, this.app);

  int get bit => 1 << index;

  int get _shift => 8 * (index + 1);

  int weightOf(int sources) => (sources >> _shift & 255).clamp(1, 255);

  int withWeight(int sources, int weight) =>
      sources & ~(255 << _shift) | weight << _shift;
}