import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../history_db.dart';

class PhotoPreviewScreen extends StatelessWidget {
  final TransferHistoryItem item;
  final Future<void> Function() onResend;
  final Future<void> Function() onDelete;

  const PhotoPreviewScreen({
    super.key,
    required this.item,
    required this.onResend,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final file = File(item.filePath);
    final timestamp = DateTime.fromMillisecondsSinceEpoch(item.timestampMs);
    final formattedDate = DateFormat('yyyy-MM-dd HH:mm:ss').format(timestamp);

    return Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F1115),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.filename,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${item.formattedSize}  •  $formattedDate',
              style: TextStyle(
                color: Colors.white.withOpacity(0.55),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // Interactive Image Viewer
          Expanded(
            child: Center(
              child: Hero(
                tag: 'history_thumb_${item.id ?? item.timestampMs}',
                child: FutureBuilder<bool>(
                  future: file.exists(),
                  builder: (ctx, snapshot) {
                    if (snapshot.data == true) {
                      return InteractiveViewer(
                        minScale: 0.8,
                        maxScale: 4.0,
                        child: Image.file(
                          file,
                          fit: BoxFit.contain,
                        ),
                      );
                    }
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.broken_image_rounded,
                          size: 64,
                          color: Colors.white.withOpacity(0.25),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Original file no longer in local cache',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),

          // Bottom Action Bar (Resend / Delete from History)
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1D24),
              border: Border(
                top: BorderSide(color: Colors.white.withOpacity(0.07)),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await onDelete();
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFF87171),
                        side: BorderSide(
                          color: const Color(0xFFEF4444).withOpacity(0.45),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      label: const Text(
                        'Delete from History',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        await onResend();
                        if (context.mounted) {
                          Navigator.of(context).pop();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3B82F6),
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      icon: const Icon(Icons.send_rounded, size: 19),
                      label: const Text(
                        'Resend to Laptop',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

