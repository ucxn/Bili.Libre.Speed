import 'package:PiliBro/grpc/bilibili/app/listener/v1.pb.dart'
    show Author, BKArcPart, BKArchive, BKStat, DetailItem, PlayItem;
import 'package:PiliBro/grpc/bilibili/app/listener/v1.pbenum.dart'
    show PlaylistSource;
import 'package:PiliBro/http/fav.dart';
import 'package:PiliBro/http/loading_state.dart';
import 'package:PiliBro/models_new/fav/fav_detail/media.dart';
import 'package:PiliBro/models_new/fav/fav_folder/list.dart';
import 'package:PiliBro/pages/audio/view.dart';
import 'package:PiliBro/utils/accounts.dart';
import 'package:PiliBro/utils/storage.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 收藏夹条目 -> 听视频页的 DetailItem。
///
/// 不依赖 gRPC Listener/Playlist：私密稿件（state=-50）在那套服务里不下发，
/// 但 web 收藏夹数据里是正常条目，本地构造后整表传进听视频页即可保留。
/// 只填首 P 的 cid 作占位分 P，选中后由 AudioController 用 web 详情补齐真实分 P。
List<DetailItem> buildFavAudioPlaylist(Iterable<FavDetailItemModel> items) {
  final result = <DetailItem>[];
  for (final e in items) {
    final aid = e.id;
    final cid = e.ugc?.firstCid;
    if (aid == null || cid == null) continue;
    final oid = Int64(aid);
    final subId = Int64(cid);
    final title = e.title ?? '';
    final duration = e.duration ?? 0;
    result.add(
      DetailItem(
        item: PlayItem(itemType: 1, oid: oid, subId: [subId]),
        arc: BKArchive(
          oid: oid,
          title: title,
          cover: e.cover ?? '',
          desc: e.intro ?? '',
          duration: Int64(duration),
          displayedOid: e.bvid ?? '',
        ),
        parts: [
          BKArcPart(
            oid: oid,
            subId: subId,
            title: title,
            duration: Int64(duration),
            page: 1,
          ),
        ],
        owner: Author(
          mid: Int64(e.upper?.mid ?? 0),
          name: e.upper?.name ?? '',
          avatar: e.upper?.face ?? '',
        ),
        stat: BKStat(view: e.cntInfo?.play ?? 0),
      ),
    );
  }
  return result;
}

/// 「一键听歌」：在「我的」页面用预先选好的收藏夹直接进入听音频模式。
/// 设置与网络逻辑都放这里，页面只负责放一个按钮。
abstract final class OneKeyListen {
  static const String _mediaIdKey = 'oneKeyListenMediaId';
  static const String _titleKey = 'oneKeyListenFavTitle';
  static const int _pageSize = 20;
  static const int _maxPages = 10;

  // 「我的」页是保活的，长按换收藏夹只写 Hive 不会触发页面重建；
  // 用可监听的名称让按钮提示立刻跟着变，不用等重新打开页面。
  static final ValueNotifier<String> titleNotifier = ValueNotifier<String>(
    GStorage.setting.get(_titleKey) as String? ?? '',
  );

  static int? get mediaId => GStorage.setting.get(_mediaIdKey) as int?;
  static String get title => titleNotifier.value;

  /// 点击：播放已选收藏夹；没设置过就先选一次，选完立刻播放。
  static Future<void> play() async {
    if (!Accounts.main.isLogin) {
      SmartDialog.showToast('请先登录');
      return;
    }
    var folderId = mediaId;
    if (folderId == null) {
      folderId = await _selectFolder();
      if (folderId == null) return;
    }
    await _launch(folderId);
  }

  /// 长按：只改选中的收藏夹，不立即播放。
  static Future<void> configure() async {
    if (!Accounts.main.isLogin) {
      SmartDialog.showToast('请先登录');
      return;
    }
    await _selectFolder();
  }

  static Future<int?> _selectFolder() async {
    final res = await FavHttp.allFavFolders(Accounts.main.mid);
    if (res case Success(:final response)) {
      final list = response.list;
      if (list == null || list.isEmpty) {
        SmartDialog.showToast('没有可用的收藏夹');
        return null;
      }
      final context = Get.context;
      if (context == null || !context.mounted) return null;
      final current = mediaId;
      final folder = await showDialog<FavFolderInfo>(
        context: context,
        builder: (context) => AlertDialog(
          clipBehavior: Clip.hardEdge,
          title: const Text('选择一键听歌的收藏夹'),
          contentPadding: const EdgeInsets.only(top: 5, bottom: 18),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in list)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        item.id == current
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 20,
                      ),
                      title: Text(
                        '${item.title}  (${item.mediaCount})',
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.of(context).pop(item),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      if (folder == null) return null;
      await GStorage.setting.put(_mediaIdKey, folder.id);
      await GStorage.setting.put(_titleKey, folder.title);
      titleNotifier.value = folder.title;
      SmartDialog.showToast('已设置：${folder.title}');
      return folder.id;
    } else {
      res.toast();
      return null;
    }
  }

  static Future<void> _launch(int mediaId) async {
    SmartDialog.showLoading(msg: '正在读取收藏夹…');
    final items = <FavDetailItemModel>[];
    try {
      // 本地收藏夹页只加载首屏，一键听歌尽量把整个收藏夹读全，
      // 免得列表后半段的私密稿件又被 gRPC 分页吞掉。
      for (var pn = 1; pn <= _maxPages; pn++) {
        final res = await FavHttp.userFavFolderDetail(
          mediaId: mediaId,
          pn: pn,
          ps: _pageSize,
        );
        if (res case Success(:final response)) {
          items.addAll(response.medias ?? const <FavDetailItemModel>[]);
          if (response.hasMore != true) break;
        } else {
          if (pn == 1) {
            res.toast();
            return;
          }
          break;
        }
      }
    } finally {
      await SmartDialog.dismiss();
    }

    final playable = items
        .where((e) => e.type == 2 && e.id != null && e.ugc?.firstCid != null)
        .toList();
    if (playable.isEmpty) {
      SmartDialog.showToast('该收藏夹里没有可听的视频');
      return;
    }
    final first = playable.first;
    AudioPage.toAudioPage(
      itemType: 1,
      oid: first.id!,
      subId: [first.ugc!.firstCid!],
      id: mediaId,
      // MEDIA_LIST 下收藏夹的业务类型是 3（合集是 8）
      extraId: 3,
      from: PlaylistSource.MEDIA_LIST,
      playlist: buildFavAudioPlaylist(playable),
    );
  }
}

/// 「我的」页面动作区按钮：点击一键听歌，长按更换收藏夹。
/// 布局与页面里其它 _actionButton 保持一致（四个一行、末尾空位补齐）。
Widget oneKeyListenAction({required Color color}) {
  return Flexible(
    child: ValueListenableBuilder<String>(
      valueListenable: OneKeyListen.titleNotifier,
      builder: (context, selected, _) => Tooltip(
        // 提示正在显示时 message 变化不一定会重绘 overlay，换 key 强制刷新
        key: ValueKey('oneKeyListen:$selected'),
        message: selected.isEmpty
            ? '一键听歌 · 长按选择收藏夹'
            : '当前：$selected\n长按可更换收藏夹',
        child: InkWell(
          onTap: OneKeyListen.play,
          onLongPress: OneKeyListen.configure,
          borderRadius: BorderRadius.circular(12),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 80),
            child: AspectRatio(
              aspectRatio: 1,
              child: Column(
                spacing: 6,
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.headphones, color: color),
                  const Text('一键听歌', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
