// Nova Player — a modern, futuristic offline video player for Android.
// Single-file architecture: state management via ChangeNotifier + ValueNotifier
// (no external state packages, easy to split into modules later).
//
// See pubspec.yaml for dependencies and android_manifest_snippet.xml for perms.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ResumeStore.instance.init();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const NovaApp());
}

/* ───────────────────────────── DESIGN SYSTEM ───────────────────────────── */

class Nova {
  // Deep space background + neon cyan/violet accents (glassmorphism friendly).
  static const bg = Color(0xFF06070D);
  static const bgAlt = Color(0xFF0B0E1A);
  static const surface = Color(0x14FFFFFF);
  static const stroke = Color(0x1FFFFFFF);
  static const accent = Color(0xFF31E1F7);
  static const accent2 = Color(0xFF7B5CFF);
  static const text = Color(0xFFEAF0FF);
  static const muted = Color(0xFF8A93B2);

  static const glow = [
    BoxShadow(color: Color(0x5531E1F7), blurRadius: 24, spreadRadius: -6),
  ];

  static LinearGradient get accentGradient => const LinearGradient(
        colors: [accent, accent2],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  static ThemeData theme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        secondary: accent2,
        surface: bgAlt,
      ),
      textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme)
          .apply(bodyColor: text, displayColor: text),
      splashFactory: InkSparkle.splashFactory,
    );
  }
}

/// Frosted-glass container used across the whole app.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = EdgeInsets.zero,
    this.blur = 18,
    this.glow = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final double blur;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        boxShadow: glow ? Nova.glow : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: Nova.surface,
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Nova.stroke),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Animated aurora background — cheap, GPU friendly, sets the futuristic tone.
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child});
  final Widget child;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 18))
        ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Nova.bg)),
        AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            final t = _c.value * 2 * math.pi;
            return Positioned.fill(
              child: Stack(
                children: [
                  _blob(Alignment(math.cos(t) * .7, -.8 + math.sin(t) * .15),
                      Nova.accent2, 320),
                  _blob(Alignment(-.8 + math.sin(t) * .3, .9 - math.cos(t) * .2),
                      Nova.accent, 260),
                ],
              ),
            );
          },
        ),
        widget.child,
      ],
    );
  }

  Widget _blob(Alignment a, Color c, double size) => Align(
        alignment: a,
        child: IgnorePointer(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [c.withOpacity(.28), Colors.transparent],
              ),
            ),
          ),
        ),
      );
}

/* ───────────────────────────── DATA MODELS ───────────────────────────── */

class VideoItem {
  VideoItem({
    required this.id,
    required this.title,
    required this.folder,
    required this.duration,
    required this.width,
    required this.height,
    required this.modified,
    required this.asset,
  });

  final String id;
  final String title;
  final String folder;
  final Duration duration;
  final int width;
  final int height;
  final DateTime modified;
  final AssetEntity asset;

  String get resolutionLabel {
    final short = math.min(width, height);
    if (short >= 2000) return '4K';
    if (short >= 1400) return '2K';
    if (short >= 1000) return '1080p';
    if (short >= 700) return '720p';
    if (short >= 460) return '480p';
    return '${width}x$height';
  }

  Future<String?> filePath() async => (await asset.file)?.path;
  Future<Uint8List?> thumb() =>
      asset.thumbnailDataWithSize(const ThumbnailSize(480, 270), quality: 80);
}

class VideoFolder {
  VideoFolder(this.name, this.videos);
  final String name;
  final List<VideoItem> videos;
  Duration get total =>
      videos.fold(Duration.zero, (p, v) => p + v.duration);
}

/* ───────────────────────── RESUME POSITION STORE ───────────────────────── */

class ResumeStore {
  ResumeStore._();
  static final instance = ResumeStore._();
  late SharedPreferences _prefs;

  Future<void> init() async => _prefs = await SharedPreferences.getInstance();

  int positionMs(String id) => _prefs.getInt('resume_$id') ?? 0;

  Future<void> save(String id, Duration pos, Duration total) async {
    // Forget the position when nearly finished so it restarts next time.
    if (total.inSeconds > 0 && pos.inSeconds > total.inSeconds - 8) {
      await _prefs.remove('resume_$id');
      return;
    }
    if (pos.inSeconds < 5) return;
    await _prefs.setInt('resume_$id', pos.inMilliseconds);
  }

  double progress(String id, Duration total) {
    if (total.inMilliseconds == 0) return 0;
    return (positionMs(id) / total.inMilliseconds).clamp(0, 1);
  }
}

/* ───────────────────────── MEDIA LIBRARY (STATE) ───────────────────────── */

enum LibraryStatus { idle, loading, denied, ready, empty }

class MediaLibrary extends ChangeNotifier {
  LibraryStatus status = LibraryStatus.idle;
  List<VideoItem> videos = [];
  List<VideoFolder> folders = [];
  String query = '';

  static const _allowedExt = {'mp4', 'mkv', 'avi', 'webm', 'mov', '3gp', 'm4v'};

  List<VideoItem> get filtered {
    if (query.trim().isEmpty) return videos;
    final q = query.toLowerCase();
    return videos.where((v) => v.title.toLowerCase().contains(q)).toList();
  }

  void search(String v) {
    query = v;
    notifyListeners();
  }

  Future<void> load({bool force = false}) async {
    if (status == LibraryStatus.loading) return;
    status = LibraryStatus.loading;
    notifyListeners();

    if (!await _ensurePermission()) {
      status = LibraryStatus.denied;
      notifyListeners();
      return;
    }

    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      onlyAll: true,
    );

    final found = <VideoItem>[];
    if (albums.isNotEmpty) {
      final all = albums.first;
      final count = await all.assetCountAsync;
      const page = 200;
      for (var i = 0; i < count; i += page) {
        final batch = await all.getAssetListRange(start: i, end: i + page);
        for (final a in batch) {
          final name = a.title ?? 'Video';
          final ext = name.contains('.')
              ? name.split('.').last.toLowerCase()
              : '';
          if (ext.isNotEmpty && !_allowedExt.contains(ext)) continue;
          found.add(VideoItem(
            id: a.id,
            title: name,
            folder: _folderOf(a),
            duration: Duration(seconds: a.duration),
            width: a.width,
            height: a.height,
            modified: a.modifiedDateTime,
            asset: a,
          ));
        }
      }
    }

    found.sort((a, b) => b.modified.compareTo(a.modified));
    videos = found;
    folders = _group(found);
    status = found.isEmpty ? LibraryStatus.empty : LibraryStatus.ready;
    notifyListeners();
  }

  String _folderOf(AssetEntity a) {
    final rel = a.relativePath ?? '';
    final parts = rel.split('/').where((e) => e.isNotEmpty).toList();
    return parts.isEmpty ? 'Internal storage' : parts.last;
  }

  List<VideoFolder> _group(List<VideoItem> items) {
    final map = <String, List<VideoItem>>{};
    for (final v in items) {
      map.putIfAbsent(v.folder, () => []).add(v);
    }
    final list = map.entries.map((e) => VideoFolder(e.key, e.value)).toList();
    list.sort((a, b) => b.videos.length.compareTo(a.videos.length));
    return list;
  }

  Future<bool> _ensurePermission() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (ps.isAuth || ps.hasAccess) return true;
    // Fallback for older Android / broad storage access.
    final video = await Permission.videos.request();
    if (video.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }
}

/// Tiny inherited-widget so any widget can reach the library.
class LibraryScope extends InheritedNotifier<MediaLibrary> {
  const LibraryScope({super.key, required MediaLibrary library, required super.child})
      : super(notifier: library);

  static MediaLibrary of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<LibraryScope>()!.notifier!;
}

/* ─────────────────────────────── APP SHELL ─────────────────────────────── */

class NovaApp extends StatefulWidget {
  const NovaApp({super.key});
  @override
  State<NovaApp> createState() => _NovaAppState();
}

class _NovaAppState extends State<NovaApp> {
  final library = MediaLibrary();

  @override
  void initState() {
    super.initState();
    library.load();
  }

  @override
  void dispose() {
    library.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LibraryScope(
      library: library,
      child: MaterialApp(
        title: 'Nova Player',
        debugShowCheckedModeBanner: false,
        theme: Nova.theme(),
        home: const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);

    return Scaffold(
      extendBody: true,
      backgroundColor: Colors.transparent,
      body: AuroraBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _Header(onRefresh: () => lib.load(force: true)),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  switchInCurve: Curves.easeOutCubic,
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, .04),
                        end: Offset.zero,
                      ).animate(anim),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(_tab),
                    child: switch (_tab) {
                      0 => const VideosTab(),
                      1 => const FoldersTab(),
                      _ => const RecentTab(),
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NovaNavBar(
        index: _tab,
        onChanged: (i) => setState(() => _tab = i),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onRefresh});
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  gradient: Nova.accentGradient,
                  borderRadius: BorderRadius.circular(11),
                  boxShadow: Nova.glow,
                ),
                child: const Icon(Icons.play_arrow_rounded,
                    size: 22, color: Colors.black),
              ),
              const SizedBox(width: 12),
              Text('NOVA',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 4,
                  )),
              const Spacer(),
              IconButton(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh_rounded, color: Nova.muted),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GlassCard(
            radius: 16,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: TextField(
              onChanged: lib.search,
              style: const TextStyle(fontSize: 14),
              cursorColor: Nova.accent,
              decoration: const InputDecoration(
                border: InputBorder.none,
                hintText: 'Search your library',
                hintStyle: TextStyle(color: Nova.muted, fontSize: 14),
                icon: Icon(Icons.search_rounded, color: Nova.muted, size: 20),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class NovaNavBar extends StatelessWidget {
  const NovaNavBar({super.key, required this.index, required this.onChanged});
  final int index;
  final ValueChanged<int> onChanged;

  static const _items = [
    (Icons.movie_filter_rounded, 'Videos'),
    (Icons.folder_special_rounded, 'Folders'),
    (Icons.history_rounded, 'Resume'),
  ];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 22, 22),
      child: GlassCard(
        radius: 26,
        glow: true,
        padding: const EdgeInsets.all(6),
        child: Row(
          children: List.generate(_items.length, (i) {
            final selected = i == index;
            return Expanded(
              child: GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onChanged(i);
                },
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    gradient: selected ? Nova.accentGradient : null,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_items[i].$1,
                          size: 20,
                          color: selected ? Colors.black : Nova.muted),
                      const SizedBox(height: 3),
                      Text(
                        _items[i].$2,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: selected ? Colors.black : Nova.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/* ───────────────────────────────── TABS ───────────────────────────────── */

class _StateView extends StatelessWidget {
  const _StateView({required this.icon, required this.title, this.action});
  final IconData icon;
  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: Nova.muted),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Nova.muted)),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      );
}

class VideosTab extends StatelessWidget {
  const VideosTab({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);

    switch (lib.status) {
      case LibraryStatus.loading:
      case LibraryStatus.idle:
        return const Center(
            child: CircularProgressIndicator(color: Nova.accent));
      case LibraryStatus.denied:
        return _StateView(
          icon: Icons.lock_outline_rounded,
          title: 'Storage access is required\nto scan your videos.',
          action: FilledButton(
            onPressed: () => openAppSettings(),
            child: const Text('Grant permission'),
          ),
        );
      case LibraryStatus.empty:
        return const _StateView(
            icon: Icons.videocam_off_rounded, title: 'No videos found.');
      case LibraryStatus.ready:
        final items = lib.filtered;
        return RefreshIndicator(
          color: Nova.accent,
          backgroundColor: Nova.bgAlt,
          onRefresh: () => lib.load(force: true),
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 130),
            physics: const AlwaysScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisExtent(),
            itemCount: items.length,
            itemBuilder: (_, i) => VideoCard(
              video: items[i],
              playlist: items,
              index: i,
            ),
          ),
        );
    }
  }
}

/// Responsive grid: 1 wide card per row on phones, 2 on tablets.
class SliverGridDelegateWithFixedCrossAxisExtent
    extends SliverGridDelegateWithMaxCrossAxisExtent {
  const SliverGridDelegateWithFixedCrossAxisExtent()
      : super(
          maxCrossAxisExtent: 420,
          mainAxisExtent: 216,
          crossAxisSpacing: 14,
          mainAxisSpacing: 14,
        );
}

class FoldersTab extends StatelessWidget {
  const FoldersTab({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    if (lib.status != LibraryStatus.ready) return const VideosTab();

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 130),
      itemCount: lib.folders.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) {
        final f = lib.folders[i];
        return GestureDetector(
          onTap: () => Navigator.of(context).push(_fadeRoute(FolderPage(folder: f))),
          child: GlassCard(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: Nova.accentGradient,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.folder_rounded,
                      color: Colors.black, size: 24),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(f.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 15)),
                      const SizedBox(height: 3),
                      Text('${f.videos.length} videos · ${fmt(f.total)}',
                          style: const TextStyle(
                              color: Nova.muted, fontSize: 12)),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Nova.muted),
              ],
            ),
          ),
        );
      },
    );
  }
}

class FolderPage extends StatelessWidget {
  const FolderPage({super.key, required this.folder});
  final VideoFolder folder;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AuroraBackground(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: Text(folder.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 30),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisExtent(),
                  itemCount: folder.videos.length,
                  itemBuilder: (_, i) => VideoCard(
                    video: folder.videos[i],
                    playlist: folder.videos,
                    index: i,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RecentTab extends StatelessWidget {
  const RecentTab({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = LibraryScope.of(context);
    final items = lib.videos
        .where((v) => ResumeStore.instance.positionMs(v.id) > 0)
        .toList();

    if (items.isEmpty) {
      return const _StateView(
          icon: Icons.bookmark_border_rounded,
          title: 'Nothing to resume yet.\nStart watching something.');
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 130),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisExtent(),
      itemCount: items.length,
      itemBuilder: (_, i) =>
          VideoCard(video: items[i], playlist: items, index: i),
    );
  }
}

/* ───────────────────────────── VIDEO CARD ───────────────────────────── */

class VideoCard extends StatefulWidget {
  const VideoCard({
    super.key,
    required this.video,
    required this.playlist,
    required this.index,
  });

  final VideoItem video;
  final List<VideoItem> playlist;
  final int index;

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  Uint8List? _thumb;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    widget.video.thumb().then((d) {
      if (mounted) setState(() => _thumb = d);
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.video;
    final progress = ResumeStore.instance.progress(v.id, v.duration);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: () async {
        HapticFeedback.lightImpact();
        await Navigator.of(context).push(_fadeRoute(PlayerPage(
          playlist: widget.playlist,
          startIndex: widget.index,
        )));
        if (mounted) setState(() {});
      },
      child: AnimatedScale(
        scale: _pressed ? .97 : 1,
        duration: const Duration(milliseconds: 140),
        child: GlassCard(
          radius: 22,
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_thumb != null)
                        Image.memory(_thumb!, fit: BoxFit.cover)
                      else
                        const ColoredBox(color: Nova.bgAlt),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Color(0xCC000000)],
                          ),
                        ),
                      ),
                      Positioned(
                        right: 8,
                        top: 8,
                        child: _chip(v.resolutionLabel),
                      ),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: _chip(fmt(v.duration)),
                      ),
                      Center(
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black.withOpacity(.35),
                            border: Border.all(color: Nova.stroke),
                          ),
                          child: const Icon(Icons.play_arrow_rounded,
                              color: Nova.accent),
                        ),
                      ),
                      if (progress > 0)
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            valueColor:
                                const AlwaysStoppedAnimation(Nova.accent),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(v.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14)),
              const SizedBox(height: 2),
              Text('${v.folder} · ${v.width}x${v.height}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Nova.muted, fontSize: 11.5)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(.55),
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: Nova.stroke),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 10.5, color: Nova.text)),
      );
}

/* ─────────────────────────────── PLAYER ─────────────────────────────── */

enum FitMode { fit, stretch, zoom, crop }

extension on FitMode {
  String get label => switch (this) {
        FitMode.fit => 'Fit',
        FitMode.stretch => 'Stretch',
        FitMode.zoom => 'Zoom',
        FitMode.crop => 'Crop',
      };
  BoxFit get boxFit => switch (this) {
        FitMode.fit => BoxFit.contain,
        FitMode.stretch => BoxFit.fill,
        FitMode.zoom => BoxFit.cover,
        FitMode.crop => BoxFit.fitWidth,
      };
}

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.playlist, required this.startIndex});
  final List<VideoItem> playlist;
  final int startIndex;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  VideoPlayerController? _ctrl;
  late int _index = widget.startIndex;

  bool _ready = false;
  bool _controlsVisible = true;
  Timer? _hideTimer;
  Timer? _saveTimer;

  FitMode _fit = FitMode.fit;
  double _speed = 1.0;

  // Gesture HUD state
  String? _hud;            // text shown in the center pill
  IconData? _hudIcon;
  double? _hudValue;       // 0..1 bar, null = no bar
  Timer? _hudTimer;

  double _volume = .5;
  double _brightness = .5;
  Duration? _seekPreview;
  Duration _dragStart = Duration.zero;

  VideoItem get current => widget.playlist[_index];

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
      DeviceOrientation.portraitUp,
    ]);
    WakelockPlus.enable();
    _initSystemLevels();
    _open(_index);
  }

  Future<void> _initSystemLevels() async {
    try {
      VolumeController().showSystemUI = false;
      _volume = await VolumeController().getVolume();
      _brightness = await ScreenBrightness().current;
      if (mounted) setState(() {});
    } catch (_) {/* emulator / unsupported */}
  }

  Future<void> _open(int index) async {
    _saveProgress();
    await _ctrl?.dispose();
    setState(() {
      _ready = false;
      _index = index;
    });

    final item = widget.playlist[index];
    final path = await item.filePath();
    if (path == null) return;

    final c = VideoPlayerController.file(File(path));
    _ctrl = c;
    await c.initialize();
    await c.setPlaybackSpeed(_speed);

    final resume = ResumeStore.instance.positionMs(item.id);
    if (resume > 0) {
      await c.seekTo(Duration(milliseconds: resume));
      _flashHud('Resumed at ${fmt(Duration(milliseconds: resume))}',
          Icons.history_rounded);
    }
    await c.play();

    c.addListener(_onTick);
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveProgress());

    if (mounted) setState(() => _ready = true);
    _scheduleHide();
  }

  void _onTick() {
    if (!mounted) return;
    final c = _ctrl!;
    if (c.value.position >= c.value.duration &&
        c.value.duration > Duration.zero &&
        !c.value.isPlaying) {
      _next();
      return;
    }
    setState(() {});
  }

  void _saveProgress() {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    ResumeStore.instance.save(current.id, c.value.position, c.value.duration);
  }

  void _next() {
    if (_index + 1 < widget.playlist.length) {
      _open(_index + 1);
    } else {
      Navigator.pop(context);
    }
  }

  void _prev() {
    if (_index > 0) _open(_index - 1);
  }

  @override
  void dispose() {
    _saveProgress();
    _hideTimer?.cancel();
    _hudTimer?.cancel();
    _saveTimer?.cancel();
    _ctrl?.removeListener(_onTick);
    _ctrl?.dispose();
    WakelockPlus.disable();
    ScreenBrightness().resetScreenBrightness();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  /* ── controls visibility ── */

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  /* ── HUD ── */

  void _flashHud(String text, IconData icon, {double? value}) {
    _hudTimer?.cancel();
    setState(() {
      _hud = text;
      _hudIcon = icon;
      _hudValue = value;
    });
    _hudTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _hud = null);
    });
  }

  /* ── gestures ── */

  void _onVerticalDrag(DragUpdateDetails d, double width) {
    final left = d.localPosition.dx < width / 2;
    final delta = -d.delta.dy / 320; // full swipe ≈ full range
    if (left) {
      _brightness = (_brightness + delta).clamp(0.0, 1.0);
      ScreenBrightness().setScreenBrightness(_brightness);
      _flashHud('${(_brightness * 100).round()}%',
          _brightness < .35
              ? Icons.brightness_low_rounded
              : Icons.brightness_high_rounded,
          value: _brightness);
    } else {
      _volume = (_volume + delta).clamp(0.0, 1.0);
      VolumeController().setVolume(_volume);
      _flashHud('${(_volume * 100).round()}%',
          _volume == 0
              ? Icons.volume_off_rounded
              : _volume < .5
                  ? Icons.volume_down_rounded
                  : Icons.volume_up_rounded,
          value: _volume);
    }
  }

  void _onHorizontalStart(DragStartDetails _) {
    _dragStart = _ctrl?.value.position ?? Duration.zero;
    _seekPreview = _dragStart;
  }

  void _onHorizontalUpdate(DragUpdateDetails d, double width) {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    // 1 screen width of swipe = 90 seconds of seek.
    final seconds = (d.primaryDelta ?? 0) / width * 90;
    final target = (_seekPreview ?? _dragStart) +
        Duration(milliseconds: (seconds * 1000).round());
    setState(() {
      _seekPreview = Duration(
        milliseconds:
            target.inMilliseconds.clamp(0, c.value.duration.inMilliseconds),
      );
    });
  }

  void _onHorizontalEnd(DragEndDetails _) {
    final p = _seekPreview;
    if (p != null) _ctrl?.seekTo(p);
    setState(() => _seekPreview = null);
  }

  void _onDoubleTapAt(Offset pos, Size size) {
    final c = _ctrl;
    if (c == null || !c.value.isInitialized) return;
    final third = size.width / 3;
    HapticFeedback.mediumImpact();
    if (pos.dx < third) {
      c.seekTo(c.value.position - const Duration(seconds: 10));
      _flashHud('-10s', Icons.fast_rewind_rounded);
    } else if (pos.dx > third * 2) {
      c.seekTo(c.value.position + const Duration(seconds: 10));
      _flashHud('+10s', Icons.fast_forward_rounded);
    } else {
      _togglePlay();
    }
  }

  void _togglePlay() {
    final c = _ctrl;
    if (c == null) return;
    if (c.value.isPlaying) {
      c.pause();
      _flashHud('Paused', Icons.pause_rounded);
    } else {
      c.play();
      _flashHud('Playing', Icons.play_arrow_rounded);
      _scheduleHide();
    }
    setState(() {});
  }

  Future<void> _pickSpeed() async {
    final v = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _SheetOptions<double>(
        title: 'Playback speed',
        options: const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0],
        selected: _speed,
        label: (s) => '${s}x',
      ),
    );
    if (v != null) {
      _speed = v;
      await _ctrl?.setPlaybackSpeed(v);
      _flashHud('${v}x', Icons.speed_rounded);
      setState(() {});
    }
  }

  void _cycleFit() {
    setState(() {
      _fit = FitMode.values[(_fit.index + 1) % FitMode.values.length];
    });
    _flashHud(_fit.label, Icons.aspect_ratio_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    final size = MediaQuery.sizeOf(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggleControls,
        onDoubleTapDown: (d) => _onDoubleTapAt(d.localPosition, size),
        onDoubleTap: () {},
        onVerticalDragUpdate: (d) => _onVerticalDrag(d, size.width),
        onHorizontalDragStart: _onHorizontalStart,
        onHorizontalDragUpdate: (d) => _onHorizontalUpdate(d, size.width),
        onHorizontalDragEnd: _onHorizontalEnd,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video surface
            if (_ready && c != null && c.value.isInitialized)
              FittedBox(
                fit: _fit.boxFit,
                clipBehavior: Clip.hardEdge,
                child: SizedBox(
                  width: c.value.size.width,
                  height: c.value.size.height,
                  child: VideoPlayer(c),
                ),
              )
            else
              const Center(
                  child: CircularProgressIndicator(color: Nova.accent)),

            // Gesture HUD
            if (_hud != null)
              Center(
                child: GlassCard(
                  radius: 18,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_hudIcon, color: Nova.accent, size: 26),
                      const SizedBox(height: 6),
                      Text(_hud!,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      if (_hudValue != null) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 110,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: _hudValue,
                              minHeight: 4,
                              backgroundColor: Colors.white24,
                              valueColor:
                                  const AlwaysStoppedAnimation(Nova.accent),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

            // Seek preview (timestamp while horizontally dragging)
            if (_seekPreview != null && c != null)
              Center(
                child: GlassCard(
                  radius: 16,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  child: Text(
                    '${fmt(_seekPreview!)} / ${fmt(c.value.duration)}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),

            // Controls overlay
            AnimatedOpacity(
              opacity: _controlsVisible ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: IgnorePointer(
                ignoring: !_controlsVisible,
                child: _ControlsOverlay(
                  title: current.title,
                  controller: c,
                  fitLabel: _fit.label,
                  speed: _speed,
                  onBack: () => Navigator.pop(context),
                  onPlayPause: _togglePlay,
                  onNext: _next,
                  onPrev: _prev,
                  onFit: _cycleFit,
                  onSpeed: _pickSpeed,
                  onSeek: (d) => c?.seekTo(d),
                  onInteract: _scheduleHide,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.title,
    required this.controller,
    required this.fitLabel,
    required this.speed,
    required this.onBack,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrev,
    required this.onFit,
    required this.onSpeed,
    required this.onSeek,
    required this.onInteract,
  });

  final String title;
  final VideoPlayerController? controller;
  final String fitLabel;
  final double speed;
  final VoidCallback onBack, onPlayPause, onNext, onPrev, onFit, onSpeed, onInteract;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) {
    final v = controller?.value;
    final pos = v?.position ?? Duration.zero;
    final dur = v?.duration ?? Duration.zero;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Colors.transparent, Color(0xCC000000)],
          stops: [0, .45, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded)),
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                TextButton(
                  onPressed: () {
                    onInteract();
                    onFit();
                  },
                  child: Text(fitLabel,
                      style: const TextStyle(color: Nova.accent)),
                ),
                TextButton(
                  onPressed: () {
                    onInteract();
                    onSpeed();
                  },
                  child: Text('${speed}x',
                      style: const TextStyle(color: Nova.accent)),
                ),
              ],
            ),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  iconSize: 34,
                  onPressed: onPrev,
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
                const SizedBox(width: 22),
                GestureDetector(
                  onTap: onPlayPause,
                  child: Container(
                    width: 68,
                    height: 68,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: Nova.accentGradient,
                      boxShadow: Nova.glow,
                    ),
                    child: Icon(
                      (v?.isPlaying ?? false)
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      size: 36,
                      color: Colors.black,
                    ),
                  ),
                ),
                const SizedBox(width: 22),
                IconButton(
                  iconSize: 34,
                  onPressed: onNext,
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              ],
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Row(
                children: [
                  Text(fmt(pos),
                      style: const TextStyle(fontSize: 12, color: Nova.text)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        activeTrackColor: Nova.accent,
                        inactiveTrackColor: Colors.white24,
                        thumbColor: Nova.accent,
                        overlayShape:
                            const RoundSliderOverlayShape(overlayRadius: 14),
                        thumbShape:
                            const RoundSliderThumbShape(enabledThumbRadius: 7),
                      ),
                      child: Slider(
                        min: 0,
                        max: math.max(dur.inMilliseconds.toDouble(), 1),
                        value: pos.inMilliseconds
                            .clamp(0, math.max(dur.inMilliseconds, 1))
                            .toDouble(),
                        onChanged: (val) {
                          onInteract();
                          onSeek(Duration(milliseconds: val.round()));
                        },
                      ),
                    ),
                  ),
                  Text(fmt(dur),
                      style: const TextStyle(fontSize: 12, color: Nova.text)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetOptions<T> extends StatelessWidget {
  const _SheetOptions({
    required this.title,
    required this.options,
    required this.selected,
    required this.label,
  });

  final String title;
  final List<T> options;
  final T selected;
  final String Function(T) label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: GlassCard(
        radius: 24,
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title,
                style: const TextStyle(
                    fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            ...options.map((o) {
              final sel = o == selected;
              return ListTile(
                dense: true,
                onTap: () => Navigator.pop(context, o),
                title: Text(label(o),
                    style: TextStyle(
                        color: sel ? Nova.accent : Nova.text,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w400)),
                trailing: sel
                    ? const Icon(Icons.check_rounded, color: Nova.accent)
                    : null,
              );
            }),
          ],
        ),
      ),
    );
  }
}

/* ───────────────────────────────  UTILS  ─────────────────────────────── */

String fmt(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

Route<T> _fadeRoute<T>(Widget page) => PageRouteBuilder<T>(
      transitionDuration: const Duration(milliseconds: 340),
      reverseTransitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (_, a, __) => page,
      transitionsBuilder: (_, a, __, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween(begin: .96, end: 1.0)
              .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
          child: child,
        ),
      ),
    );
