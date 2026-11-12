import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'history_db.dart';
import 'network_service.dart';
import 'widgets/history_card.dart';
import 'widgets/preview_screen.dart';
import 'widgets/status_bar.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0F1115),
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  runApp(const InstantDropApp());
}

class InstantDropApp extends StatelessWidget {
  const InstantDropApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InstantDrop',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1115),
        cardColor: const Color(0xFF1A1D24),
        primaryColor: const Color(0xFF3B82F6),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF3B82F6),
          secondary: Color(0xFF60A5FA),
          surface: Color(0xFF1A1D24),
          error: Color(0xFFEF4444),
        ),
        useMaterial3: true,
        fontFamily: Platform.isIOS ? '.SF Pro Display' : 'Roboto',
      ),
      home: const InstantDropHomeScreen(),
    );
  }
}

class InstantDropHomeScreen extends StatefulWidget {
  const InstantDropHomeScreen({super.key});

  @override
  State<InstantDropHomeScreen> createState() => _InstantDropHomeScreenState();
}

class _InstantDropHomeScreenState extends State<InstantDropHomeScreen> {
  final NetworkService _networkService = NetworkService();
  final ImagePicker _imagePicker = ImagePicker();
  StreamSubscription<List<SharedMediaFile>>? _shareIntentSub;

  List<TransferHistoryItem> _history = [];
  bool _isLoadingHistory = true;

  @override
  void initState() {
    super.initState();
    _networkService.addListener(_onNetworkStateChanged);
    _networkService.startDiscovery();
    _loadHistory();
    _initShareSheetListener();
  }

  void _onNetworkStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadHistory() async {
    final items = await HistoryDatabase.instance.fetchAllHistory();
    if (!mounted) return;
    setState(() {
      _history = items;
      _isLoadingHistory = false;
    });
  }

  /// Configures `receive_sharing_intent` so photos shared from the native Android/iOS Gallery
  /// are immediately queued and streamed to the laptop over TCP.
  void _initShareSheetListener() {
    // 1. Handle photos shared while the app is already running in memory
    _shareIntentSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (List<SharedMediaFile> sharedFiles) {
        if (sharedFiles.isNotEmpty) {
          _handleSharedFiles(sharedFiles);
        }
      },
      onError: (Object err) {
        debugPrint('[ShareIntent] Stream error: $err');
      },
    );

    // 2. Handle photos shared when the app was cold-launched from the OS share sheet
    ReceiveSharingIntent.instance.getInitialMedia().then(
      (List<SharedMediaFile> sharedFiles) {
        if (sharedFiles.isNotEmpty) {
          _handleSharedFiles(sharedFiles);
          ReceiveSharingIntent.instance.reset();
        }
      },
    );
  }

  Future<void> _handleSharedFiles(List<SharedMediaFile> sharedFiles) async {
    // Wait briefly on cold start to allow UDP beacon discovery if not yet connected
    if (!_networkService.isConnected) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }

    final filesToSend = <File>[];
    for (final media in sharedFiles) {
      if (media.path.isNotEmpty) {
        filesToSend.add(File(media.path));
      }
    }

    if (filesToSend.isNotEmpty) {
      await _queueAndSendFiles(filesToSend);
    }
  }

  /// Captures a photo using the camera and immediately streams it to the laptop.
  Future<void> _onTakePhotoPressed() async {
    try {
      final XFile? captured = await _imagePicker.pickImage(
        source: ImageSource.camera,
        // Do not re-compress or alter image quality
        requestFullMetadata: true,
      );
      if (captured == null) return;

      final timestampStr = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final ext = p.extension(captured.path).isNotEmpty
          ? p.extension(captured.path)
          : '.jpg';
      final cleanFilename = 'IMG_$timestampStr$ext';

      await _sendSingleFile(
        File(captured.path),
        overrideFilename: cleanFilename,
      );
    } catch (e) {
      _showSnackBar('Camera error: $e', isError: true);
    }
  }

  /// Opens native multi-select gallery picker and batch-streams selected photos.
  Future<void> _onPickFromGalleryPressed() async {
    try {
      final List<XFile> pickedFiles = await _imagePicker.pickMultiImage(
        requestFullMetadata: true,
      );
      if (pickedFiles.isEmpty) return;

      final files = pickedFiles.map((x) => File(x.path)).toList();
      await _queueAndSendFiles(files);
    } catch (e) {
      _showSnackBar('Gallery picker error: $e', isError: true);
    }
  }

  Future<void> _queueAndSendFiles(List<File> files) async {
    for (final file in files) {
      await _sendSingleFile(file);
    }
  }

  /// Creates a local history record, executes the raw binary TCP transfer, and updates SQLite.
  Future<void> _sendSingleFile(
    File file, {
    String? overrideFilename,
    TransferHistoryItem? existingRecord,
  }) async {
    final exists = await file.exists();
    final fileSize = exists ? await file.length() : 0;
    final filename = overrideFilename ??
        existingRecord?.filename ??
        p.basename(file.path);

    TransferHistoryItem workingItem;

    if (existingRecord != null) {
      workingItem = existingRecord.copyWith(
        status: TransferStatus.sending,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
      );
      await HistoryDatabase.instance.updateRecord(workingItem);
      _replaceItemInState(workingItem);
    } else {
      final draft = TransferHistoryItem(
        filename: filename,
        filePath: file.path,
        fileSizeBytes: fileSize,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        status: TransferStatus.sending,
        durationMs: 0,
        targetDevice: _networkService.activeEndpoint?.deviceName,
      );
      workingItem = await HistoryDatabase.instance.insertRecord(draft);
      if (mounted) {
        setState(() {
          _history.insert(0, workingItem);
        });
      }
    }

    final result = await _networkService.sendPhotoFile(
      file: file,
      filename: filename,
    );

    final updatedItem = workingItem.copyWith(
      status: result.success ? TransferStatus.sent : TransferStatus.failed,
      durationMs: result.elapsedMs,
      fileSizeBytes: result.fileSizeBytes > 0 ? result.fileSizeBytes : fileSize,
      targetDevice: _networkService.activeEndpoint?.deviceName,
      errorMessage: result.errorMessage,
    );

    await HistoryDatabase.instance.updateRecord(updatedItem);
    _replaceItemInState(updatedItem);

    if (!result.success && mounted) {
      _showSnackBar(
        result.errorMessage ?? 'Transfer failed',
        isError: true,
      );
    }
  }

  void _replaceItemInState(TransferHistoryItem updated) {
    if (!mounted) return;
    setState(() {
      final idx = _history.indexWhere((e) => e.id == updated.id);
      if (idx != -1) {
        _history[idx] = updated;
      }
    });
  }

  Future<void> _deleteHistoryItem(TransferHistoryItem item) async {
    if (item.id != null) {
      await HistoryDatabase.instance.deleteRecord(item.id!);
    }
    if (!mounted) return;
    setState(() {
      _history.removeWhere((e) => e.id == item.id);
    });
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor:
            isError ? const Color(0xFFEF4444) : const Color(0xFF1A1D24),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(
          message,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _shareIntentSub?.cancel();
    _networkService.removeListener(_onNetworkStateChanged);
    _networkService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: SafeArea(
        child: Column(
          children: [
            // Top Status Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 12),
              child: ConnectionStatusBar(
                endpoint: _networkService.activeEndpoint,
                onOpenManualSettings: () => showManualIpDialog(
                  context: context,
                  networkService: _networkService,
                ),
              ),
            ),

            // Section Header for Transfer History Feed
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
              child: Row(
                children: [
                  Text(
                    'TRANSFER HISTORY',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1D24),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${_history.length}',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (_history.isNotEmpty)
                    TextButton(
                      onPressed: () async {
                        await HistoryDatabase.instance.clearAllHistory();
                        if (mounted) {
                          setState(() => _history.clear());
                        }
                      },
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        foregroundColor: Colors.white.withOpacity(0.45),
                      ),
                      child: const Text(
                        'Clear All',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),

            // Main Screen Body: Chronological Transfer History Feed
            Expanded(
              child: _isLoadingHistory
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF3B82F6),
                      ),
                    )
                  : _history.isEmpty
                      ? _buildEmptyState()
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
                          itemCount: _history.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (context, index) {
                            final item = _history[index];
                            return HistoryCard(
                              item: item,
                              onRetry: () => _sendSingleFile(
                                File(item.filePath),
                                existingRecord: item,
                              ),
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => PhotoPreviewScreen(
                                      item: item,
                                      onResend: () => _sendSingleFile(
                                        File(item.filePath),
                                        existingRecord: item,
                                      ),
                                      onDelete: () => _deleteHistoryItem(item),
                                    ),
                                  ),
                                );
                              },
                            );
                          },
                        ),
            ),

            // Primary Action Area (Bottom Hero Section)
            _buildPrimaryActionArea(),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFF1A1D24),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white.withOpacity(0.06)),
              ),
              child: Icon(
                Icons.wifi_tethering_rounded,
                size: 34,
                color: const Color(0xFF3B82F6).withOpacity(0.85),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'Ready for Instant Drop',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Take a photo, pick from your gallery, or share directly from your OS Photo Gallery to beam original files over LAN.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withOpacity(0.5),
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPrimaryActionArea() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D24),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.07), width: 1),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Row(
        children: [
          // "Take Photo" Button
          Expanded(
            child: SizedBox(
              height: 58,
              child: ElevatedButton.icon(
                onPressed: _onTakePhotoPressed,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3B82F6),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.camera_alt_rounded, size: 22),
                label: const Text(
                  'Take Photo',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),

          // "Pick from Gallery" Button
          Expanded(
            child: SizedBox(
              height: 58,
              child: OutlinedButton.icon(
                onPressed: _onPickFromGalleryPressed,
                style: OutlinedButton.styleFrom(
                  backgroundColor: const Color(0xFF0F1115),
                  foregroundColor: Colors.white,
                  side: BorderSide(
                    color: const Color(0xFF3B82F6).withOpacity(0.5),
                    width: 1.4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(
                  Icons.photo_library_rounded,
                  size: 21,
                  color: Color(0xFF60A5FA),
                ),
                label: const Text(
                  'Pick Gallery',
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

