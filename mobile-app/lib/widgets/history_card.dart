import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../history_db.dart';

class HistoryCard extends StatelessWidget {
  final TransferHistoryItem item;
  final VoidCallback onTap;
  final VoidCallback onRetry;

  const HistoryCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final timestamp = DateTime.fromMillisecondsSinceEpoch(item.timestampMs);
    final formattedTime = DateFormat('MMM d, HH:mm:ss').format(timestamp);
    final file = File(item.filePath);

    return Material(
      color: const Color(0xFF1A1D24),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withOpacity(0.06),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              // Thumbnail Preview
              Hero(
                tag: 'history_thumb_${item.id ?? item.timestampMs}',
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 60,
                    height: 60,
                    child: FutureBuilder<bool>(
                      future: file.exists(),
                      builder: (ctx, snapshot) {
                        if (snapshot.data == true) {
                          return Image.file(
                            file,
                            fit: BoxFit.cover,
                            cacheWidth: 180,
                            errorBuilder: (_, __, ___) => _FallbackThumb(),
                          );
                        }
                        return _FallbackThumb();
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),

              // Metadata (Filename, File size, Timestamp)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          item.formattedSize,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.6),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (item.status == TransferStatus.sent &&
                            item.formattedThroughput.isNotEmpty) ...[
                          Text(
                            '  •  ',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.3),
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            item.formattedThroughput,
                            style: const TextStyle(
                              color: Color(0xFF60A5FA),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      formattedTime,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.42),
                        fontSize: 11.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              // Transfer Status Badge & One-Tap Retry Button
              _buildStatusBadge(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge() {
    switch (item.status) {
      case TransferStatus.sending:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF3B82F6).withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF3B82F6)),
                ),
              ),
              SizedBox(width: 6),
              Text(
                'Sending...',
                style: TextStyle(
                  color: Color(0xFF60A5FA),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );

      case TransferStatus.sent:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF10B981).withOpacity(0.14),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFF10B981).withOpacity(0.3),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                size: 13,
                color: Color(0xFF34D399),
              ),
              const SizedBox(width: 5),
              Text(
                'Sent in ${item.durationMs}ms',
                style: const TextStyle(
                  color: Color(0xFF34D399),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );

      case TransferStatus.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                'Failed',
                style: TextStyle(
                  color: Color(0xFFF87171),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 28,
              child: ElevatedButton.icon(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF3B82F6),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 13),
                label: const Text(
                  'Retry',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        );
    }
  }
}

class _FallbackThumb extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F1115),
      child: Icon(
        Icons.image_outlined,
        color: Colors.white.withOpacity(0.3),
        size: 26,
      ),
    );
  }
}

