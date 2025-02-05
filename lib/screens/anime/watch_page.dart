// ignore_for_file: invalid_use_of_protected_member
import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:math' show max;
import 'package:anymex/controllers/service_handler/service_handler.dart';
import 'package:anymex/models/Offline/Hive/video.dart' as model;
import 'package:anymex/core/Search/getVideo.dart';
import 'package:anymex/constants/contants.dart';
import 'package:anymex/controllers/offline/offline_storage_controller.dart';
import 'package:anymex/controllers/settings/adaptors/player/player_adaptor.dart';
import 'package:anymex/controllers/settings/methods.dart';
import 'package:anymex/controllers/settings/settings.dart';
import 'package:anymex/controllers/source/source_controller.dart';
import 'package:anymex/models/Media/media.dart' as anymex;
import 'package:anymex/models/Offline/Hive/episode.dart';
import 'package:anymex/screens/anime/widgets/episode_watch_screen.dart';
import 'package:anymex/screens/anime/widgets/media_indicator.dart';
import 'package:anymex/screens/anime/widgets/video_slider.dart';
import 'package:anymex/screens/settings/sub_settings/settings_player.dart';
import 'package:anymex/utils/string_extensions.dart';
import 'package:anymex/widgets/common/checkmark_tile.dart';
import 'package:anymex/widgets/common/glow.dart';
import 'package:anymex/widgets/helper/platform_builder.dart';
import 'package:anymex/widgets/helper/tv_wrapper.dart';
import 'package:anymex/widgets/minor_widgets/custom_button.dart';
import 'package:anymex/widgets/minor_widgets/custom_text.dart';
import 'package:anymex/widgets/minor_widgets/custom_textspan.dart';
import 'package:anymex/widgets/non_widgets/snackbar.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:iconsax/iconsax.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:window_manager/window_manager.dart';

class WatchPage extends StatefulWidget {
  final model.Video episodeSrc;
  final Episode currentEpisode;
  final List<Episode> episodeList;
  final anymex.Media anilistData;
  final List<model.Video> episodeTracks;
  const WatchPage(
      {super.key,
      required this.episodeSrc,
      required this.episodeList,
      required this.anilistData,
      required this.currentEpisode,
      required this.episodeTracks});

  @override
  State<WatchPage> createState() => _WatchPageState();
}

class _WatchPageState extends State<WatchPage> with TickerProviderStateMixin {
  late Rx<model.Video> episode;
  late Rx<Episode> currentEpisode;
  late RxList<model.Video> episodeTracks;
  late RxList<Episode> episodeList;
  late Rx<anymex.Media> anilistData;
  RxList<model.Track?> subtitles = <model.Track>[].obs;

  // Library
  final offlineStorage = Get.find<OfflineStorageController>();

  // Player Related Stuff
  late Player player;
  late VideoController playerController;
  final isPlaying = true.obs;
  final currentPosition = const Duration(milliseconds: 0).obs;
  final episodeDuration = const Duration(minutes: 24).obs;
  final formattedTime = "00:00".obs;
  final formattedDuration = "24:00".obs;
  final showControls = false.obs;
  final isBuffering = true.obs;
  final bufferred = const Duration(milliseconds: 0).obs;
  final playbackSpeed = 1.0.obs;
  final isFullscreen = false.obs;
  final selectedSubIndex = 0.obs;
  final selectedAudioIndex = 0.obs;
  final settings = Get.find<Settings>();
  final RxString resizeMode = "Cover".obs;
  late PlayerSettings playerSettings;

  // Player Seek Related
  final RxBool _volumeIndicator = false.obs;
  final RxBool _brightnessIndicator = false.obs;
  Timer? _volumeTimer;
  Timer? _brightnessTimer;
  var _volumeInterceptEventStream = false;
  final RxDouble _volumeValue = 0.0.obs;
  final RxDouble _brightnessValue = 0.0.obs;
  late AnimationController _leftAnimationController;
  late AnimationController _rightAnimationController;
  RxInt skipDuration = 10.obs;
  final isLocked = false.obs;
  RxList<String> subtitleText = [''].obs;
  RxInt subtitleDelay = 0.obs;

  final doubleTapLabel = 0.obs;
  Timer? doubleTapTimeout;
  final isLeftSide = false.obs;
  Timer? _hideControlsTimer;
  final pressed2x = false.obs;

  //
  final sourceController = Get.find<SourceController>();
  final serviceHandler = Get.find<ServiceHandler>();
  final isEpisodeDialogOpen = false.obs;
  late bool isLoggedIn;
  final leftOriented = true.obs;
  final isMobile = Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    if (!settings.isTV.value) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    }
    _leftAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _rightAnimationController = AnimationController(
      duration: const Duration(milliseconds: 1000),
      vsync: this,
    );
    _initRxVariables();
    _initHiveVariables();
    _initPlayer(true);
    _attachListeners();
    if (isMobile) {
      _handleVolumeAndBrightness();
    }
    if (widget.currentEpisode.number.toInt() > 1) {
      final episodeNum = widget.currentEpisode.number.toInt() - 1;
      trackAnilistAndLocal(episodeNum, widget.currentEpisode);
    }
  }

  Future<void> trackEpisode(
      Duration position, Duration duration, Episode currentEpisode) async {
    final percentageCompletion =
        (position.inMilliseconds / episodeDuration.value.inMilliseconds) * 100;

    bool crossed = percentageCompletion >= 90;
    final epNum = crossed
        ? currentEpisode.number.toInt()
        : currentEpisode.number.toInt() - 1;
    await trackAnilistAndLocal(epNum, currentEpisode);
  }

  Future<void> trackAnilistAndLocal(int epNum, Episode currentEpisode) async {
    final temp = serviceHandler.onlineService.animeList
        .firstWhereOrNull((e) => e.id == anilistData.value.id);
    if (currentEpisode.number.toInt() > ((temp?.episodeCount) ?? '1').toInt()) {
      await serviceHandler.updateListEntry(
          listId: anilistData.value.id, progress: epNum, isAnime: true);
      serviceHandler.onlineService
          .setCurrentMedia(anilistData.value.id.toString());
      offlineStorage.addOrUpdateAnime(
          widget.anilistData, widget.episodeList, currentEpisode);
    }
    offlineStorage.addOrUpdateWatchedEpisode(
        widget.anilistData.id, currentEpisode);
  }

  void _initPlayer(bool firstTime) {
    Episode? savedEpisode = offlineStorage.getWatchedEpisode(
        widget.anilistData.id, currentEpisode.value.number);
    int startTimeMilliseconds = savedEpisode?.timeStampInMilliseconds ?? 0;
    if (firstTime) {
      player = Player(
          configuration:
              const PlayerConfiguration(bufferSize: 1024 * 1024 * 64));
      playerController = VideoController(player);
    } else {
      currentPosition.value = Duration.zero;
      episodeDuration.value = Duration.zero;
      bufferred.value = Duration.zero;
    }
    toggleControls();
    player.open(Media(episode.value.url,
        start: Duration(milliseconds: startTimeMilliseconds)));
  }

  void _attachListeners() {
    player.stream.playing.listen((e) {
      isPlaying.value = e;
    });
    player.stream.position.listen((e) {
      currentPosition.value = e;
      currentEpisode.value.timeStampInMilliseconds = e.inMilliseconds;
      formattedTime.value = formatDuration(e);
      if (e.inSeconds == episodeDuration.value.inSeconds) {
        if (episodeDuration.value.inMinutes >= 1) {
          fetchEpisode(false);
        }
      }
    });
    player.stream.duration.listen((e) {
      episodeDuration.value = e;
      currentEpisode.value.durationInMilliseconds = e.inMilliseconds;
      formattedDuration.value = formatDuration(e);
    });
    player.stream.buffering.listen((e) {
      isBuffering.value = e;
    });
    player.stream.buffer.listen((e) {
      bufferred.value = e;
    });
    player.stream.rate.listen((e) {
      playbackSpeed.value = e;
    });
    player.stream.subtitle.listen((e) {
      subtitleText.value = e;
    });
  }

  void _initRxVariables() {
    episode = Rx<model.Video>(widget.episodeSrc);
    episodeList = RxList<Episode>(widget.episodeList);
    anilistData = Rx<anymex.Media>(widget.anilistData);
    currentEpisode = Rx<Episode>(widget.currentEpisode);
    currentEpisode.value.source = sourceController.activeSource.value!.name;
    episodeTracks = RxList<model.Video>(widget.episodeTracks);
    currentEpisode.value.currentTrack = episode.value;
    currentEpisode.value.videoTracks = episodeTracks;
    _initSubs();
  }

  void _initSubs() {
    final List<String> labels = [];

    for (var e in episodeTracks) {
      final subs = e.subtitles;
      if (subs != null) {
        for (var s in subs) {
          if (!labels.contains(s.label)) {
            subtitles.add(s);
            labels.add(s.label ?? '');
          }
        }
      }
    }
  }

  void _initHiveVariables() {
    playerSettings = settings.playerSettings.value;
    resizeMode.value = settings.resizeMode;
    isLoggedIn = serviceHandler.isLoggedIn.value;
    skipDuration.value = settings.seekDuration;
  }

  String formatDuration(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '$hours:$minutes:$seconds'
        : '$minutes:$seconds';
  }

  String extractQuality(String quality) {
    final extractedQuality =
        quality.split(" ").firstWhere((e) => e.contains("p"));
    return extractedQuality;
  }

  Episode? navEpisode(bool prev) {
    if (prev) {
      final episode = episodeList.firstWhereOrNull((e) =>
          e.number == (currentEpisode.value.number.toInt() - 1).toString());
      print("Found Episode: ${episode?.title ?? ''}");
      return episode;
    } else {
      final episode = episodeList.firstWhereOrNull((e) =>
          e.number == (currentEpisode.value.number.toInt() + 1).toString());
      print("Found Episode: ${episode?.title ?? ''}");
      return episode;
    }
  }

  Future<void> fetchEpisode(bool prev) async {
    log("Envoked FetchEpisode");
    trackEpisode(
        currentPosition.value, episodeDuration.value, currentEpisode.value);
    // Put it into Loading State
    setState(() {
      player.open(Media(''));
    });
    final episodeToNav = navEpisode(prev);
    if (episodeToNav != null) {
      currentEpisode.value = episodeToNav;
    }
    final video = await getVideo(
        source: sourceController.activeSource.value!, url: episodeToNav!.link!);
    final preferredStream = video.firstWhere(
      (e) => e.quality == episode.value.quality,
      orElse: () {
        snackBar("Preferred Stream Not Found, Selecting ${video[0].quality}");
        return video[0];
      },
    );

    episode.value = preferredStream;
    episodeTracks.value = video;
    currentEpisode.value.currentTrack = preferredStream;
    currentEpisode.value.videoTracks = video;
    _initPlayer(false);
    _initSubs();
  }

  Future<void> setVolume(double value) async {
    try {
      VolumeController().setVolume(value);
    } catch (_) {}
    _volumeValue.value = value;
    _volumeIndicator.value = true;
    _volumeInterceptEventStream = true;
    _volumeTimer?.cancel();
    _volumeTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) {
        _volumeIndicator.value = false;
        _volumeInterceptEventStream = false;
      }
    });
  }

  Future<void> setBrightness(double value) async {
    try {
      await ScreenBrightness().setScreenBrightness(value);
    } catch (_) {}
    setState(() {
      _brightnessIndicator.value = true;
      _brightnessTimer?.cancel();
      _brightnessTimer = Timer(const Duration(milliseconds: 200), () {
        if (mounted) {
          _brightnessIndicator.value = false;
        }
      });
    });
  }

  void _handleVolumeAndBrightness() {
    Future.microtask(() async {
      try {
        VolumeController().showSystemUI = false;
        _volumeValue.value = await VolumeController().getVolume();
        VolumeController().listener((value) {
          if (mounted && !_volumeInterceptEventStream) {
            _volumeValue.value = value;
          }
        });
      } catch (_) {}
    });
    Future.microtask(() async {
      try {
        _brightnessValue.value = await ScreenBrightness().current;
        ScreenBrightness().onCurrentBrightnessChanged.listen((value) {
          if (mounted) {
            _brightnessValue.value = value;
          }
        });
      } catch (_) {}
    });
  }

  void _handleDoubleTap(TapDownDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final tapPosition = details.globalPosition;
    final isLeft = tapPosition.dx < screenWidth / 2;
    _skipSegments(isLeft);
  }

  void _skipSegments(bool isLeft) {
    player.pause();
    if (isLeftSide.value != isLeft) {
      doubleTapLabel.value = 0;
      skipDuration.value = 0;
    }
    isLeftSide.value = isLeft;
    doubleTapLabel.value += 10;
    skipDuration.value += 10;
    if (isLeft) {
      final duration = Duration(
        seconds: max(0, currentPosition.value.inSeconds - skipDuration.value),
      );
      formattedTime.value = formatDuration(duration);
    } else {
      final dur = Duration(
        seconds: currentPosition.value.inSeconds + skipDuration.value,
      );
      formattedTime.value = formatDuration(dur);
    }
    isLeft
        ? _leftAnimationController.forward(from: 0)
        : _rightAnimationController.forward(from: 0);

    doubleTapTimeout?.cancel();

    doubleTapTimeout = Timer(const Duration(milliseconds: 1000), () {
      if (currentPosition.value == const Duration(seconds: 0)) return;
      if (isLeft) {
        final duration = Duration(
          seconds: max(0, currentPosition.value.inSeconds - skipDuration.value),
        );
        player.seek(duration);
      } else {
        final dur = Duration(
          seconds: currentPosition.value.inSeconds + skipDuration.value,
        );
        player.seek(dur);
      }
      _leftAnimationController.stop();
      _rightAnimationController.stop();
      doubleTapLabel.value = 0;
      skipDuration.value = 0;
      player.play();
    });
  }

  void toggleControls({bool? val}) {
    showControls.value = val ?? !showControls.value;

    if (showControls.value && isPlaying.value) {
      _hideControlsTimer?.cancel();

      _hideControlsTimer = Timer(const Duration(seconds: 5), () {
        showControls.value = false;
      });
    }
  }

  @override
  void dispose() {
    Future.delayed(Duration.zero, () async {
      await trackEpisode(
          currentPosition.value, episodeDuration.value, currentEpisode.value);
    });
    player.dispose();
    if (isMobile && !settings.isTV.value) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
      ScreenBrightness().resetScreenBrightness();
    } else {
      windowManager.setFullScreen(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        alignment: Alignment.center,
        children: [
          _buildPlayer(context),
          _buildOverlay(context),
          _buildControls(),
          _buildSubtitle(),
          _buildRippleEffect(),
          Obx(() {
            if (pressed2x.value) {
              return Positioned(
                  top: 30,
                  child: Container(
                    width: 80,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.8),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        AnymexText(
                          text: "2x",
                          variant: TextVariant.semiBold,
                        ),
                        SizedBox(width: 5),
                        Icon(Icons.fast_forward)
                      ],
                    ),
                  ));
            } else {
              return const SizedBox.shrink();
            }
          }),
          if (isMobile) ...[
            _buildBrightnessSlider(),
            _buildVolumeSlider(),
          ]
        ],
      ),
    );
  }

  Obx _buildPlayer(BuildContext context) {
    return Obx(() => Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: isEpisodeDialogOpen.value
                  ? Get.width *
                      getResponsiveSize(context,
                          mobileSize: 0.6, dektopSize: 0.7, isStrict: true)
                  : Get.width,
              child: Video(
                controller: playerController,
                alignment: Alignment.center,
                controls: null,
                fit: resizeModes[resizeMode.value]!,
                subtitleViewConfiguration: const SubtitleViewConfiguration(
                  visible: false,
                ),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: isEpisodeDialogOpen.value
                  ? Get.width *
                      getResponsiveSize(context,
                          mobileSize: 0.4, dektopSize: 0.3, isStrict: true)
                  : 0,
              child: Focus(
                focusNode: FocusNode(
                    canRequestFocus: isEpisodeDialogOpen.value,
                    skipTraversal: !isEpisodeDialogOpen.value,
                    descendantsAreFocusable: isEpisodeDialogOpen.value,
                    descendantsAreTraversable: isEpisodeDialogOpen.value),
                child: EpisodeWatchScreen(
                  episodeList: episodeList.value,
                  anilistData: anilistData.value,
                  currentEpisode: currentEpisode.value,
                  onEpisodeSelected: (src, streamList, selectedEpisode) {
                    episode.value = src;
                    episodeTracks.value = streamList;
                    currentEpisode.value = selectedEpisode;
                    _initPlayer(false);
                  },
                ),
              ),
            )
          ],
        ));
  }

  Obx _buildOverlay(BuildContext context) {
    return Obx(
      () => AnimatedPositioned(
          duration: const Duration(milliseconds: 300),
          left: 0,
          top: 0,
          bottom: 0,
          right: isEpisodeDialogOpen.value
              ? Get.width *
                  getResponsiveSize(context,
                      mobileSize: 0.4, dektopSize: 0.3, isStrict: true)
              : 0,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (e) {
              pressed2x.value = true;
              player.setRate(2.0);
            },
            onLongPressEnd: (e) {
              pressed2x.value = false;
              player.setRate(1.0);
            },
            onTap: toggleControls,
            onDoubleTapDown: (e) => _handleDoubleTap(e),
            onVerticalDragUpdate: (e) async {
              if (isMobile) {
                final delta = e.delta.dy;
                final Offset position = e.localPosition;

                if (position.dx <= MediaQuery.of(context).size.width / 2) {
                  final brightness = _brightnessValue - delta / 500;
                  final result = brightness.value.clamp(0.0, 1.0);
                  setBrightness(result);
                } else {
                  final volume = _volumeValue - delta / 500;
                  final result = volume.value.clamp(0.0, 1.0);
                  setVolume(result);
                }
              }
            },
            child: AnimatedOpacity(
              curve: Curves.easeInOut,
              duration: const Duration(milliseconds: 300),
              opacity: showControls.value ? 1 : 0,
              child: Container(
                color: Colors.black.withOpacity(0.5),
              ),
            ),
          )),
    );
  }

  Obx _buildVolumeSlider() {
    return Obx(() => AnimatedOpacity(
          curve: Curves.easeInOut,
          opacity: _volumeIndicator.value ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: MediaIndicatorBuilder(
            value: _volumeValue.value,
            isVolumeIndicator: true,
          ),
        ));
  }

  Obx _buildBrightnessSlider() {
    return Obx(() => AnimatedOpacity(
          curve: Curves.easeInOut,
          opacity: _brightnessIndicator.value ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 300),
          child: MediaIndicatorBuilder(
            value: _brightnessValue.value,
            isVolumeIndicator: false,
          ),
        ));
  }

  Obx _buildSubtitle() {
    return Obx(() => AnimatedPositioned(
        right: 0,
        left: 0,
        top: 0,
        duration: const Duration(milliseconds: 100),
        bottom: showControls.value ? 100 : (30 + settings.bottomMargin),
        child: AnimatedContainer(
          alignment: Alignment.bottomCenter,
          duration: const Duration(milliseconds: 300),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                    color: subtitleText[0].isEmpty
                        ? Colors.transparent
                        : colorOptions[settings.subtitleBackgroundColor],
                    borderRadius: BorderRadius.circular(12.multiplyRadius())),
                child: Text(
                  [
                    for (final line in subtitleText)
                      if (line.trim().isNotEmpty) line.trim(),
                  ].join('\n'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: fontColorOptions[settings.subtitleColor],
                      fontSize: settings.subtitleSize.toDouble(),
                      fontFamily: "Poppins-Bold",
                      shadows: [
                        Shadow(
                          offset: const Offset(1.0, 1.0),
                          blurRadius: 10.0,
                          color:
                              fontColorOptions[settings.subtitleOutlineColor]!,
                        ),
                      ]),
                ),
              ),
            ],
          ),
        )));
  }

  Widget _buildRippleEffect() {
    return Obx(() {
      if (doubleTapLabel.value == 0) {
        return const SizedBox();
      }
      return AnimatedPositioned(
        left: isLeftSide.value ? 0 : MediaQuery.of(context).size.width / 1.5,
        width: MediaQuery.of(context).size.width / 2.5,
        top: 0,
        bottom: 0,
        duration: const Duration(milliseconds: 1000),
        child: AnimatedBuilder(
          animation: isLeftSide.value
              ? _leftAnimationController
              : _rightAnimationController,
          builder: (context, child) {
            final scale = Tween<double>(begin: 1.5, end: 1).animate(
              CurvedAnimation(
                parent: isLeftSide.value
                    ? _leftAnimationController
                    : _rightAnimationController,
                curve: Curves.easeInOut,
              ),
            );

            return GestureDetector(
              onDoubleTapDown: (t) => _handleDoubleTap(t),
              child: Opacity(
                opacity: 1.0 -
                    (isLeftSide.value
                        ? _leftAnimationController.value
                        : _rightAnimationController.value),
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.2),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(isLeftSide.value ? 0 : 100),
                      topRight: Radius.circular(isLeftSide.value ? 100 : 0),
                      bottomLeft: Radius.circular(isLeftSide.value ? 0 : 100),
                      bottomRight: Radius.circular(isLeftSide.value ? 100 : 0),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ScaleTransition(
                        scale: scale,
                        child: Icon(
                          isLeftSide.value
                              ? Icons.fast_rewind_rounded
                              : Icons.fast_forward_rounded,
                          color: Colors.white,
                          size: 40,
                        ),
                      ),
                      Container(
                        margin: const EdgeInsets.only(top: 20),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16.0,
                          vertical: 8.0,
                        ),
                        child: Text(
                          "${doubleTapLabel.value}s",
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      );
    });
  }

  void playerSettingsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      clipBehavior: Clip.antiAlias,
      isScrollControlled: true,
      builder: (context) {
        return Wrap(
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: const SettingsPlayer(isModal: true),
              ),
            ),
          ],
        );
      },
    );
  }

  showAudioSelector() {
    showModalBottomSheet(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (context) {
          return ListView(
            padding: const EdgeInsets.all(20.0),
            children: [
              const Center(
                child: AnymexText(
                  text: "Choose Audio",
                  size: 18,
                  variant: TextVariant.bold,
                ),
              ),
              const SizedBox(height: 10),
              episode.value.audios != null
                  ? const SizedBox.shrink()
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: episode.value.audios?.length ?? 0,
                      itemBuilder: (context, index) {
                        final e = episode.value.audios![index];
                        final isSelected = selectedAudioIndex.value == index;
                        return GestureDetector(
                          onTap: () {
                            selectedAudioIndex.value = index;
                            player.setAudioTrack(AudioTrack.uri(e.file!,
                                language: e.label ?? '??'));
                            Get.back();
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5.0),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  vertical: 2.5, horizontal: 10),
                              title: AnymexText(
                                text: e.label ?? '??',
                                variant: TextVariant.bold,
                                size: 16,
                                color: isSelected
                                    ? Colors.black
                                    : Theme.of(context).colorScheme.primary,
                              ),
                              tileColor: isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainer,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              trailing: Icon(
                                Iconsax.music,
                                color: isSelected
                                    ? Colors.black
                                    : Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ],
          );
        });
  }

  showTrackSelector() {
    showModalBottomSheet(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (context) {
          return ListView(
            padding: const EdgeInsets.all(20.0),
            children: [
              const Center(
                child: AnymexText(
                  text: "Choose Track",
                  size: 18,
                  variant: TextVariant.bold,
                ),
              ),
              const SizedBox(height: 10),
              ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                physics: const NeverScrollableScrollPhysics(),
                itemCount: episodeTracks.length,
                itemBuilder: (context, index) {
                  final e = episodeTracks[index];
                  final isSelected = episode.value.quality == e.quality;
                  return GestureDetector(
                    onTap: () {
                      episode.value = e;
                      player.open(Media(e.url,
                          start: currentPosition.value,
                          end: episodeDuration.value));
                      Get.back();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5.0),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 2.5, horizontal: 10),
                        title: AnymexText(
                          text: e.quality,
                          variant: TextVariant.bold,
                          size: 16,
                          color: isSelected
                              ? Colors.black
                              : Theme.of(context).colorScheme.primary,
                        ),
                        tileColor: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.surfaceContainer,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        trailing: Icon(
                          Iconsax.play5,
                          color: isSelected
                              ? Colors.black
                              : Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        });
  }

  void showSubtitleSelector() {
    showModalBottomSheet(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        builder: (context) {
          return SizedBox(
            height: MediaQuery.of(context).size.height * 0.5,
            child: ListView(
              padding: const EdgeInsets.all(20.0),
              children: [
                const Center(
                  child: AnymexText(
                    text: "Choose Subtitle",
                    size: 18,
                    variant: TextVariant.bold,
                  ),
                ),
                const SizedBox(height: 10),
                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  itemCount: subtitles.length + 2,
                  itemBuilder: (context, index) {
                    final isSelected = selectedSubIndex.value == index;
                    if (index == 0) {
                      // "None" option
                      return GestureDetector(
                        onTap: () {
                          selectedSubIndex.value = index;
                          player.setSubtitleTrack(SubtitleTrack.no());
                          Get.back();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5.0),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 2.5, horizontal: 10),
                            title: AnymexText(
                              text: "None",
                              variant: TextVariant.bold,
                              size: 16,
                              color: isSelected
                                  ? Colors.black
                                  : Theme.of(context).colorScheme.primary,
                            ),
                            tileColor: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            trailing: Icon(
                              Iconsax.subtitle5,
                              color: isSelected
                                  ? Colors.black
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      );
                    } else if (index == subtitles.length + 1) {
                      // "Add Subtitle" option
                      return GestureDetector(
                        onTap: () async {
                          final result = await FilePicker.platform.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: extensions,
                          );

                          if (result?.files.single.path != null) {
                            final file = result!.files.single;
                            final filePath = file.path!;
                            selectedSubIndex.value = index;
                            subtitles.add(
                                model.Track(file: filePath, label: file.name));
                            player.setSubtitleTrack(
                              SubtitleTrack(filePath, file.name, file.name,
                                  uri: false, data: false),
                            );
                            Get.back();
                          } else {
                            snackBar('No subtitle file selected.',
                                duration: 2000);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5.0),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 2.5, horizontal: 10),
                            title: AnymexText(
                              text: "Add Subtitle",
                              variant: TextVariant.bold,
                              size: 16,
                              color: isSelected
                                  ? Colors.black
                                  : Theme.of(context).colorScheme.primary,
                            ),
                            tileColor: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            trailing: Icon(
                              Iconsax.add,
                              color: isSelected
                                  ? Colors.black
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      );
                    } else {
                      // Existing subtitles
                      final e = subtitles[index - 1];
                      return GestureDetector(
                        onTap: () {
                          selectedSubIndex.value = index;
                          player.setSubtitleTrack(SubtitleTrack.uri(e!.file!));
                          Get.back();
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5.0),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                vertical: 2.5, horizontal: 10),
                            title: AnymexText(
                              text: e?.label ?? 'None',
                              variant: TextVariant.bold,
                              size: 16,
                              color: isSelected
                                  ? Colors.black
                                  : Theme.of(context).colorScheme.primary,
                            ),
                            tileColor: isSelected
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .surfaceContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            trailing: Icon(
                              Iconsax.subtitle5,
                              color: isSelected
                                  ? Colors.black
                                  : Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          );
        });
  }

  Widget _buildControls() {
    return Obx(() {
      return AnimatedPositioned(
        duration: const Duration(milliseconds: 300),
        left: 0,
        top: 0,
        bottom: 0,
        right: isEpisodeDialogOpen.value
            ? Get.width *
                getResponsiveSize(context,
                    mobileSize: 0.4, dektopSize: 0.3, isStrict: true)
            : 0,
        child: IgnorePointer(
          ignoring: !showControls.value,
          child: AnimatedOpacity(
            curve: Curves.easeInOut,
            opacity: showControls.value ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: Stack(
              children: [
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      // curve: Curves.,
                      transform: Matrix4.identity()
                        ..translate(0.0, showControls.value ? 0.0 : -100.0),
                      padding: EdgeInsets.symmetric(
                          vertical: 15.0,
                          horizontal: isEpisodeDialogOpen.value ? 0 : 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!isLocked.value) ...[
                            BlurWrapper(
                              child: IconButton(
                                  onPressed: () {
                                    Get.back();
                                  },
                                  icon: const Icon(
                                      Icons.arrow_back_ios_new_rounded,
                                      color: Colors.white)),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              width: getResponsiveSize(context,
                                  mobileSize: Get.width * 0.3,
                                  dektopSize: isEpisodeDialogOpen.value
                                      ? Get.width * 0.3
                                      : (Get.width * 0.6)),
                              padding: const EdgeInsets.only(top: 3.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  AnymexText(
                                    text:
                                        'Episode ${currentEpisode.value.number}: ${currentEpisode.value.title}',
                                    variant: TextVariant.semiBold,
                                    maxLines: 3,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                  AnymexText(
                                    text: anilistData.value.title.toUpperCase(),
                                    variant: TextVariant.bold,
                                    color: Colors.white.withOpacity(0.8),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const Spacer(),
                          BlurWrapper(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                if (!isLocked.value) ...[
                                  _buildIcon(
                                      onTap: () {
                                        isEpisodeDialogOpen.value =
                                            !isEpisodeDialogOpen.value;
                                        if (MediaQuery.of(context)
                                                .orientation ==
                                            Orientation.portrait) {
                                          isEpisodeDialogOpen.value = false;
                                          showModalBottomSheet(
                                              context: context,
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          20)),
                                              clipBehavior: Clip.antiAlias,
                                              builder: (context) {
                                                return EpisodeWatchScreen(
                                                  episodeList:
                                                      episodeList.value,
                                                  anilistData:
                                                      anilistData.value,
                                                  currentEpisode:
                                                      currentEpisode.value,
                                                  onEpisodeSelected: (src,
                                                      streamList,
                                                      selectedEpisode) {
                                                    episode.value = src;
                                                    episodeTracks.value =
                                                        streamList;
                                                    currentEpisode.value =
                                                        selectedEpisode;
                                                    _initPlayer(false);
                                                    isEpisodeDialogOpen.value =
                                                        false;
                                                  },
                                                );
                                              });
                                        }
                                      },
                                      icon: HugeIcons.strokeRoundedFolder03),
                                  _buildIcon(
                                      onTap: () {
                                        showPlaybackSpeedDialog(context);
                                      },
                                      icon: HugeIcons.strokeRoundedClock01),
                                ],
                                _buildIcon(
                                    onTap: () {
                                      isLocked.value = !isLocked.value;
                                    },
                                    icon: isLocked.value
                                        ? Icons.lock
                                        : Icons.lock_open),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      transform: Matrix4.identity()
                        ..translate(0.0, showControls.value ? 0.0 : 100.0),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20.0, vertical: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              AnymexTextSpans(
                                maxLines: 1,
                                spans: [
                                  AnymexTextSpan(
                                      text: '${formattedTime.value} ',
                                      variant: TextVariant.semiBold,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary),
                                  AnymexTextSpan(
                                    variant: TextVariant.semiBold,
                                    text: ' /  ${formattedDuration.value}',
                                  ),
                                ],
                              ),
                              if (!isLocked.value) _buildSkipButton(false),
                            ],
                          ),
                          IgnorePointer(
                            ignoring: isLocked.value,
                            child: SizedBox(
                              height: 27,
                              child: VideoSliderTheme(
                                child: Slider(
                                    focusNode: FocusNode(
                                        canRequestFocus: false,
                                        skipTraversal: true),
                                    min: 0,
                                    value: currentPosition.value.inMilliseconds
                                        .toDouble(),
                                    max: episodeDuration.value.inMilliseconds <=
                                            currentPosition.value.inMilliseconds
                                        ? const Duration(minutes: 200)
                                            .inMilliseconds
                                            .toDouble()
                                        : episodeDuration.value.inMilliseconds
                                            .toDouble(),
                                    secondaryTrackValue: bufferred
                                        .value.inMilliseconds
                                        .toDouble(),
                                    onChangeStart: (val) {
                                      if (episodeDuration.value.inMilliseconds
                                              .toDouble() !=
                                          0.0) {
                                        player.pause();
                                      }
                                    },
                                    onChangeEnd: (val) {
                                      if (episodeDuration.value.inMilliseconds
                                              .toDouble() !=
                                          0.0) {
                                        player.seek(Duration(
                                            milliseconds: val.toInt()));
                                        player.play();
                                      }
                                    },
                                    onChanged: (val) {
                                      if (episodeDuration.value.inMilliseconds
                                              .toDouble() !=
                                          0.0) {
                                        currentPosition.value =
                                            Duration(milliseconds: val.toInt());
                                        formattedTime.value = formatDuration(
                                            currentPosition.value);
                                      }
                                    }),
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          if (!isLocked.value)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                BlurWrapper(
                                  child: Row(
                                    children: [
                                      _buildIcon(
                                          onTap: () {
                                            playerSettingsSheet(context);
                                          },
                                          icon: HugeIcons
                                              .strokeRoundedSettings01),
                                      _buildIcon(
                                          onTap: () {
                                            showTrackSelector();
                                          },
                                          icon: HugeIcons
                                              .strokeRoundedFolderVideo),
                                      _buildIcon(
                                          onTap: () {
                                            showSubtitleSelector();
                                          },
                                          icon:
                                              HugeIcons.strokeRoundedSubtitle),
                                      if (episode.value.audios != null &&
                                          episode.value.audios!.isNotEmpty)
                                        _buildIcon(
                                            onTap: () {
                                              showAudioSelector();
                                            },
                                            icon: HugeIcons
                                                .strokeRoundedMusicNote01),
                                    ],
                                  ),
                                ),
                                BlurWrapper(
                                  child: Row(
                                    children: [
                                      if (Platform.isAndroid ||
                                          Platform.isIOS) ...[
                                        _buildIcon(
                                            onTap: () async {
                                              SystemChrome
                                                  .setPreferredOrientations([
                                                DeviceOrientation.portraitUp,
                                              ]);
                                            },
                                            icon: Icons.phone_android),
                                        _buildIcon(
                                            onTap: () async {
                                              leftOriented.value =
                                                  !leftOriented.value;
                                              if (!leftOriented.value) {
                                                SystemChrome
                                                    .setPreferredOrientations([
                                                  DeviceOrientation
                                                      .landscapeLeft,
                                                ]);
                                              } else {
                                                SystemChrome
                                                    .setPreferredOrientations([
                                                  DeviceOrientation
                                                      .landscapeRight,
                                                ]);
                                              }
                                            },
                                            icon: Icons.screen_rotation),
                                      ],
                                      _buildIcon(
                                          onTap: () {
                                            final newIndex =
                                                (resizeModeList.indexOf(
                                                            resizeMode.value) +
                                                        1) %
                                                    resizeModeList.length;
                                            resizeMode.value =
                                                resizeModeList[newIndex];
                                            snackBar(resizeMode.value);
                                          },
                                          icon: Icons.aspect_ratio_rounded),
                                      if (!Platform.isAndroid &&
                                          !Platform.isIOS)
                                        _buildIcon(
                                            onTap: () async {
                                              isFullscreen.value =
                                                  !isFullscreen.value;
                                              await windowManager.setFullScreen(
                                                  isFullscreen.value);
                                            },
                                            icon: !isFullscreen.value
                                                ? Icons.fullscreen
                                                : Icons
                                                    .fullscreen_exit_rounded),
                                    ],
                                  ),
                                ),
                              ],
                            )
                        ],
                      ),
                    )
                  ],
                ),
                if (!isLocked.value) ...[_buildPlaybackButtons()],
                if (settings.isTV.value)
                  Positioned(
                      right: 10,
                      top: MediaQuery.of(context).size.height * 0.48,
                      child: _buildIcon(icon: Icons.arrow_back_ios))
              ],
            ),
          ),
        ),
      );
    });
  }

  Widget _buildPlaybackButtons() {
    return Positioned.fill(
      child: AnimatedContainer(
        transform: Matrix4.identity()
          ..translate(0.0, showControls.value ? 0.0 : 50.0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
        alignment: Alignment.center,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.max,
          children: [
            _buildPlaybackButton(
              icon: Icons.skip_previous_rounded,
              color: currentEpisode.value.number.toInt() <= 1
                  ? Colors.grey[800]
                  : Colors.white,
              onTap: () async {
                if (currentEpisode.value.number.toInt() <= 1) {
                  snackBar(
                      "Seriously? You're trying to rewind? You haven't even made it past the intro.");
                } else {
                  await fetchEpisode(true);
                }
              },
            ),
            isBuffering.value
                ? _buildBufferingIndicator()
                : _buildPlaybackButton(
                    icon: isPlaying.value
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded,
                    onTap: () {
                      player.playOrPause();
                    },
                  ),
            _buildPlaybackButton(
              icon: Icons.skip_next_rounded,
              color: currentEpisode.value.number.toInt() >=
                      episodeList.value.last.number.toInt()
                  ? Colors.grey[800]
                  : Colors.white,
              onTap: () async {
                if (currentEpisode.value.number.toInt() >=
                    episodeList.value.last.number.toInt()) {
                  snackBar(
                      "That's it, genius. You ran out of episodes. Try a book next time.");
                } else {
                  await fetchEpisode(false);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  _buildSkipButton(bool invert) {
    return BlurWrapper(
      borderRadius: BorderRadius.circular(20.multiplyRoundness()),
      child: AnymeXButton(
        height: 50,
        width: 120,
        variant: ButtonVariant.simple,
        borderRadius: BorderRadius.circular(20.multiplyRoundness()),
        backgroundColor: Colors.transparent,
        onTap: () {
          if (invert) {
            final duration = Duration(
                seconds:
                    currentPosition.value.inSeconds - settings.skipDuration);
            if (duration.inMilliseconds < 0) {
              currentPosition.value = const Duration(milliseconds: 0);
              player.seek(const Duration(seconds: 0));
            } else {
              currentPosition.value = duration;
              player.seek(duration);
            }
          } else {
            final duration = Duration(
                seconds:
                    currentPosition.value.inSeconds + settings.skipDuration);
            currentPosition.value = duration;
            player.seek(duration);
          }
        },
        child: invert
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.fast_rewind_rounded,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 5),
                  AnymexText(
                    text: "-${settings.skipDuration}s",
                    variant: TextVariant.semiBold,
                    color: Colors.white,
                  ),
                ],
              )
            : Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnymexText(
                    text: "+${settings.skipDuration}s",
                    variant: TextVariant.semiBold,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 5),
                  const Icon(
                    Icons.fast_forward_rounded,
                    color: Colors.white,
                  )
                ],
              ),
      ),
    );
  }

  void showPlaybackSpeedDialog(BuildContext context) async {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(
          backgroundColor: Theme.of(context).colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: Container(
            width: getResponsiveValue(context,
                mobileValue: null, desktopValue: 500.0),
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Playback Speed',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.7,
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: cursedSpeed.length,
                    itemBuilder: (context, index) {
                      final e = cursedSpeed[index];

                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3.0),
                        child: _buildSpeedOption(
                            context, player, e, playbackSpeed.value),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSpeedOption(BuildContext context, Player playerController,
      double speed, double currentSpeed) {
    return ListTileWithCheckMark(
      active: speed == currentSpeed,
      leading: const Icon(Icons.speed),
      onTap: () {
        player.setRate(speed);
        Navigator.of(context).pop();
      },
      title: '${speed.toStringAsFixed(2)}x',
      color: Theme.of(context).colorScheme.primary,
    );
  }

  Widget _buildPlaybackButton(
      {required Function() onTap, IconData? icon, Color? color}) {
    final isPlay =
        icon == (Icons.play_arrow_rounded) || icon == Icons.pause_rounded;
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final padding = getResponsiveSize(context,
        mobileSize: isPlay ? 10 : 5,
        dektopSize: isPlay ? 20 : 10,
        isStrict: true);
    final radius = getResponsiveSize(context,
        mobileSize: 20.multiplyRadius(),
        dektopSize: 40.multiplyRadius(),
        isStrict: true);
    return Container(
      decoration: BoxDecoration(
        color: isPlay
            ? Theme.of(context).colorScheme.primary
            : Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: isPlay ? [glowingShadow(context)] : [],
      ),
      clipBehavior: Clip.antiAlias,
      margin:
          EdgeInsets.symmetric(horizontal: isPlay ? (isMobile ? 20 : 50) : 0),
      child: BlurWrapper(
        borderRadius: BorderRadius.circular(radius),
        child: TVWrapper(
          onTap: () {
            onTap.call();
            player.pause();
          },
          bgColor: Colors.transparent,
          focusedBorderColor: Colors.transparent,
          child: IconButton(
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radius),
              ),
              padding: EdgeInsets.all(padding),
            ),
            onPressed: onTap,
            icon: Icon(icon,
                color: isPlay ? Theme.of(context).colorScheme.onPrimary : color,
                size: getResponsiveSize(context,
                    mobileSize: 40, dektopSize: 80, isStrict: true)),
          ),
        ),
      ),
    );
  }

  Widget _buildBufferingIndicator() {
    final size = getResponsiveSize(context, mobileSize: 50, dektopSize: 70);
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal:
              getResponsiveSize(context, mobileSize: 25, dektopSize: 50)),
      child: SizedBox(
          height: size, width: size, child: const CircularProgressIndicator()),
    );
  }

  Widget _buildIcon({VoidCallback? onTap, IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5.0, vertical: 3),
      child: TVWrapper(
        onTap: () {
          onTap?.call();
          player.pause();
        },
        child: IconButton(
            onPressed: onTap,
            icon: Icon(
              icon,
              color: Colors.white,
            )),
      ),
    );
  }
}
