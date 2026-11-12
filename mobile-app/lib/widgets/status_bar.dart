import 'package:flutter/material.dart';
import '../network_service.dart';

class ConnectionStatusBar extends StatelessWidget {
  final LaptopEndpoint? endpoint;
  final VoidCallback onOpenManualSettings;

  const ConnectionStatusBar({
    super.key,
    required this.endpoint,
    required this.onOpenManualSettings,
  });

  @override
  Widget build(BuildContext context) {
    final isConnected = endpoint != null;

    return Row(
      children: [
        // Brand Logo & Title
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(11),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3B82F6).withOpacity(0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Icon(
            Icons.bolt_rounded,
            color: Colors.white,
            size: 22,
          ),
        ),
        const SizedBox(width: 12),
        const Text(
          'InstantDrop',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: Colors.white,
          ),
        ),
        const Spacer(),

        // Status Pill
        InkWell(
          onTap: onOpenManualSettings,
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: isConnected
                  ? const Color(0xFF10B981).withOpacity(0.12)
                  : const Color(0xFFF59E0B).withOpacity(0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isConnected
                    ? const Color(0xFF10B981).withOpacity(0.38)
                    : const Color(0xFFF59E0B).withOpacity(0.38),
                width: 1,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isConnected ? '🟢' : '🟡',
                  style: const TextStyle(fontSize: 10),
                ),
                const SizedBox(width: 6),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 155),
                  child: Text(
                    isConnected
                        ? 'Connected to ${endpoint!.deviceName}'
                        : 'Searching for Laptop...',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: isConnected
                          ? const Color(0xFF34D399)
                          : const Color(0xFFFBBF24),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(
                  Icons.tune_rounded,
                  size: 14,
                  color: Colors.white.withOpacity(0.65),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Modal dialog allowing manual IP address & port override if UDP broadcast is filtered.
Future<void> showManualIpDialog({
  required BuildContext context,
  required NetworkService networkService,
}) async {
  final current = networkService.activeEndpoint;
  final ipController = TextEditingController(text: current?.ip ?? '');
  final portController = TextEditingController(
    text: (current?.tcpPort ?? NetworkService.defaultTcpPort).toString(),
  );
  final nameController = TextEditingController(
    text: (current?.isManual == true) ? current?.deviceName ?? '' : '',
  );

  await showDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        backgroundColor: const Color(0xFF1A1D24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withOpacity(0.08)),
        ),
        title: const Row(
          children: [
            Icon(Icons.lan_rounded, color: Color(0xFF3B82F6), size: 22),
            SizedBox(width: 10),
            Text(
              'Laptop Connection',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'InstantDrop automatically listens on UDP port 45454. If your router blocks UDP broadcasts, enter your laptop IP manually below.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.65),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              _DialogTextField(
                controller: ipController,
                label: 'Laptop Local IP Address',
                hint: '192.168.1.100',
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              _DialogTextField(
                controller: portController,
                label: 'TCP Port',
                hint: '45455',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 12),
              _DialogTextField(
                controller: nameController,
                label: 'Label (Optional)',
                hint: 'Studio MacBook / Desktop PC',
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        actions: [
          if (current?.isManual == true)
            TextButton(
              onPressed: () {
                networkService.clearManualEndpoint();
                Navigator.of(ctx).pop();
              },
              child: const Text(
                'Auto-Discover',
                style: TextStyle(color: Color(0xFFFBBF24)),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Cancel',
              style: TextStyle(color: Colors.white.withOpacity(0.6)),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF3B82F6),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            ),
            onPressed: () {
              final ip = ipController.text.trim();
              final port = int.tryParse(portController.text.trim()) ??
                  NetworkService.defaultTcpPort;
              if (ip.isNotEmpty) {
                networkService.setManualEndpoint(
                  ip: ip,
                  tcpPort: port,
                  customName: nameController.text.trim(),
                );
              }
              Navigator.of(ctx).pop();
            },
            child: const Text(
              'Save Endpoint',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      );
    },
  );
}

class _DialogTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;

  const _DialogTextField({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.8),
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          style: const TextStyle(color: Colors.white, fontSize: 14),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.3)),
            filled: true,
            fillColor: const Color(0xFF0F1115),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF3B82F6), width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

